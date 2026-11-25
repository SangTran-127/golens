#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
	echo "usage: prepare.sh <fixture-dir> <output-profile-path> [kind]" >&2
	exit 2
fi

fixture=$(cd "$1" && pwd)
out_dir=$(cd "$(dirname "$2")" && pwd)
out="$out_dir/$(basename "$2")"
kind=${3:-alloc}

case "$kind" in
alloc | inuse) ;;
*)
	echo "unsupported kind: $kind (supported: alloc, inuse)" >&2
	exit 2
	;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
cp -R "$fixture/." "$work/"
cd "$work"

GOWORK=off GOTOOLCHAIN=local nice -n 15 \
	go test -count=1 -run '^$' -bench 'RenderRows' -benchtime=200x -memprofilerate=4096 \
	-memprofile "$work/profile.pprof" -o "$work/bench.test" . >/dev/null

test -s "$work/profile.pprof"
cp "$work/profile.pprof" "$out"
echo "$out"
