package database

import (
	"testing"
	"time"
)

func TestFormatValues(t *testing.T) {
	cases := []struct {
		kind uint8
		v    any
		want string
	}{
		{KindInt, int64(-42), "-42"},
		{KindInt, uint64(18446744073709551615), "18446744073709551615"},
		{KindBool, int64(1), "true"},
		{KindBool, int64(0), "false"},
		{KindFloat, 1.5, "1.5"},
		{KindFloat, 1e6, "1000000"},
		{KindFloat, 1e-9, "1e-09"},
		{KindFloat, float32(0.1), "0.1"},
		{KindText, "héllo", "héllo"},
		{KindText, []byte{0xff, 0x00}, "0xff00"},
		{KindJSON, []byte(`{ "a" : [1, 2] }`), `{"a":[1,2]}`},
		{KindJSON, "not json {", "not json {"},
		{KindDateTime, []byte("2026-11-15 10:00:00"), "2026-11-15T10:00:00"},
		{KindDateTime, time.Date(2026, 11, 15, 0, 0, 0, 0, time.UTC), "2026-11-15"},
		{KindDateTime, time.Date(2026, 11, 15, 1, 2, 3, 0, time.UTC), "2026-11-15T01:02:03Z"},
		{KindBinary, []byte{1, 2}, "\x01\x02"},
	}
	for _, c := range cases {
		if got := string(appendValue(nil, c.kind, c.v)); got != c.want {
			t.Errorf("%v (%T): got %q want %q", c.v, c.v, got, c.want)
		}
	}
}

func TestPostgresText(t *testing.T) {
	cases := []struct {
		oid  uint32
		in   string
		want string
	}{
		{16, "t", "true"},
		{16, "f", "false"},
		{17, `\x00ff10`, "\x00\xff\x10"},
		{1184, "2026-11-15 10:00:00+07", "2026-11-15T10:00:00+07:00"},
		{1184, "2026-11-15 10:00:00.123456-03:30", "2026-11-15T10:00:00.123456-03:30"},
		{1114, "2026-11-15 10:00:00.5", "2026-11-15T10:00:00.5"},
		{1082, "2026-11-15", "2026-11-15"},
		{3802, `{"a": 1, "b": [1, 2]}`, `{"a":1,"b":[1,2]}`},
		{1700, "12345678901234567890.000100", "12345678901234567890.000100"},
		{1007, "{1,2,3}", "{1,2,3}"},
	}
	for _, c := range cases {
		if got := string(appendPGText(nil, c.oid, pgTypeFor(c.oid).kind, []byte(c.in))); got != c.want {
			t.Errorf("oid %d %q: got %q want %q", c.oid, c.in, got, c.want)
		}
	}
	if pgTypeFor(99999).name != "oid 99999" || pgTypeFor(2950).kind != KindUUID {
		t.Fatal("type map")
	}
}

func TestKindMapping(t *testing.T) {
	for decl, want := range map[string]uint8{"INTEGER": KindInt, "varchar(20)": KindText, "BOOLEAN": KindBool, "REAL": KindFloat,
		"DATETIME": KindDateTime, "NUMERIC(10,2)": KindDecimal, "BLOB": KindBinary, "": KindUnknown, "JSON": KindJSON} {
		if got := sqliteKind(decl); got != want {
			t.Errorf("sqlite %q: %d", decl, got)
		}
	}
	for name, want := range map[string]uint8{"UNSIGNED BIGINT": KindInt, "DECIMAL": KindDecimal, "DOUBLE": KindFloat, "DATETIME": KindDateTime,
		"JSON": KindJSON, "VARBINARY": KindBinary, "VARCHAR": KindText, "TEXT": KindText} {
		if got := mysqlTypeKind(name); got != want {
			t.Errorf("mysql %q: %d", name, got)
		}
	}
}

func TestErrorKinds(t *testing.T) {
	for code, want := range map[string]string{"42601": "syntax", "42P01": "syntax", "28P01": "auth", "23505": "constraint", "25006": "readOnly", "57014": "cancelled", "42501": "permission", "08006": "connectionLost", "22012": "server"} {
		if got := pgKind(code); got != want {
			t.Errorf("pg %s: %s", code, got)
		}
	}
	for n, want := range map[uint16]string{1064: "syntax", 1045: "auth", 1792: "readOnly", 1317: "cancelled", 1062: "constraint", 1142: "permission", 1365: "server"} {
		if got := mysqlKind(n); got != want {
			t.Errorf("mysql %d: %s", n, got)
		}
	}
	for _, k := range errorKinds {
		if defaultMessages[k] == "" {
			t.Errorf("no message for %s", k)
		}
	}
	if p := positionIn("ab\ncdé f", 9); p == nil || p.Line != 2 || p.Col != 6 {
		t.Fatalf("%+v", p)
	}
}
