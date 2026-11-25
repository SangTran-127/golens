package testutil

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const maxProfileEntries = 500

type ProfileEntry struct {
	Function      string   `json:"function"`
	File          string   `json:"file"`
	Line          int      `json:"line"`
	Flat          int64    `json:"flat"`
	FlatPercent   float64  `json:"flatPercent"`
	Cum           int64    `json:"cum"`
	CumPercent    float64  `json:"cumPercent"`
	FormattedFlat string   `json:"formattedFlat"`
	FormattedCum  string   `json:"formattedCum"`
	Children      []string `json:"children,omitempty"`
	Callers       []string `json:"callers,omitempty"`
	Count         int64    `json:"count,omitempty"`
}

type pprofValueType struct {
	typ  int64
	unit int64
}

type pprofSample struct {
	locationIDs []uint64
	values      []int64
}

type pprofLine struct {
	functionID uint64
	line       int64
}

type pprofLocation struct {
	id    uint64
	lines []pprofLine
}

type pprofFunction struct {
	id         uint64
	name       int64
	systemName int64
	filename   int64
	startLine  int64
}

type pprofProfile struct {
	sampleTypes []pprofValueType
	samples     []pprofSample
	locations   []pprofLocation
	functions   []pprofFunction
	stringTable []string
}

func (p *pprofProfile) stringAt(idx int64) string {
	if idx < 0 || int(idx) >= len(p.stringTable) {
		return ""
	}
	return p.stringTable[idx]
}

func ParsePprofFiles(cpuPaths []string, memPaths []string, workspaceRoot string, modulePath string, suiteDirs map[string]string) (cpu []ProfileEntry, mem []ProfileEntry) {
	cpu, _ = parsePprofGroupMode(cpuPaths, "cpu", workspaceRoot, modulePath, suiteDirs, false)
	mem, _ = parsePprofGroupMode(memPaths, "memory", workspaceRoot, modulePath, suiteDirs, false)
	return cpu, mem
}

func ParseAllPprofFiles(cpuPaths, memPaths, blockPaths, mutexPaths []string, workspaceRoot, modulePath string, suiteDirs map[string]string) (cpu, mem, block, mutex []ProfileEntry) {
	cpu, _ = parsePprofGroupMode(cpuPaths, "cpu", workspaceRoot, modulePath, suiteDirs, false)
	mem, _ = parsePprofGroupMode(memPaths, "memory", workspaceRoot, modulePath, suiteDirs, false)
	block, _ = parsePprofGroupMode(blockPaths, "block", workspaceRoot, modulePath, suiteDirs, false)
	mutex, _ = parsePprofGroupMode(mutexPaths, "mutex", workspaceRoot, modulePath, suiteDirs, false)
	return cpu, mem, block, mutex
}

func ParseSinglePprof(path string, isCPU bool, workspaceRoot, modulePath string, suiteDirs map[string]string) ([]ProfileEntry, error) {
	mode := "memory"
	if isCPU {
		mode = "cpu"
	}
	return parsePprofGroupMode([]string{path}, mode, workspaceRoot, modulePath, suiteDirs, true)
}

type ImportedProfile struct {
	Mode    string         `json:"mode"`
	Entries []ProfileEntry `json:"entries"`
	Error   string         `json:"error,omitempty"`
}

func detectProfileMode(path string, prof *pprofProfile) string {
	lower := strings.ToLower(path)
	if strings.Contains(lower, "mutex") {
		return "mutex"
	}
	if strings.Contains(lower, "block") {
		return "block"
	}
	hasCPU := false
	for _, st := range prof.sampleTypes {
		t := prof.stringAt(st.typeIndex())
		if t == "alloc_space" || t == "inuse_space" || t == "alloc_objects" || t == "inuse_objects" {
			return "memory"
		}
		if t == "contentions" || t == "delay" {
			if strings.Contains(lower, "mutex") {
				return "mutex"
			}
			return "block"
		}
		if t == "cpu" {
			hasCPU = true
		}
	}
	if !hasCPU && strings.Contains(strings.ToLower(filepath.Base(path)), "mem") {
		return "memory"
	}
	return "cpu"
}

func ParseProfile(path string, limit int) ([]ProfileEntry, error) {
	prof, err := readPprofFile(path)
	if err != nil {
		return nil, err
	}
	mode := detectProfileMode(path, prof)
	entries, err := parsePprofGroupMode([]string{path}, mode, filepath.Dir(path), "", nil, true)
	if err != nil {
		return nil, err
	}
	if limit > 0 && len(entries) > limit {
		entries = entries[:limit]
	}
	return entries, nil
}

func ParseProfileFileJSON(path string) string {
	prof, err := readPprofFile(path)
	if err != nil {
		b, _ := json.Marshal(ImportedProfile{Mode: "cpu", Entries: []ProfileEntry{}, Error: err.Error()})
		return string(b)
	}
	mode := detectProfileMode(path, prof)
	entries, err := ParseProfile(path, 50)
	if err != nil {
		b, _ := json.Marshal(ImportedProfile{Mode: mode, Entries: []ProfileEntry{}, Error: err.Error()})
		return string(b)
	}
	if entries == nil {
		entries = []ProfileEntry{}
	}
	b, _ := json.Marshal(ImportedProfile{Mode: mode, Entries: entries})
	return string(b)
}

type profileAccumulator struct {
	function string
	file     string
	line     int
	flat     int64
	cum      int64
	count    int64
	children map[string]int64
	callers  map[string]int64
}

type stackFrame struct {
	function string
	file     string
	line     int
}

func parsePprofGroup(paths []string, isCPU bool, workspaceRoot, modulePath string, suiteDirs map[string]string, strictErr bool) ([]ProfileEntry, error) {
	mode := "memory"
	if isCPU {
		mode = "cpu"
	}
	return parsePprofGroupMode(paths, mode, workspaceRoot, modulePath, suiteDirs, strictErr)
}

func parsePprofGroupMode(paths []string, mode string, workspaceRoot, modulePath string, suiteDirs map[string]string, strictErr bool) ([]ProfileEntry, error) {
	modRoot := workspaceRoot
	if modulePath == "" && workspaceRoot != "" {
		if r, m := FindModuleRoot(workspaceRoot); m != "" {
			modRoot = r
			modulePath = m
		}
	}

	entriesByFunc := make(map[string]*profileAccumulator)
	var totalValue int64

	for _, path := range paths {
		if path == "" {
			continue
		}
		prof, err := readPprofFile(path)
		if err != nil {
			if strictErr {
				return nil, err
			}
			continue
		}
		valIdx := selectValueIndexForMode(prof, mode)
		if valIdx < 0 {
			continue
		}
		countIdx := selectCountIndex(prof)

		locMap := make(map[uint64]pprofLocation, len(prof.locations))
		for _, loc := range prof.locations {
			locMap[loc.id] = loc
		}
		fnMap := make(map[uint64]pprofFunction, len(prof.functions))
		for _, fn := range prof.functions {
			fnMap[fn.id] = fn
		}

		for _, sample := range prof.samples {
			if valIdx >= len(sample.values) || len(sample.locationIDs) == 0 {
				continue
			}
			val := sample.values[valIdx]
			if val <= 0 {
				continue
			}
			var sampleCount int64
			if countIdx >= 0 && countIdx < len(sample.values) {
				sampleCount = sample.values[countIdx]
			}

			var frames []stackFrame
			for _, locID := range sample.locationIDs {
				loc, ok := locMap[locID]
				if !ok {
					continue
				}
				for _, ln := range loc.lines {
					fn, ok := fnMap[ln.functionID]
					if !ok {
						continue
					}
					fnName := prof.stringAt(fn.name)
					if fnName == "" {
						fnName = prof.stringAt(fn.systemName)
					}
					if fnName == "" {
						continue
					}
					rawFile := prof.stringAt(fn.filename)
					resolvedFile := resolveProfileFile(rawFile, workspaceRoot, modRoot, modulePath, suiteDirs)
					lineNo := int(fn.startLine)
					if lineNo <= 0 {
						lineNo = int(ln.line)
					}
					frames = append(frames, stackFrame{
						function: fnName,
						file:     resolvedFile,
						line:     lineNo,
					})
				}
			}

			if len(frames) == 0 {
				continue
			}

			totalValue += val

			leaf := frames[0]
			leafAcc := getOrCreateAccumulator(entriesByFunc, leaf)
			leafAcc.flat += val
			leafAcc.count += sampleCount

			seenInSample := make(map[string]bool, len(frames))
			for _, fr := range frames {
				if seenInSample[fr.function] {
					continue
				}
				seenInSample[fr.function] = true
				acc := getOrCreateAccumulator(entriesByFunc, fr)
				acc.cum += val
			}

			seenEdges := make(map[[2]string]bool, len(frames))
			for i := 1; i < len(frames); i++ {
				callerFn := frames[i].function
				calleeFn := frames[i-1].function
				if callerFn == calleeFn {
					continue
				}
				edge := [2]string{callerFn, calleeFn}
				if seenEdges[edge] {
					continue
				}
				seenEdges[edge] = true
				callerAcc := getOrCreateAccumulator(entriesByFunc, frames[i])
				calleeAcc := getOrCreateAccumulator(entriesByFunc, frames[i-1])
				callerAcc.children[calleeFn] += val
				calleeAcc.callers[callerFn] += val
			}
		}
	}

	if len(entriesByFunc) == 0 || totalValue <= 0 {
		return []ProfileEntry{}, nil
	}

	out := make([]ProfileEntry, 0, len(entriesByFunc))
	for _, acc := range entriesByFunc {
		if acc.flat == 0 && acc.cum == 0 {
			continue
		}
		flatPct := math.Round((float64(acc.flat)*100.0/float64(totalValue))*10) / 10
		cumPct := math.Round((float64(acc.cum)*100.0/float64(totalValue))*10) / 10
		var fmtFlat, fmtCum string
		if mode == "memory" {
			fmtFlat = formatBytes(acc.flat)
			fmtCum = formatBytes(acc.cum)
		} else {
			fmtFlat = formatDurationNanos(acc.flat)
			fmtCum = formatDurationNanos(acc.cum)
		}
		out = append(out, ProfileEntry{
			Function:      acc.function,
			File:          acc.file,
			Line:          acc.line,
			Flat:          acc.flat,
			FlatPercent:   flatPct,
			Cum:           acc.cum,
			CumPercent:    cumPct,
			FormattedFlat: fmtFlat,
			FormattedCum:  fmtCum,
			Children:      sortedEdgeNames(acc.children),
			Callers:       sortedEdgeNames(acc.callers),
			Count:         acc.count,
		})
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Flat != out[j].Flat {
			return out[i].Flat > out[j].Flat
		}
		if out[i].Cum != out[j].Cum {
			return out[i].Cum > out[j].Cum
		}
		return out[i].Function < out[j].Function
	})

	if len(out) > maxProfileEntries {
		out = out[:maxProfileEntries]
	}

	return out, nil
}

func sortedEdgeNames(edges map[string]int64) []string {
	if len(edges) == 0 {
		return nil
	}
	names := make([]string, 0, len(edges))
	for name := range edges {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		wi, wj := edges[names[i]], edges[names[j]]
		if wi != wj {
			return wi > wj
		}
		return names[i] < names[j]
	})
	return names
}

func getOrCreateAccumulator(m map[string]*profileAccumulator, fr stackFrame) *profileAccumulator {
	acc, exists := m[fr.function]
	if !exists {
		acc = &profileAccumulator{
			function: fr.function,
			file:     fr.file,
			line:     fr.line,
			children: make(map[string]int64),
			callers:  make(map[string]int64),
		}
		m[fr.function] = acc
		return acc
	}
	if acc.file == "" && fr.file != "" {
		acc.file = fr.file
	}
	if acc.line <= 0 && fr.line > 0 {
		acc.line = fr.line
	}
	return acc
}

func resolveProfileFile(rawFile, workspaceRoot, modRoot, modulePath string, suiteDirs map[string]string) string {
	if rawFile == "" {
		return ""
	}
	if filepath.IsAbs(rawFile) {
		cleaned := filepath.Clean(rawFile)
		if _, err := os.Stat(cleaned); err == nil {
			return cleaned
		}
	}
	importPath, baseName := splitImportAndFile(rawFile)
	return resolveCoverageFile(rawFile, importPath, baseName, workspaceRoot, modRoot, modulePath, suiteDirs)
}

func selectValueIndex(prof *pprofProfile, isCPU bool) int {
	if isCPU {
		return selectValueIndexForMode(prof, "cpu")
	}
	return selectValueIndexForMode(prof, "memory")
}

func selectValueIndexForMode(prof *pprofProfile, mode string) int {
	n := len(prof.sampleTypes)
	if n == 0 {
		return 0
	}
	switch mode {
	case "block", "mutex":
		for i, st := range prof.sampleTypes {
			if prof.stringAt(st.typeIndex()) == "delay" || prof.stringAt(st.unitIndex()) == "nanoseconds" {
				return i
			}
		}
		return n - 1
	case "memory":
		for i, st := range prof.sampleTypes {
			if prof.stringAt(st.typeIndex()) == "alloc_space" {
				return i
			}
		}
		for i, st := range prof.sampleTypes {
			if prof.stringAt(st.typeIndex()) == "inuse_space" {
				return i
			}
		}
		for i, st := range prof.sampleTypes {
			if prof.stringAt(st.unitIndex()) == "bytes" {
				return i
			}
		}
		return n - 1
	default:
		for i, st := range prof.sampleTypes {
			if prof.stringAt(st.typeIndex()) == "cpu" && prof.stringAt(st.unitIndex()) == "nanoseconds" {
				return i
			}
		}
		for i, st := range prof.sampleTypes {
			if prof.stringAt(st.unitIndex()) == "nanoseconds" {
				return i
			}
		}
		return n - 1
	}
}

func selectCountIndex(prof *pprofProfile) int {
	for i, st := range prof.sampleTypes {
		if prof.stringAt(st.typeIndex()) == "contentions" || prof.stringAt(st.unitIndex()) == "count" {
			return i
		}
	}
	return -1
}

func (vt pprofValueType) typeIndex() int64 { return vt.typ }
func (vt pprofValueType) unitIndex() int64 { return vt.unit }

func formatDurationNanos(v int64) string {
	switch {
	case v < 1_000:
		return fmt.Sprintf("%dns", v)
	case v < 1_000_000:
		return fmt.Sprintf("%.1fµs", float64(v)/1e3)
	case v < 1_000_000_000:
		return fmt.Sprintf("%.2fms", float64(v)/1e6)
	default:
		return fmt.Sprintf("%.2fs", float64(v)/1e9)
	}
}

func formatBytes(v int64) string {
	switch {
	case v < 1024:
		return fmt.Sprintf("%d B", v)
	case v < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(v)/1024)
	default:
		return fmt.Sprintf("%.2f MB", float64(v)/(1024*1024))
	}
}

func readPprofFile(path string) (*pprofProfile, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return nil, fmt.Errorf("empty profile")
	}
	data := raw
	if len(raw) >= 2 && raw[0] == 0x1f && raw[1] == 0x8b {
		zr, err := gzip.NewReader(bytes.NewReader(raw))
		if err != nil {
			return nil, err
		}
		defer func() { _ = zr.Close() }()
		decompressed, err := io.ReadAll(zr)
		if err != nil {
			return nil, err
		}
		data = decompressed
	}
	return decodeProfile(data)
}

func decodeProfile(b []byte) (*pprofProfile, error) {
	prof := &pprofProfile{}
	for len(b) > 0 {
		fieldNum, wireType, n, ok := readTag(b)
		if !ok {
			return nil, fmt.Errorf("invalid protobuf tag")
		}
		b = b[n:]
		switch fieldNum {
		case 1:
			if wireType != 2 {
				return nil, fmt.Errorf("unexpected wire type for sample_type")
			}
			msg, m, ok := readBytes(b)
			if !ok {
				return nil, fmt.Errorf("truncated sample_type")
			}
			b = b[m:]
			vt, ok := decodeValueType(msg)
			if !ok {
				return nil, fmt.Errorf("invalid sample_type")
			}
			prof.sampleTypes = append(prof.sampleTypes, vt)
		case 2:
			if wireType != 2 {
				return nil, fmt.Errorf("unexpected wire type for sample")
			}
			msg, m, ok := readBytes(b)
			if !ok {
				return nil, fmt.Errorf("truncated sample")
			}
			b = b[m:]
			s, ok := decodeSample(msg)
			if !ok {
				return nil, fmt.Errorf("invalid sample")
			}
			prof.samples = append(prof.samples, s)
		case 4:
			if wireType != 2 {
				return nil, fmt.Errorf("unexpected wire type for location")
			}
			msg, m, ok := readBytes(b)
			if !ok {
				return nil, fmt.Errorf("truncated location")
			}
			b = b[m:]
			loc, ok := decodeLocation(msg)
			if !ok {
				return nil, fmt.Errorf("invalid location")
			}
			prof.locations = append(prof.locations, loc)
		case 5:
			if wireType != 2 {
				return nil, fmt.Errorf("unexpected wire type for function")
			}
			msg, m, ok := readBytes(b)
			if !ok {
				return nil, fmt.Errorf("truncated function")
			}
			b = b[m:]
			fn, ok := decodeFunction(msg)
			if !ok {
				return nil, fmt.Errorf("invalid function")
			}
			prof.functions = append(prof.functions, fn)
		case 6:
			if wireType != 2 {
				return nil, fmt.Errorf("unexpected wire type for string_table")
			}
			strBytes, m, ok := readBytes(b)
			if !ok {
				return nil, fmt.Errorf("truncated string_table")
			}
			b = b[m:]
			prof.stringTable = append(prof.stringTable, string(strBytes))
		default:
			m, ok := skipField(wireType, b)
			if !ok {
				return nil, fmt.Errorf("failed to skip field %d", fieldNum)
			}
			b = b[m:]
		}
	}
	return prof, nil
}

func decodeValueType(b []byte) (pprofValueType, bool) {
	var vt pprofValueType
	for len(b) > 0 {
		fieldNum, wireType, n, ok := readTag(b)
		if !ok {
			return vt, false
		}
		b = b[n:]
		switch {
		case fieldNum == 1 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return vt, false
			}
			b = b[m:]
			vt.typ = int64(v)
		case fieldNum == 2 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return vt, false
			}
			b = b[m:]
			vt.unit = int64(v)
		default:
			m, ok := skipField(wireType, b)
			if !ok {
				return vt, false
			}
			b = b[m:]
		}
	}
	return vt, true
}

func decodeSample(b []byte) (pprofSample, bool) {
	var s pprofSample
	for len(b) > 0 {
		fieldNum, wireType, n, ok := readTag(b)
		if !ok {
			return s, false
		}
		b = b[n:]
		switch {
		case fieldNum == 1 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return s, false
			}
			b = b[m:]
			s.locationIDs = append(s.locationIDs, v)
		case fieldNum == 1 && wireType == 2:
			packed, m, ok := readBytes(b)
			if !ok {
				return s, false
			}
			b = b[m:]
			for len(packed) > 0 {
				v, k, ok := readVarint(packed)
				if !ok {
					return s, false
				}
				packed = packed[k:]
				s.locationIDs = append(s.locationIDs, v)
			}
		case fieldNum == 2 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return s, false
			}
			b = b[m:]
			s.values = append(s.values, int64(v))
		case fieldNum == 2 && wireType == 2:
			packed, m, ok := readBytes(b)
			if !ok {
				return s, false
			}
			b = b[m:]
			for len(packed) > 0 {
				v, k, ok := readVarint(packed)
				if !ok {
					return s, false
				}
				packed = packed[k:]
				s.values = append(s.values, int64(v))
			}
		default:
			m, ok := skipField(wireType, b)
			if !ok {
				return s, false
			}
			b = b[m:]
		}
	}
	return s, true
}

func decodeLocation(b []byte) (pprofLocation, bool) {
	var loc pprofLocation
	for len(b) > 0 {
		fieldNum, wireType, n, ok := readTag(b)
		if !ok {
			return loc, false
		}
		b = b[n:]
		switch {
		case fieldNum == 1 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return loc, false
			}
			b = b[m:]
			loc.id = v
		case fieldNum == 4 && wireType == 2:
			msg, m, ok := readBytes(b)
			if !ok {
				return loc, false
			}
			b = b[m:]
			ln, ok := decodeLine(msg)
			if !ok {
				return loc, false
			}
			loc.lines = append(loc.lines, ln)
		default:
			m, ok := skipField(wireType, b)
			if !ok {
				return loc, false
			}
			b = b[m:]
		}
	}
	return loc, true
}

func decodeLine(b []byte) (pprofLine, bool) {
	var ln pprofLine
	for len(b) > 0 {
		fieldNum, wireType, n, ok := readTag(b)
		if !ok {
			return ln, false
		}
		b = b[n:]
		switch {
		case fieldNum == 1 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return ln, false
			}
			b = b[m:]
			ln.functionID = v
		case fieldNum == 2 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return ln, false
			}
			b = b[m:]
			ln.line = int64(v)
		default:
			m, ok := skipField(wireType, b)
			if !ok {
				return ln, false
			}
			b = b[m:]
		}
	}
	return ln, true
}

func decodeFunction(b []byte) (pprofFunction, bool) {
	var fn pprofFunction
	for len(b) > 0 {
		fieldNum, wireType, n, ok := readTag(b)
		if !ok {
			return fn, false
		}
		b = b[n:]
		switch {
		case fieldNum == 1 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return fn, false
			}
			b = b[m:]
			fn.id = v
		case fieldNum == 2 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return fn, false
			}
			b = b[m:]
			fn.name = int64(v)
		case fieldNum == 3 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return fn, false
			}
			b = b[m:]
			fn.systemName = int64(v)
		case fieldNum == 4 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return fn, false
			}
			b = b[m:]
			fn.filename = int64(v)
		case fieldNum == 5 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return fn, false
			}
			b = b[m:]
			fn.startLine = int64(v)
		default:
			m, ok := skipField(wireType, b)
			if !ok {
				return fn, false
			}
			b = b[m:]
		}
	}
	return fn, true
}

func readTag(b []byte) (uint64, int, int, bool) {
	v, n, ok := readVarint(b)
	if !ok || v>>3 == 0 {
		return 0, 0, 0, false
	}
	return v >> 3, int(v & 0x7), n, true
}

func readVarint(b []byte) (uint64, int, bool) {
	var x uint64
	var s uint
	for i := 0; i < len(b) && i < 10; i++ {
		c := b[i]
		if c < 0x80 {
			if i == 9 && c > 1 {
				return 0, 0, false
			}
			return x | uint64(c)<<s, i + 1, true
		}
		x |= uint64(c&0x7f) << s
		s += 7
	}
	return 0, 0, false
}

func readBytes(b []byte) ([]byte, int, bool) {
	length, n, ok := readVarint(b)
	if !ok {
		return nil, 0, false
	}
	if length > uint64(len(b)-n) {
		return nil, 0, false
	}
	end := n + int(length)
	return b[n:end], end, true
}

func skipField(wireType int, b []byte) (int, bool) {
	switch wireType {
	case 0:
		_, n, ok := readVarint(b)
		return n, ok
	case 1:
		if len(b) < 8 {
			return 0, false
		}
		return 8, true
	case 2:
		_, n, ok := readBytes(b)
		return n, ok
	case 5:
		if len(b) < 4 {
			return 0, false
		}
		return 4, true
	default:
		return 0, false
	}
}
