#!/usr/bin/env bash

set -e

CROSS=
CROSS2=
STRIP=strip
if ! [ -z "$1" ]; then
	CROSS="CC=${1}-gcc"
	CROSS2="PKG_CONFIG=${1}-pkg-config"
	STRIP="${1}-strip"
fi
if ! [ -d ply-image-repo ]; then
	git clone -n https://chromium.googlesource.com/chromiumos/third_party/ply-image ply-image-repo
	cd ply-image-repo
	git checkout 6cf4e4cd968bb72ade54e423e2b97eb3a80c6de9
	git apply ../ply-image.patch
else
	cd ply-image-repo
	make clean
fi
make ply-image "${CROSS:-ASDFGHJKLQWER=stfu}" "${CROSS2:-ASDFGHJKLQWERT=stfu}"
"$STRIP" -s src/ply-image
cp src/ply-image ..
