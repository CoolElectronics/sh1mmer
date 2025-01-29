#!/usr/bin/env bash

set -eE

fail() {
	printf "%s\n" "$*" >&2
	exit 1
}

readlink /proc/$$/exe | grep -q bash || fail "Please run with bash"

check_deps() {
	for dep in "$@"; do
		command -v "$dep" &>/dev/null || echo "$dep"
	done
}

missing_deps=$(check_deps sfdisk tar file jq zcat tune2fs)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

cleanup() {
	[ -d "$WORKDIR"/mnt ] && umount "$WORKDIR"/mnt 2>/dev/null || :
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	[ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
	trap - EXIT INT
}

HAS_CROS_PAYLOADS=0

MODELS=
HWIDS=()
RELEASE_IMAGE=
TEST_IMAGE=
TOOLKIT=
ROOTFS_VERSION=
KERNEL_VERSION=
FRECON=0
LAST_MOUNTED=
DUMPED=0

fancy_bool() {
	if [ $1 -ge 1 ]; then
		echo "yes"
	else
		echo "no"
	fi
}

is_ext2() {
	local rootfs="$1"
	local offset="${2-0}"

	local sb_magic_offset=$((0x438))
	local sb_value=$(dd if="$rootfs" skip=$((offset + sb_magic_offset)) \
		count=2 bs=1 2>/dev/null | tr -d '\0')
	local expected_sb_value=$(printf '\123\357')
	if [ "$sb_value" = "$expected_sb_value" ]; then
		return 0
	fi
	return 1
}

get_hwids() {
	local file
	for file in "$@"; do
		[ -f "$file" ] || continue
		mkdir "$WORKDIR"/extract
		cat "$file" >"$WORKDIR"/hwid
		chmod +x "$WORKDIR"/hwid
		"$WORKDIR"/hwid -n -d "$WORKDIR"/extract >/dev/null 2>&1 || "$WORKDIR"/hwid "$WORKDIR"/extract >/dev/null || :
		find "$WORKDIR"/extract -type f -printf "%f\n" | grep "^[A-Z0-9-]*$"
		rm -rf "$WORKDIR"/extract "$WORKDIR"/hwid
	done
}

check_stateful() {
	#echo "STATE p$2"
	local board json toolkit_file active_test_list hwid_bundle
	LAST_MOUNTED=$(tune2fs -l "$1" | grep "^Last mounted on:" | awk '{print $4}')
	if [ "$LAST_MOUNTED" = /stateful ]; then
		DUMPED=1
	fi
	mount -o ro "$1" "$WORKDIR"/mnt
	if [ -d "$WORKDIR"/mnt/dev_image/factory/py/test/test_lists ]; then
		MODELS=$(grep -PzorIh -m1 "\(('ro',)? *'model_name',[^\[]*\[\K[^\]]*" "$WORKDIR"/mnt/dev_image/factory/py/test/test_lists | tr -d '\n\0')
	fi
	if [ -d "$WORKDIR"/mnt/dev_image/factory/hwid ]; then
		HWIDS+=($(find "$WORKDIR"/mnt/dev_image/factory/hwid -type f -printf "%f\n" | grep "^[A-Z0-9-]*$"))
	fi
	if [ -f "$WORKDIR"/mnt/dev_image/factory/TOOLKIT_VERSION ]; then
		TOOLKIT=$(head -n 1 "$WORKDIR"/mnt/dev_image/factory/TOOLKIT_VERSION)
	fi
	if [ -d "$WORKDIR"/mnt/cros_payloads ]; then
		HAS_CROS_PAYLOADS=1
		if [ -f "$WORKDIR"/mnt/cros_payloads/rma_metadata.json ]; then
			board=$(jq -r "first.board" "$WORKDIR"/mnt/cros_payloads/rma_metadata.json)
			json="$WORKDIR"/mnt/cros_payloads/"$board".json
		else
			json=$(find "$WORKDIR"/mnt/cros_payloads -maxdepth 1 -type f -name "*.json" -print -quit)
		fi
		RELEASE_IMAGE=$(jq -r ".release_image.version" "$json")
		TEST_IMAGE=$(jq -r ".test_image.version" "$json")
		TOOLKIT=$(jq -r ".toolkit.version" "$json" | head -n 1)
		toolkit_file=$(jq -r ".toolkit.file" "$json")
		if [ -f "$WORKDIR"/mnt/cros_payloads/"$toolkit_file" ]; then
			mkdir "$WORKDIR"/extract2
			zcat "$WORKDIR"/mnt/cros_payloads/"$toolkit_file" >"$WORKDIR"/toolkit
			chmod +x "$WORKDIR"/toolkit
			"$WORKDIR"/toolkit --quiet --noexec --target "$WORKDIR"/extract2
			HWIDS+=($(get_hwids "$WORKDIR"/extract2/usr/local/factory/py/hwidfile/*.sh))
			if [ -d "$WORKDIR"/extract2/usr/local/factory/hwid ]; then
				HWIDS+=($(find "$WORKDIR"/extract2/usr/local/factory/hwid -type f -printf "%f\n" | grep "^[A-Z0-9-]*$"))
			fi
			if [ -f "$WORKDIR"/extract2/usr/local/factory/py/test/test_lists/active_test_list.json ]; then
				active_test_list=$(jq -r ".id" "$WORKDIR"/extract2/usr/local/factory/py/test/test_lists/active_test_list.json)
				MODELS=$(grep -Pzo -m1 '"(vpd.ro.model_name|serials.model_name)"[^\[]*\[\K[^\]]*' "$WORKDIR"/extract2/usr/local/factory/py/test/test_lists/"$active_test_list".test_list.json | tr -d '\n\0')
			else
				MODELS=$(grep -PzorIh -m1 '"(vpd.ro.model_name|serials.model_name)"[^\[]*\[\K[^\]]*' "$WORKDIR"/extract2/usr/local/factory/py/test/test_lists | tr -d '\n\0')
			fi
			rm -rf "$WORKDIR"/extract2 "$WORKDIR"/toolkit
		fi
		hwid_bundle=$(jq -r ".hwid.file" "$json")
		if [ -f "$WORKDIR"/mnt/cros_payloads/"$hwid_bundle" ]; then
			zcat "$WORKDIR"/mnt/cros_payloads/"$hwid_bundle" >"$WORKDIR"/hwid_dec
			HWIDS+=($(get_hwids "$WORKDIR"/hwid_dec))
			rm -f "$WORKDIR"/hwid_dec
		fi
	fi
	MODELS=$(echo "$MODELS" | sed "s/^ *[\"']//;s/[\"'] *$//;s/--/,/g;s/[\"'] *,\{0,1\} *[\"']/\n/g" | sort | uniq | sed "s/$/, /" | tr -d '\n' | head -c -2)
	HWIDS=$(printf '%s\n' "${HWIDS[@]}" | sort | uniq | sed "s/$/, /" | tr -d '\n' | head -c -2)
	umount "$WORKDIR"/mnt
}

check_rootfs() {
	is_ext2 "$1" || return
	#echo "ROOTFS p$2"
	if [ $HAS_CROS_PAYLOADS -eq 1 ] && [ $2 -ne 3 ]; then
		fail "Multi-board/universal images not supported"
	fi
	local version modules_path
	mount -o ro "$1" "$WORKDIR"/mnt
	if [ -f "$WORKDIR"/mnt/etc/lsb-release ]; then
		if version="$(grep -m 1 "^CHROMEOS_RELEASE_DESCRIPTION=" "$WORKDIR"/mnt/etc/lsb-release)"; then
			version=$(echo "$version" | cut -d "=" -f 2)
		fi
	fi
	case $2 in
		3)
			ROOTFS_VERSION="$version"
			modules_path=$(echo "$WORKDIR"/mnt/lib/modules/* | head -n 1)
			if [ -d "$modules_path" ]; then
				KERNEL_VERSION=$(basename "$modules_path") || :
			fi
			if [ -f "$WORKDIR"/mnt/usr/sbin/factory_tty.sh ]; then
				FRECON=1
			fi
			;;
		5) TEST_IMAGE="$version" ;;
		7) RELEASE_IMAGE="$version" ;;
	esac
	umount "$WORKDIR"/mnt
}

trap 'echo $BASH_COMMAND failed with exit code $?.' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

IMAGE="$1"
WORKDIR=$(mktemp -d)
mkdir "$WORKDIR"/mnt
[ -z "$1" ] && fail "Usage: $0 <image>"
[ "$EUID" -ne 0 ] && fail "Please run as root"
[ -b "$1" -o -f "$1" ] || fail "$1 doesn't exist or is not a file or block device"
sfdisk -l "$IMAGE" 2>/dev/null | grep -q "Disklabel type: gpt" || fail "$IMAGE is not GPT, or is corrupted"

echo "$IMAGE"
LOOPDEV=$(losetup -f)
losetup -r -P "$LOOPDEV" "$IMAGE"
table=$(sfdisk -d "$LOOPDEV" 2>/dev/null | grep "^$LOOPDEV")
for part in $(echo "$table" | awk '{print $1}'); do
	entry=$(echo "$table" | grep "^${part}\s")
	echo "$entry" | grep -q 'name="OEM"' && continue
	num=$(echo "$part" | grep -o "[0-9]*$")
	sectors=$(echo "$entry" | grep -o "size=[^,]*" | awk -F '[ =]' '{print $NF}')
	[ "$sectors" -gt 1 ] || continue
	type=$(echo "$entry" | grep -o "type=[^,]*" | awk -F '[ =]' '{print $NF}' | tr '[:lower:]' '[:upper:]')
	if [ $num -eq 1 ]; then
		if [ "$type" = "0FC63DAF-8483-4772-8E79-3D69D8477DE4" ] || [ "$type" = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" ]; then
			check_stateful "$part" "$num" || :
		fi
	elif [ "$type" = "3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC" ] || [ "$type" = "0FC63DAF-8483-4772-8E79-3D69D8477DE4" ] || [ "$type" = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" ]; then
		check_rootfs "$part" "$num" || :
	fi
done

echo "Models: $MODELS"
echo "HWIDs: $HWIDS"
echo "Release image: $RELEASE_IMAGE"
echo "Test image: $TEST_IMAGE"
echo "Toolkit: $TOOLKIT"
echo "Rootfs version: $ROOTFS_VERSION"
echo "Kernel version: $KERNEL_VERSION"
echo "Last mounted on: $LAST_MOUNTED"
echo "Dumped from USB drive: $(fancy_bool $DUMPED)"
echo "Uses cros_payloads: $(fancy_bool $HAS_CROS_PAYLOADS)"
echo "Frecon: $(fancy_bool $FRECON)"
