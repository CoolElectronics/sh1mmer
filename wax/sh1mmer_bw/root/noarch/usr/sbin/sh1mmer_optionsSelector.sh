CHR_ESC=$(printf "\x1b")
CHR_BS=$(printf "\x08")
CHR_DEL=$(printf "\x7f")

readinput() {
	local mode
	# discard stdin
	read -rsn 10000 -t 0.1 mode || :
	read -rsn1 mode

	case "$mode" in
		"$CHR_ESC") read -rsn2 mode ;;
		"$CHR_BS" | "$CHR_DEL") echo kB ;;
		"") echo kE ;;
		*) echo "$mode" ;;
	esac

	case "$mode" in
		"[A") echo kU ;;
		"[B") echo kD ;;
		"[D") echo kL ;;
		"[C") echo kR ;;
	esac
}
