package dap

import (
	"strings"
	"testing"
)

func TestReadableTimeDuration(t *testing.T) {
	tests := []struct {
		typ, val, want string
	}{
		{"time.Duration", "1000000000", "1s"},
		{"time.Duration", "5000000", "5ms"},
		{"*time.Duration", "time.Duration(60000000000)", "1m0s"},
	}
	for _, tt := range tests {
		got := Readable(tt.typ, tt.val)
		if got != tt.want {
			t.Errorf("Readable(%q, %q) = %q; want %q", tt.typ, tt.val, got, tt.want)
		}
	}
}

func TestReadableNetIP(t *testing.T) {
	got := Readable("net.IP", "[]uint8 len: 4, cap: 4, [192, 168, 1, 1]")
	if got != "192.168.1.1" {
		t.Errorf("Readable net.IP IPv4 = %q; want 192.168.1.1", got)
	}

	got6 := Readable("net.IP", "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 127, 0, 0, 1]")
	if got6 != "127.0.0.1" {
		t.Errorf("Readable net.IP IPv6 mapped = %q; want 127.0.0.1", got6)
	}
}

func TestReadableTimeTime(t *testing.T) {
	// Zero time
	gotZero := Readable("time.Time", "time.Time {wall: 0, ext: 0, loc: nil}")
	if gotZero != "0001-01-01 00:00:00Z" {
		t.Errorf("Readable zero time = %q; want 0001-01-01 00:00:00Z", gotZero)
	}

	// Known time: 2024-01-01 00:00:00 UTC
	// Without monotonic: wall = 0, ext = 63839664000
	// 63839664000 - 62135596800 = 1704067200
	gotKnown := Readable("time.Time", "time.Time {wall: 0, ext: 63839664000, loc: nil}")
	if !strings.HasPrefix(gotKnown, "2024-01-01 00:00:00") {
		t.Errorf("Readable known time = %q; expected 2024-01-01 00:00:00...", gotKnown)
	}

	// Pointer nil
	gotNil := Readable("*time.Time", "nil")
	if gotNil != "<nil>" {
		t.Errorf("Readable nil time pointer = %q; want <nil>", gotNil)
	}
}

func TestReadableByteSlice(t *testing.T) {
	// UTF-8 text JSON
	jsonBytes := "[]uint8 len: 13, cap: 16, [123, 34, 105, 100, 34, 58, 32, 49, 50, 51, 125]" // `{"id": 123}`
	gotJSON := Readable("[]byte", jsonBytes)
	if !strings.Contains(gotJSON, `[]byte(len=11) "{\"id\": 123}"`) {
		t.Errorf("Readable UTF-8 bytes = %q; want []byte(len=11) ...", gotJSON)
	}

	// Non-printable binary
	binaryBytes := "[]uint8 len: 4, cap: 4, [0, 1, 2, 255]"
	gotBin := Readable("[]byte", binaryBytes)
	if !strings.Contains(gotBin, "0x000102ff") {
		t.Errorf("Readable binary bytes = %q; want 0x000102ff", gotBin)
	}

	// Empty byte slice
	gotEmpty := Readable("[]byte", "[]uint8 len: 0, cap: 0, []")
	if gotEmpty != "[]byte(len=0) \"\"" {
		t.Errorf("Readable empty bytes = %q; want []byte(len=0) \"\"", gotEmpty)
	}
}

func TestReadableURL(t *testing.T) {
	val := `url.URL {Scheme: "https", Opaque: "", User: nil, Host: "api.example.com", Path: "/v1/users", RawPath: "", OmitHost: false, ForceQuery: false, RawQuery: "page=2", Fragment: "results"}`
	got := Readable("url.URL", val)
	want := `url.URL("https://api.example.com/v1/users?page=2#results")`
	if got != want {
		t.Errorf("Readable url.URL = %q; want %q", got, want)
	}

	gotNil := Readable("*url.URL", "nil")
	if gotNil != "<nil>" {
		t.Errorf("Readable nil url = %q; want <nil>", gotNil)
	}
}

func TestReadableAtomic(t *testing.T) {
	gotInt := Readable("sync/atomic.Int64", "sync/atomic.Int64 {v: 42}")
	if gotInt != "atomic.Int64(42)" {
		t.Errorf("Readable atomic.Int64 = %q; want atomic.Int64(42)", gotInt)
	}

	gotBool := Readable("sync/atomic.Bool", "sync/atomic.Bool {v: 1}")
	if gotBool != "atomic.Bool(true)" {
		t.Errorf("Readable atomic.Bool(true) = %q; want atomic.Bool(true)", gotBool)
	}

	gotBoolFalse := Readable("atomic.Bool", "atomic.Bool {v: 0}")
	if gotBoolFalse != "atomic.Bool(false)" {
		t.Errorf("Readable atomic.Bool(false) = %q; want atomic.Bool(false)", gotBoolFalse)
	}
}

func TestReadableSQLNull(t *testing.T) {
	gotValid := Readable("database/sql.NullString", `database/sql.NullString {String: "hello", Valid: true}`)
	if gotValid != "hello" {
		t.Errorf("Readable valid NullString = %q; want hello", gotValid)
	}

	gotNull := Readable("database/sql.NullString", `database/sql.NullString {String: "", Valid: false}`)
	if gotNull != "<null>" {
		t.Errorf("Readable invalid NullString = %q; want <null>", gotNull)
	}

	gotIntNull := Readable("sql.NullInt64", `sql.NullInt64 {Int64: 0, Valid: false}`)
	if gotIntNull != "<null>" {
		t.Errorf("Readable invalid NullInt64 = %q; want <null>", gotIntNull)
	}

	gotIntValid := Readable("sql.NullInt64", `sql.NullInt64 {Int64: 99, Valid: true}`)
	if gotIntValid != "99" {
		t.Errorf("Readable valid NullInt64 = %q; want 99", gotIntValid)
	}
}

func TestInspectRawVariablePayload(t *testing.T) {
	// JSON payload
	jsonVal := `[123, 34, 110, 97, 109, 101, 34, 58, 34, 86, 101, 108, 111, 34, 125]` // `{"name":"Velo"}`
	ins := InspectRawVariablePayload("[]byte", jsonVal)
	if ins.Length != 15 {
		t.Errorf("Inspect payload length = %d; want 15", ins.Length)
	}
	if !strings.Contains(ins.Text, `{"name":"Velo"}`) {
		t.Errorf("Inspect payload text = %q; want contain JSON", ins.Text)
	}
	if !strings.Contains(ins.JSON, "{\n  \"name\": \"Velo\"\n}") {
		t.Errorf("Inspect payload pretty JSON = %q", ins.JSON)
	}
	if !strings.Contains(ins.HexDump, "7b 22 6e 61 6d 65 22 3a") {
		t.Errorf("Inspect payload hex dump = %q", ins.HexDump)
	}
	if ins.Truncated {
		t.Errorf("Inspect payload truncated should be false")
	}

	// Large payload truncation (>64KB)
	largeData := strings.Repeat("A", 70000)
	largeIns := InspectRawVariablePayload("string", largeData)
	if largeIns.Length != 70000 {
		t.Errorf("Inspect large length = %d; want 70000", largeIns.Length)
	}
	if !largeIns.Truncated {
		t.Errorf("Inspect large truncated should be true")
	}
	if !strings.Contains(largeIns.Text, "... (truncated at 64 KB)") {
		t.Errorf("Inspect large text should contain truncation note")
	}
}
