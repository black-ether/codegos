// Codegos is a small, dependency-free comment navigator prototype.
// It extracts standalone comments, builds a hierarchy from indentation,
// and retrieves the source block associated with a comment line.
package main

import (
	"bytes"
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
	Text      string
	StartLine int
	EndLine   int
	Indent    int // Visual indentation columns; tabs count as 4-column tab stops.
	Depth     int
	Children  []*Comment
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "-h" || os.Args[1] == "--help") {
		usage()
		return
	}
	path, targetLine, err := parseArgs(os.Args[1:])
	if err != nil {
		usage()
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}

	source, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error reading file:", err)
		os.Exit(1)
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

	if targetLine != 0 {
		if err := printNavigation(path, source, comments, targetLine); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}

	fmt.Printf("Comment tree: %s (%s)\n\n", filepath.Base(path), language)
	if len(comments) == 0 {
		fmt.Println("(No standalone comments found)")
		return
	}
	printLevel(tree, "")
}

func usage() {
	fmt.Fprintln(os.Stderr, `Usage:
  codegos <source-file>
  codegos <source-file> go <line-number>

Examples:
  go run . ./example.ps1
  go run . ./example.py go 23

Supported extensions in this prototype: .go, .py, .ps1, .psm1, .psd1`)
}

func parseArgs(args []string) (string, int, error) {
	if len(args) == 0 {
		return "", 0, fmt.Errorf("missing source file")
	}
	if len(args) == 1 {
		return args[0], 0, nil
	}
	if len(args) != 3 || args[1] != "go" {
		return "", 0, fmt.Errorf("expected: codegos <source-file> [go <line-number>]")
	}
	line, err := strconv.Atoi(args[2])
	if err != nil || line < 1 {
		return "", 0, fmt.Errorf("invalid line number %q", args[2])
	}
	return args[0], line, nil
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
			if prev.Indent == node.Indent && prev.EndLine+1 == node.StartLine {
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
func buildTree(comments []*Comment) []*Comment {
	roots := make([]*Comment, 0)
	stack := make([]*Comment, 0)

	for _, comment := range comments {
		for len(stack) > 0 && comment.Indent <= stack[len(stack)-1].Indent {
			stack = stack[:len(stack)-1]
		}
		comment.Depth = len(stack)
		comment.Children = nil
		if len(stack) == 0 {
			roots = append(roots, comment)
		} else {
			parent := stack[len(stack)-1]
			parent.Children = append(parent.Children, comment)
		}
		stack = append(stack, comment)
	}
	return roots
}

// printLevel prints only the nodes provided, never their descendants.
// Line references remain at the end so their width does not affect indentation.
func printLevel(nodes []*Comment, prefix string) {
	for i, node := range nodes {
		last := i == len(nodes)-1
		connector := "├── "
		if last {
			connector = "└── "
		}
		children := ""
		if n := len(node.Children); n > 0 {
			children = fmt.Sprintf(" (%d child%s)", n, pluralSuffix(n))
		}
		fmt.Printf("%s%s%s%s %s\n", prefix, connector, oneLine(node.Text), children, nodeLocation(node))
	}
}

func nodeLocation(node *Comment) string {
	if node.EndLine > node.StartLine {
		return fmt.Sprintf("[L:%d-%d]", node.StartLine, node.EndLine)
	}
	return fmt.Sprintf("[L:%d]", node.StartLine)
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
func blockEnd(comments []*Comment, index, sourceLineCount int) int {
	target := comments[index]
	end := sourceLineCount
	for i := index + 1; i < len(comments); i++ {
		if comments[i].Indent <= target.Indent {
			end = comments[i].StartLine - 1
			break
		}
	}
	return end
}

func printLines(lines []string, from, to int, prefix string) {
	if from < 1 {
		from = 1
	}
	if to > len(lines) {
		to = len(lines)
	}
	for n := from; n <= to; n++ {
		fmt.Printf("%s%5d | %s\n", prefix, n, lines[n-1])
	}
}

// printNavigation reveals one level. Short children may show their code, but
// grandchildren are not expanded. Long leaf blocks get a bounded preview.
func printNavigation(path string, source []byte, comments []*Comment, targetLine int) error {
	index := -1
	for i, node := range comments {
		if node.StartLine == targetLine {
			index = i
			break
		}
	}
	if index < 0 {
		return fmt.Errorf("no comment starts at L:%d; run Codegos without go to list roots", targetLine)
	}

	const shortBlockLines = 4
	const fullLeafLines = 29
	const previewLines = 8
	lines := sourceLines(source)
	target := comments[index]
	end := blockEnd(comments, index, len(lines))
	span := end - target.StartLine + 1
	fmt.Printf("%s — %s (%d lines) %s\n", filepath.Base(path), oneLine(target.Text), span, nodeLocation(target))

	if len(target.Children) > 0 {
		fmt.Printf("\n%d immediate children:\n", len(target.Children))
		for i, child := range target.Children {
			connector := "├── "
			bodyPrefix := "│   "
			if i == len(target.Children)-1 {
				connector = "└── "
				bodyPrefix = "    "
			}
			childIndex := -1
			for j, node := range comments {
				if node == child {
					childIndex = j
					break
				}
			}
			childEnd := blockEnd(comments, childIndex, len(lines))
			childSpan := childEnd - child.StartLine + 1
			label := ""
			if n := len(child.Children); n > 0 {
				label = fmt.Sprintf(" (%d child%s)", n, pluralSuffix(n))
			} else {
				label = fmt.Sprintf(" (%d lines)", childSpan)
			}
			fmt.Printf("%s%s%s %s\n", connector, oneLine(child.Text), label, nodeLocation(child))
			if childSpan <= shortBlockLines && len(child.Children) == 0 {
				printLines(lines, child.EndLine+1, childEnd, bodyPrefix)
			}
		}
		return nil
	}

	start := target.EndLine + 1
	if start > end {
		fmt.Println("(No source lines in this block)")
		return nil
	}
	bodyLines := end - start + 1
	if bodyLines <= fullLeafLines {
		fmt.Println("\nSource:")
		printLines(lines, start, end, "")
		return nil
	}
	fmt.Printf("\nSource preview (first %d of %d lines):\n", previewLines, bodyLines)
	printLines(lines, start, start+previewLines-1, "")
	fmt.Printf("... %d more lines omitted\n", bodyLines-previewLines)
	return nil
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
