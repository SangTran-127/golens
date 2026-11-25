package docker

import (
	"regexp"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

type segment struct {
	line int
	col  int
	off  int
	text string
}

type instruction struct {
	cmd     string
	line    int
	endLine int
	kwCol   int
	args    string
	segs    []segment
}

type stage struct {
	index    int
	name     string
	from     *instruction
	image    string
	imageOff int
	parent   *stage
	insts    []*instruction
}

type dockerfile struct {
	lines  []string
	insts  []*instruction
	stages []*stage
}

type word struct {
	raw string
	val string
	off int
}

var heredocRe = regexp.MustCompile(`(?:^|[^<])<<(-?)["']?([A-Za-z_][A-Za-z0-9_]*)`)

func isBlankOrComment(line string) bool {
	t := strings.TrimSpace(line)
	return t == "" || t[0] == '#'
}

func parseDockerfile(content string) *dockerfile {
	df := &dockerfile{lines: strings.Split(content, "\n")}
	for i, l := range df.lines {
		df.lines[i] = strings.TrimSuffix(l, "\r")
	}
	escape := escapeChar(df.lines)
	lines := df.lines
	for i := 0; i < len(lines); {
		if isBlankOrComment(lines[i]) {
			i++
			continue
		}
		raw := lines[i]
		lead := len(raw) - len(strings.TrimLeft(raw, " \t"))
		kwEnd := len(raw)
		if j := strings.IndexAny(raw[lead:], " \t"); j >= 0 {
			kwEnd = lead + j
		}
		inst := &instruction{cmd: strings.ToUpper(raw[lead:kwEnd]), line: i, endLine: i, kwCol: lead}
		var args strings.Builder
		ln, col := i, kwEnd
		for {
			text := lines[ln][col:]
			trimmedRight := strings.TrimRight(text, " \t")
			cont := strings.HasSuffix(trimmedRight, escape)
			if cont {
				text = trimmedRight[:len(trimmedRight)-len(escape)]
			}
			body := strings.TrimLeft(text, " \t")
			col += len(text) - len(body)
			body = strings.TrimRight(body, " \t")
			if args.Len() > 0 && body != "" {
				args.WriteByte(' ')
			}
			inst.segs = append(inst.segs, segment{line: ln, col: col, off: args.Len(), text: body})
			args.WriteString(body)
			inst.endLine = ln
			if !cont {
				break
			}
			ln++
			for ln < len(lines) && isBlankOrComment(lines[ln]) {
				ln++
			}
			if ln >= len(lines) {
				break
			}
			col = 0
		}
		inst.args = args.String()
		i = inst.endLine + 1
		if inst.cmd == "RUN" || inst.cmd == "COPY" || inst.cmd == "ADD" {
			for _, m := range heredocRe.FindAllStringSubmatch(inst.args, -1) {
				for i < len(lines) {
					done := strings.TrimSpace(lines[i]) == m[2]
					i++
					if done {
						break
					}
				}
				inst.endLine = i - 1
			}
		}
		df.insts = append(df.insts, inst)
	}
	df.buildStages()
	return df
}

func escapeChar(lines []string) string {
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if !strings.HasPrefix(t, "#") {
			break
		}
		k, v, ok := strings.Cut(strings.TrimSpace(t[1:]), "=")
		if !ok {
			break
		}
		if strings.EqualFold(strings.TrimSpace(k), "escape") && strings.TrimSpace(v) == "`" {
			return "`"
		}
	}
	return `\`
}

func (df *dockerfile) buildStages() {
	var cur *stage
	for _, inst := range df.insts {
		if inst.cmd != "FROM" {
			if cur != nil {
				cur.insts = append(cur.insts, inst)
			}
			continue
		}
		st := &stage{index: len(df.stages), from: inst}
		toks := tokenize(inst.args)
		k := 0
		for k < len(toks) && strings.HasPrefix(toks[k].val, "--") {
			k++
		}
		if k < len(toks) {
			st.image, st.imageOff = toks[k].val, toks[k].off
			if k+2 < len(toks) && strings.EqualFold(toks[k+1].val, "as") {
				st.name = toks[k+2].val
			}
			st.parent = df.stageNamed(st.image)
		}
		df.stages = append(df.stages, st)
		cur = st
	}
}

func (df *dockerfile) stageNamed(name string) *stage {
	for _, s := range df.stages {
		if s.name != "" && strings.EqualFold(s.name, name) {
			return s
		}
	}
	return nil
}

func (s *stage) root() *stage {
	for s.parent != nil {
		s = s.parent
	}
	return s
}

func (s *stage) chain() []*stage {
	var out []*stage
	for ; s != nil; s = s.parent {
		out = append(out, s)
	}
	return out
}

func tokenize(s string) []word {
	var toks []word
	i := 0
	for i < len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' {
			i++
			continue
		}
		if c == ';' || c == '&' || c == '|' {
			j := i + 1
			if j < len(s) && (s[j] == '&' || s[j] == '|') {
				j++
			}
			toks = append(toks, word{raw: s[i:j], val: s[i:j], off: i})
			i = j
			continue
		}
		start := i
		var val strings.Builder
		var quote byte
		for i < len(s) {
			c := s[i]
			if quote != 0 {
				if c == quote {
					quote = 0
				} else {
					val.WriteByte(c)
				}
				i++
				continue
			}
			if c == '"' || c == '\'' {
				quote = c
				i++
				continue
			}
			if c == ' ' || c == '\t' || c == '\n' || c == ';' || c == '&' || c == '|' {
				break
			}
			val.WriteByte(c)
			i++
		}
		toks = append(toks, word{raw: s[start:i], val: val.String(), off: start})
	}
	return toks
}

func (inst *instruction) pos(off int) (int, int) {
	seg := inst.segs[0]
	for _, s := range inst.segs {
		if s.off <= off {
			seg = s
		}
	}
	d := off - seg.off
	if d > len(seg.text) {
		d = len(seg.text)
	}
	return seg.line, seg.col + d
}

type span struct {
	line, col, endLine, endCol int
}

func utf16Col(line string, byteCol int) int {
	if byteCol > len(line) {
		byteCol = len(line)
	}
	n := 0
	for _, r := range line[:byteCol] {
		if r == utf8.RuneError {
			n++
			continue
		}
		n += utf16.RuneLen(r)
	}
	return n
}

func (df *dockerfile) argSpan(inst *instruction, off, length int) span {
	line, col := inst.pos(off)
	text := df.lines[line]
	end := col + length
	if end > len(text) {
		end = len(text)
	}
	return span{line, utf16Col(text, col), line, utf16Col(text, end)}
}

func (df *dockerfile) keywordSpan(inst *instruction) span {
	text := df.lines[inst.line]
	return span{inst.line, utf16Col(text, inst.kwCol), inst.line, utf16Col(text, inst.kwCol+len(inst.cmd))}
}

func (df *dockerfile) lineIndent(line int) string {
	text := df.lines[line]
	return text[:len(text)-len(strings.TrimLeft(text, " \t"))]
}
