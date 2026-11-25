package main

import (
	"os"
	"testing"
)

func TestFixtureBoundaries(t *testing.T) {
	data, err := os.ReadFile("experiment/fixtures/sample.ps1")
	if err != nil {
		t.Fatal(err)
	}
	nodes, err := extractComments("powershell", data)
	if err != nil {
		t.Fatal(err)
	}
	roots := buildTree(nodes)
	if len(roots) != 4 || len(roots[0].Children) != 1 || roots[0].Children[0].EndLine != 3 || blockEnd(roots[0], 15) != 7 || blockEnd(roots[0].Children[0].Children[0], 15) != 6 || roots[1].StartLine != 9 || roots[1].Children[0].EndLine != 11 {
		t.Fatalf("incorrect region nesting or bounds: %+v", roots)
	}
}

func BenchmarkSource(b *testing.B) {
	data, err := os.ReadFile(os.Getenv("CODEGOS_FIXTURE"))
	if err != nil {
		b.Fatal(err)
	}
	lang, err := languageFromExtension(os.Getenv("CODEGOS_FIXTURE"))
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		nodes, _ := extractComments(lang, data)
		buildTree(nodes)
	}
}
