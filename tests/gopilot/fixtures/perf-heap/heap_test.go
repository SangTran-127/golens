package main

import "testing"

func TestRenderRowsTotal(t *testing.T) {
	if got := renderRows(3); got != 3*(len("row-0-")+32)+0+1+2 {
		t.Fatalf("renderRows = %d", got)
	}
}

func TestLoadIndexRetainsShards(t *testing.T) {
	loadIndex(4, 1024)
	if index.Bytes() != 4*1024 {
		t.Fatalf("bytes = %d", index.Bytes())
	}
}
