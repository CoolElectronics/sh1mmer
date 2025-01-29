function setup() {
	stty -echo # turn off showing of input
	printf "\033[?25l" # turn off cursor so that it doesn't make holes in the image
	printf "\033[2J\033[H" # clear screen
	sleep 0.1
}

function cleanup() {
	printf "\033[2J\033[H" # clear screen
	printf "\033[?25h" # turn on cursor
	stty echo
}

function movecursor_generic() {
	printf "\033[$((3+$1));6H" # move cursor to correct place for sh1mmer menu
}

function movecursor_Credits() {
	printf "\033[$((10+$1));6H" # move cursor to correct place for sh1mmer menu
}

function showbg() {
	local image="/usr/share/sh1mmer-assets/$1"
	if [ $HAS_FRECON -eq 1 ]; then
		printf "\033]image:file=$image;scale=1\a"
	else
		ply-image "$image" 2>/dev/null
	fi
}

function test() {
	setup
	showbg "Credits.png"
	movecursor_Credits 0
	echo -n "Test"
	sleep 1
	cleanup
}
