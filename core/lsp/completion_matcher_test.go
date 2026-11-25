package lsp

import (
	"math/rand"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode"
)

func referenceWordStartMatch(lq []rune, c []rune) ([]int, bool) {
	var try func(qi, ci int, pos []int) ([]int, bool)
	try = func(qi, ci int, pos []int) ([]int, bool) {
		if qi == len(lq) {
			return pos, true
		}
		for i := ci; i < len(c); i++ {
			if unicode.ToLower(c[i]) != lq[qi] {
				continue
			}
			contiguous := len(pos) > 0 && pos[len(pos)-1] == i-1
			if !contiguous && !isWordBoundary(c, i) {
				continue
			}
			if r, ok := try(qi+1, i+1, append(pos, i)); ok {
				return r, true
			}
		}
		return nil, false
	}
	if len(c) > 128 {
		return nil, false
	}
	return try(0, 0, make([]int, 0, len(lq)))
}

func referenceMatchCandidate(query, candidate string) (matchResult, bool) {
	if query == "" {
		return matchResult{score: tierPrefix * 1000}, true
	}
	q := []rune(query)
	c := []rune(candidate)
	if len(q) > len(c) {
		return matchResult{}, false
	}
	lq := make([]rune, len(q))
	for i, r := range q {
		lq[i] = unicode.ToLower(r)
	}
	prefix, exactCase := true, true
	for i := range q {
		if unicode.ToLower(c[i]) != lq[i] {
			prefix = false
			break
		}
		if c[i] != q[i] {
			exactCase = false
		}
	}
	if prefix {
		pos := make([]int, len(q))
		for i := range pos {
			pos[i] = i
		}
		tier := tierPrefix
		if exactCase {
			tier = tierExactCase
		}
		return matchResult{score: tier * 1000, positions: pos}, true
	}
	if pos, ok := referenceWordStartMatch(lq, c); ok {
		return matchResult{score: tierWordStart * 1000, positions: pos}, true
	}
	pos := make([]int, 0, len(q))
	j := 0
	for i := 0; i < len(c) && j < len(lq); i++ {
		if unicode.ToLower(c[i]) == lq[j] {
			pos = append(pos, i)
			j++
		}
	}
	if j < len(lq) {
		return matchResult{}, false
	}
	return matchResult{score: tierSubseq * 1000, positions: pos}, true
}

func TestCandidateMatcherAgreesWithReference(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	alphabet := []rune("aAbBsS_.1Éé")
	randStr := func(n int) string {
		var b strings.Builder
		for i := 0; i < n; i++ {
			b.WriteRune(alphabet[rng.Intn(len(alphabet))])
		}
		return b.String()
	}
	for iter := 0; iter < 20000; iter++ {
		query := randStr(rng.Intn(5))
		m := newCandidateMatcher(query)
		for k := 0; k < 4; k++ {
			cand := randStr(rng.Intn(14))
			got, gotOK := m.match(cand)
			want, wantOK := referenceMatchCandidate(query, cand)
			if gotOK != wantOK || got.score != want.score || !reflect.DeepEqual(got.positions, want.positions) {
				t.Fatalf("%q~%q: got (%v,%v) want (%v,%v)", query, cand, got, gotOK, want, wantOK)
			}
		}
	}
}

func TestWordStartMatchAvoidsExponentialBacktracking(t *testing.T) {
	cand := strings.Repeat("A_", 60) + "z"
	query := strings.Repeat("a", 30) + "b"
	start := time.Now()
	if _, ok := matchCandidate(query, cand); ok {
		t.Fatal("expected no match")
	}
	cand2 := strings.Repeat("A_", 60) + "b"
	if _, ok := matchCandidate(query, cand2); !ok {
		t.Fatal("expected subsequence match")
	}
	if d := time.Since(start); d > 200*time.Millisecond {
		t.Fatalf("pathological word-start match took %v", d)
	}
}

func TestAllowFuncProbesModulePrefixes(t *testing.T) {
	g := moduleGraph{root: "/w", mods: []string{"example.com/app", "github.com/x/y"}, loaded: true}
	allow := g.allowFunc("/w")
	cases := map[string]bool{
		"example.com/app":            true,
		"example.com/app/internal/z": true,
		"example.com/application":    false,
		"github.com/x":               false,
		"github.com/x/y/z":           true,
		"github.com/x/yy":            false,
		"fmt":                        true,
		"net/http":                   true,
		"golang.org/x/tools":         false,
	}
	for p, want := range cases {
		if got := allow(p); got != want {
			t.Errorf("allow(%q)=%v want %v", p, got, want)
		}
	}
}
