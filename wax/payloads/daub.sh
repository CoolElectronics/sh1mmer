#!/bin/bash
# DAUB - Depthcharge Automatic Update Blocker - Written with love by Hannah <3

function panic() {
    echo -ne "\e[1;31mFatal Error: $1\e[0m"
    sleep 1
    exit 1
}

function get_largest_cros_blockdev() {
	local largest size dev_name tmp_size remo
	size=0
	for blockdev in /sys/block/*; do
		dev_name="${blockdev##*/}"
		echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
		tmp_size=$(cat "$blockdev"/size)
		remo=$(cat "$blockdev"/removable)
		if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
			case "$(sfdisk -d "/dev/$dev_name" 2>/dev/null)" in
				*'name="STATE"'*'name="KERN-A"'*'name="ROOT-A"'*)
					largest="/dev/$dev_name"
					size="$tmp_size"
					;;
			esac
		fi
	done
	echo "$largest"
}

function find_inactive_parts() {
    local disk="$1"
    local kern_a_priority=$(cgpt show "$disk" -i 2 -P)

    if [ "$kern_a_priority" == "1" ] || [ "$kern_a_priority" == "2" ]; then
        inactive_kern=4
        inactive_root=5
    else
        inactive_kern=2
        inactive_root=3
    fi
}

function main() {
    local disk=$(get_largest_cros_blockdev)
    [ -z "$disk" ] && panic "No CrOS SSD found on device!"

    echo "Searching for inactive partitions."
    find_inactive_parts "$disk"

    echo "Deleting updatable partitions."
    (
        echo "d"
        echo "$inactive_kern"
        echo "d"
        echo "$inactive_root"

        echo "w"
    ) | fdisk "$disk" 2>/dev/null

    echo "Formatting stateful."
    mkfs.ext4 -F -b 4096 -L H-STATE "${disk}p1" >/dev/null 2>&1

    echo "Done!"
    return 0
}

if [ "$0" == "$BASH_SOURCE" ]; then
    main "$@"
fi
