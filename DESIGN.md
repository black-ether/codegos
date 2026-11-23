# becv-next — working design (SPEC PHASE, no code yet)

Working name: becv-next (placeholder — rename before first build).
Lineage: Black-Ether Code Visualizer / becv comment companion.
Reference sources copied to `reference\` (originals untouched in
`C:\Users\ncode\scripts\Black-Ether Code Visualizer`).
Status: settling what it does before choosing final scope/language. Go is the
leaning (toolchain confirmed on host: go1.24.0 windows/amd64).

## Problem statement

Two concrete problems, one tool:

P1. Context scarcity. Local small models / free-tier endpoints cannot swallow large
    scripts (e.g. an 80KB .psm1). Feeding raw code wastes tokens and buries the model
    in noise. Need a cheap, intent-preserving map of a file that fits any context.

P2. Grounded navigation. A lossy summary alone can mislead a model. The map must be
    an index into real code: every entry anchored to line numbers, plus a fast way
    to fetch the exact code range for a chosen section. Map -> pick -> fetch real code.

Key insight: the semantics come from the AUTHOR'S COMMENTS, not machine inference.
Numbered/structured comments are the program's plan, already written. Extracting
them is cheap, language-agnostic, and carries no regex-classification risk. This is
what breakitdown's tag/phase machinery tried to approximate and failed at.

## Core loop (the whole product)

1. `map <file>`  -> compact comment outline: hierarchy + `L:start-end` anchors +
   tiny stats header (path, total lines, est. tokens of map vs full file).
2. model/human picks a section.
3. `show <file> <start>-<end>` -> plain `[L:n] code` lines, exact, unmodified.

That's it. Two commands. Everything else must earn its place later.

## Output contract (map)

- Every entry carries anchors: `L42-58 | 1. Import required modules`.
  Range = comment line through line before next entry (EOF for last). Range INCLUDES
  the heading comment line, so a fetch shows the author's intent with the code.
- Hierarchy: best-effort parse of numbering schemes (1. / 1.1 / a. / T1 / 0.1 ...)
  and/or source indentation. Failure falls back to a FLAT anchored list — still
  useful. Wrong indent is benign; wrong/missing anchors are not.
- Plain markdown or text. No box-drawing glyphs, no ANSI color (LLM consumption).
- Stats header: file path, total lines, comment-entry count, chars/4 token estimate
  for map and for full file (heuristic, labeled as estimate).
- Deterministic output (same file -> same map), so anchors are stable across calls.

## Non-goals for v1 (explicitly dropped from the old project)

- No 4-level tag taxonomy, no Setup/Execution phase inference, no phase spans.
- No cache (old one was write-only dead weight).
- No AST parsing in v1 -> no per-language parser maintenance, no tree-sitter/cgo.
  (Optional later: signature fallback for uncommented functions, if a real need appears.)
- No TUI/GUI, no colorized tree (human pretty-view can be a later surface).
- No multi-file/repo indexing yet — single file is the unit.

## Language recommendation: Go

- Single static binary (CGO_ENABLED=0), zero runtime deps, instant startup —
  matches user's quality bar (PS tool startup latency was a complaint) and the
  existing seermon Go workflow on this host.
- Problem is string/line processing + CLI: Go stdlib covers 100% of v1. No modules
  needed at all (if any ever are: GOPROXY=https://goproxy.cn,direct on this network).
- Host facts: go1.24.0 present; no gcc -> no -race locally; build to bin\ with a
  build script hardcoding the destination (windows-go-services skill conventions).
- Alternatives considered: Rust (overkill, slower iteration), Python (venv friction,
  slow startup), staying PowerShell (works, but the rewrite goal is a fast portable
  binary; PS version remains as reference behavior).

## Open questions (answer by number; defaults are my recommendation)

Q1. Language scope: v1 = language-agnostic comment extraction via extension ->
    comment-syntax table (#, //, /* */, --, ;, """ ...). No AST. DEFAULT: yes.
Q2. Which comments enter the map: full-line comments + block comments. Inline
    (trailing) comments excluded by default. DEFAULT: yes; --inline only if needed.
Q3. Hierarchy effort: simple numbering-scheme detection + indentation tiebreak,
    flat fallback. No grand unified numbering parser. DEFAULT: yes.
Q4. Fetch by map-entry index (`show file @3`) in addition to line ranges?
    DEFAULT: line ranges only in v1; @n later if the two-prompt workflow wants it.
Q5. Formats: markdown (default) + plain text. JSON deferred until a tool consumer
    exists. DEFAULT: yes.
Q6. Block comments: include full block text in map, or first line only?
    DEFAULT: first line + anchor (blocks are often license headers/noise); flag later.
Q7. Final name/binary name. DEFAULT: decide at M1; folder stays becv-next until then.

## Milestones (phased, gated — stop after each for review)

M0. Settle this spec (current step).
M1. Comment extraction engine + FLAT anchored map (md/txt) + `show` range command.
    Golden fixtures from real files below. Prove token savings on Untitled-40.ps1.
M2. Hierarchy parsing + re-indent (the example output shape), still anchor-exact.
M3. Only if a consumer exists: JSON, --inline, @n fetch, AST signature fallback.

## Test corpus (verified present)

- D:\desktop\archivbe\Untitled-40.ps1  <- the user's example source (numbered comments)
- reference\test_comments.ps1          <- block/inline edge cases
- reference\cleanmycode.ps1            <- small real script
- reference\Modules\ScriptAnalysisUtils.psm1 <- 80KB stress case (token math)
- any seermon .go file                 <- proves language-agnostic extraction

## Reference map (what to read in reference\)

- becv.ps1 — the companion being rewritten: ListComments/Tree/Markdown modes,
  -ShowLineNumbers, -ShowCodeAroundLine, -SpacesPerLevel, -Raw. Behavior to port.
- becvN.ps1 / becvN2.ps1 — later iterations; check for ideas worth keeping.
- Modules\CommentVisUtils.psm1 — Select-SingleLineComment (extraction logic),
  Get-LanguageProfile (comment syntax per extension).
- breakitdown_dev.md — full analysis of the abandoned tagging approach; §8 lists
  the failure modes we are deliberately not repeating.
