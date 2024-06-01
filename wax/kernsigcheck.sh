#!/usr/bin/env bash

set -eE

KEYFILE=lib/mp-reco-2024-05-03.txt

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

missing_deps=$(check_deps sfdisk futility)
[ "$missing_deps" ] && fail "The following required commands weren't found in PATH:\n${missing_deps}"

cleanup() {
	[ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" || :
	[ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
	trap - EXIT INT
}

check_kern() {
	local total i verify_result name type ver fsum flags ksum
	echo "$1"
	if ! verify_result=$(futility vbutil_kernel --verify "$1" 2>/dev/null); then
		echo "Did not pass hash verification (invalid)"
		return 1
	fi
	flags=$(echo "$verify_result" | grep -m 1 "Flags:" | sed "s/\s*Flags:\s*//g")
	ksum=$(echo "$verify_result" | grep -m 1 "Data key sha1sum:" | sed "s/\s*Data key sha1sum:\s*//g")
	echo "Allowed boot mode flags: $flags"
	echo "Kernel key sum: $ksum"
	total=$(wc -l "$KEYFILE" | awk '{print $1}')
	i=1
	while read keyline; do
		printf "\rTrying key $i/$total  "
		echo "$keyline" | awk -F ';' '{print $6}' | base64 -d >"$WORKDIR"/key.vbpubk
		if futility vbutil_kernel --verify "$1" --signpubkey "$WORKDIR"/key.vbpubk >/dev/null 2>&1; then
			name=$(echo "$keyline" | awk -F ';' '{print $1}')
			type=$(echo "$keyline" | awk -F ';' '{print $2}')
			ver=$(echo "$keyline" | awk -F ';' '{print $3}')
			fsum=$(echo "$keyline" | awk -F ';' '{print $5}')
			echo ""
			echo "Verified by key: $name $type v$ver"
			echo "Will boot on firmware with gbb.recovery_key: $fsum"
			if [ "$name" = developer ]; then
				echo "WARNING: Developer key detected. CTRL+U boot only."
			fi
			break
		fi
		if [ $i -eq $total ]; then
			echo ""
			echo "Not verified by any known recovery key."
			break
		fi
		: $((i++))
	done <"$KEYFILE"
}

trap 'echo $BASH_COMMAND failed with exit code $?.' ERR
trap 'cleanup; exit' EXIT
trap 'echo Abort.; cleanup; exit' INT

[ -z "$1" ] && fail "Usage: $0 <image|kern>"
[ -b "$1" -o -f "$1" ] || fail "$1 doesn't exist or is not a file or block device"
[ -r "$1" ] || fail "Cannot read $1, try running as root?"
[ -f "$KEYFILE" ] || fail "Could not find required key list at $KEYFILE"
IMAGE="$1"
WORKDIR=$(mktemp -d)

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
