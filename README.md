# Codegos — comment navigator prototype

A dependency-free Go prototype (standard library only) that turns a source file's
own comments into a navigable outline, then fetches the exact source block behind a
chosen comment.

Three modes:

1. `codegos <file>` — print the root-level comment outline with line anchors.
2. `codegos <file> go <line>` — reveal the block behind the comment starting at that
   line, one level deep. Add `--full` to retrieve the entire block.
3. `codegos <file> show <start>-<end>` — retrieve an inclusive range of source lines.

## Supported file types

| Extension | Language   | Comment syntax      |
|-----------|------------|---------------------|
| `.go`     | Go         | `//`, `/* */`       |
| `.py`, `.pyw` | Python | `#`                 |
| `.ps1`, `.psm1`, `.psd1` | PowerShell | `#`, `<# #>` |

Outline and drill-down match extensions case-insensitively and reject unsupported
extensions (exit 2). Range reads work with any text file.

## Usage

```
codegos <source-file> [--plain | --json]
codegos <source-file> go <line-number> [--full] [--plain | --json]
codegos <source-file> show <start>-<end> [--plain | --json]
codegos -h
```

While developing, substitute `go run .` for the binary:

```powershell
go run . .\examples\sample.ps1
go run . .\examples\sample.ps1 go 8
```

Exit codes: `0` success, `2` usage error or unsupported extension, `1` unreadable
file, extraction failure, a line number with no comment, or a range beyond EOF.

## Outline mode

`codegos examples/sample.ps1` prints root-level entries:

```
Comment tree: sample.ps1 (powershell, 13 lines)

1-2 | ├── region Initialization Load required modules [block 1-4]
  5 | ├── Configure environment (2 children) [block 5-10]
 11 | ├── Run application [block 11-12]
 13 | └── endregion [block 13-13]
```

- One entry per standalone comment; inline comments are excluded.
- Comment text is collapsed to a single line.
- `(N children)` marks entries that have nested comments.
- Headings and source lines share an aligned `line | text` column. Multiple-line
  headings show a range such as `1-2 |`. Use the first line of the range with `go`.
- `[block start-end]` is the full inclusive section span, including the heading
  and its descendants. Pass that range to `show` to read it directly.
- A file with no standalone comments prints `(No standalone comments found)`.

## Drill-down mode

`codegos examples/sample.ps1 go 8` opens a code block:

```
sample.ps1

  5 | Parent: Configure environment
  8 | Validate configuration (3 lines) [block 8-10]
  9 |     if (!$config) { throw 'Missing config' }
 10 |
 11 | Next: Run application
```

Behavior:

- The file name appears above the selected heading, which shows its line anchor
  and block span.
- A node with children lists its immediate children, each labelled `(N children)`
  or `(N lines)`. A leaf child whose block is 4 lines or fewer is printed with its
  code. Grandchildren are never expanded.
- A leaf node prints its full source when the block is 29 lines or fewer;
  otherwise the first 8 lines plus `... N more lines omitted`.
- For a leaf, `Parent` shows the immediate enclosing heading when it exists.
  `Next` shows the first following heading at the same or shallower indentation,
  when one exists. It appears after the source or preview.
- `(No source lines in this block)` when a comment has no code after it.
- A line number with no comment starting there is an error, not a silent no-op.

Block boundary rule: a node's block runs from the line after its comment to the line
before the next comment at the same or shallower indentation, so nested comments
stay inside the parent's span.

## Exact source reads

`codegos examples/sample.ps1 show 5-10` and
`codegos examples/sample.ps1 go 5 --full` both return source rows for lines 5
through 10. Full sections include the original heading and any nested comments,
with no preview limit. Both commands preserve indentation and blank lines.
Range reads require positive line numbers in ascending order and accept a
single-line range such as `5-5`.

## Output formats

Use `--plain` for compact text. It keeps the aligned `line | text` rows,
block spans, and parent and next context. Indentation after the separator
indicates children. Exact source reads already use this format by default.

Use `--json` for a single JSON object on stdout. For example,
`codegos examples/sample.ps1 show 13-13 --json` returns an object like this:

```json
{
  "file": "examples/sample.ps1",
  "total_lines": 13,
  "mode": "show",
  "source": [{"line": 13, "text": "#endregion"}]
}
```

- Outline output uses `headings` for the root entries, including an empty
  array when there are no headings.
- Drill-down output uses `selected` and, when available, `children`,
  `parent`, `next`, `source`, and `omitted_lines`. With `--full`, it
  includes the complete numbered source in `source`.
- A heading's `start_line` and `end_line` are its comment anchors.
  `start_line` through `block_end` is the inclusive block span.
- Source records have a 1-based `line` and the original line `text`.
  Errors go to stderr and use the usual exit codes.

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
`T1`), `#region`/`#endregion` are ordinary comments, there is no
token-statistics header, and each run reads one file.

`DESIGN.md` is the pre-code spec for this project. The shipped prototype is
narrower than that spec and omits token estimates and Markdown output.

## Test

```powershell
go test .
go vet .
```

`go test ./...` also compiles `examples/`, which needs bubbletea, lipgloss, and
gopsutil — not yet listed in `go.mod`.
