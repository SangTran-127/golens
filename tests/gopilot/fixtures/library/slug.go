package slug

import (
	"strings"
	"unicode"
)

type Options struct {
	Separator rune
	MaxLen    int
}

func Make(s string) string {
	return MakeWithOptions(s, Options{Separator: '-'})
}

func MakeWithOptions(s string, opts Options) string {
	if opts.Separator == 0 {
		opts.Separator = '-'
	}
	var b strings.Builder
	pendingSep := false
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if pendingSep && b.Len() > 0 {
				b.WriteRune(opts.Separator)
			}
			pendingSep = false
			b.WriteRune(r)
			continue
		}
		pendingSep = true
	}
	out := b.String()
	if opts.MaxLen > 0 && len([]rune(out)) > opts.MaxLen {
		out = string([]rune(out)[:opts.MaxLen])
	}
	return out
}
