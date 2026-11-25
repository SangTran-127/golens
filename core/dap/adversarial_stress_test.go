package dap

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"sync"
	"testing"
	"time"
)

// ============================================================================
// Adversarial Stress Testing: Huge Payloads (>10MB, >20MB)
// ============================================================================

func TestAdversarial_HugeRawString15MB(t *testing.T) {
	// Construct 15MB ASCII payload
	const size = 15 * 1024 * 1024
	hugeStr := strings.Repeat("A", size)

	start := time.Now()
	ins := InspectRawVariablePayload("string", hugeStr)
	elapsed := time.Since(start)

	if elapsed > 1*time.Second {
		t.Errorf("InspectRawVariablePayload took too long on 15MB string: %v", elapsed)
	}
	if ins.Length != size {
		t.Errorf("ins.Length = %d; want %d", ins.Length, size)
	}
	if !ins.Truncated {
		t.Errorf("ins.Truncated must be true for 15MB payload")
	}
	if !strings.Contains(ins.Text, "... (truncated at 64 KB)") {
		t.Errorf("ins.Text missing truncation marker")
	}
	if len(ins.HexDump) == 0 {
		t.Errorf("ins.HexDump must not be empty")
	}
}

func TestAdversarial_HugeByteSliceDelveFormat10MB(t *testing.T) {
	// Construct Delve formatted byte slice with 1,000,000 numbers (> 4MB string)
	var sb strings.Builder
	sb.WriteString("[]uint8 len: 1000000, cap: 1000000, [")
	for i := 0; i < 500000; i++ {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString(fmt.Sprintf("%d", i%256))
	}
	sb.WriteString("]")
	payload := sb.String()

	start := time.Now()
	ins := InspectRawVariablePayload("[]byte", payload)
	elapsed := time.Since(start)

	if elapsed > 2*time.Second {
		t.Errorf("InspectRawVariablePayload took too long on huge byte list: %v", elapsed)
	}
	if ins.Length != 500000 {
		t.Errorf("ins.Length = %d; want 500000", ins.Length)
	}
	if !ins.Truncated {
		t.Errorf("ins.Truncated must be true")
	}
	if !strings.Contains(ins.HexDump, "... (truncated at 64 KB)") {
		t.Errorf("HexDump must contain truncation notice")
	}
}

func TestAdversarial_HugeJSON10MB(t *testing.T) {
	// 10MB of JSON elements
	var sb strings.Builder
	sb.WriteString("[")
	chunk := `{"id":12345,"name":"stress-test-item","status":"active"},`
	targetLen := 10 * 1024 * 1024
	for sb.Len() < targetLen {
		sb.WriteString(chunk)
	}
	sb.WriteString(`{"id":99999,"name":"end"}]`)
	hugeJSON := sb.String()

	start := time.Now()
	ins := InspectRawVariablePayload("json.RawMessage", hugeJSON)
	elapsed := time.Since(start)

	if elapsed > 1*time.Second {
		t.Errorf("InspectRawVariablePayload on 10MB JSON took %v", elapsed)
	}
	if ins.Length != len(hugeJSON) {
		t.Errorf("ins.Length = %d; want %d", ins.Length, len(hugeJSON))
	}
	if !ins.Truncated {
		t.Errorf("ins.Truncated must be true")
	}
}

// ============================================================================
// Adversarial Stress Testing: Deep Nesting, Cycles & Pathological Inputs
// ============================================================================

func TestAdversarial_DeeplyNestedJSON5000Levels(t *testing.T) {
	// 5000 opening and closing brackets
	const depth = 5000
	nested := strings.Repeat("[", depth) + "1" + strings.Repeat("]", depth)

	start := time.Now()
	ins := InspectRawVariablePayload("string", nested)
	elapsed := time.Since(start)

	if elapsed > 2500*time.Millisecond {
		t.Errorf("Deeply nested JSON took too long (possible hang/catastrophic slowdown): %v", elapsed)
	}
	if ins.Length != len(nested) {
		t.Errorf("ins.Length = %d; want %d", ins.Length, len(nested))
	}
}

func TestAdversarial_DeeplyNestedObjects2000Levels(t *testing.T) {
	// Construct {"a":{"a":{"a":...}}}
	const depth = 2000
	nested := strings.Repeat(`{"a":`, depth) + "42" + strings.Repeat("}", depth)

	start := time.Now()
	ins := InspectRawVariablePayload("string", nested)
	elapsed := time.Since(start)

	if elapsed > 500*time.Millisecond {
		t.Errorf("Deeply nested objects took too long: %v", elapsed)
	}
	if ins.Length != len(nested) {
		t.Errorf("ins.Length = %d; want %d", ins.Length, len(nested))
	}
}

func TestAdversarial_PathologicalUnmatchedBrackets(t *testing.T) {
	// Millions of open brackets with no match to test regex / parser backtracking
	unmatched := "[" + strings.Repeat("[", 100000)

	start := time.Now()
	ins := InspectRawVariablePayload("[]byte", unmatched)
	elapsed := time.Since(start)

	if elapsed > 500*time.Millisecond {
		t.Errorf("Pathological unmatched brackets took too long: %v", elapsed)
	}
	if ins.Length != len(unmatched) {
		t.Errorf("ins.Length = %d; want %d", ins.Length, len(unmatched))
	}
}

func TestAdversarial_CircularReferenceString(t *testing.T) {
	circular := `*(*main.Node)(0xc0000b4000) = main.Node {Val: 1, Next: *(*main.Node)(0xc0000b4000)}`
	ins := InspectRawVariablePayload("*main.Node", circular)
	if ins.Length != len(circular) {
		t.Errorf("Circular payload length mismatch: got %d, want %d", ins.Length, len(circular))
	}
	if ins.Truncated {
		t.Errorf("Circular payload under 64KB should not be truncated")
	}
}

// ============================================================================
// Adversarial Stress Testing: Invalid UTF-8 & Rune Slicing Boundaries
// ============================================================================

func TestAdversarial_InvalidUTF8RawBytes(t *testing.T) {
	// Raw binary byte slice with invalid UTF-8 sequences (0xFF, 0xFE, 0x80, etc.)
	invalidBytes := []byte{0xFF, 0xFE, 0x00, 0x80, 0xC0, 0xAF}
	byteStr := fmt.Sprintf("[]uint8 len: 6, cap: 6, [%d, %d, %d, %d, %d, %d]",
		invalidBytes[0], invalidBytes[1], invalidBytes[2], invalidBytes[3], invalidBytes[4], invalidBytes[5])

	ins := InspectRawVariablePayload("[]byte", byteStr)
	if ins.Length != 6 {
		t.Errorf("ins.Length = %d; want 6", ins.Length)
	}
	if ins.JSON != "" {
		t.Errorf("Invalid UTF-8 should not parse as valid JSON, got %q", ins.JSON)
	}
	if !strings.Contains(ins.HexDump, "ff fe 00 80 c0 af") {
		t.Errorf("HexDump missing expected bytes: %q", ins.HexDump)
	}

	// Verify Readable also falls back to hex for invalid UTF-8
	readable := Readable("[]byte", byteStr)
	if !strings.Contains(readable, "0xfffe0080c0af") {
		t.Errorf("Readable should format invalid UTF-8 as hex, got %q", readable)
	}
}

func TestAdversarial_TruncatedRuneAt64KBBoundary(t *testing.T) {
	// Pad exactly 65535 ASCII bytes, then place a 4-byte UTF-8 emoji
	// Byte 65535 will be the first byte of emoji, and 65536 will be truncated!
	padding := strings.Repeat("A", 65535)
	emoji := "\U0001F389" // \xf0\x9f\x8e\x89 (4 bytes)
	data := padding + emoji

	ins := InspectRawVariablePayload("string", data)
	if ins.Length != len(data) {
		t.Errorf("ins.Length = %d; want %d", ins.Length, len(data))
	}
	if !ins.Truncated {
		t.Errorf("ins.Truncated must be true")
	}

	// Verify json.Marshal succeeds without panic or error on truncated rune string
	b, err := json.Marshal(ins)
	if err != nil {
		t.Fatalf("json.Marshal failed on truncated rune: %v", err)
	}
	if len(b) == 0 {
		t.Errorf("json.Marshal produced empty output")
	}
}

func TestAdversarial_ZeroBytePayloadsAndNull(t *testing.T) {
	cases := []struct {
		typ, val string
	}{
		{"", ""},
		{"[]byte", ""},
		{"[]byte", "[]"},
		{"[]byte", "[]uint8 len: 0, cap: 0, []"},
		{"string", ""},
		{"*time.Time", "nil"},
		{"*time.Time", "(*time.Time)(nil)"},
		{"*url.URL", "nil"},
		{"*url.URL", "(*url.URL)(nil)"},
	}

	for _, tc := range cases {
		ins := InspectRawVariablePayload(tc.typ, tc.val)
		if ins.Truncated {
			t.Errorf("Zero payload %q %q should not be truncated", tc.typ, tc.val)
		}
		// Must marshal to valid JSON cleanly
		b, err := json.Marshal(ins)
		if err != nil {
			t.Errorf("json.Marshal failed on zero payload (%s, %s): %v", tc.typ, tc.val, err)
		}
		if len(b) == 0 {
			t.Errorf("json.Marshal returned empty")
		}
	}
}

// ============================================================================
// Adversarial Stress Testing: time.Time Boundary Values
// ============================================================================

func TestAdversarial_TimeTimeBoundaries(t *testing.T) {
	// 1. Epoch Zero (0001-01-01 00:00:00Z)
	zero := Readable("time.Time", "time.Time {wall: 0, ext: 0, loc: nil}")
	if zero != "0001-01-01 00:00:00Z" {
		t.Errorf("Epoch zero = %q; want 0001-01-01 00:00:00Z", zero)
	}

	// 2. Unix Epoch (1970-01-01 00:00:00 UTC)
	// ext = unixToInternal = 62135596800
	unixEpoch := Readable("time.Time", "time.Time {wall: 0, ext: 62135596800, loc: nil}")
	if !strings.HasPrefix(unixEpoch, "1970-01-01 00:00:00") {
		t.Errorf("Unix epoch = %q; want 1970-01-01 00:00:00...", unixEpoch)
	}

	// 3. Year 9999: 9999-12-31 23:59:59 UTC
	// seconds between year 1 and 9999-12-31 is approx 315537897599
	year9999 := Readable("time.Time", "time.Time {wall: 0, ext: 315537897599, loc: nil}")
	if !strings.HasPrefix(year9999, "9999-12-31") {
		t.Errorf("Year 9999 = %q; want 9999-12-31...", year9999)
	}

	// 4. Negative ext (BCE / before year 1)
	negTime := Readable("time.Time", "time.Time {wall: 0, ext: -62135596800, loc: nil}")
	if len(negTime) == 0 {
		t.Errorf("Negative ext should produce formatted date string, got empty")
	}

	// 5. MinInt64 ext (extreme underflow boundary)
	minExt := fmt.Sprintf("time.Time {wall: 0, ext: %d, loc: nil}", math.MinInt64)
	outMin := Readable("time.Time", minExt)
	if len(outMin) == 0 {
		t.Errorf("MinInt64 ext must not panic or return empty, got %q", outMin)
	}

	// 6. MaxUint64 wall
	maxWall := fmt.Sprintf("time.Time {wall: %d, ext: 0, loc: nil}", uint64(math.MaxUint64))
	outMax := Readable("time.Time", maxWall)
	if len(outMax) == 0 {
		t.Errorf("MaxUint64 wall must not panic or return empty, got %q", outMax)
	}
}

// ============================================================================
// Adversarial Stress Testing: Atomic Types Boundary Values
// ============================================================================

func TestAdversarial_AtomicBoundaries(t *testing.T) {
	tests := []struct {
		typ, val, want string
	}{
		{"sync/atomic.Int64", fmt.Sprintf("sync/atomic.Int64 {v: %d}", math.MinInt64), fmt.Sprintf("atomic.Int64(%d)", math.MinInt64)},
		{"sync/atomic.Int64", fmt.Sprintf("sync/atomic.Int64 {v: %d}", math.MaxInt64), fmt.Sprintf("atomic.Int64(%d)", math.MaxInt64)},
		{"atomic.Int64", "atomic.Int64 {v: 0}", "atomic.Int64(0)"},
		{"sync/atomic.Uint64", fmt.Sprintf("sync/atomic.Uint64 {v: %d}", uint64(math.MaxUint64)), fmt.Sprintf("atomic.Uint64(%d)", uint64(math.MaxUint64))},
		{"sync/atomic.Int32", fmt.Sprintf("sync/atomic.Int32 {v: %d}", math.MinInt32), fmt.Sprintf("atomic.Int32(%d)", math.MinInt32)},
		{"sync/atomic.Int32", fmt.Sprintf("sync/atomic.Int32 {v: %d}", math.MaxInt32), fmt.Sprintf("atomic.Int32(%d)", math.MaxInt32)},
		{"sync/atomic.Bool", "sync/atomic.Bool {v: 1}", "atomic.Bool(true)"},
		{"sync/atomic.Bool", "sync/atomic.Bool {v: 0}", "atomic.Bool(false)"},
		{"atomic.Bool", "atomic.Bool {v: true}", "atomic.Bool(true)"},
		{"atomic.Bool", "atomic.Bool {v: false}", "atomic.Bool(false)"},
		{"sync/atomic.Pointer[string]", "sync/atomic.Pointer[string] {v: 0x14000123456}", "atomic.Pointer[string](0x14000123456)"},
	}

	for _, tt := range tests {
		got := Readable(tt.typ, tt.val)
		if got != tt.want {
			t.Errorf("Readable(%q, %q) = %q; want %q", tt.typ, tt.val, got, tt.want)
		}
	}
}

// ============================================================================
// Adversarial Stress Testing: sql.Null* Boundary Values & Edge Cases
// ============================================================================

func TestAdversarial_SQLNullBoundaries(t *testing.T) {
	// 1. Valid: false always returns <null> regardless of inner value
	if got := Readable("database/sql.NullString", `database/sql.NullString {String: "any value", Valid: false}`); got != "<null>" {
		t.Errorf("Invalid NullString must return <null>, got %q", got)
	}
	if got := Readable("sql.NullInt64", `sql.NullInt64 {Int64: 999999, Valid: false}`); got != "<null>" {
		t.Errorf("Invalid NullInt64 must return <null>, got %q", got)
	}

	// 2. Valid: true with long string (50KB)
	longVal := strings.Repeat("hello_sql_", 5000)
	payload := fmt.Sprintf(`database/sql.NullString {String: "%s", Valid: true}`, longVal)
	gotLong := Readable("database/sql.NullString", payload)
	if gotLong != longVal {
		t.Errorf("Valid NullString length mismatch: got %d, want %d", len(gotLong), len(longVal))
	}

	// 3. Valid: true with empty string
	if got := Readable("database/sql.NullString", `database/sql.NullString {String: "", Valid: true}`); got != "" {
		t.Errorf("Empty valid NullString must return \"\", got %q", got)
	}

	// 4. Valid: true with special characters: commas, brackets, colons
	special := `database/sql.NullString {String: "foo, bar: baz {1, 2}", Valid: true}`
	gotSpecial := Readable("database/sql.NullString", special)
	if gotSpecial != "foo, bar: baz {1, 2}" {
		t.Errorf("Valid NullString with special chars = %q; want %q", gotSpecial, "foo, bar: baz {1, 2}")
	}

	// 5. Test edge case where string contains the substring `Valid: false`
	embeddedFalse := `database/sql.NullString {String: "User setting is Valid: false here", Valid: true}`
	gotEmbedded := Readable("database/sql.NullString", embeddedFalse)
	if gotEmbedded != "User setting is Valid: false here" {
		t.Errorf("Valid NullString containing 'Valid: false' in string body was misidentified as: %q", gotEmbedded)
	}

	// 6. Test edge case where invalid string contains the substring `Valid: true`
	embeddedTrue := `database/sql.NullString {String: "User setting is Valid: true here", Valid: false}`
	gotEmbeddedTrue := Readable("database/sql.NullString", embeddedTrue)
	if gotEmbeddedTrue != "<null>" {
		t.Errorf("Invalid NullString containing 'Valid: true' in string body was misidentified as: %q; want <null>", gotEmbeddedTrue)
	}
}

// ============================================================================
// Adversarial Stress Testing: High Concurrency & Race Detector
// ============================================================================

func TestAdversarial_HighConcurrencyReadableAndInspect(t *testing.T) {
	const goroutines = 50
	const iterations = 200

	var wg sync.WaitGroup
	wg.Add(goroutines)

	for g := 0; g < goroutines; g++ {
		go func(gid int) {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				// Alternating operations
				switch i % 5 {
				case 0:
					_ = Readable("time.Time", "time.Time {wall: 0, ext: 63839664000, loc: nil}")
				case 1:
					_ = Readable("sync/atomic.Int64", fmt.Sprintf("sync/atomic.Int64 {v: %d}", gid*1000+i))
				case 2:
					_ = Readable("database/sql.NullString", fmt.Sprintf(`database/sql.NullString {String: "thread_%d_item_%d", Valid: true}`, gid, i))
				case 3:
					_ = InspectRawVariablePayload("string", fmt.Sprintf(`{"gid": %d, "iter": %d, "data": "concurrent_test"}`, gid, i))
				case 4:
					b := []byte(fmt.Sprintf("[]uint8 len: 4, cap: 4, [%d, %d, %d, %d]", gid%256, i%256, 1, 2))
					_ = InspectRawVariablePayload("[]byte", string(b))
				}
			}
		}(g)
	}

	wg.Wait()
}
