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

missing_deps=$(check_deps sfdisk futility binwalk lz4 zcat file cpio)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

cleanup() {
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	[ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
	trap - EXIT INT
}

is_linux_kernel() {
	file -b "$1" | grep -q "^Linux kernel"
}

binwalk_grep() {
	local err fifo binwalk_pid bin_line
	err=0
	fifo=$(mktemp -u)
	mkfifo "$fifo"
	binwalk "$1" >"$fifo" &
	binwalk_pid="$!"
	bin_line=$(grep -m 1 "$2" "$fifo")
	if [ -z "$bin_line" ]; then
		err=1
	else
		kill "$binwalk_pid"
		echo "$bin_line"
	fi
	rm "$fifo"
	return "$err"
}

check_kern() {
	local bin_line bin_offset cpio_root check_file mount_file
	echo "$1"
	echo "Extracting kernel"
	futility vbutil_kernel --get-vmlinuz "$1" --vmlinuz-out "$WORKDIR"/vmlinuz
	# did we actually get the vmlinuz?
	if ! is_linux_kernel "$WORKDIR"/vmlinuz; then
		rm "$WORKDIR"/vmlinuz
		if ! bin_line=$(binwalk_grep "$1" "\(Linux kernel\|LZ4 compressed data\|gzip compressed data\)"); then
			echo "Could not extract linux kernel from KERN blob."
			return 2
		fi
		bin_offset=$(echo "$bin_line" | awk '{print $1}')
		dd if="$1" of="$WORKDIR"/bin bs=4MiB iflag=skip_bytes skip="${bin_offset:-0}" 2>/dev/null
		case "$bin_line" in
			*"Linux kernel"*) mv "$WORKDIR"/bin "$WORKDIR"/vmlinuz ;; # there will be trailing garbage data
			*"LZ4 compressed data"*)
				lz4 -q -d "$WORKDIR"/bin "$WORKDIR"/vmlinuz || :
				if ! is_linux_kernel "$WORKDIR"/vmlinuz; then
					echo "Could not extract linux kernel from KERN blob."
					return 2
				fi
				;;
			*"gzip compressed data"*)
				zcat -q "$WORKDIR"/bin >"$WORKDIR"/bin2 || :
				if ! bin_line=$(binwalk_grep "$WORKDIR"/bin2 "Linux kernel"); then
					echo "Could not extract linux kernel from KERN blob."
					return 2
				fi
				bin_offset=$(echo "$bin_line" | awk '{print $1}')
				# there will be trailing garbage data
				dd if="$WORKDIR"/bin2 of="$WORKDIR"/vmlinuz bs=4MiB iflag=skip_bytes skip="${bin_offset:-0}" 2>/dev/null
				;;
		esac
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
	for f in $(find "$cpio_root"/../.. -maxdepth 1 -type f); do
		if file -b "$f" | grep -qw "cpio"; then
			(cd "$WORKDIR"; cpio -im lib <"$f" 2>/dev/null)
			echo -n "Initramfs date: "
			date -ur "$WORKDIR"/lib
			rm -rf "$WORKDIR"/lib
			break
		fi
	done
	if [ -f "$cpio_root"/bin/bootstrap.sh ]; then
		check_file=/bin/bootstrap.sh
		mount_file=/bin/bootstrap.sh
	else
		check_file=/lib/factory_init.sh
		mount_file=/init
	fi
	if ! [ -f "$cpio_root$mount_file" ]; then
		echo "Missing /bin/bootstrap.sh, cannot determine patch."
		return 2
	fi
	if grep -q "block_devmode" "$cpio_root$check_file"; then
		echo "WARNING: initramfs appears to check block_devmode in crossystem."
		echo "Disable WP to bypass, or hope that crossystem is broken (hana/elm)"
	fi
	if grep -q "Mounting usb" "$cpio_root$mount_file"; then
		echo "Not patched!"
		return 0
	elif grep -q "Mounting rootfs..." "$cpio_root$mount_file"; then
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
