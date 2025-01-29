#!/bin/bash

SCRIPT_DATE="[2024-11-11]"

. /usr/sbin/sh1mmer_gui.sh
. /usr/sbin/sh1mmer_optionsSelector.sh

setup
showbg Disclaimer.png
sleep 1
read -rsn1

mkdir -p -m 1777 /run/lock

mkdir -p /mnt/sh1mmer /usr/local
if mount /dev/disk/by-label/SH1MMER /mnt/sh1mmer >/dev/null 2>&1; then
	mount --bind /mnt/sh1mmer/chromebrew /usr/local >/dev/null 2>&1 || umount /mnt/sh1mmer
fi

loadmenu() {
	case $selected in
	0) bash /usr/sbin/sh1mmer_payload.sh ;;
	1) bash /usr/sbin/sh1mmer_utilities.sh ;;
	2) credits ;;
	3) reboot; tail -f /dev/null ;;
	esac
}

credits() {
	showbg Credits.png
	printf "\033[H"
	echo "Script date: ${SCRIPT_DATE}"
	while :; do
		case $(readinput) in
		'kB') break ;;
		esac
	done
}

selector() {
	selected=0
	while :; do
		showbg "qsm/qsm-select0$selected.png"
		input=$(readinput)
		case "$input" in
		'kE') # again, bash return doesn't work if you have anything other than 0 or 1, so we'll just take the value of selected globally. real asm moment
			# i have been informed i was wrong with this comment.
			return ;;
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
	# thank you r58 :pray: | almost got it right this time -r58Playz
	selector 0 1 2 3
	loadmenu # idiot use $? for the return number! i told you! -r58Playz
	# well guess what that doesn't work anyway - ce
done

cleanup

bash # a failsafe in case i accidentally mess up very badly. this should never be reached
