package main

import (
	"strings"
	"testing"
)

func TestGoExtractionIgnoresInlineAndStringMarkers(t *testing.T) {
	source := []byte(`package demo

var s = "// not a comment"
// root
    // child
func run() { // inline comment
}
/* block
   comment */
`)
	comments := extractGoComments(source)
	if len(comments) != 3 {
		t.Fatalf("got %d comments, want 3: %#v", len(comments), comments)
	}
	if comments[0].Text != "root" || comments[0].StartLine != 4 {
		t.Fatalf("unexpected first comment: %#v", comments[0])
	}
	if comments[1].Indent != 4 || comments[1].StartLine != 5 {
		t.Fatalf("unexpected child comment: %#v", comments[1])
	}
	if comments[2].StartLine != 8 || comments[2].EndLine != 9 {
		t.Fatalf("unexpected block comment: %#v", comments[2])
	}
}

func TestPythonExtractionDoesNotTreatTripleQuotedStringsAsComments(t *testing.T) {
	source := []byte("text = '''\n# not a comment\n'''\n# real comment\nvalue = '# not one either'\n    # child\n")
	comments := extractPythonComments(source)
	if len(comments) != 2 {
		t.Fatalf("got %d comments, want 2: %#v", len(comments), comments)
	}
	if comments[0].StartLine != 4 || comments[0].Text != "real comment" {
		t.Fatalf("unexpected first comment: %#v", comments[0])
	}
	if comments[1].StartLine != 6 || comments[1].Indent != 4 {
		t.Fatalf("unexpected second comment: %#v", comments[1])
	}
}

func TestPowerShellExtractionIgnoresStringsHereStringsAndInlineComments(t *testing.T) {
	source := []byte("$a = '# not a comment'\n# root\n    # child\nWrite-Host 'hello' # inline\n$text = @'\n# here-string content\n'@\n<# block\ncomment #>\n")
	comments := extractPowerShellComments(source)
	if len(comments) != 3 {
		t.Fatalf("got %d comments, want 3: %#v", len(comments), comments)
	}
	if comments[0].StartLine != 2 || comments[1].StartLine != 3 {
		t.Fatalf("unexpected line comments: %#v", comments[:2])
	}
	if comments[2].StartLine != 8 || comments[2].EndLine != 9 {
		t.Fatalf("unexpected block comment: %#v", comments[2])
	}
}

func TestBuildTreeUsesRelativeIndentation(t *testing.T) {
	comments := []*Comment{
		{Text: "root", Indent: 0},
		{Text: "child", Indent: 8},
		{Text: "grandchild", Indent: 12},
		{Text: "sibling", Indent: 8},
		{Text: "next root", Indent: 0},
	}
	roots := buildTree(comments)
	if len(roots) != 2 {
		t.Fatalf("got %d roots, want 2", len(roots))
	}
	if len(roots[0].Children) != 2 || len(roots[0].Children[0].Children) != 1 {
		t.Fatal("unexpected hierarchy")
	}
	if comments[2].Depth != 2 || comments[3].Depth != 1 {
		t.Fatalf("unexpected depths: grandchild=%d sibling=%d", comments[2].Depth, comments[3].Depth)
	}
}

func TestPrintSourceBlockStopsAtSameOrShallowerComment(t *testing.T) {
	source := []byte("# parent\nline 2\n    # child\nline 4\n# next parent\nline 6\n")
	comments := extractPythonComments(source)
	if len(comments) != 3 {
		t.Fatalf("got %d comments, want 3", len(comments))
	}
	// The parent block ends immediately before the next root comment.
	lines := sourceLines(source)
	startLine := comments[0].EndLine + 1
	endLine := len(lines)
	for i := 1; i < len(comments); i++ {
		if comments[i].Indent <= comments[0].Indent {
			endLine = comments[i].StartLine - 1
			break
		}
	}
	got := strings.Join(lines[startLine-1:endLine], "\n")
	if got != "line 2\n    # child\nline 4" {
		t.Fatalf("unexpected source block: %q", got)
	}
}

func TestLanguageFromExtension(t *testing.T) {
	cases := map[string]string{"A.GO": "go", "a.py": "python", "a.psm1": "powershell"}
	for path, want := range cases {
		got, err := languageFromExtension(path)
		if err != nil || got != want {
			t.Fatalf("languageFromExtension(%q) = %q, %v; want %q", path, got, err, want)
		}
	}
	if _, err := languageFromExtension("file.unknown"); err == nil {
		t.Fatal("expected unsupported extension error")
	}
}
