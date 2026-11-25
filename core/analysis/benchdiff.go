package analysis

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
)

type BenchmarkEntry struct {
	Name        string  `json:"name"`
	NsPerOp     float64 `json:"nsPerOp"`
	BytesPerOp  int64   `json:"bytesPerOp"`
	AllocsPerOp int64   `json:"allocsPerOp"`
}

type BenchmarkDiffItem struct {
	Name                string  `json:"name"`
	BaselineNsPerOp     float64 `json:"baselineNsPerOp"`
	CurrentNsPerOp      float64 `json:"currentNsPerOp"`
	NsDeltaPct          float64 `json:"nsDeltaPct"`
	BaselineBytesPerOp  int64   `json:"baselineBytesPerOp"`
	CurrentBytesPerOp   int64   `json:"currentBytesPerOp"`
	BytesDeltaPct       float64 `json:"bytesDeltaPct"`
	BaselineAllocsPerOp int64   `json:"baselineAllocsPerOp"`
	CurrentAllocsPerOp  int64   `json:"currentAllocsPerOp"`
	AllocsDeltaPct      float64 `json:"allocsDeltaPct"`
	Verdict             string  `json:"verdict"`
	InlineBadge         string  `json:"inlineBadge"`
}

type BenchmarkComparisonReport struct {
	Items          []BenchmarkDiffItem `json:"items"`
	FasterCount    int                 `json:"fasterCount"`
	RegressedCount int                 `json:"regressedCount"`
	UnchangedCount int                 `json:"unchangedCount"`
}

func NormalizeBenchmarkName(raw string) string {
	name := strings.TrimSpace(raw)
	if name == "" {
		return ""
	}
	if idx := strings.LastIndex(name, "::"); idx >= 0 && idx+2 < len(name) {
		name = name[idx+2:]
	}
	if idx := strings.LastIndexByte(name, '\x00'); idx >= 0 && idx+1 < len(name) {
		name = name[idx+1:]
	}
	if dash := strings.LastIndexByte(name, '-'); dash > 0 && dash+1 < len(name) {
		allDigits := true
		for i := dash + 1; i < len(name); i++ {
			if name[i] < '0' || name[i] > '9' {
				allDigits = false
				break
			}
		}
		if allDigits {
			name = name[:dash]
		}
	}
	return name
}

func CompareBenchmarkRuns(baselineRaw string, currentRaw string) (string, error) {
	baseOrder, baseMap := parseBenchmarkRunInput(baselineRaw)
	curOrder, curMap := parseBenchmarkRunInput(currentRaw)

	report := BenchmarkComparisonReport{
		Items: []BenchmarkDiffItem{},
	}

	if len(curOrder) == 0 && len(baseOrder) > 0 {
		for _, name := range baseOrder {
			base := baseMap[name]
			report.Items = append(report.Items, BenchmarkDiffItem{
				Name:                name,
				BaselineNsPerOp:     base.NsPerOp,
				CurrentNsPerOp:      base.NsPerOp,
				NsDeltaPct:          0,
				BaselineBytesPerOp:  base.BytesPerOp,
				CurrentBytesPerOp:   base.BytesPerOp,
				BytesDeltaPct:       0,
				BaselineAllocsPerOp: base.AllocsPerOp,
				CurrentAllocsPerOp:  base.AllocsPerOp,
				AllocsDeltaPct:      0,
				Verdict:             "unchanged",
				InlineBadge:         "≈0.0% ns/op",
			})
			report.UnchangedCount++
		}
		data, err := json.Marshal(report)
		if err != nil {
			return "", err
		}
		return string(data), nil
	}

	for _, name := range curOrder {
		cur := curMap[name]
		base, hasBase := baseMap[name]
		if !hasBase || base.NsPerOp <= 0 {
			report.Items = append(report.Items, BenchmarkDiffItem{
				Name:               name,
				CurrentNsPerOp:     cur.NsPerOp,
				CurrentBytesPerOp:  cur.BytesPerOp,
				CurrentAllocsPerOp: cur.AllocsPerOp,
				Verdict:            "new",
				InlineBadge:        "new",
			})
			continue
		}

		nsDeltaPct := ((cur.NsPerOp - base.NsPerOp) / base.NsPerOp) * 100.0
		var bytesDeltaPct float64
		if base.BytesPerOp > 0 {
			bytesDeltaPct = (float64(cur.BytesPerOp-base.BytesPerOp) / float64(base.BytesPerOp)) * 100.0
		}
		var allocsDeltaPct float64
		if base.AllocsPerOp > 0 {
			allocsDeltaPct = (float64(cur.AllocsPerOp-base.AllocsPerOp) / float64(base.AllocsPerOp)) * 100.0
		}

		var verdict string
		var inlineBadge string
		if nsDeltaPct <= -3.0 {
			verdict = "faster"
			report.FasterCount++
			inlineBadge = fmt.Sprintf("%.1f%% faster", nsDeltaPct)
		} else if nsDeltaPct >= 5.0 {
			verdict = "regressed"
			report.RegressedCount++
			inlineBadge = fmt.Sprintf("+%.1f%% slower", nsDeltaPct)
		} else {
			verdict = "unchanged"
			report.UnchangedCount++
			inlineBadge = fmt.Sprintf("≈%.1f%% ns/op", math.Abs(nsDeltaPct))
		}

		report.Items = append(report.Items, BenchmarkDiffItem{
			Name:                name,
			BaselineNsPerOp:     base.NsPerOp,
			CurrentNsPerOp:      cur.NsPerOp,
			NsDeltaPct:          nsDeltaPct,
			BaselineBytesPerOp:  base.BytesPerOp,
			CurrentBytesPerOp:   cur.BytesPerOp,
			BytesDeltaPct:       bytesDeltaPct,
			BaselineAllocsPerOp: base.AllocsPerOp,
			CurrentAllocsPerOp:  cur.AllocsPerOp,
			AllocsDeltaPct:      allocsDeltaPct,
			Verdict:             verdict,
			InlineBadge:         inlineBadge,
		})
	}

	data, err := json.Marshal(report)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func parseBenchmarkRunInput(raw string) ([]string, map[string]BenchmarkEntry) {
	order := make([]string, 0)
	byName := map[string]BenchmarkEntry{}
	seen := map[string]bool{}

	addEntry := func(entry BenchmarkEntry) {
		norm := NormalizeBenchmarkName(entry.Name)
		if norm == "" || entry.NsPerOp <= 0 {
			return
		}
		entry.Name = norm
		if !seen[norm] {
			seen[norm] = true
			order = append(order, norm)
		}
		byName[norm] = entry
	}

	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return order, byName
	}

	if strings.HasPrefix(trimmed, "{") && json.Valid([]byte(trimmed)) {
		if parsedJSONMap(trimmed, addEntry) {
			return order, byName
		}
	}

	if strings.HasPrefix(trimmed, "[") && json.Valid([]byte(trimmed)) {
		var list []BenchmarkEntry
		if err := json.Unmarshal([]byte(trimmed), &list); err == nil {
			for _, item := range list {
				addEntry(item)
			}
			return order, byName
		}
	}

	for _, line := range strings.Split(trimmed, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "{") {
			var ev struct {
				Output string `json:"Output"`
			}
			if json.Unmarshal([]byte(line), &ev) == nil && ev.Output != "" {
				line = strings.TrimSpace(ev.Output)
			}
		}
		if entry, ok := parseBenchmarkLine(line); ok {
			addEntry(entry)
		}
	}

	return order, byName
}

func parsedJSONMap(trimmed string, addEntry func(BenchmarkEntry)) bool {
	dec := json.NewDecoder(bytes.NewReader([]byte(trimmed)))
	tok, err := dec.Token()
	if err != nil || tok != json.Delim('{') {
		return false
	}
	matchedAny := false
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return false
		}
		key, ok := keyTok.(string)
		if !ok {
			return false
		}
		var rawVal json.RawMessage
		if err := dec.Decode(&rawVal); err != nil {
			return false
		}
		if key == "Action" || key == "Output" || key == "Package" || key == "Test" {
			continue
		}
		var strMetric string
		if json.Unmarshal(rawVal, &strMetric) == nil {
			if entry, ok := parseMetricSummary(key, strMetric); ok {
				addEntry(entry)
				matchedAny = true
			}
			continue
		}
		var obj struct {
			Name        string  `json:"name"`
			NsPerOp     float64 `json:"nsPerOp"`
			BytesPerOp  int64   `json:"bytesPerOp"`
			AllocsPerOp int64   `json:"allocsPerOp"`
		}
		if json.Unmarshal(rawVal, &obj) == nil && obj.NsPerOp > 0 {
			name := key
			if obj.Name != "" {
				name = obj.Name
			}
			addEntry(BenchmarkEntry{
				Name:        name,
				NsPerOp:     obj.NsPerOp,
				BytesPerOp:  obj.BytesPerOp,
				AllocsPerOp: obj.AllocsPerOp,
			})
			matchedAny = true
		}
	}
	return matchedAny
}

func parseMetricSummary(name string, summary string) (BenchmarkEntry, bool) {
	cleaned := strings.ReplaceAll(summary, "·", " ")
	fields := strings.Fields(cleaned)
	entry := BenchmarkEntry{Name: name}
	foundNs := false
	for i := 0; i+1 < len(fields); i++ {
		valStr := fields[i]
		unit := fields[i+1]
		switch unit {
		case "ns/op":
			if v, err := strconv.ParseFloat(valStr, 64); err == nil && v > 0 {
				entry.NsPerOp = v
				foundNs = true
				i++
			}
		case "B/op":
			if v, err := strconv.ParseFloat(valStr, 64); err == nil {
				entry.BytesPerOp = int64(math.Round(v))
				i++
			}
		case "allocs/op":
			if v, err := strconv.ParseFloat(valStr, 64); err == nil {
				entry.AllocsPerOp = int64(math.Round(v))
				i++
			}
		}
	}
	return entry, foundNs
}

func parseBenchmarkLine(line string) (BenchmarkEntry, bool) {
	cleaned := strings.ReplaceAll(line, "·", " ")
	fields := strings.Fields(cleaned)
	if len(fields) < 3 {
		return BenchmarkEntry{}, false
	}
	rawName := fields[0]
	norm := NormalizeBenchmarkName(rawName)
	if !strings.HasPrefix(norm, "Benchmark") {
		return BenchmarkEntry{}, false
	}
	if rest := norm[len("Benchmark"):]; rest != "" && rest[0] >= 'a' && rest[0] <= 'z' {
		return BenchmarkEntry{}, false
	}

	entry := BenchmarkEntry{Name: norm}
	startIdx := 1
	if fields[2] != "ns/op" {
		iters, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || iters <= 0 {
			return BenchmarkEntry{}, false
		}
		startIdx = 2
	}

	foundNs := false
	for i := startIdx; i+1 < len(fields); i++ {
		valStr := fields[i]
		unit := fields[i+1]
		switch unit {
		case "ns/op":
			if v, err := strconv.ParseFloat(valStr, 64); err == nil && v > 0 {
				entry.NsPerOp = v
				foundNs = true
				i++
			}
		case "B/op":
			if v, err := strconv.ParseFloat(valStr, 64); err == nil {
				entry.BytesPerOp = int64(math.Round(v))
				i++
			}
		case "allocs/op":
			if v, err := strconv.ParseFloat(valStr, 64); err == nil {
				entry.AllocsPerOp = int64(math.Round(v))
				i++
			}
		}
	}
	return entry, foundNs
}
