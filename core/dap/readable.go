package dap

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	durationValue = regexp.MustCompile(`^(?:time\.Duration\()?(-?\d+)\)?$`)
	byteList      = regexp.MustCompile(`\[([0-9, ]*)\]\s*$`)
	timeWallExt   = regexp.MustCompile(`wall:\s*(\d+).*?ext:\s*(-?\d+)`)
	atomicVal     = regexp.MustCompile(`(?:v|val|value):\s*([^,}]+)`)
	sqlNullValid  = regexp.MustCompile(`,?\s*Valid:\s*(true|false)\s*\}?\s*$`)
	sqlNullVal    = regexp.MustCompile(`(?:String|Int64|Int32|Int16|Byte|Float64|Bool|Time):\s*(?:("(?:\\[\s\S]|[^"\\])*")|([^,}]+))`)
	urlFields     = regexp.MustCompile(`Scheme:\s*"([^"]*)".*?Host:\s*"([^"]*)".*?Path:\s*"([^"]*)".*?RawQuery:\s*"([^"]*)".*?Fragment:\s*"([^"]*)"`)
)

const (
	hasMonotonic   = 1 << 63
	minWallYear    = 1885
	wallToInternal = 59453308800
	unixToInternal = 62135596800
	maxPayloadSize = 64 * 1024
)

type VariablePayloadInspection struct {
	Type      string `json:"type"`
	Length    int    `json:"length"`
	Text      string `json:"text"`
	JSON      string `json:"json,omitempty"`
	HexDump   string `json:"hexDump"`
	Truncated bool   `json:"truncated"`
}

func Readable(typ, value string) string {
	cleanTyp := strings.TrimPrefix(typ, "*")

	if strings.Contains(typ, "struct {") {
		return strings.TrimPrefix(value, typ+" ")
	}

	switch {
	case cleanTyp == "time.Duration":
		if m := durationValue.FindStringSubmatch(strings.TrimSpace(value)); m != nil {
			if n, err := strconv.ParseInt(m[1], 10, 64); err == nil {
				return time.Duration(n).String()
			}
		}

	case cleanTyp == "net.IP":
		if ip, ok := formatIP(value); ok {
			return ip
		}

	case cleanTyp == "time.Time":
		if formatted, ok := formatTime(value); ok {
			return formatted
		}

	case cleanTyp == "[]byte" || cleanTyp == "[]uint8" || cleanTyp == "json.RawMessage":
		if formatted, ok := formatByteSlice(value); ok {
			return formatted
		}

	case cleanTyp == "url.URL" || strings.HasSuffix(cleanTyp, "/url.URL"):
		if formatted, ok := formatURL(value); ok {
			return formatted
		}

	case strings.HasPrefix(cleanTyp, "sync/atomic.") || strings.HasPrefix(cleanTyp, "atomic."):
		if formatted, ok := formatAtomic(cleanTyp, value); ok {
			return formatted
		}

	case strings.HasPrefix(cleanTyp, "database/sql.Null") || strings.HasPrefix(cleanTyp, "sql.Null"):
		if formatted, ok := formatSQLNull(value); ok {
			return formatted
		}
	}

	return value
}

func formatTime(value string) (string, bool) {
	if strings.TrimSpace(value) == "nil" || strings.TrimSpace(value) == "(*time.Time)(nil)" {
		return "<nil>", true
	}
	m := timeWallExt.FindStringSubmatch(value)
	if m == nil {
		return "", false
	}
	wall, errWall := strconv.ParseUint(m[1], 10, 64)
	ext, errExt := strconv.ParseInt(m[2], 10, 64)
	if errWall != nil || errExt != nil {
		return "", false
	}

	if wall == 0 && ext == 0 {
		return "0001-01-01 00:00:00Z", true
	}

	var secUnix, nsec int64
	nsec = int64(wall & 0x3fffffff)

	if (wall & hasMonotonic) != 0 {
		secInternal := int64((wall<<1)>>31) + wallToInternal
		secUnix = secInternal - unixToInternal
	} else {
		secUnix = ext - unixToInternal
	}

	t := time.Unix(secUnix, nsec).UTC()
	return t.Format("2006-01-02 15:04:05.999Z07:00"), true
}

func extractBytesFromDelveValue(value string) ([]byte, bool) {
	trimmedVal := strings.TrimSpace(value)
	if !strings.HasSuffix(trimmedVal, "]") {
		return nil, false
	}
	openIdx := strings.LastIndex(trimmedVal, "[")
	if openIdx < 0 {
		return nil, false
	}
	rawParts := strings.TrimSpace(trimmedVal[openIdx+1 : len(trimmedVal)-1])
	if rawParts == "" {
		return []byte{}, true
	}

	count := 1
	for i := 0; i < len(rawParts); i++ {
		if rawParts[i] == ',' {
			count++
		}
	}
	b := make([]byte, 0, count)

	cur := 0
	hasNum := false
	for i := 0; i < len(rawParts); i++ {
		c := rawParts[i]
		if c >= '0' && c <= '9' {
			cur = cur*10 + int(c-'0')
			if cur > 255 {
				return nil, false
			}
			hasNum = true
		} else if c == ',' {
			if !hasNum {
				return nil, false
			}
			b = append(b, byte(cur))
			cur = 0
			hasNum = false
		} else if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			continue
		} else {
			return nil, false
		}
	}
	if hasNum {
		b = append(b, byte(cur))
	}
	return b, true
}

func formatByteSlice(value string) (string, bool) {
	b, ok := extractBytesFromDelveValue(value)
	if !ok {
		return "", false
	}
	total := len(b)
	if total == 0 {
		return "[]byte(len=0) \"\"", true
	}

	printableCount := 0
	for _, c := range b {
		if (c >= 32 && c <= 126) || c == '\n' || c == '\r' || c == '\t' {
			printableCount++
		}
	}

	ratio := float64(printableCount) / float64(total)
	if utf8.Valid(b) && ratio >= 0.80 {
		preview := string(b)
		if len(preview) > 60 {
			cut := 57
			for cut > 0 && !utf8.RuneStart(preview[cut]) {
				cut--
			}
			preview = preview[:cut] + "..."
		}
		return fmt.Sprintf("[]byte(len=%d) %q", total, preview), true
	}

	hexPreview := hex.EncodeToString(b)
	if len(hexPreview) > 32 {
		hexPreview = hexPreview[:29] + "..."
	}
	return fmt.Sprintf("[]byte(len=%d) 0x%s", total, hexPreview), true
}

func formatURL(value string) (string, bool) {
	if strings.TrimSpace(value) == "nil" || strings.TrimSpace(value) == "(*url.URL)(nil)" {
		return "<nil>", true
	}
	m := urlFields.FindStringSubmatch(value)
	if m != nil {
		u := url.URL{
			Scheme:   m[1],
			Host:     m[2],
			Path:     m[3],
			RawQuery: m[4],
			Fragment: m[5],
		}
		return fmt.Sprintf("url.URL(%q)", u.String()), true
	}
	return "", false
}

func formatAtomic(cleanTyp, value string) (string, bool) {
	m := atomicVal.FindStringSubmatch(value)
	if m == nil {
		return "", false
	}
	val := strings.TrimSpace(m[1])
	shortTyp := cleanTyp
	if idx := strings.LastIndex(shortTyp, "."); idx >= 0 {
		shortTyp = "atomic." + shortTyp[idx+1:]
	}
	if strings.HasSuffix(cleanTyp, "Bool") {
		if val == "1" || val == "true" {
			return shortTyp + "(true)", true
		}
		return shortTyp + "(false)", true
	}
	return fmt.Sprintf("%s(%s)", shortTyp, val), true
}

func formatSQLNull(value string) (string, bool) {
	vm := sqlNullValid.FindStringSubmatch(value)
	if vm != nil && vm[1] == "false" {
		return "<null>", true
	}
	if vm == nil || vm[1] != "true" {
		return "", false
	}

	if strings.Contains(value, "Time:") || strings.Contains(value, "time.Time") {
		if tStr, ok := formatTime(value); ok {
			return tStr, true
		}
	}

	valm := sqlNullVal.FindStringSubmatch(value)
	if valm != nil {
		raw := valm[1]
		if raw == "" {
			raw = valm[2]
		}
		raw = strings.TrimSpace(raw)
		if strings.HasPrefix(raw, `"`) && strings.HasSuffix(raw, `"`) && len(raw) >= 2 {
			if unq, err := strconv.Unquote(raw); err == nil {
				return unq, true
			}
			return raw[1 : len(raw)-1], true
		}
		return raw, true
	}
	return "<valid>", true
}

func formatIP(value string) (string, bool) {
	b, ok := extractBytesFromDelveValue(value)
	if !ok || (len(b) != 4 && len(b) != 16) {
		return "", false
	}
	return net.IP(b).String(), true
}

func maxJSONNestingDepth(b []byte) int {
	depth, maxDepth := 0, 0
	inString := false
	escaped := false
	for i := 0; i < len(b); i++ {
		c := b[i]
		if inString {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				inString = false
			}
			continue
		}
		switch c {
		case '"':
			inString = true
		case '{', '[':
			depth++
			if depth > maxDepth {
				maxDepth = depth
			}
		case '}', ']':
			if depth > 0 {
				depth--
			}
		}
	}
	return maxDepth
}

func InspectRawVariablePayload(typ, value string) VariablePayloadInspection {
	res := VariablePayloadInspection{
		Type: typ,
	}

	var rawBytes []byte
	if b, ok := extractBytesFromDelveValue(value); ok {
		rawBytes = b
	} else {
		trimmed := strings.TrimSpace(value)
		if strings.HasPrefix(trimmed, `"`) && strings.HasSuffix(trimmed, `"`) {
			if unq, err := strconv.Unquote(trimmed); err == nil {
				rawBytes = []byte(unq)
			} else {
				rawBytes = []byte(trimmed)
			}
		} else {
			rawBytes = []byte(value)
		}
	}

	res.Length = len(rawBytes)
	truncated := false
	inspectBytes := rawBytes
	if len(inspectBytes) > maxPayloadSize {
		inspectBytes = inspectBytes[:maxPayloadSize]
		truncated = true
	}
	res.Truncated = truncated

	text := string(inspectBytes)
	if truncated {
		text += "\n... (truncated at 64 KB)"
	}
	res.Text = text

	if json.Valid(inspectBytes) {
		if maxJSONNestingDepth(inspectBytes) <= 100 {
			var jsonDst bytes.Buffer
			if json.Indent(&jsonDst, inspectBytes, "", "  ") == nil {
				res.JSON = jsonDst.String()
			}
		} else {
			res.JSON = string(inspectBytes)
		}
		if truncated && res.JSON != "" {
			res.JSON += "\n... (truncated at 64 KB)"
		}
	}

	hexDump := hex.Dump(inspectBytes)
	if truncated {
		hexDump += "\n... (truncated at 64 KB)"
	}
	res.HexDump = strings.TrimRight(hexDump, "\n")

	return res
}
