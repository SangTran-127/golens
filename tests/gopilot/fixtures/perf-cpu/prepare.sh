#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
	echo "usage: prepare.sh <fixture-dir> <output-profile-path> [kind]" >&2
	exit 2
fi

fixture=$(cd "$1" && pwd)
out_dir=$(cd "$(dirname "$2")" && pwd)
out="$out_dir/$(basename "$2")"
kind=${3:-cpu}

case "$kind" in
cpu) flag=-cpuprofile ;;
*)
	echo "unsupported kind: $kind (supported: cpu)" >&2
	exit 2
	;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
cp -R "$fixture/." "$work/"
cd "$work"

GOWORK=off GOTOOLCHAIN=local nice -n 15 \
	go test -count=1 -run '^$' -bench 'BuildReport' -benchtime=1500ms \
	"$flag" "$work/profile.pprof" -o "$work/bench.test" . >/dev/null

test -s "$work/profile.pprof"
cp "$work/profile.pprof" "$out"
echo "$out"
