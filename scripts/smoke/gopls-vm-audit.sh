#!/bin/bash
# Live audit of every gopls-backed feature against the real Linux micro-VM (no vsock bridge, no
# GOLENS_TEST_VSOCK_PATH), with the workspace in ~/Documents the way a user opens a project.
# MODE=vm (default): sandboxed app, gopls in the VM. MODE=local: same app signed without the
# sandbox and virtualization entitlements, so the core falls back to a host gopls.
# Usage: MODE=vm|local scripts/smoke/gopls-vm-audit.sh [phase ...]   (phases: A B C D D2 E G H L; FIXTURE_DIR, LMS_DIR, AUDIT_OUT override paths)
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
MODE=${MODE:-vm}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
PHASES=${*:-A B C D}

if [ "$MODE" = vm ]; then DOMAIN=dev.golens.test.goplsaudit; else DOMAIN=dev.golens.test.goplsaudit.local; fi
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
FIX=${FIXTURE_DIR:-$HOME/Documents/golens-gopls-audit}
OUT=${AUDIT_OUT:-$REPO/plans/reports/gopls-sandbox-live-audit-evidence/$MODE}
if [ "$MODE" = vm ]; then
  mkdir -p "$CONTAINER_DIR/tmp"
  WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-goplsaudit.XXXXXX")" && pwd -P)
else
  WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-goplsaudit-local.XXXXXX")" && pwd -P)
fi
ART=$WORK/art
mkdir -p "$ART/shots" "$ART/logs" "$OUT"
APP_PID=
OWNED_PIDS=
LOGSTREAM_PID=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$LOGSTREAM_PID" ] && kill -TERM "$LOGSTREAM_PID" 2>/dev/null
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  cp -R "$ART/." "$OUT/" 2>/dev/null
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if [ "$MODE" = vm ]; then
  BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
else
  cat > "$WORK/local.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
<key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
PLIST
  ENTITLEMENTS="$WORK/local.entitlements" BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
fi
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

make_fixture() {
  rm -rf "$FIX"; mkdir -p "$FIX/shapes" "$FIX/store" "$FIX/diag" "$FIX/tidy"
  cat > "$FIX/go.mod" <<'EOF'
module example.com/auditshop

go 1.22

require github.com/google/uuid v1.6.0
EOF
  cat > "$FIX/go.sum" <<'EOF'
github.com/google/uuid v1.6.0 h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
github.com/google/uuid v1.6.0/go.mod h1:TIyPZe4MgqvfeYDBFedMoGGpEw/LqOeaOT+nhxU+yHo=
EOF
  cat > "$FIX/main.go" <<'EOF'
package main

import (
	"fmt"
	"strings"

	"example.com/auditshop/shapes"
	"example.com/auditshop/store"
	"github.com/google/uuid"
)

func describe(s shapes.Shape) string {
	return strings.ToUpper(s.Name())
}

func main() {
	r := shapes.Rect{W: 2, H: 3}
	c := shapes.Circle{R: 1}
	total := shapes.Total(r, c)
	st := store.NewStore()
	st.Put("rect", r)
	id := uuid.NewString()
	names := shapes.Map([]shapes.Shape{r, c}, describe)
	fmt.Println(total, id, names, st.Len())
}
EOF
  cat > "$FIX/shapes/shape.go" <<'EOF'
// Package shapes holds geometry types used by the audit fixture.
package shapes

import "math"

// Shape is anything with an area and a name.
type Shape interface {
	Area() float64
	Name() string
}

// Rect is an axis-aligned rectangle.
type Rect struct {
	W, H float64
}

// Area returns the rectangle area.
func (r Rect) Area() float64 { return r.W * r.H }

// Name returns "rect".
func (r Rect) Name() string { return "rect" }

// Circle is a circle with radius R.
type Circle struct {
	R float64
}

// Area returns the circle area.
func (c Circle) Area() float64 { return math.Pi * c.R * c.R }

// Name returns "circle".
func (c Circle) Name() string { return "circle" }

// Total sums the area of every shape.
func Total(shapes ...Shape) float64 {
	sum := 0.0
	for _, s := range shapes {
		sum += s.Area()
	}
	return sum
}

// Map applies f to every element of xs.
func Map[T, U any](xs []T, f func(T) U) []U {
	out := make([]U, 0, len(xs))
	for _, x := range xs {
		out = append(out, f(x))
	}
	return out
}

// Stack is a generic LIFO stack.
type Stack[T any] struct {
	items []T
}

// Push adds v on top.
func (s *Stack[T]) Push(v T) { s.items = append(s.items, v) }
EOF
  cat > "$FIX/shapes/shape_test.go" <<'EOF'
package shapes

import "testing"

func TestTotal(t *testing.T) {
	if got := Total(Rect{W: 2, H: 3}); got != 6 {
		t.Fatalf("Total = %v, want 6", got)
	}
}
EOF
  cat > "$FIX/store/store.go" <<'EOF'
// Package store keeps shapes by key.
package store

import (
	"sync"

	"example.com/auditshop/shapes"
)

// Store is a concurrency-safe shape registry.
type Store struct {
	mu    sync.Mutex
	items map[string]shapes.Shape
}

// NewStore returns an empty Store.
func NewStore() *Store {
	return &Store{items: map[string]shapes.Shape{}}
}

// Put stores s under key.
func (s *Store) Put(key string, sh shapes.Shape) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items[key] = sh
}

// Len reports how many shapes are stored.
func (s *Store) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.items)
}

// Area sums every stored shape.
func (s *Store) Area() float64 {
	all := make([]shapes.Shape, 0, len(s.items))
	for _, v := range s.items {
		all = append(all, v)
	}
	return shapes.Total(all...)
}
EOF
  cat > "$FIX/diag/diag.go" <<'EOF'
package diag

// Double returns twice n.
func Double(n int) int {
	return n * 2
}

func useDouble() int {
	x := Double(21)
	return x
}
EOF
  cat > "$FIX/tidy/tidy.go" <<'EOF'
package tidy

import (
	"os"
	"fmt"
)

func   Messy( a int,b int )int{
return a+b
}

func Greeting() string {
	return strconv.Itoa(42)
}

func Hello() { fmt.Println("hi") }
EOF
  cat > "$FIX/tidy/save.go" <<'EOF'
package tidy

import (
	"os"
	"fmt"
)

func   SaveMe( a int,b int )int{
return a+b
}

func Hostname() string {
	h, _ := os.Hostname()
	return strconv.Quote(h) + fmt.Sprint(1)
}
EOF
}

launch() { # name file steps [workspace]
  local ws=${4:-$FIX}
  LOG=$ART/logs/$1.log
  local envs=(DRIVE="$3" DRIVE_OUT="$LOG" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" GOLENS_MEASURE=1 GOLENS_LSP_TRACE=1)
  if [ "$MODE" = vm ]; then
    envs+=(GOLENS_EXECUTION_MODE="${GOLENS_EXECUTION_MODE:-vm}")
  else
    envs+=(GOLENS_EXECUTION_MODE="${GOLENS_EXECUTION_MODE:-host}")
  fi
  log stream --style compact --level debug --predicate "subsystem == \"$DOMAIN\"" > "$ART/logs/$1.core.log" 2>&1 &
  LOGSTREAM_PID=$!
  sleep 1
  date '+launch %H:%M:%S' > "$ART/logs/$1.launch"
  env "${envs[@]}" "$APP" -GoLensLastWorkspacePath "$ws" -GoLensLastFilePath "$ws/$2" -GoLensShowConsole '<true/>' > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}

finish() { # timeoutSeconds
  local i=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $(($1 * 5)) ]; do
    OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
    sleep 0.2; i=$((i + 1))
  done
  if kill -0 "$APP_PID" 2>/dev/null; then echo "  ($1 s elapsed; killing app)" >&2; kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
  sleep 1
  kill -TERM "$LOGSTREAM_PID" 2>/dev/null; LOGSTREAM_PID=
}

snapshot_fixture() { (cd "$FIX" && for f in main.go shapes/shape.go shapes/shape_test.go store/store.go tidy/tidy.go tidy/save.go diag/diag.go; do echo "=== $f"; cat "$f"; done) > "$ART/logs/$1.fixture-after.txt"; }

# Phase A: navigation from main.go (cold attempt first, then warm), hover, quick documentation.
A="wait:4;fakeactive;time:start;mark:ready;\
caret:shapes.Tot;time:defx-cold;menu:Navigate/Go to Definition;wait:1;selinfo;wait:2;selinfo;line;menu:Navigate/Back;wait:1;\
caret:shapes.Tot;time:refs-cold;menu:Navigate/Find References;wait:1.5;wininfo;wait:3;wininfo;deeplabels;postkey:53;wait:0.5;\
wait:20;time:warm;shot:A00-warm;deeplabels;\
caret:, descr;time:def-same;menu:Navigate/Go to Definition;wait:1;selinfo;wait:3;selinfo;line;shot:A01-def-same;\
caret:shapes.Tot;time:def-xpkg;menu:Navigate/Go to Definition;wait:1;selinfo;wait:3;selinfo;line;shot:A02-def-xpkg;menu:Navigate/Back;wait:1.5;selinfo;\
caret:st.Pu;time:def-method;menu:Navigate/Go to Definition;wait:1;selinfo;wait:3;selinfo;line;shot:A03-def-method;menu:Navigate/Back;wait:1.5;selinfo;\
caret:strings.ToUp;time:def-stdlib;menu:Navigate/Go to Definition;wait:1;selinfo;wait:4;selinfo;line;shot:A04-def-stdlib;wininfo;menu:Navigate/Back;wait:1.5;selinfo;\
caret:uuid.NewStr;time:def-dep;menu:Navigate/Go to Definition;wait:1;selinfo;wait:4;selinfo;line;shot:A05-def-dep;wininfo;menu:Navigate/Back;wait:1.5;selinfo;\
caret:\"rect\", r;time:typedef;menu:Navigate/Go to Type Definition;wait:1;selinfo;wait:3;selinfo;line;shot:A06-typedef;menu:Navigate/Back;wait:1.5;selinfo;\
caret:s shapes.Sha;time:impl;menu:Navigate/Go to Implementation;wait:1;wininfo;wait:3;wininfo;deeplabels;selinfo;shot:A07-impl;postkey:53;wait:0.5;\
caret:shapes.Tot;time:refs;menu:Navigate/Find References;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:A08-refs;postkey:53;wait:0.5;\
caret:st.Pu;time:refs-method;menu:Navigate/Find References;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:A09-refs-method;postkey:53;wait:0.5;\
hover:ToUpper;time:hover-stdlib;wait:1;wininfo;wait:2.5;wininfo;panelshot:A10-hover-stdlib;shot:A10-hover-stdlib-win;\
hover:NewString;time:hover-dep;wait:1;wininfo;wait:2.5;wininfo;panelshot:A11-hover-dep;\
hover:Total(r;time:hover-xpkg;wait:1;wininfo;wait:2.5;wininfo;panelshot:A12-hover-xpkg;\
hover:describe(s;time:hover-same;wait:3.5;wininfo;panelshot:A13-hover-same;\
hover:package;postkey:53;wait:1;hover:NewString;time:hover-dep-retry;wait:3.5;wininfo;panelshot:A11b-hover-dep-retry;hover:package;postkey:53;wait:1;hover:describe(s;time:hover-same-retry;wait:3.5;wininfo;panelshot:A13b-hover-same-retry;hover:package;postkey:53;wait:1;hover:Put(;time:hover-method;wait:3.5;wininfo;panelshot:A14-hover-method;axpress:Open Source;wait:3;selinfo;line;menu:Navigate/Back;wait:1.5;\
caret:shapes.Tot;time:quickdoc;menu:View/Quick Documentation;wait:1;wininfo;wait:3;wininfo;panelshot:A15-quickdoc;postkey:53;wait:0.5;\
caret:shapes.Tot;time:callh;menu:Navigate/Call Hierarchy;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:A16-callh;postkey:53;wait:0.5;\
caret:shapes.Tot;time:defx-again;menu:Navigate/Go to Definition;wait:3;selinfo;line;menu:Navigate/Back;wait:1;\
caret:shapes.Tot;time:refs-again;menu:Navigate/Find References;wait:4;wininfo;deeplabels;postkey:53;wait:0.5;\
mark:done;quit"

# Phase B: shapes/shape.go: usages from the declaration, hierarchy, symbols, lenses, highlight, inlay hints, change signature, rename.
B="wait:4;fakeactive;time:start;mark:ready;\
caret:func Tot;time:usages-cold;cmdclick:Total(shapes;wait:1.5;wininfo;wait:3;wininfo;deeplabels;postkey:53;wait:0.5;\
wait:20;time:warm;shot:B00-warm;deeplabels;\
time:usages;cmdclick:Total(shapes;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:B01-usages;shot:B01-usages-win;postkey:53;wait:0.5;\
caret:func Tot;time:refs-decl;menu:Navigate/Find References;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:B02-refs-decl;postkey:53;wait:0.5;\
caret:func Tot;time:callh;menu:Navigate/Call Hierarchy;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:B03-callh;postkey:53;wait:0.5;\
caret:func (r Rect) Area() float64 { return r.W;time:callh-out;menu:Navigate/Call Hierarchy;wait:4;wininfo;deeplabels;shot:B03b-callh-area;postkey:53;wait:0.5;\
caret:type Sha;time:typeh;menu:Navigate/Type Hierarchy;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:B04-typeh;postkey:53;wait:0.5;\
caret:type Sha;time:impl-iface;menu:Navigate/Go to Implementation;wait:1;wininfo;wait:3;wininfo;deeplabels;shot:B05-impl-iface;postkey:53;wait:0.5;\
caret:\\tAre;time:impl-method;menu:Navigate/Go to Implementation;wait:4;wininfo;deeplabels;shot:B06-impl-method;postkey:53;wait:0.5;\
caret:func (c Circle) Are;time:impl-up;menu:Navigate/Go to Implementation;wait:4;wininfo;deeplabels;selinfo;postkey:53;wait:0.5;\
time:docsym;menu:Navigate/Go to Symbol in File…;wait:1;fr:Pus;wait:1.5;wininfo;deeplabels;shot:B07-docsym;postkey:53;wait:0.5;\
time:wssym;menu:Navigate/Go to Workspace Symbol…;wait:1;fr:NewStore;wait:3;wininfo;deeplabels;shot:B08-wssym;postkey:53;wait:0.5;\
caret:sum += s.Are;time:highlight;wait:2;shot:B09-highlight-inlay;\
caret:func Tot;time:lens;wait:1;shot:B10-lens;deeplabels;\
select:Total;time:chsig;menu:Editor/Change Signature…;wait:3;wininfo;sheetshot:B11-chsig;axpress:Cancel;wait:1;\
select:Pi * c.R;time:extractvar;menu:Editor/Extract Variable;wait:2;find:Pi * c.R;text;undo;wait:0.5;\
caret:type Circ;time:rename;menu:Editor/Rename Symbol…;wait:3;wininfo;code:Disk;postkey:36;wait:2;find:type Disk struct;find:func (c Disk) Area;wait:4;find:type Disk struct;shot:B12-rename;deeplabels;\
time:save;menu:File/Save All;wait:2;\
mark:done;quit"

# Phase C: main.go editing: completion, unimported completion, signature help, diagnostics appear and clear.
C="wait:4;fakeactive;time:start;mark:ready;\
caret:st.Len());time:compl-cold;code:\\n\\tst.;wait:1.5;panel;wait:2;panel;postkey:53;undo;undo;undo;wait:1;\
wait:20;time:warm;\
caret:st.Len());time:compl;code:\\n\\tst.;wait:1;panel;wait:2;panel;shot:C01-compl;postkey:53;wait:0.3;undo;undo;undo;wait:1;\
caret:st.Len());time:compl-unimported;code:\\n\\tstrconv.It;wait:1;panel;wait:2;panel;shot:C02-compl-unimported;postkey:53;wait:0.3;undo;undo;undo;undo;wait:1;\
caret:st.Len());time:compl-pkg;code:\\n\\tshapes.Ci;wait:1;panel;wait:2;panel;shot:C03-compl-pkg;postkey:53;wait:0.3;undo;undo;undo;undo;wait:1;\
caret:st.Len());time:sighelp;code:\\n\\tst.Put(;wait:1;wininfo;wait:2;wininfo;panelshot:C04-sighelp;shot:C04-sighelp-win;postkey:53;wait:0.3;undo;undo;undo;undo;wait:1;text;\
caret:st.Len());time:diag-add;code:\\n\\t_ = 1 + \"s\";wait:1;underline:+ \"s;wait:3;underline:+ \"s;wait:4;underline:+ \"s;shot:C05-diag;deeplabels;\
time:diag-fix;select:1 + \"s\";code:1;wait:1;underline:_ = 1;wait:4;underline:_ = 1;deeplabels;shot:C06-diag-cleared;\
text;mark:done;quit"

# Phase D: tidy/tidy.go: code actions, organize imports, format document; tidy/save.go then format/imports on save.
D="wait:4;fakeactive;time:start;mark:ready;wait:20;time:warm;shot:D00-warm;deeplabels;\
caret:strconv.It;time:codeact;menu:Editor/Show Code Actions;wait:2;wininfo;panelshot:D01-codeact;menushot:D01-codeact;postkey:53;wait:0.5;\
time:orgimp;menu:Editor/Organize Imports;wait:3;find:\"strconv\";find:\"os\";text;shot:D02-orgimp;\
time:format;menu:Editor/Format Document;wait:3;find:func Messy(a int, b int) int {;text;shot:D03-format;\
mark:done;quit"

D2="wait:4;fakeactive;time:start;mark:ready;wait:20;time:warm;\
caret:a+b;code: ;time:fmtsave;menu:File/Save;wait:4;find:func SaveMe(a int, b int) int {;find:\"strconv\";text;shot:D04-format-on-save;\
mark:done;quit"

# Phase E: the VM is already running on another project; the user then opens the fixture with File > Open Project… (open panel).
FIRST=$FIX-first
E="wait:4;fakeactive;mark:ready;wait:8;time:open;stubpanel:$FIX;menu:File/Open Project…;wait:4;deeplabels;rowexpand:shapes;wait:0.5;axpress:main.go;wait:2;selinfo;\
caret:shapes.Tot;time:defx;menu:Navigate/Go to Definition;wait:1;selinfo;wait:3;selinfo;line;menu:Navigate/Back;wait:1;selinfo;\
caret:shapes.Tot;time:refs;menu:Navigate/Find References;wait:1;deeplabels;wait:3;deeplabels;shot:E01-refs;postkey:53;wait:0.5;\
caret:strings.ToUp;time:def-stdlib;menu:Navigate/Go to Definition;wait:4;selinfo;shot:E02-def-stdlib;menu:Navigate/Back;wait:1;\
hover:Total(r;time:hover;wait:3.5;wininfo;\
wait:20;time:late;caret:shapes.Tot;menu:Navigate/Find References;wait:4;deeplabels;shot:E03-refs-late;postkey:53;wait:0.5;\
caret:shapes.Tot;time:defx-late;menu:Navigate/Go to Definition;wait:3;selinfo;line;\
mark:done;quit"

# Phase G: are the usage/implementation lenses fetched once gopls is warm?
G="wait:4;fakeactive;mark:ready;wait:25;time:main-warm;shot:G00-main-warm;\
rowexpand:shapes;wait:0.5;axpress:shape.go;wait:6;time:shape-opened;selinfo;shot:G01-shape-lens;\
caret:sum := 0.0;code: ;time:edited;wait:6;shot:G02-shape-lens-after-edit;undo;\
caret:func Tot;time:chsig;menu:Editor/Change Signature…;wait:3;wininfo;deeplabels;shot:G03-chsig;postkey:53;wait:0.5;\
mark:done;quit"

# Phase L: the owner's real workload (a clone of lms-saas/backend): usages and references of a helper used ~720 times.
LMS=${LMS_DIR:-$HOME/Documents/golens-gopls-audit-lms}
L="wait:4;fakeactive;mark:ready;time:usages-t4;cmdclick:Fail(c;wait:2;deeplabels;wait:5;deeplabels;shot:L01-usages-t4;postkey:53;wait:0.5;\
wait:10;time:usages-t25;cmdclick:Fail(c;wait:2;deeplabels;wait:5;deeplabels;shot:L02-usages-t25;postkey:53;wait:0.5;\
wait:25;time:usages-t60;cmdclick:Fail(c;wait:2;deeplabels;wait:5;deeplabels;shot:L03-usages-t60;postkey:53;wait:0.5;\
caret:func O;time:refs-ok;menu:Navigate/Find References;wait:2;deeplabels;wait:5;deeplabels;shot:L04-refs-ok;postkey:53;wait:0.5;\
caret:gin.Cont;time:def-gin;menu:Navigate/Go to Definition;wait:2;selinfo;wait:4;selinfo;line;shot:L05-def-gin;menu:Navigate/Back;wait:1;\
hover:Context;time:hover-gin;wait:3.5;wininfo;\
time:lens;shot:L06-lens;\
wait:30;time:usages-t110;cmdclick:Fail(c;wait:2;deeplabels;wait:5;deeplabels;shot:L07-usages-t110;postkey:53;wait:0.5;\
mark:done;quit"

# Phase H: Change Signature applied across packages, and Call Hierarchy callees.
H="wait:4;fakeactive;mark:ready;wait:20;time:warm;\
caret:func Tot;time:chsig;menu:Editor/Change Signature…;wait:3;field:0:TotalArea;wait:0.5;wininfo;axpress:Refactor;wait:5;find:func TotalArea(;menu:File/Save;wait:2;\
caret:func TotalAre;time:callees;menu:Navigate/Call Hierarchy;wait:3;axpress:Callees;wait:3;deeplabels;shot:H01-callees;postkey:53;wait:0.5;\
mark:done;quit"

echo "GoLens gopls audit — mode=$MODE — fixture $FIX — artifacts $ART -> $OUT"
for ph in $PHASES; do
  make_fixture
  case $ph in
    A) launch A main.go "$A"; finish 200 ;;
    B) launch B shapes/shape.go "$B"; finish 200 ;;
    C) launch C main.go "$C"; finish 160 ;;
    D) launch D tidy/tidy.go "$D"; finish 120 ;;
    D2) launch D2 tidy/save.go "$D2"; finish 90 ;;
    E) rm -rf "$FIRST"; mkdir -p "$FIRST"; printf 'module example.com/first\n\ngo 1.22\n' > "$FIRST/go.mod"; printf 'package main\n\nfunc main() {}\n' > "$FIRST/first.go"
       launch E first.go "$E" "$FIRST"; finish 120; rm -rf "$FIRST" ;;
    G) launch G main.go "$G"; finish 90 ;;
    H) launch H shapes/shape.go "$H"; finish 90 ;;
    L) launch L internal/helpers/respond.go "$L" "$LMS"; finish 200 ;;
  esac
  snapshot_fixture "$ph"
  echo "phase $ph done: $(grep -c '^DRIVE' "$ART/logs/$ph.log" 2>/dev/null) driver lines, mark done: $(grep -c 'DRIVE mark done' "$ART/logs/$ph.log" 2>/dev/null)"
done
rm -rf "$FIX"
