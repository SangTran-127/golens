package lsp

import (
	"reflect"
	"testing"
)

func TestExpandTemplateIndentsBodyAndKeepsStops(t *testing.T) {
	exp := ExpandTemplate("for ${1:i}, ${2:v} := range ${3:items} {\n\t$0\n}", "\t", "")
	if exp.Text != "for i, v := range items {\n\t\t\n\t}" {
		t.Fatalf("text %q", exp.Text)
	}
	want := []TabStop{{Index: 1, Start: 4, Length: 1}, {Index: 2, Start: 7, Length: 1}, {Index: 3, Start: 18, Length: 5}}
	if !reflect.DeepEqual(exp.Stops, want) {
		t.Fatalf("stops %+v", exp.Stops)
	}
	if exp.Final != 28 {
		t.Fatalf("final %d", exp.Final)
	}
}

func TestExpandTemplateReindentsTheSelection(t *testing.T) {
	selection := "\t\tx := 1\n\t\tif x > 0 {\n\t\t\tfmt.Println(x)\n\t\t}\n"
	exp := ExpandTemplate("if ${1:cond} {\n\t$TM_SELECTED_TEXT\n}$0", "\t\t", selection)
	want := "if cond {\n\t\t\tx := 1\n\t\t\tif x > 0 {\n\t\t\t\tfmt.Println(x)\n\t\t\t}\n\t\t}"
	if exp.Text != want {
		t.Fatalf("text %q\nwant %q", exp.Text, want)
	}
	if len(exp.Stops) != 1 || exp.Stops[0].Start != 3 || exp.Stops[0].Length != 4 {
		t.Fatalf("stops %+v", exp.Stops)
	}
}

func TestExpandTemplateEscapesSelectionAndDefaults(t *testing.T) {
	exp := ExpandTemplate(`log.Printf("${1:${TM_SELECTED_TEXT}} = %v\n", ${2:$TM_SELECTED_TEXT})`, "", "cfg[\"$x}\"]")
	want := `log.Printf("cfg["$x}"] = %v\n", cfg["$x}"])`
	if exp.Text != want {
		t.Fatalf("text %q\nwant %q", exp.Text, want)
	}
	if len(exp.Stops) != 2 || exp.Stops[0].Length != 10 || exp.Stops[1].Length != 10 {
		t.Fatalf("stops %+v", exp.Stops)
	}
	empty := ExpandTemplate(`log.Println(${1:$TM_SELECTED_TEXT})$0`, "", "")
	if empty.Text != "log.Println()" || empty.Stops[0].Length != 0 {
		t.Fatalf("empty selection %+v", empty)
	}
}

func TestUsesSelection(t *testing.T) {
	if !UsesSelection("go func() {\n\t$TM_SELECTED_TEXT\n}()") || !UsesSelection("${TM_SELECTED_TEXT}") || UsesSelection("for $1 {\n}") {
		t.Fatal("selection detection")
	}
}
