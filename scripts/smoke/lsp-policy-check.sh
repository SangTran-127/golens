#!/bin/bash
# Checks the LSP request policy and the file URI encoder without launching the app.
# The encoder is compared byte for byte with Go's (&url.URL{Scheme: "file", Path: p}).String(), which the core rewriter expects.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/golens-lsp-policy.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/gouri"
printf 'module gouri\n\ngo 1.22\n' > "$WORK/gouri/go.mod"
cat > "$WORK/gouri/main.go" <<'EOF'
package main

import (
	"fmt"
	"net/url"
)

func main() {
	samples := []string{
		"/Users/dev/My Project (copy)!/main.go",
		"/Users/dev/Tài liệu/dự án/main.go",
		"/Users/dev/Tài/x.go",
		"/Users/dev/a+b,c;d=e@f$g&h:i/~j_k-l.m.go",
		"/Users/dev/100% done/#hash?/[x]{y}'z\"q`*.go",
		"/Users/dev/emoji \U0001F600/main.go",
	}
	for _, s := range samples {
		fmt.Println((&url.URL{Scheme: "file", Path: s}).String())
	}
}
EOF
(cd "$WORK/gouri" && go run . > "$WORK/expected.txt")

swiftc -O -o "$WORK/check" "$REPO/desktop/State/LSPRequestPolicy.swift" "$HERE/lsp-policy/main.swift"
"$WORK/check" "$WORK/expected.txt"
