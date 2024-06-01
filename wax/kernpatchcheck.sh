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

missing_deps=$(check_deps sfdisk futility binwalk lz4 file)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

cleanup() {
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	[ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
	trap - EXIT INT
}

is_linux_kernel() {
	file -b "$1" | grep -q "^Linux kernel"
}

check_kern() {
	local binwalk_pid lz4_offset cpio_root
	echo "$1"
	echo "Extracting kernel"
	futility vbutil_kernel --get-vmlinuz "$1" --vmlinuz-out "$WORKDIR"/vmlinuz
	# did we actually get the vmlinuz? if not, it's probably an arm kernel (extra steps)
	if ! is_linux_kernel "$WORKDIR"/vmlinuz; then
		mkfifo "$WORKDIR"/binwalk_out
		binwalk "$1" >"$WORKDIR"/binwalk_out &
		binwalk_pid="$!"
		lz4_offset=$(grep -m 1 "LZ4 compressed data" "$WORKDIR"/binwalk_out | awk '{print $1}')
		kill "$binwalk_pid"
		rm "$WORKDIR"/binwalk_out "$WORKDIR"/vmlinuz
		dd if="$1" bs=4096 iflag=skip_bytes,count_bytes skip="${lz4_offset:-0}" | lz4 -q -d - "$WORKDIR"/vmlinuz || :
	fi
	if ! is_linux_kernel "$WORKDIR"/vmlinuz; then
		echo "Could not extract linux kernel from KERN blob."
		return 2
	fi
	echo "Extracting initramfs"
	mkdir "$WORKDIR"/extract
	trap "rm -rf \"$WORKDIR\"/extract; trap - RETURN" RETURN
	binwalk --run-as="$USER" -MreqC "$WORKDIR"/extract "$WORKDIR"/vmlinuz 2>/dev/null || :
	cpio_root=$(find "$WORKDIR"/extract -type d -name "cpio-root" -print -quit) || :
	if [ -z "$cpio_root" ]; then
		echo "Could not extract initramfs."
		return 2
	fi
	if ! [ -f "$cpio_root"/bin/bootstrap.sh ]; then
		echo "Missing /bin/bootstrap.sh, cannot determine patch."
		return 2
	fi
	if grep -q "block_devmode" "$cpio_root"/bin/bootstrap.sh; then
		echo "WARNING: initramfs appears to check block_devmode in crossystem."
		echo "Disable WP to bypass, or hope that crossystem is broken (e.g. hana)"
	fi
	if grep -q "Mounting usb..." "$cpio_root"/bin/bootstrap.sh; then
		echo "Not patched!"
		return 0
	elif grep -q "Mounting rootfs..." "$cpio_root"/bin/bootstrap.sh; then
		echo "Patched (forced rootfs verification)"
		return 1
	else
		echo "Cannot determine patch."
		return 2
	fi
}

trap 'echo $BASH_COMMAND failed with exit code $?.' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

[ -z "$1" ] && fail "Usage: $0 <image|kern>"
[ -b "$1" -o -f "$1" ] || fail "$1 doesn't exist or is not a file or block device"
[ -r "$1" ] || fail "Cannot read $1, try running as root?"
IMAGE="$1"
WORKDIR=$(mktemp -d)
[ -z "$SUDO_USER" ] || USER="$SUDO_USER"

if sfdisk -l "$IMAGE" 2>/dev/null | grep -q "Disklabel type: gpt"; then
	[ "$EUID" -ne 0 ] && fail "Please run as root for whole shim images"
	LOOPDEV=$(losetup -f)
	losetup -r -P "$LOOPDEV" "$IMAGE"
	table=$(sfdisk -d "$LOOPDEV" 2>/dev/null | grep "^$LOOPDEV")
	for part in $(echo "$table" | awk '{print $1}'); do
		entry=$(echo "$table" | grep "^${part}\s")
		sectors=$(echo "$entry" | grep -o "size=[^,]*" | awk -F '[ =]' '{print $NF}')
		type=$(echo "$entry" | grep -o "type=[^,]*" | awk -F '[ =]' '{print $NF}' | tr '[:lower:]' '[:upper:]')
		if [ "$type" = "FE3A2A5D-4F32-41A7-B725-ACCC3285A309" ] && [ "$sectors" -gt 1 ]; then
			check_kern "$part" || :
			echo ""
		fi
	done
else
	check_kern "$IMAGE" || :
fi
