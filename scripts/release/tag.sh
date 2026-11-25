#!/bin/sh
# Publishes origin/main as today's GoLens release (vYYYY.MM.DD, then vYYYY.MM.DD.1, .2 ... for later releases the same day):
# exports the source snapshot to the public repository as one commit and tags it there, which starts its Release workflow.
set -eu
cd "$(dirname "$0")/../.."
public=git@github.com:SangTran-127/golens.git

branch=$(git symbolic-ref --short HEAD)
[ "$branch" = main ] || { echo "release from main, not $branch" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD is not origin/main: push or pull first" >&2; exit 1; }

tags=$(GIT_SSH_COMMAND=/usr/bin/ssh git ls-remote --tags "$public" | sed -n 's#.*refs/tags/\(v[^^]*\)$#\1#p')
base=$(date +%Y.%m.%d)
version=$base
n=0
while printf '%s\n' "$tags" | grep -qx "v$version"; do
  n=$((n + 1))
  version="$base.$n"
done

python3 scripts/release/public-snapshot.py --ref origin/main --version "$version" --push --tag
echo "Release: gh run watch --repo SangTran-127/golens \$(gh run list --repo SangTran-127/golens --workflow Release --limit 1 --json databaseId -q '.[0].databaseId')"
