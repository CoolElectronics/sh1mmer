#!/bin/bash

if [ -f movie_payload_pngquant.tar.gz ]; then
	echo "extracting movie_payload_pngquant.tar.gz"
	mkdir /tmp/movie_payload
	tar -xf movie_payload_pngquant.tar.gz -C /tmp/movie_payload
else
	echo "movie_payload_pngquant.tar.gz not found!" >&2
	exit 1
fi

if [ $HAS_FRECON -eq 1 ]; then
	for file in /tmp/movie_payload/*.png; do
		printf "\033]image:file=$file;scale=1\a"
		sleep 0.03
	done
else
	for file in /tmp/movie_payload/*.png; do
		ply-image "$file" 2>/dev/null
		sleep 0.03
	done
fi

rm -rf /tmp/movie_payload
