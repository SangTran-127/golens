package database

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

func appendFloat(dst []byte, v float64, bits int) []byte {
	a := math.Abs(v)
	if a != 0 && (a >= 1e21 || a < 1e-6) {
		return strconv.AppendFloat(dst, v, 'g', -1, bits)
	}
	return strconv.AppendFloat(dst, v, 'f', -1, bits)
}

func compactJSON(dst, v []byte) []byte {
	var buf bytes.Buffer
	if json.Compact(&buf, v) == nil {
		return append(dst, buf.Bytes()...)
	}
	return append(dst, v...)
}

func isoTimestamp(dst, v []byte) []byte {
	if len(v) < 19 || v[10] != ' ' {
		return append(dst, v...)
	}
	start := len(dst)
	dst = append(dst, v...)
	dst[start+10] = 'T'
	n := len(dst)
	for i := n - 1; i >= start+19; i-- {
		c := dst[i]
		if c == '+' || c == '-' {
			off := dst[i:]
			switch len(off) {
			case 3:
				return append(dst, ':', '0', '0')
			case 6:
				if off[3] == ':' {
					return dst
				}
			}
			return dst
		}
		if (c < '0' || c > '9') && c != ':' && c != '.' {
			return dst
		}
	}
	return dst
}

func formatTime(dst []byte, t time.Time) []byte {
	if t.Hour() == 0 && t.Minute() == 0 && t.Second() == 0 && t.Nanosecond() == 0 && t.Location() == time.UTC {
		return t.AppendFormat(dst, "2006-01-02")
	}
	return t.AppendFormat(dst, time.RFC3339Nano)
}

func appendValue(dst []byte, kind uint8, v any) []byte {
	switch x := v.(type) {
	case int64:
		if kind == KindBool {
			if x != 0 {
				return append(dst, "true"...)
			}
			return append(dst, "false"...)
		}
		return strconv.AppendInt(dst, x, 10)
	case uint64:
		return strconv.AppendUint(dst, x, 10)
	case float64:
		return appendFloat(dst, x, 64)
	case float32:
		return appendFloat(dst, float64(x), 32)
	case bool:
		return strconv.AppendBool(dst, x)
	case time.Time:
		return formatTime(dst, x)
	case string:
		return appendBytesAs(dst, kind, []byte(x))
	case []byte:
		return appendBytesAs(dst, kind, x)
	}
	return dst
}

func appendBytesAs(dst []byte, kind uint8, v []byte) []byte {
	switch kind {
	case KindBinary:
		return append(dst, v...)
	case KindJSON:
		return compactJSON(dst, v)
	case KindDateTime:
		return isoTimestamp(dst, v)
	}
	if !utf8.Valid(v) {
		dst = append(dst, '0', 'x')
		return hex.AppendEncode(dst, v)
	}
	return append(dst, v...)
}

func sqliteKind(decl string) uint8 {
	d := strings.ToUpper(decl)
	switch {
	case d == "":
		return KindUnknown
	case strings.Contains(d, "BOOL"):
		return KindBool
	case strings.Contains(d, "INT"):
		return KindInt
	case strings.Contains(d, "JSON"):
		return KindJSON
	case strings.Contains(d, "UUID"):
		return KindUUID
	case strings.Contains(d, "CHAR"), strings.Contains(d, "CLOB"), strings.Contains(d, "TEXT"):
		return KindText
	case strings.Contains(d, "BLOB"):
		return KindBinary
	case strings.Contains(d, "REAL"), strings.Contains(d, "FLOA"), strings.Contains(d, "DOUB"):
		return KindFloat
	case strings.Contains(d, "DATE"), strings.Contains(d, "TIME"):
		return KindDateTime
	case strings.Contains(d, "NUMERIC"), strings.Contains(d, "DECIMAL"):
		return KindDecimal
	}
	return KindText
}

func kindOfValue(v any) uint8 {
	switch v.(type) {
	case int64, uint64:
		return KindInt
	case float64, float32:
		return KindFloat
	case []byte:
		return KindBinary
	case time.Time:
		return KindDateTime
	case bool:
		return KindBool
	}
	return KindText
}

func mysqlTypeKind(typeName string) uint8 {
	t := strings.ToUpper(typeName)
	t = strings.TrimPrefix(t, "UNSIGNED ")
	switch t {
	case "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT", "YEAR":
		return KindInt
	case "DECIMAL":
		return KindDecimal
	case "FLOAT", "DOUBLE":
		return KindFloat
	case "DATE", "DATETIME", "TIMESTAMP", "TIME":
		return KindDateTime
	case "JSON":
		return KindJSON
	case "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "BINARY", "VARBINARY", "BIT", "GEOMETRY":
		return KindBinary
	}
	return KindText
}

type pgType struct {
	name string
	kind uint8
}

var pgTypes = map[uint32]pgType{
	16: {"bool", KindBool}, 17: {"bytea", KindBinary}, 18: {"char", KindText}, 19: {"name", KindText},
	20: {"int8", KindInt}, 21: {"int2", KindInt}, 23: {"int4", KindInt}, 24: {"regproc", KindText}, 25: {"text", KindText},
	26: {"oid", KindInt}, 28: {"xid", KindInt}, 114: {"json", KindJSON}, 142: {"xml", KindText}, 600: {"point", KindText},
	650: {"cidr", KindText}, 700: {"float4", KindFloat}, 701: {"float8", KindFloat}, 790: {"money", KindDecimal},
	829: {"macaddr", KindText}, 869: {"inet", KindText}, 1042: {"bpchar", KindText}, 1043: {"varchar", KindText},
	1082: {"date", KindDateTime}, 1083: {"time", KindDateTime}, 1114: {"timestamp", KindDateTime},
	1184: {"timestamptz", KindDateTime}, 1186: {"interval", KindDateTime}, 1266: {"timetz", KindDateTime},
	1560: {"bit", KindText}, 1562: {"varbit", KindText}, 1700: {"numeric", KindDecimal}, 2205: {"regclass", KindText},
	2950: {"uuid", KindUUID}, 3802: {"jsonb", KindJSON}, 3614: {"tsvector", KindText}, 3904: {"int4range", KindText},
	3926: {"int8range", KindText}, 3910: {"tstzrange", KindText}, 3912: {"daterange", KindText}, 2249: {"record", KindText},
	705: {"unknown", KindText}, 1000: {"_bool", KindText}, 1001: {"_bytea", KindText}, 1005: {"_int2", KindText},
	1007: {"_int4", KindText}, 1009: {"_text", KindText}, 1014: {"_bpchar", KindText}, 1015: {"_varchar", KindText},
	1016: {"_int8", KindText}, 1021: {"_float4", KindText}, 1022: {"_float8", KindText}, 1115: {"_timestamp", KindText},
	1182: {"_date", KindText}, 1185: {"_timestamptz", KindText}, 1231: {"_numeric", KindText}, 2951: {"_uuid", KindText},
	199: {"_json", KindText}, 3807: {"_jsonb", KindText},
}

func pgTypeFor(oid uint32) pgType {
	if t, ok := pgTypes[oid]; ok {
		return t
	}
	return pgType{name: "oid " + strconv.FormatUint(uint64(oid), 10), kind: KindText}
}

func appendPGText(dst []byte, oid uint32, kind uint8, v []byte) []byte {
	switch oid {
	case 16:
		if len(v) == 1 && v[0] == 't' {
			return append(dst, "true"...)
		}
		if len(v) == 1 && v[0] == 'f' {
			return append(dst, "false"...)
		}
	case 17:
		if len(v) >= 2 && v[0] == '\\' && v[1] == 'x' {
			n := hex.DecodedLen(len(v) - 2)
			start := len(dst)
			dst = append(dst, make([]byte, n)...)
			if _, err := hex.Decode(dst[start:], v[2:]); err == nil {
				return dst
			}
			dst = dst[:start]
		}
		return append(dst, v...)
	case 1114, 1184:
		return isoTimestamp(dst, v)
	case 114, 3802:
		return compactJSON(dst, v)
	}
	return append(dst, v...)
}
