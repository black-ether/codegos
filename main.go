// Codegos is a small, dependency-free comment navigator prototype.
// It extracts standalone comments, builds a hierarchy from indentation,
// and retrieves the source block associated with a comment line.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/scanner"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Comment is a comment node in the navigation tree.
// StartLine and EndLine are 1-based source line numbers.
type Comment struct {
	directive string
	rangeEnd  int
	Text      string
	StartLine int
	EndLine   int
	Indent    int // Visual indentation columns; tabs count as 4-column tab stops.
	Depth     int
	Parent    *Comment
	Next      *Comment // First following heading at the same or shallower indentation.
	Children  []*Comment
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "-h" || os.Args[1] == "--help") {
		usage()
		return
	}
	options, err := parseArgs(os.Args[1:])
	if err != nil {
		usage()
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}

	path := options.path
	source, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error reading file:", err)
		os.Exit(1)
	}

	lines := sourceLines(source)
	if options.showEnd != 0 {
		if options.showEnd > len(lines) {
			fmt.Fprintf(os.Stderr, "error: range %d-%d exceeds file length (%d lines)\n", options.line, options.showEnd, len(lines))
			os.Exit(1)
		}
		if options.format == "json" {
			writeJSON(jsonOutput{File: path, TotalLines: len(lines), Mode: "show", Source: sourceRange(lines, options.line, options.showEnd)})
		} else {
			printLines(lines, options.line, options.showEnd, "", len(strconv.Itoa(len(lines))))
		}
		return
	}

	language, err := languageFromExtension(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}

	comments, err := extractComments(language, source)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error extracting comments:", err)
		os.Exit(1)
	}
	tree := buildTree(comments)
	visible := comments[:0]
	for _, c := range comments {
		if c.directive != "endregion" {
			visible = append(visible, c)
		}
	}
	comments = visible
	width := lineNumberWidth(comments, len(lines))

	if options.line != 0 {
		if err := printNavigation(path, language, lines, comments, options, width); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}

	if options.format == "json" {
		nodes := make([]headingJSON, 0, len(tree))
		for _, node := range tree {
			nodes = append(nodes, describeHeading(node, len(lines)))
		}
		writeJSON(jsonOutput{File: path, Language: language, TotalLines: len(lines), Mode: "outline", Headings: &nodes})
		return
	}
	if options.format == "plain" {
		fmt.Printf("%s (%s, %d lines)\n", filepath.Base(path), language, len(lines))
		printLevel(tree, width, len(lines), true)
		return
	}
	fmt.Printf("Comment tree: %s (%s, %d lines)\n\n", filepath.Base(path), language, len(lines))
	if len(comments) == 0 {
		fmt.Println("(No standalone comments found)")
		return
	}
	printLevel(tree, width, len(lines), false)
}

func usage() {
	fmt.Fprintln(os.Stderr, `Usage:
  codegos <source-file> [--plain | --json]
  codegos <source-file> go <line-number> [--full] [--plain | --json]
  codegos <source-file> show <start>-<end> [--plain | --json]

Examples:
  go run . ./example.ps1
  go run . ./example.py go 23 --full
  go run . ./example.py show 23-40

Supported extensions in this prototype: .go, .py, .ps1, .psm1, .psd1`)
}

type cliOptions struct {
	path    string
	line    int
	showEnd int
	full    bool
	format  string
}

func parseArgs(args []string) (cliOptions, error) {
	if len(args) == 0 {
		return cliOptions{}, fmt.Errorf("missing source file")
	}
	options := cliOptions{path: args[0]}
	for len(args) > 1 && strings.HasPrefix(args[len(args)-1], "--") {
		flag := args[len(args)-1]
		args = args[:len(args)-1]
		switch flag {
		case "--full":
			if options.full {
				return cliOptions{}, fmt.Errorf("--full can only be supplied once")
			}
			options.full = true
		case "--plain", "--json":
			if options.format != "" {
				return cliOptions{}, fmt.Errorf("choose one output format")
			}
			options.format = strings.TrimPrefix(flag, "--")
		default:
			return cliOptions{}, fmt.Errorf("unknown option %q", flag)
		}
	}
	if options.full && (len(args) != 3 || args[1] != "go") {
		return cliOptions{}, fmt.Errorf("--full requires go <line-number>")
	}
	if len(args) == 1 {
		return options, nil
	}
	if len(args) == 3 && args[1] == "show" {
		start, end, found := strings.Cut(args[2], "-")
		from, startErr := strconv.Atoi(start)
		to, endErr := strconv.Atoi(end)
		if !found || startErr != nil || endErr != nil || from < 1 || to < from {
			return cliOptions{}, fmt.Errorf("invalid line range %q: expected positive start-end with start <= end", args[2])
		}
		options.line, options.showEnd = from, to
		return options, nil
	}
	if len(args) != 3 || args[1] != "go" {
		return cliOptions{}, fmt.Errorf("expected go <line-number> [--full] or show <start>-<end>")
	}
	line, err := strconv.Atoi(args[2])
	if err != nil || line < 1 {
		return cliOptions{}, fmt.Errorf("invalid line number %q", args[2])
	}
	options.line = line
	return options, nil
}

func languageFromExtension(path string) (string, error) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".go":
		return "go", nil
	case ".py", ".pyw":
		return "python", nil
	case ".ps1", ".psm1", ".psd1":
		return "powershell", nil
	default:
		return "", fmt.Errorf("unsupported file extension %q; supported: .go, .py, .ps1, .psm1, .psd1", filepath.Ext(path))
	}
}

func extractComments(language string, source []byte) ([]*Comment, error) {
	var nodes []*Comment
	switch language {
	case "go":
		nodes = extractGoComments(source)
	case "python":
		nodes = extractPythonComments(source)
	case "powershell":
		nodes = extractPowerShellComments(source)
	default:
		return nil, fmt.Errorf("no extractor for language %q", language)
	}
	return groupAdjacentComments(nodes), nil
}

// Consecutive standalone comments at the same indentation form one heading.
// This prevents multi-line descriptions from flooding the root outline.
func groupAdjacentComments(nodes []*Comment) []*Comment {
	grouped := make([]*Comment, 0, len(nodes))
	for _, node := range nodes {
		if len(grouped) > 0 {
			prev := grouped[len(grouped)-1]
			if prev.directive == "" && node.directive == "" && prev.Indent == node.Indent && prev.EndLine+1 == node.StartLine {
				prev.Text += " " + node.Text
				prev.EndLine = node.EndLine
				continue
			}
		}
		grouped = append(grouped, node)
	}
	return grouped
}

// --- Go comment extraction -------------------------------------------------
// The Go standard library scanner already distinguishes comments from comment-like
// text inside strings, raw strings, and rune literals.
func extractGoComments(source []byte) []*Comment {
	fileSet := token.NewFileSet()
	file := fileSet.AddFile("", fileSet.Base(), len(source))
	var s scanner.Scanner
	s.Init(file, source, nil, scanner.ScanComments)

	comments := make([]*Comment, 0)
	for {
		pos, tok, lit := s.Scan()
		if tok == token.EOF {
			break
		}
		if tok != token.COMMENT {
			continue
		}

		position := file.Position(pos)
		prefix := linePrefix(source, position.Offset)
		if !onlyHorizontalWhitespace(prefix) {
			continue // Inline comments are intentionally not navigation nodes.
		}

		startLine := position.Line
		endLine := startLine + bytes.Count([]byte(lit), []byte("\n"))
		text := strings.TrimSpace(stripGoComment(lit))
		if text == "" {
			continue
		}

		comments = append(comments, &Comment{
			Text:      text,
			StartLine: startLine,
			EndLine:   endLine,
			Indent:    visualIndent(prefix),
		})
	}
	return comments
}

func stripGoComment(lit string) string {
	if strings.HasPrefix(lit, "//") {
		return strings.TrimPrefix(lit, "//")
	}
	if strings.HasPrefix(lit, "/*") && strings.HasSuffix(lit, "*/") {
		return lit[2 : len(lit)-2]
	}
	return lit
}

// --- Python comment extraction --------------------------------------------
// Python's # comments are recognized outside quoted strings. Triple-quoted
// strings are treated as strings/docstrings, not as ordinary comments.
type pythonLexState struct {
	quote  byte
	triple bool
}

func extractPythonComments(source []byte) []*Comment {
	lines := sourceLines(source)
	comments := make([]*Comment, 0)
	var state pythonLexState

	for lineIndex, line := range lines {
		commentAt := findPythonComment(line, &state)
		if commentAt < 0 {
			continue
		}
		prefix := line[:commentAt]
		text := strings.TrimSpace(line[commentAt+1:])
		if text == "" {
			continue
		}
		comments = append(comments, &Comment{
			Text:      text,
			StartLine: lineIndex + 1,
			EndLine:   lineIndex + 1,
			Indent:    visualIndent(prefix),
		})
	}
	return comments
}

func findPythonComment(line string, state *pythonLexState) int {
	for i := 0; i < len(line); {
		if state.triple {
			closeAt := findTripleQuoteEnd(line, i, state.quote)
			if closeAt < 0 {
				return -1
			}
			state.triple = false
			state.quote = 0
			i = closeAt + 3
			continue
		}

		if state.quote != 0 {
			closeAt, continued := findQuotedStringEnd(line, i, state.quote, '\\')
			if closeAt < 0 {
				if !continued {
					state.quote = 0 // Invalid/unclosed ordinary string; recover at newline.
				}
				return -1
			}
			state.quote = 0
			i = closeAt + 1
			continue
		}

		switch line[i] {
		case '#':
			if onlyHorizontalWhitespace(line[:i]) {
				return i
			}
			return -1 // An inline comment is not a navigation node.
		case '\'', '"':
			q := line[i]
			if i+2 < len(line) && line[i+1] == q && line[i+2] == q {
				state.quote = q
				state.triple = true
				i += 3
				continue
			}
			state.quote = q
			closeAt, continued := findQuotedStringEnd(line, i+1, q, '\\')
			if closeAt < 0 {
				if !continued {
					state.quote = 0
				}
				return -1
			}
			state.quote = 0
			i = closeAt + 1
		default:
			i++
		}
	}

	// A normal Python string can continue across a physical line only when
	// escaped with a backslash. Triple-quoted strings remain tracked separately.
	if state.quote != 0 && !state.triple && !hasOddTrailingBackslashes(line) {
		state.quote = 0
	}
	return -1
}

func findTripleQuoteEnd(line string, start int, quote byte) int {
	for i := start; i+2 < len(line); i++ {
		if line[i] == '\\' {
			i++
			continue
		}
		if line[i] == quote && line[i+1] == quote && line[i+2] == quote {
			return i
		}
	}
	return -1
}

// Returns the quote position and true when a backslash continuation reaches
// the end of the physical line.
func findQuotedStringEnd(line string, start int, quote byte, escape byte) (int, bool) {
	for i := start; i < len(line); i++ {
		if line[i] == escape {
			i++
			continue
		}
		if line[i] == quote {
			return i, false
		}
	}
	return -1, hasOddTrailingBackslashes(line)
}

func hasOddTrailingBackslashes(s string) bool {
	count := 0
	for i := len(s) - 1; i >= 0 && s[i] == '\\'; i-- {
		count++
	}
	return count%2 == 1
}

// --- PowerShell comment extraction ----------------------------------------
// This lightweight scanner handles # line comments, <# #> block comments,
// quoted strings, here-strings, and nested block comments. It deliberately
// extracts only comments whose opening marker is first non-whitespace on a line.
type powershellLexState struct {
	quote      byte
	blockDepth int
	blockNode  *Comment
	blockText  strings.Builder
	hereEnd    string
}

func extractPowerShellComments(source []byte) []*Comment {
	lines := sourceLines(source)
	comments := make([]*Comment, 0)
	var state powershellLexState

	for lineIndex, line := range lines {
		lineNo := lineIndex + 1
		i := 0

		// Here-string content is not scanned for comments. PowerShell's closing
		// marker must appear at the start of a line (allowing indentation here).
		if state.hereEnd != "" {
			if strings.TrimSpace(line) == state.hereEnd {
				state.hereEnd = ""
			}
			continue
		}

		for i < len(line) {
			if state.blockDepth > 0 {
				if strings.HasPrefix(line[i:], "<#") {
					state.blockDepth++
					i += 2
					continue
				}
				if strings.HasPrefix(line[i:], "#>") {
					state.blockDepth--
					i += 2
					if state.blockDepth == 0 {
						if state.blockNode != nil {
							state.blockNode.EndLine = lineNo
							state.blockNode.Text = strings.TrimSpace(state.blockText.String())
							if state.blockNode.Text != "" {
								comments = append(comments, state.blockNode)
							}
						}
						state.blockNode = nil
						state.blockText.Reset()
						continue
					}
					continue
				}
				if state.blockNode != nil {
					state.blockText.WriteByte(line[i])
				}
				i++
				continue
			}

			if state.quote != 0 {
				closed, next := consumePowerShellQuoted(line, i, state.quote)
				i = next
				if closed {
					state.quote = 0
				}
				if !closed {
					break
				}
				continue
			}

			// A here-string starts with @' or @" and has no other text on the
			// opening line. Its body is never treated as comments.
			if i+1 < len(line) && line[i] == '@' && (line[i+1] == '\'' || line[i+1] == '"') && strings.TrimSpace(line[i+2:]) == "" {
				if line[i+1] == '\'' {
					state.hereEnd = "'@"
				} else {
					state.hereEnd = `"@`
				}
				break
			}

			if line[i] == '\'' || line[i] == '"' {
				state.quote = line[i]
				i++
				continue
			}

			if strings.HasPrefix(line[i:], "<#") {
				prefix := line[:i]
				if onlyHorizontalWhitespace(prefix) {
					state.blockNode = &Comment{
						StartLine: lineNo,
						EndLine:   lineNo,
						Indent:    visualIndent(prefix),
					}
				} else {
					state.blockNode = nil // Track but do not expose inline comments.
				}
				state.blockDepth = 1
				state.blockText.Reset()
				i += 2
				continue
			}

			if line[i] == '#' {
				prefix := line[:i]
				if onlyHorizontalWhitespace(prefix) {
					text := strings.TrimSpace(line[i+1:])
					if text != "" {
						comments = append(comments, &Comment{
							directive: powerShellDirective(line[i+1:]),
							Text:      text,
							StartLine: lineNo,
							EndLine:   lineNo,
							Indent:    visualIndent(prefix),
						})
					}
				}
				break // Ignore inline comments and everything after a line-comment marker.
			}

			i++
		}

		if state.blockDepth > 0 && state.blockNode != nil {
			state.blockText.WriteByte('\n')
		}
	}

	// Keep an unterminated standalone block comment visible as an incomplete node.
	if state.blockDepth > 0 && state.blockNode != nil {
		state.blockNode.EndLine = len(lines)
		state.blockNode.Text = strings.TrimSpace(state.blockText.String()) + " [unterminated block comment]"
		comments = append(comments, state.blockNode)
	}

	return comments
}

func consumePowerShellQuoted(line string, start int, quote byte) (closed bool, next int) {
	for i := start; i < len(line); i++ {
		if quote == '"' && line[i] == '`' {
			i++ // PowerShell double-quoted strings use backtick escapes.
			continue
		}
		if line[i] == quote {
			if quote == '\'' && i+1 < len(line) && line[i+1] == '\'' {
				i++ // Doubled single quote inside a single-quoted string.
				continue
			}
			return true, i + 1
		}
	}
	// PowerShell quoted strings can span physical lines.
	return false, len(line)
}

// --- Shared hierarchy and display -----------------------------------------
// PowerShell folding markers start immediately after the comment delimiter.
func powerShellDirective(body string) string {
	word, _, _ := strings.Cut(strings.ToLower(strings.ReplaceAll(body, "\t", " ")), " ")
	if word == "region" || word == "endregion" {
		return word
	}
	return ""
}

func buildTree(comments []*Comment) []*Comment {
	roots := make([]*Comment, 0)
	stack := make([]*Comment, 0)

	// Pair first so an unfinished region cannot swallow the rest of the file.
	pairs := map[*Comment]*Comment{}
	var opens []*Comment
	for _, c := range comments {
		switch c.directive {
		case "region":
			opens = append(opens, c)
		case "endregion":
			if len(opens) > 0 {
				open := opens[len(opens)-1]
				pairs[open] = c
				opens = opens[:len(opens)-1]
			}
		}
	}
	var floors []int
	for _, comment := range comments {
		floor := 0
		if len(floors) > 0 {
			floor = floors[len(floors)-1]
		}
		if floor > 0 && pairs[stack[floor-1]] == comment {
			for _, c := range stack[floor:] {
				c.rangeEnd = comment.StartLine - 1
			}
			stack[floor-1].rangeEnd = comment.StartLine
			stack = stack[:floor-1]
			floors = floors[:len(floors)-1]
			continue
		}
		if comment.directive == "endregion" {
			continue
		}
		comment.rangeEnd = 0
		for len(stack) > floor && comment.Indent <= stack[len(stack)-1].Indent {
			stack[len(stack)-1].Next = comment
			stack = stack[:len(stack)-1]
		}
		comment.Depth = len(stack)
		comment.Parent = nil
		comment.Next = nil
		comment.Children = nil
		if len(stack) == 0 {
			roots = append(roots, comment)
		} else {
			parent := stack[len(stack)-1]
			comment.Parent = parent
			parent.Children = append(parent.Children, comment)
		}
		stack = append(stack, comment)
		if pairs[comment] != nil {
			floors = append(floors, len(stack))
		}
	}
	return roots
}

// printLevel prints only the nodes provided, never their descendants.
func printLevel(nodes []*Comment, width, sourceLineCount int, plain bool) {
	for i, node := range nodes {
		last := i == len(nodes)-1
		connector := "├── "
		if last {
			connector = "└── "
		}
		if plain {
			connector = ""
		}
		children := ""
		if n := len(node.Children); n > 0 {
			children = fmt.Sprintf(" (%d child%s)", n, pluralSuffix(n))
		}
		printRow(width, nodeLocation(node), connector+oneLine(node.Text)+children+blockLocation(node, blockEnd(node, sourceLineCount)))
	}
}

func blockLocation(node *Comment, end int) string {
	return fmt.Sprintf(" [block %d-%d]", node.StartLine, end)
}

func nodeLocation(node *Comment) string {
	if node.EndLine > node.StartLine {
		return fmt.Sprintf("%d-%d", node.StartLine, node.EndLine)
	}
	return strconv.Itoa(node.StartLine)
}

func lineNumberWidth(comments []*Comment, sourceLineCount int) int {
	width := len(strconv.Itoa(sourceLineCount))
	for _, node := range comments {
		width = max(width, len(nodeLocation(node)))
	}
	return width
}

func printRow(width int, location, text string) {
	fmt.Printf("%*s | %s\n", width, location, text)
}

func pluralSuffix(n int) string {
	if n == 1 {
		return ""
	}
	return "ren"
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// blockEnd returns the last line belonging to a navigation node, including
// descendants, stopping at the next peer or ancestor comment.
func blockEnd(node *Comment, sourceLineCount int) int {
	if node.rangeEnd != 0 {
		return node.rangeEnd
	}
	if node.Next != nil {
		return node.Next.StartLine - 1
	}
	return sourceLineCount
}

func printLines(lines []string, from, to int, prefix string, width int) {
	if from < 1 {
		from = 1
	}
	if to > len(lines) {
		to = len(lines)
	}
	for n := from; n <= to; n++ {
		printRow(width, strconv.Itoa(n), prefix+lines[n-1])
	}
}

// printNavigation reveals one level. Short children may show their code, but
// grandchildren are not expanded. Long leaf blocks get a bounded preview.
func printNavigation(path, language string, lines []string, comments []*Comment, options cliOptions, width int) error {
	var target *Comment
	for _, node := range comments {
		if node.StartLine == options.line {
			target = node
			break
		}
	}
	if target == nil {
		return fmt.Errorf("no comment starts at L:%d; run Codegos without go to list roots", options.line)
	}

	end := blockEnd(target, len(lines))
	if options.format == "json" {
		writeJSON(navigationJSON(path, language, lines, target, options.full))
		return nil
	}
	if options.full {
		printLines(lines, target.StartLine, end, "", len(strconv.Itoa(len(lines))))
		return nil
	}
	span := end - target.StartLine + 1
	plain := options.format == "plain"
	if !plain {
		fmt.Printf("%s\n\n", filepath.Base(path))
	}
	if len(target.Children) == 0 && target.Parent != nil {
		printRow(width, nodeLocation(target.Parent), "Parent: "+oneLine(target.Parent.Text))
	}
	printRow(width, nodeLocation(target), fmt.Sprintf("%s (%d lines)%s", oneLine(target.Text), span, blockLocation(target, end)))

	if len(target.Children) > 0 {
		if !plain {
			fmt.Printf("\n%d immediate children:\n", len(target.Children))
		}
		for i, child := range target.Children {
			connector := "├── "
			bodyPrefix := "│   "
			if i == len(target.Children)-1 {
				connector = "└── "
				bodyPrefix = "    "
			}
			if plain {
				connector = "  "
				bodyPrefix = "    "
			}
			childEnd := blockEnd(child, len(lines))
			childSpan := childEnd - child.StartLine + 1
			label := ""
			if n := len(child.Children); n > 0 {
				label = fmt.Sprintf(" (%d child%s)", n, pluralSuffix(n))
			} else {
				label = fmt.Sprintf(" (%d lines)", childSpan)
			}
			printRow(width, nodeLocation(child), connector+oneLine(child.Text)+label+blockLocation(child, childEnd))
			if childSpan <= shortBlockLines && len(child.Children) == 0 {
				printLines(lines, child.EndLine+1, childEnd, bodyPrefix, width)
			}
		}
		return nil
	}

	start := target.EndLine + 1
	if start > end {
		fmt.Println("(No source lines in this block)")
	} else {
		last, omitted := leafPreview(start, end)
		if omitted > 0 && !plain {
			fmt.Printf("\nSource preview (first %d of %d lines):\n", previewLines, end-start+1)
		}
		printLines(lines, start, last, "", width)
		if omitted > 0 {
			fmt.Printf("... %d more lines omitted\n", omitted)
		}
	}
	if target.Next != nil {
		printRow(width, nodeLocation(target.Next), "Next: "+oneLine(target.Next.Text))
	}
	return nil
}

const (
	shortBlockLines = 4
	fullLeafLines   = 29
	previewLines    = 8
)

func leafPreview(start, end int) (last, omitted int) {
	if end-start+1 <= fullLeafLines {
		return end, 0
	}
	last = start + previewLines - 1
	return last, end - last
}

type headingJSON struct {
	Text       string     `json:"text"`
	StartLine  int        `json:"start_line"`
	EndLine    int        `json:"end_line"`
	BlockEnd   int        `json:"block_end"`
	ChildCount int        `json:"child_count"`
	Source     []lineJSON `json:"source,omitempty"`
}

type lineJSON struct {
	Line int    `json:"line"`
	Text string `json:"text"`
}

type jsonOutput struct {
	File         string         `json:"file"`
	Language     string         `json:"language,omitempty"`
	TotalLines   int            `json:"total_lines"`
	Mode         string         `json:"mode"`
	Full         bool           `json:"full,omitempty"`
	Headings     *[]headingJSON `json:"headings,omitempty"`
	Selected     *headingJSON   `json:"selected,omitempty"`
	Parent       *headingJSON   `json:"parent,omitempty"`
	Next         *headingJSON   `json:"next,omitempty"`
	Children     []headingJSON  `json:"children,omitempty"`
	Source       []lineJSON     `json:"source,omitempty"`
	OmittedLines int            `json:"omitted_lines,omitempty"`
}

func describeHeading(node *Comment, totalLines int) headingJSON {
	return headingJSON{
		Text: oneLine(node.Text), StartLine: node.StartLine, EndLine: node.EndLine,
		BlockEnd: blockEnd(node, totalLines), ChildCount: len(node.Children),
	}
}

func sourceRange(lines []string, start, end int) []lineJSON {
	var source []lineJSON
	for n := start; n <= end; n++ {
		source = append(source, lineJSON{Line: n, Text: lines[n-1]})
	}
	return source
}

func navigationJSON(path, language string, lines []string, target *Comment, full bool) jsonOutput {
	total := len(lines)
	selected := describeHeading(target, total)
	out := jsonOutput{File: path, Language: language, TotalLines: total, Mode: "go", Full: full, Selected: &selected}
	if full {
		out.Source = sourceRange(lines, target.StartLine, selected.BlockEnd)
		return out
	}
	if len(target.Children) > 0 {
		for _, child := range target.Children {
			heading := describeHeading(child, total)
			if heading.ChildCount == 0 && heading.BlockEnd-child.StartLine+1 <= shortBlockLines {
				heading.Source = sourceRange(lines, child.EndLine+1, heading.BlockEnd)
			}
			out.Children = append(out.Children, heading)
		}
		return out
	}
	if target.Parent != nil {
		parent := describeHeading(target.Parent, total)
		out.Parent = &parent
	}
	if target.Next != nil {
		next := describeHeading(target.Next, total)
		out.Next = &next
	}
	start := target.EndLine + 1
	last, omitted := leafPreview(start, selected.BlockEnd)
	out.Source = sourceRange(lines, start, last)
	out.OmittedLines = omitted
	return out
}

func writeJSON(out jsonOutput) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, "error writing JSON:", err)
		os.Exit(1)
	}
}

// --- Small shared utilities ----------------------------------------------
func sourceLines(source []byte) []string {
	if len(source) == 0 {
		return nil
	}
	normalized := strings.ReplaceAll(string(source), "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	lines := strings.Split(normalized, "\n")
	if strings.HasSuffix(normalized, "\n") {
		lines = lines[:len(lines)-1]
	}
	return lines
}

func linePrefix(source []byte, offset int) string {
	if offset > len(source) {
		offset = len(source)
	}
	start := bytes.LastIndexByte(source[:offset], '\n') + 1
	return string(source[start:offset])
}

func onlyHorizontalWhitespace(s string) bool {
	for _, r := range s {
		if r != ' ' && r != '\t' {
			return false
		}
	}
	return true
}

func visualIndent(s string) int {
	column := 0
	for _, r := range s {
		switch r {
		case ' ':
			column++
		case '\t':
			column += 4 - (column % 4)
		default:
			return column
		}
	}
	return column
}
