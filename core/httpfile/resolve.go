package httpfile

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var placeholderPattern = regexp.MustCompile(`\{\{\s*([^{}]+?)\s*\}\}`)

type Resolver struct {
	Globals     map[string]string
	FileVars    map[string]string
	Environment map[string]string
	Now         func() time.Time
	missing     map[string]bool
}

func NewResolver(globals, fileVars, env map[string]string) *Resolver {
	return &Resolver{Globals: globals, FileVars: fileVars, Environment: env, Now: time.Now, missing: map[string]bool{}}
}

func (r *Resolver) Missing() []string {
	out := make([]string, 0, len(r.missing))
	for k := range r.missing {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func (r *Resolver) Resolve(s string) string {
	return r.resolveDepth(s, 0)
}

func (r *Resolver) resolveDepth(s string, depth int) string {
	if !strings.Contains(s, "{{") {
		return s
	}
	return placeholderPattern.ReplaceAllStringFunc(s, func(m string) string {
		name := strings.TrimSpace(placeholderPattern.FindStringSubmatch(m)[1])
		if v, ok := r.dynamic(name); ok {
			return v
		}
		if v, ok := r.lookup(name); ok {
			if depth < 5 {
				return r.resolveDepth(v, depth+1)
			}
			return v
		}
		r.missing[name] = true
		return m
	})
}

func (r *Resolver) lookup(name string) (string, bool) {
	for _, scope := range []map[string]string{r.Globals, r.FileVars, r.Environment} {
		if v, ok := scope[name]; ok {
			return v, true
		}
	}
	return "", false
}

func (r *Resolver) dynamic(name string) (string, bool) {
	if !strings.HasPrefix(name, "$") {
		return "", false
	}
	switch {
	case name == "$uuid" || name == "$random.uuid":
		return newUUID(), true
	case name == "$timestamp":
		return strconv.FormatInt(r.Now().Unix(), 10), true
	case name == "$isoTimestamp":
		return r.Now().UTC().Format(time.RFC3339), true
	case name == "$randomInt":
		return strconv.FormatInt(randomInt(0, 1000), 10), true
	case strings.HasPrefix(name, "$random.integer"):
		lo, hi := int64(0), int64(1000)
		if args := between(name, "(", ")"); args != "" {
			parts := strings.Split(args, ",")
			if len(parts) == 2 {
				a, errA := strconv.ParseInt(strings.TrimSpace(parts[0]), 10, 64)
				b, errB := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
				if errA == nil && errB == nil && b > a {
					lo, hi = a, b
				}
			}
		}
		return strconv.FormatInt(randomInt(lo, hi), 10), true
	case strings.HasPrefix(name, "$env."), strings.HasPrefix(name, "$processEnv."):
		key := name[strings.Index(name, ".")+1:]
		if v, ok := os.LookupEnv(key); ok {
			return v, true
		}
		return "", false
	}
	return "", false
}

func between(s, open, close string) string {
	i := strings.Index(s, open)
	j := strings.LastIndex(s, close)
	if i < 0 || j <= i {
		return ""
	}
	return s[i+1 : j]
}

func randomInt(lo, hi int64) int64 {
	n, err := rand.Int(rand.Reader, big.NewInt(hi-lo))
	if err != nil {
		return lo
	}
	return lo + n.Int64()
}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
