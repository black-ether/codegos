# Codegos — Minimal Go Prototype

A dependency-free prototype that extracts standalone comments, builds a hierarchy from comment indentation, and retrieves the source block associated with a selected comment.

## Supported file types

- Go: `.go`
- Python: `.py`, `.pyw`
- PowerShell: `.ps1`, `.psm1`, `.psd1`

Unsupported extensions produce an error rather than falling back to the wrong comment syntax.

## Run

```powershell
go run . .\example.ps1
go run . .\example.ps1 --at 23
```

The first command prints the comment tree. The second retrieves the source block associated with the comment node beginning at line 23.

## Initial behavior

- Only comments whose opening marker is the first non-whitespace content on a line become navigation nodes.
- Inline comments are ignored.
- Original 1-based line numbers are retained.
- Indentation determines hierarchy. A deeper indentation creates a child; equal or shallower indentation starts a sibling or ancestor-level node.
- Tabs count as four-column tab stops for indentation comparison.
- A comment node's source block begins after the comment and ends immediately before the next comment at the same or a shallower indentation level.
- Empty comments are omitted. No other content/noise filtering is applied.
- Python triple-quoted strings are treated as strings, not comments.

## Current limitations

This is a starting prototype, not a production-grade lexer. Go comment recognition uses the Go standard-library scanner. Python and PowerShell use small purpose-built lexical scanners that cover common strings and comment forms but do not implement every edge case in their languages. In particular, complex PowerShell expandable-string subexpressions and newer Python f-string parsing rules need additional tests.

Multiline block comments are represented as one node. Python docstrings are not treated as comments. `#region` and `#endregion` are currently ordinary PowerShell comments; BECS/region interpretation is not implemented.

## Test

```powershell
go test ./...
go vet ./...
```
