#!/bin/bash

. /usr/sbin/sh1mmer_gui.sh
. /usr/sbin/sh1mmer_optionsSelector.sh

get_largest_blockdev() {
	local largest size dev_name tmp_size remo
	size=0
	for blockdev in /sys/block/*; do
		dev_name="${blockdev##*/}"
		echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
		tmp_size=$(cat "$blockdev"/size)
		remo=$(cat "$blockdev"/removable)
		if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
			largest="/dev/$dev_name"
			size="$tmp_size"
		fi
	done
	echo "$largest"
}

get_largest_cros_blockdev() {
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

format_part_number() {
	echo -n "$1"
	echo "$1" | grep -q '[0-9]$' && echo -n p
	echo "$2"
}

deprovision() {
	vpd -i RW_VPD -s check_enrollment=0
	unblock_devmode
}

reprovision() {
	vpd -i RW_VPD -s check_enrollment=1
}

usb() {
	crossystem dev_boot_usb=1
}

fix_gbb() {
	/usr/share/vboot/bin/set_gbb_flags.sh 0x0
}

disable_verity() {
	local cros_dev="$(get_largest_cros_blockdev)"
	if [ -z "$cros_dev" ]; then
		echo "No CrOS SSD found on device!"
		return 1
	fi
	echo "READ THIS!!!!!! DON'T BE STUPID"
	echo "This script will disable rootfs verification. What does this mean? You'll be able to edit any file on the chromebook, useful for development, messing around, etc"
	echo "IF YOU DO THIS AND GO BACK INTO VERIFIED MODE (press the space key when it asks you to on the boot screen) YOUR CHROMEBOOK WILL STOP WORKING AND YOU WILL HAVE TO RECOVER"
	echo ""
	echo "This will disable rootfs verification on ${cros_dev} ..."
	sleep 4
	echo "Do you still want to do this? (y/N)"
	read -r action
	case "$action" in
		[yY]) : ;;
		*) return ;;
	esac
	/usr/share/vboot/bin/make_dev_ssd.sh -i "$cros_dev" --remove_rootfs_verification
}

unblock_devmode() {
	local res
	vpd -i RW_VPD -s block_devmode=0
	crossystem block_devmode=0
	if [ -e /etc/init/tcsd.conf ]; then
		initctl stop tcsd || :
		if tpmc getp 0x100a >/dev/null 2>&1; then
			tpmc clear
			tpmc def 0x100a 0x28 0x12000
			tpmc write 0x100a 76 28 10 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
		fi
	else
		res=$(cryptohome --action=get_firmware_management_parameters 2>&1)
		if [ $? -eq 0 ] && ! echo "$res" | grep -q "Unknown action"; then
			tpm_manager_client take_ownership
			cryptohome --action=remove_firmware_management_parameters
		fi
	fi
}

shell() {
	cleanup
	echo "You can su chronos if you need to use chromebrew"
	bash
	setup
}

runtask() {
	# are you happy now?!
	# no, i am not YOU USED IT WRONG!!! -r58Playz
	showbg terminalGeneric.png

	curidx=0
	movecursor_generic $curidx # you need to put in a number!
	echo "Starting task $1"
	sleep 2
	curidx=1
	if "$1"; then
		movecursor_generic $curidx # ya forgot it here
		echo "Task $1 succeeded."
		sleep 3
	else
		# movecursor_generic $curidx # ya forgot it here
		# NO I DIDN'T! i wasn't skidding, the issue i told you would happen did happen! -ce
		read -p "THERE WAS AN ERROR! The utility likely did not work. Press return to continue." e
	fi
}

selector() {
	#clear # FOR TESTING! REMOVE THIS ONCE ASSETS ARE FIXED -ce

	selected=0
	while :; do
		showbg "utils/utils-select0${selected}.png" # or something
		input=$(readinput)
		case "$input" in
		'kB') exit ;;
		'kE') return ;;
		'kU')
			((selected--))
			if [ $selected -lt 0 ]; then selected=$(($# - 1)); fi
			;;
		'kD')
			((selected++))
			if [ $selected -ge $# ]; then selected=0; fi
			;;
		esac
	done
}

while :; do
	showbg Utilities.png
	selector 0 1 2 3 4 5 6
	case $selected in
	'0') runtask fix_gbb ;;
	'1') runtask deprovision ;;
	'2') runtask reprovision ;;
	'3') runtask usb ;;
	'4') runtask disable_verity ;;
	'5') shell ;;
	'6') runtask unblock_devmode ;;
	esac
done
