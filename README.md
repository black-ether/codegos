# Codegos — comment navigator prototype

A dependency-free Go prototype (standard library only) that turns a source file's
own comments into a navigable outline, then fetches the exact source block behind a
chosen comment.

Two modes:

1. `codegos <file>` — print the root-level comment outline with line anchors.
2. `codegos <file> go <line>` — reveal the block behind the comment starting at that
   line, one level deep.

## Supported file types

| Extension | Language   | Comment syntax      |
|-----------|------------|---------------------|
| `.go`     | Go         | `//`, `/* */`       |
| `.py`, `.pyw` | Python | `#`                 |
| `.ps1`, `.psm1`, `.psd1` | PowerShell | `#`, `<# #>` |

Extensions are matched case-insensitively. Any other extension is an error
(exit 2), never guessed.

## Usage

```
codegos <source-file>
codegos <source-file> go <line-number>
codegos -h
```

While developing, substitute `go run .` for the binary:

```powershell
go run . .\main.go
go run . .\main.go go 150
```

Exit codes: `0` success, `2` usage error or unsupported extension, `1` unreadable
file, extraction failure, or a line number with no comment.

## Outline mode

`codegos main.go` prints root-level entries only:

```
Comment tree: main.go (go)

├── --- Go comment extraction --- ... (1 child) [L:150-152]
├── printLevel prints only the nodes provided, never their descendants. ... [L:515-516]
└── --- Small shared utilities --- [L:648]
```

- One entry per standalone comment; inline comments are excluded.
- Comment text is collapsed to a single line.
- `(N children)` marks entries that have nested comments.
- `[L:n]` / `[L:n-m]` are 1-based anchors; `m` is the last line of a multi-line
  comment.
- A file with no standalone comments prints `(No standalone comments found)`.

## Drill-down mode

`codegos main.go go 150` reveals one level:

```
main.go — --- Go comment extraction --- ... (52 lines) [L:150-152]

Source preview (first 8 of 49 lines):
  153 | func extractGoComments(source []byte) []*Comment {
  ...
... 41 more lines omitted
```

Behavior:

- Header shows file name, comment text, block span, and anchor.
- A node with children lists its immediate children, each labelled `(N children)`
  or `(N lines)`. A leaf child whose block is 4 lines or fewer is printed with its
  code. Grandchildren are never expanded.
- A leaf node prints its full source when the block is 29 lines or fewer;
  otherwise the first 8 lines plus `... N more lines omitted`.
- `(No source lines in this block)` when a comment has no code after it.
- A line number with no comment starting there is an error, not a silent no-op.

Block boundary rule: a node's block runs from the line after its comment to the line
before the next comment at the same or shallower indentation, so nested comments
stay inside the parent's span.

## Extraction rules (shared)

- Only comments whose opening marker is the first non-whitespace content on a line
  become navigation nodes; inline comments are ignored.
- Empty comments are omitted.
- Consecutive standalone comments at the same indentation are merged into one
  heading, joined with a single space.
- Indentation determines hierarchy: deeper indentation creates a child; equal or
  shallower indentation starts a sibling or ancestor-level node. Tabs count as
  four-column tab stops.
- Original 1-based line numbers are retained; CRLF and bare CR are normalized.

## Per-language notes

- **Go** — uses the standard-library `go/scanner`, so comment markers inside
  strings, raw strings, and rune literals are not mistaken for comments.
- **Python** — `#` is recognized outside quoted strings; triple-quoted strings are
  tracked as strings, so docstrings are not comments; backslash-continued strings
  are handled.
- **PowerShell** — `#` line comments and `<# #>` block comments, including nested
  blocks; single- and double-quoted strings with `''` and backtick escapes;
  here-string bodies (`@'...'@`, `@"..."@`) are never scanned; an unterminated
  block comment is kept and tagged `[unterminated block comment]`.

## Limitations

This is a prototype, not a production lexer. Python and PowerShell use small
purpose-built scanners that cover common string and comment forms but not every
edge case in those languages. There is no numbering-scheme parsing (`1.`, `1.1`,
`T1`), `#region`/`#endregion` are ordinary comments, no token-statistics header, no
JSON output, and one file per run.

`DESIGN.md` is the pre-code spec for this project. The shipped prototype is
narrower than that spec: no token estimates, no markdown output, and no separate
`show` command.

## Test

```powershell
go test .
go vet .
```

`go test ./...` also compiles `examples/`, which needs bubbletea, lipgloss, and
gopsutil — not yet listed in `go.mod`.
