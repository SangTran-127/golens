package analysis

import (
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func buildCycleGraph(nodes []string, edges map[string][]string) map[string]*PackageNode {
	pkgs := make(map[string]*PackageNode, len(nodes))
	for _, n := range nodes {
		node := &PackageNode{ImportPath: n}
		for i, target := range edges[n] {
			node.Imports = append(node.Imports, PackageImportEdge{
				TargetPath: target,
				Category:   "internal",
				FilePath:   n + "/f.go",
				Line:       i + 3,
			})
		}
		pkgs[n] = node
	}
	return pkgs
}

func exhaustiveImportCycles(orderedImportPaths []string, pkgByImportPath map[string]*PackageNode) []ImportCycle {
	cycles := make([]ImportCycle, 0)
	seen := make(map[string]bool)
	edgeLookup := make(map[string]map[string]PackageImportEdge)
	adj := make(map[string][]string)
	for _, from := range orderedImportPaths {
		node := pkgByImportPath[from]
		if node == nil {
			continue
		}
		edgeLookup[from] = make(map[string]PackageImportEdge)
		for _, imp := range node.Imports {
			if imp.Category != "internal" || imp.TargetPath == from {
				continue
			}
			edgeLookup[from][imp.TargetPath] = imp
			adj[from] = append(adj[from], imp.TargetPath)
		}
		sort.Strings(adj[from])
	}
	for _, start := range orderedImportPaths {
		visited := make(map[string]bool)
		var dfs func(curr string, path []string)
		dfs = func(curr string, path []string) {
			visited[curr] = true
			defer func() { visited[curr] = false }()
			for _, next := range adj[curr] {
				if next < start {
					continue
				}
				if next == start {
					chain := append(append([]string{}, path...), start)
					key := strings.Join(chain, "->")
					if seen[key] {
						continue
					}
					seen[key] = true
					edges := make([]ImportEdgeLocation, 0, len(chain)-1)
					for i := 0; i < len(chain)-1; i++ {
						e := edgeLookup[chain[i]][chain[i+1]]
						edges = append(edges, ImportEdgeLocation{FromPkg: chain[i], ToPkg: chain[i+1], FilePath: e.FilePath, Line: e.Line})
					}
					cycles = append(cycles, ImportCycle{ID: fmt.Sprintf("cycle-%d", len(cycles)+1), Chain: chain, Edges: edges})
					continue
				}
				if !visited[next] && len(path) < 16 {
					dfs(next, append(path, next))
				}
			}
		}
		dfs(start, []string{start})
	}
	return cycles
}

func TestDetectInternalImportCycles_LargeLayeredAcyclicGraphIsFast(t *testing.T) {
	const layers, width = 40, 12
	nodes := make([]string, 0, layers*width)
	edges := make(map[string][]string)
	name := func(l, w int) string { return fmt.Sprintf("example.com/app/l%02d/p%02d", l, w) }
	for l := 0; l < layers; l++ {
		for w := 0; w < width; w++ {
			n := name(l, w)
			nodes = append(nodes, n)
			if l+1 < layers {
				for w2 := 0; w2 < width; w2++ {
					edges[n] = append(edges[n], name(l+1, w2))
				}
			}
		}
	}
	pkgs := buildCycleGraph(nodes, edges)

	start := time.Now()
	cycles := detectInternalImportCycles(nodes, pkgs)
	if len(cycles) != 0 {
		t.Fatalf("expected no cycles in a layered DAG, got %d", len(cycles))
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("cycle detection on a layered DAG took %v", elapsed)
	}
}

func TestDetectInternalImportCycles_DenseCyclicGraphIsBounded(t *testing.T) {
	const size = 30
	nodes := make([]string, size)
	for i := range nodes {
		nodes[i] = fmt.Sprintf("example.com/app/p%02d", i)
	}
	edges := make(map[string][]string)
	for _, a := range nodes {
		for _, b := range nodes {
			if a != b {
				edges[a] = append(edges[a], b)
			}
		}
	}
	start := time.Now()
	cycles := detectInternalImportCycles(nodes, buildCycleGraph(nodes, edges))
	if len(cycles) == 0 || len(cycles) > maxReportedImportCycle {
		t.Fatalf("expected a bounded non-empty cycle list, got %d", len(cycles))
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("cycle detection on a dense graph took %v", elapsed)
	}
}

func TestDetectInternalImportCycles_MatchesExhaustiveSearch(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for trial := 0; trial < 300; trial++ {
		size := 2 + rng.Intn(8)
		nodes := make([]string, size)
		for i := range nodes {
			nodes[i] = fmt.Sprintf("example.com/app/p%d", i)
		}
		edges := make(map[string][]string)
		for _, a := range nodes {
			for _, b := range nodes {
				if rng.Intn(4) == 0 {
					edges[a] = append(edges[a], b)
					if rng.Intn(5) == 0 {
						edges[a] = append(edges[a], b)
					}
				}
			}
		}
		if rng.Intn(3) == 0 {
			edges[nodes[0]] = append(edges[nodes[0]], "example.com/app/missing")
		}
		pkgs := buildCycleGraph(nodes, edges)
		got := detectInternalImportCycles(nodes, pkgs)
		want := exhaustiveImportCycles(nodes, pkgs)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("trial %d: cycles differ\ngot  %+v\nwant %+v", trial, got, want)
		}
	}
}

func TestDetectInternalImportCycles_ReportsTwoSeparateCycles(t *testing.T) {
	nodes := []string{"m/a", "m/b", "m/c", "m/d", "m/e"}
	edges := map[string][]string{
		"m/a": {"m/b"},
		"m/b": {"m/a", "m/c"},
		"m/c": {"m/d"},
		"m/d": {"m/e"},
		"m/e": {"m/c"},
	}
	cycles := detectInternalImportCycles(nodes, buildCycleGraph(nodes, edges))
	chains := make([]string, 0, len(cycles))
	for _, c := range cycles {
		chains = append(chains, c.ID+":"+strings.Join(c.Chain, ">"))
	}
	want := []string{"cycle-1:m/a>m/b>m/a", "cycle-2:m/c>m/d>m/e>m/c"}
	if !reflect.DeepEqual(chains, want) {
		t.Fatalf("got %v want %v", chains, want)
	}
}
