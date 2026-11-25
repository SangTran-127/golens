package testutil

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
)

type ProfileSampleType struct {
	Type string `json:"type"`
	Unit string `json:"unit"`
}

type ProfileDetailOptions struct {
	ModeOverride       string
	SampleTypeOverride string
	WorkspaceRoot      string
	ModulePath         string
}

type ProfileDetail struct {
	ContentSHA256    string              `json:"contentSha256"`
	Mode             string              `json:"mode"`
	SampleType       string              `json:"sampleType"`
	Unit             string              `json:"unit"`
	SampleTypes      []ProfileSampleType `json:"sampleTypes"`
	TotalValue       int64               `json:"totalValue"`
	SampleCount      int                 `json:"sampleCount"`
	SkippedSamples   int                 `json:"skippedSamples"`
	ZeroValueSamples int                 `json:"zeroValueSamples"`
	CountType        string              `json:"countType,omitempty"`
	CountTotal       int64               `json:"countTotal,omitempty"`
	DurationNanos    int64               `json:"durationNanos"`
	PeriodType       string              `json:"periodType,omitempty"`
	PeriodUnit       string              `json:"periodUnit,omitempty"`
	Period           int64               `json:"period"`
	Truncated        bool                `json:"truncated"`
	EntriesBeforeCap int                 `json:"entriesBeforeCap"`
	EntryCap         int                 `json:"entryCap"`
	Entries          []ProfileEntry      `json:"entries"`
}

func ParseProfileDetailed(path string) (ProfileDetail, error) {
	return ParseProfileDetailedWithOptions(path, ProfileDetailOptions{})
}

func ParseProfileDetailedWithOptions(path string, opts ProfileDetailOptions) (ProfileDetail, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ProfileDetail{}, err
	}
	if len(raw) == 0 {
		return ProfileDetail{}, fmt.Errorf("empty profile")
	}
	sum := sha256.Sum256(raw)
	data, err := inflateProfileBytes(raw)
	if err != nil {
		return ProfileDetail{}, err
	}
	prof, err := decodeProfile(data)
	if err != nil {
		return ProfileDetail{}, err
	}

	mode := opts.ModeOverride
	if mode == "" {
		mode = detectProfileMode(path, prof)
	}
	switch mode {
	case "cpu", "memory", "block", "mutex":
	default:
		return ProfileDetail{}, fmt.Errorf("unsupported profile mode %q", mode)
	}

	detail := ProfileDetail{
		ContentSHA256: hex.EncodeToString(sum[:]),
		Mode:          mode,
		SampleTypes:   make([]ProfileSampleType, 0, len(prof.sampleTypes)),
		SampleCount:   len(prof.samples),
		EntryCap:      maxProfileEntries,
		Entries:       []ProfileEntry{},
	}
	for _, st := range prof.sampleTypes {
		detail.SampleTypes = append(detail.SampleTypes, ProfileSampleType{
			Type: prof.stringAt(st.typeIndex()),
			Unit: prof.stringAt(st.unitIndex()),
		})
	}
	readProfileMeta(data, prof, &detail)

	valIdx := selectValueIndexForMode(prof, mode)
	if opts.SampleTypeOverride != "" {
		valIdx = -1
		for i, st := range detail.SampleTypes {
			if st.Type == opts.SampleTypeOverride {
				valIdx = i
				break
			}
		}
		if valIdx < 0 {
			return ProfileDetail{}, fmt.Errorf("sample type %q not present in profile", opts.SampleTypeOverride)
		}
	}
	if valIdx < 0 || valIdx >= len(detail.SampleTypes) {
		return detail, nil
	}
	detail.SampleType = detail.SampleTypes[valIdx].Type
	detail.Unit = detail.SampleTypes[valIdx].Unit

	countIdx := selectCountIndex(prof)
	if countIdx == valIdx {
		countIdx = -1
	}
	if countIdx >= 0 {
		detail.CountType = detail.SampleTypes[countIdx].Type
	}

	workspaceRoot := opts.WorkspaceRoot
	if workspaceRoot == "" {
		workspaceRoot = filepath.Dir(path)
	}
	modRoot := workspaceRoot
	modulePath := opts.ModulePath
	if modulePath == "" {
		if r, m := FindModuleRoot(workspaceRoot); m != "" {
			modRoot = r
			modulePath = m
		}
	}

	entries, total, countTotal, skipped, zeroValue, before := aggregateProfileEntries(prof, valIdx, countIdx, mode, workspaceRoot, modRoot, modulePath)
	detail.TotalValue = total
	detail.CountTotal = countTotal
	detail.SkippedSamples = skipped
	detail.ZeroValueSamples = zeroValue
	detail.EntriesBeforeCap = before
	if before > maxProfileEntries {
		detail.Truncated = true
	}
	detail.Entries = entries
	return detail, nil
}

func inflateProfileBytes(raw []byte) ([]byte, error) {
	if len(raw) >= 2 && raw[0] == 0x1f && raw[1] == 0x8b {
		zr, err := gzip.NewReader(bytes.NewReader(raw))
		if err != nil {
			return nil, err
		}
		defer func() { _ = zr.Close() }()
		return io.ReadAll(zr)
	}
	return raw, nil
}

func readProfileMeta(b []byte, prof *pprofProfile, detail *ProfileDetail) {
	for len(b) > 0 {
		fieldNum, wireType, n, ok := readTag(b)
		if !ok {
			return
		}
		b = b[n:]
		switch {
		case fieldNum == 10 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return
			}
			b = b[m:]
			detail.DurationNanos = int64(v)
		case fieldNum == 12 && wireType == 0:
			v, m, ok := readVarint(b)
			if !ok {
				return
			}
			b = b[m:]
			detail.Period = int64(v)
		case fieldNum == 11 && wireType == 2:
			msg, m, ok := readBytes(b)
			if !ok {
				return
			}
			b = b[m:]
			if vt, ok := decodeValueType(msg); ok {
				detail.PeriodType = prof.stringAt(vt.typeIndex())
				detail.PeriodUnit = prof.stringAt(vt.unitIndex())
			}
		default:
			m, ok := skipField(wireType, b)
			if !ok {
				return
			}
			b = b[m:]
		}
	}
}

func aggregateProfileEntries(prof *pprofProfile, valIdx, countIdx int, mode, workspaceRoot, modRoot, modulePath string) (entries []ProfileEntry, total, countTotal int64, skipped, zeroValue, before int) {
	locMap := make(map[uint64]pprofLocation, len(prof.locations))
	for _, loc := range prof.locations {
		locMap[loc.id] = loc
	}
	fnMap := make(map[uint64]pprofFunction, len(prof.functions))
	for _, fn := range prof.functions {
		fnMap[fn.id] = fn
	}

	byFunc := make(map[string]*profileAccumulator)
	for _, sample := range prof.samples {
		if valIdx >= len(sample.values) || len(sample.locationIDs) == 0 {
			skipped++
			continue
		}
		val := sample.values[valIdx]
		if val <= 0 {
			zeroValue++
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
				name := prof.stringAt(fn.name)
				if name == "" {
					name = prof.stringAt(fn.systemName)
				}
				if name == "" {
					continue
				}
				lineNo := int(fn.startLine)
				if lineNo <= 0 {
					lineNo = int(ln.line)
				}
				frames = append(frames, stackFrame{
					function: name,
					file:     resolveProfileFile(prof.stringAt(fn.filename), workspaceRoot, modRoot, modulePath, nil),
					line:     lineNo,
				})
			}
		}
		if len(frames) == 0 {
			skipped++
			continue
		}

		total += val
		countTotal += sampleCount

		leafAcc := getOrCreateAccumulator(byFunc, frames[0])
		leafAcc.flat += val
		leafAcc.count += sampleCount

		seenInSample := make(map[string]bool, len(frames))
		for _, fr := range frames {
			if seenInSample[fr.function] {
				continue
			}
			seenInSample[fr.function] = true
			getOrCreateAccumulator(byFunc, fr).cum += val
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
			callerAcc := getOrCreateAccumulator(byFunc, frames[i])
			calleeAcc := getOrCreateAccumulator(byFunc, frames[i-1])
			callerAcc.children[calleeFn] += val
			calleeAcc.callers[callerFn] += val
		}
	}

	entries = []ProfileEntry{}
	if len(byFunc) == 0 || total <= 0 {
		return entries, total, countTotal, skipped, zeroValue, 0
	}
	for _, acc := range byFunc {
		if acc.flat == 0 && acc.cum == 0 {
			continue
		}
		flatPct := math.Round((float64(acc.flat)*100.0/float64(total))*10) / 10
		cumPct := math.Round((float64(acc.cum)*100.0/float64(total))*10) / 10
		var fmtFlat, fmtCum string
		if mode == "memory" {
			fmtFlat = formatBytes(acc.flat)
			fmtCum = formatBytes(acc.cum)
		} else {
			fmtFlat = formatDurationNanos(acc.flat)
			fmtCum = formatDurationNanos(acc.cum)
		}
		entries = append(entries, ProfileEntry{
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
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Flat != entries[j].Flat {
			return entries[i].Flat > entries[j].Flat
		}
		if entries[i].Cum != entries[j].Cum {
			return entries[i].Cum > entries[j].Cum
		}
		return entries[i].Function < entries[j].Function
	})
	before = len(entries)
	if len(entries) > maxProfileEntries {
		entries = entries[:maxProfileEntries]
	}
	return entries, total, countTotal, skipped, zeroValue, before
}
