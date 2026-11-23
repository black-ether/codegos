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
	if comments[2].Parent != comments[1] || comments[2].Next != comments[3] {
		t.Fatal("grandchild should point to its immediate parent and the next shallower heading")
	}
	if comments[1].Next != comments[3] || comments[3].Next != comments[4] {
		t.Fatal("expected each child to point to the heading that ends its block")
	}
	if comments[4].Parent != nil || comments[4].Next != nil {
		t.Fatal("final root should have neither parent nor next heading")
	}
}

func TestPrintSourceBlockStopsAtSameOrShallowerComment(t *testing.T) {
	source := []byte("# parent\nline 2\n    # child\nline 4\n# next parent\nline 6\n")
	comments := extractPythonComments(source)
	if len(comments) != 3 {
		t.Fatalf("got %d comments, want 3", len(comments))
	}
	// The parent block ends immediately before the next root comment.
	buildTree(comments)
	lines := sourceLines(source)
	startLine := comments[0].EndLine + 1
	endLine := blockEnd(comments[0], len(lines))
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

func TestParseExactSourceArgs(t *testing.T) {
	for _, test := range []struct {
		args []string
		want cliOptions
	}{
		{[]string{"file.go", "go", "5"}, cliOptions{path: "file.go", line: 5}},
		{[]string{"file.go", "go", "5", "--full"}, cliOptions{path: "file.go", line: 5, full: true}},
		{[]string{"file.txt", "show", "5-10"}, cliOptions{path: "file.txt", line: 5, showEnd: 10}},
		{[]string{"file.txt", "show", "5-5"}, cliOptions{path: "file.txt", line: 5, showEnd: 5}},
		{[]string{"file.go", "--plain"}, cliOptions{path: "file.go", format: "plain"}},
		{[]string{"file.go", "go", "5", "--json", "--full"}, cliOptions{path: "file.go", line: 5, full: true, format: "json"}},
	} {
		if got, err := parseArgs(test.args); err != nil || got != test.want {
			t.Errorf("parseArgs(%v) = %+v, %v; want %+v", test.args, got, err, test.want)
		}
	}
	for _, args := range [][]string{
		{"file.go", "go"},
		{"file.go", "go", "5", "--unknown"},
		{"file.go", "show", "5"},
		{"file.go", "show", "0-5"},
		{"file.go", "show", "5-3"},
		{"file.go", "show", "5-10-12"},
		{"file.go", "--plain", "--json"},
		{"file.go", "show", "5-10", "--full"},
	} {
		if _, err := parseArgs(args); err == nil {
			t.Errorf("parseArgs(%v) accepted invalid arguments", args)
		}
	}
}

func TestNavigationJSON(t *testing.T) {
	source := []byte("# parent\n    # child\n    work()\n" + strings.Repeat("\n", 29) + "# next\n")
	comments := extractPythonComments(source)
	buildTree(comments)
	lines := sourceLines(source)

	preview := navigationJSON("example.py", "python", lines, comments[1], false)
	if preview.Parent == nil || preview.Parent.StartLine != 1 || preview.Next == nil || preview.Next.StartLine != 33 {
		t.Fatalf("unexpected context: %+v", preview)
	}
	if preview.Selected.BlockEnd != 32 || preview.OmittedLines != 22 || len(preview.Source) != 8 {
		t.Fatalf("unexpected preview: %+v", preview)
	}
	full := navigationJSON("example.py", "python", lines, comments[0], true)
	if !full.Full || len(full.Source) != 32 || full.Source[1].Text != "    # child" || full.Source[31].Text != "" {
		t.Fatalf("unexpected full block: %+v", full)
	}
}
