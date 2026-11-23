# Codegos
## Project Brief, Core Design, and Validation Plan

**Document status:** Working draft — suitable as the project’s foundational GitHub design document; detailed parsing rules remain subject to fixture-based validation  
**Version:** 0.2  
**Date:** 21 November 2026  
**Project name:** Codegos  
**Related optional convention:** Black-Ether Comment Style (BECS)

---

## 1. Executive summary

Codegos is a lightweight, cross-platform, cross-language comment extraction and navigation tool designed for developers and coding agents.

Its core job is deliberately narrow:

1. Extract real comments from source files reliably.
2. Preserve each comment’s text, indentation, and source location.
3. Build a navigable hierarchy from comment indentation.
4. Associate each comment node with the source-code range it introduces or describes.
5. Let an agent explore that hierarchy progressively and retrieve only the relevant code.

Codegos is **not** intended to understand program logic, reconstruct an abstract syntax tree, build call graphs, or explain what code does. It does not need to understand the programming language beyond what is necessary to recognize comments correctly and map them back to their original source locations.

Black-Ether Comment Style (BECS) remains an optional convention. It may add more explicit organization and developer-authored intent, but Codegos must be useful on ordinary code, legacy code, and AI-generated code without requiring BECS annotations.
(core idea of BECS is using numbers for sequential logic and letters for non-sequential)

### Central proposition

> Codegos turns source-code comments into a compact, hierarchical navigation map, then retrieves the relevant source code only when a developer or coding agent asks for it.

The project's value must be demonstrated through measurable improvements in navigation efficiency, context consumption, and task performance.

---

## 2. The problem Codegos addresses

Coding agents can already search repositories, inspect files, and read source ranges. The problem is not that agents cannot access code. The problem is that they often have to spend repeated searches and context on discovering where relevant explanations and implementation blocks are located.

A large file may contain many comments spread across hundreds or thousands of lines. Sending every comment and the entire file to an agent wastes context. Searching raw text can also miss relevant logic when the wording in a comment differs from the implementation.

Codegos introduces an intermediate navigation layer:

- Show a compact outline of comments rather than dumping every comment at once.
- Preserve indentation so nested comment groups can be explored one level at a time.
- Attach source line references to every displayed node.
- Retrieve the source block associated with a selected comment.
- Expand a large block into its nested comment structure before returning all of its code.

The agent can move from a file overview to a subsection, then to the exact source block. It does not need to load the whole file at the beginning.

### What Codegos does not claim

Codegos does not infer a developer's intention from arbitrary code. A comment heading may express intent; indentation may express grouping; source positions identify where the relevant code is. The tool should preserve those facts without pretending that it understands the implementation semantically.

---

## 3. Product principles

### 3.1 Comment-first, not code-analysis-first

The main input to the navigation model is extracted comments. Code is retained and retrieved by source range, not semantically analyzed.

### 3.2 Useful without BECS

Ordinary comments are sufficient for Codegos to build a useful outline. BECS is an optional enhancement, not a prerequisite.

### 3.3 Preserve the original source

Codegos must not rewrite, reformat, or normalize the user's source file. It may normalize comment metadata internally, but source retrieval must return the original text and accurate locations.

### 3.4 Indentation is structural information

The indentation of a comment is preserved and used to construct a hierarchy. The parser should not require developers to type generated numbers or letters into each comment.

### 3.5 Progressive disclosure

The default output should reveal only the current level of the hierarchy. The agent chooses which node to expand or retrieve. Large blocks should not be dumped automatically when a smaller outline can guide the next request.

### 3.6 Deterministic and local-first

Core parsing and navigation must work locally without an LLM, remote service, or source-code execution. Given the same file contents and configuration, Codegos should produce the same results.

### 3.7 Language adapters, shared behavior

Programming languages have different comment and string syntax. A language adapter handles those lexical differences; a shared core builds the hierarchy, maps source ranges, and produces outputs consistently.

### 3.8 Reliable uncertainty

When a language or syntax form is unsupported, Codegos must report a limitation rather than silently claiming complete extraction. It must not fabricate hierarchy or semantic meaning.

### 3.9 Optimize for agent utility first
Terminal trees and Markdown exports are useful views at latter development , but the primary design target is a compact, predictable interface that agents can call and interpret easily.

---

## 4. Scope and priorities

### 4.1 Core scope — Codegos v1

1. File and language identification for explicitly supported languages.
2. Reliable extraction of line comments and block comments, including protection against comment-like text inside strings.
3. Preservation of raw comment text, indentation, and exact source positions.
4. Grouping of adjacent comment lines according to documented rules.
5. Construction of a comment hierarchy using indentation.
6. Automatic line references for comment nodes, displayed as `L:<line>`.
7. Deterministic association of comment nodes with following source ranges.
8. Progressive outline, expand, and source-read operations.
9. Adaptive retrieval based on block size and output budget.
10. CLI and compact JSON output for scripts and coding agents.
11. Cross-platform tests, language fixtures, correctness tests, and performance benchmarks.

### 4.2 Explicitly out of scope for v1

- Abstract syntax tree construction or general syntax-tree navigation.
- Function, class, or method indexing as a core requirement.
- Call graphs, symbol resolution, or data-flow analysis.
- Explaining code semantics or inferring undocumented intent.
- Workspace-wide dependency analysis.
- Automatic BECS annotation generation or source rewriting.
- LLM-based parsing or remote indexing.
- Editor extensions before the CLI and data model are stable.

### 4.3 Later feature: workspace navigation

A future module may analyze relationships between files across a repository, including:

- Explicit imports, includes, dot-sourcing, and module references.
- Local file and module dependencies.
- External packages, modules, executables, and system libraries.
- Reverse dependencies (which files rely on a given file or module).
- Evidence and confidence for each detected relationship.
- A cautious summary of whether a file appears locally independent or has detected dependencies.

This is a separate phase. It should not delay or complicate the comment-navigation engine. Detection of imports and dependencies must not be represented as complete runtime dependency analysis; dynamic loading and environment-dependent behavior can be difficult or impossible to establish statically.

---

## 5. Core workflow

```text
Source file
    |
    v
Language identification
    |
    v
Language-specific comment scanner
    |  - recognize real comments
    |  - avoid strings and other non-comment text
    |  - preserve line/column/byte positions
    v
Comment normalization
    |  - group adjacent comment lines
    |  - preserve indentation
    |  - retain raw source text
    v
Indentation hierarchy
    |  - determine parent/child comment nodes
    |  - preserve source order
    v
Source-range mapping
    |  - associate code following each node
    |  - partition nested child ranges
    v
Compact comment index
    |
    +--> outline
    +--> expand one level
    +--> read associated code
    +--> JSON / agent interface
```

No full language parser is required for this workflow. A language-aware lexer or a carefully tested state-machine scanner is sufficient for the core purpose. A third-party lexical library may be used where it improves correctness, but the dependency must be justified by language coverage, portability, maintenance, and performance.

---

## 6. Comment extraction and normalization

### 6.1 Language-specific comment recognition

A generic regular-expression scan is not sufficient for reliable cross-language extraction. Comment markers can occur inside string literals, raw strings, template strings, here-strings, regular expressions, or other language-specific constructs.

Each supported language adapter must define and test:

- Line-comment delimiters.
- Block-comment delimiters and whether nesting is permitted.
- String and raw-string forms that can contain comment-like characters.
- Multiline string and interpolation behavior relevant to comment recognition.
- Documentation-comment forms, if they should be extracted.
- Trailing comments that share a line with code.
- Line-ending and encoding behavior.

The scanner's responsibility is lexical recognition, not general program understanding.

### 6.2 Comment records

Each extracted comment record should preserve at least:

- Original file path.
- Comment kind (line, block, documentation, trailing, or other supported form).
- Raw comment text exactly as it appears in the source.
- Optional normalized text for display and search.
- Start and end byte offsets.
- Start and end line/column positions.
- Raw leading whitespace and normalized indentation column.
- Language adapter and extraction status.

Raw text must remain available. Normalized display text must never replace the original source content.

### 6.3 Adjacent comment grouping

Codegos needs a predictable rule for deciding when consecutive comment lines form one comment block and when they should become separate nodes.

Provisional v1 rule:

- Consecutive comment lines with the same normalized indentation and no intervening code are grouped into one comment block.
- A blank line, a change in indentation, or intervening code ends the current group unless a language-specific fixture demonstrates a safe exception.
- A multiline block comment is initially one comment block.
- Trailing comments are extracted and preserved but are not automatically treated as ordinary hierarchical headings.

This rule must be tested against real-world examples before it is frozen. In particular, list-like comment lines and multiple adjacent explanatory comments may need a distinction between a *comment block* and a *hierarchy node*.

---

## 7. Indentation-based hierarchy

### 7.1 Basic rule

Comment indentation determines hierarchy. A comment at a greater indentation than the current parent may become its child. A comment at the same or lesser indentation closes the current deeper branch and becomes a sibling or ancestor-level node.

The hierarchy is built from comment records in source order. It is not built from the indentation of executable code, function definitions, or AST nodes.

Illustrative source:

```powershell
# Initialize command management

    # Create command record

        # Prepare record fields
        # Validate required fields

    # Save command record

# Report completion
```

Illustrative outline:

```text
Initialize command management      [L:1]
├── Create command record           [L:3]
│   ├── Prepare record fields       [L:5]
│   └── Validate required fields    [L:6]
└── Save command record             [L:8]

Report completion                  [L:10]
```

### 7.2 Indentation measurement

The parser must preserve raw whitespace and calculate a normalized indentation column. Tabs must be handled consistently through a documented tab-width setting. The default tab width should be configurable; the raw indentation must remain available so a different setting can rebuild the hierarchy.

The parser must not silently rewrite indentation. Mixed tabs and spaces should produce a diagnostic when they make hierarchy ambiguous.

### 7.3 No invented levels

If all comments in a file have the same indentation, the result is a flat outline. Codegos must not manufacture subgroups merely to make the output look structured.

If an indentation jump occurs, the parser may attach the node to the nearest preceding shallower node while preserving the actual indentation difference. It should report suspicious or ambiguous jumps in diagnostics rather than inventing missing intermediate nodes.

### 7.4 Explicit boundaries and BECS

Indentation is the default hierarchy mechanism. Optional BECS region markers may later provide explicit boundaries or labels where indentation alone is insufficient. Such markers are an extension and must not be required for ordinary files.

---

## 8. Source mapping and code retrieval

### 8.1 Line references

Every comment node receives an automatically generated source reference. The compact tree displays the comment's starting line as `L:<line>`, for example:

```text
Save command definition [L:35]
```

For multiline comments or detailed output, Codegos may display a range such as `L:35-38`. The reference is generated by the parser; developers do not type it into their comments.

Line numbers are navigation coordinates, not permanent identifiers. They can change after edits. Any cached index must be validated against the current file content before a line reference is used to retrieve code.

### 8.2 Provisional source ownership rule

A comment node owns the source code following its comment block up to the next comment node at the same or a shallower indentation level, or the end of the enclosing file.

A deeper comment node creates a nested region within that range. The parent range therefore contains the overall section, while child nodes identify smaller parts of it.

This is a source-mapping convention, not a claim that the parser understands the code's semantic scope. The rule must be validated against real files containing inline comments, explanatory comments, commented-out code, blank lines, and nested indentation.

### 8.3 Retrieval behavior

The agent should be able to request code directly from a comment's line reference. The tool resolves the reference to the indexed comment node and returns its associated source range or an adaptive preview.

Proposed operations:

```text
codegos outline <file>
codegos expand <file> --at L:35
codegos read <file> --at L:35
```

The exact command names and argument syntax are provisional. The behavior is more important than the spelling.

### 8.4 Adaptive retrieval defaults

Line count is a useful first approximation, but output/token budget must take precedence.

| Associated code size | Default behavior |
|---|---|
| 1–4 lines | Return the complete code block. |
| 5–29 lines | Return the complete block if it fits the configured output budget. |
| 30+ lines with nested comment nodes | Return the immediate child outline first; let the agent choose where to expand. |
| 30+ lines without nested comments | Return a compact range/size preview and allow bounded chunk retrieval. |
| Any size exceeding output budget | Return a preview and require a narrower read or explicit full-read override. |

These thresholds are defaults for experimentation, not permanent limits. The tool should support configuration and an explicit full-read option. It should not require a model-specific tokenizer in the first version; a byte/character budget can provide a predictable initial cap. Token estimates or tokenizer adapters can be evaluated later.

### 8.5 Progressive navigation

The intended agent workflow is:

1. `outline`: show the root-level comment nodes only, with line references and child counts.
2. `expand`: show one selected node's immediate children, not the entire descendant tree.
3. `read`: retrieve the selected node's associated code, applying adaptive behavior.
4. Repeat `expand` or `read` until the agent reaches a sufficiently small block.

The output should always include enough parent context to identify where the selected node sits in the file.

---

## 9. Agent-facing interface

The first interface should be a small CLI with compact JSON output. MCP or editor integration should come later, after the command behavior and output schema have been validated.

### Minimum operations

| Operation | Purpose | Default response |
|---|---|---|
| `outline` | Show the first level of a file's comment hierarchy | Compact node labels, `L:` references, and child counts |
| `expand` | Reveal one node's immediate children | One level only, with source references |
| `read` | Retrieve code associated with a selected comment node | Adaptive source preview or exact source block |
| `scan` | Refresh or build an index | Counts, diagnostics, and index status |

A search operation may be added if experiments show that agents need it. It should not duplicate ordinary text-search tools without a clear advantage.

### Output requirements

- Human-readable tree output for terminal users.
- Stable, documented JSON schema for agent/tool consumers.
- File path and line references on all returned nodes.
- Explicit node depth and child count.
- Clear indication when output was truncated or adapted.
- No unrelated comments or code by default.
- Diagnostics separated from normal navigation results.

### Example JSON shape (illustrative)

```json
{
  "schema_version": "1",
  "file": "src/commands.ps1",
  "nodes": [
    {
      "label": "Save command definition",
      "line": 35,
      "depth": 0,
      "children_count": 4,
      "source_range": {
        "start_line": 36,
        "end_line": 82
      }
    }
  ]
}
```

This example is illustrative. The final schema should avoid redundant fields and be tested for compactness as well as clarity.

---

## 10. Cross-language and cross-platform strategy

### 10.1 Language support

Codegos should publish tested support rather than claim universal compatibility.

A practical first sequence is:

1. PowerShell — validate the existing prototype and its real use cases.
2. Go — validate the implementation's portability and a different comment syntax.
3. Python — add triple-quoted strings and common documentation-comment cases.
4. JavaScript/TypeScript — add template strings and another widely used comment system.

This sequence is a development proposal, not a permanent priority list.

For each language, publish a support status:

- **Tested:** extraction behavior is covered by fixtures for the documented syntax.
- **Partial:** known syntax forms or edge cases are not yet supported.
- **Unsupported:** Codegos does not claim reliable extraction for that language.

### 10.2 Platform support

The core should build and behave consistently on Windows, Linux, and macOS.

Tests must cover:

- LF and CRLF line endings.
- UTF-8 and BOM handling where relevant.
- Unicode comment text and file paths.
- Windows and POSIX path separators.
- Tabs and spaces in indentation.
- Large files and files with no comments.
- Files with malformed or incomplete source.

Core parsing must not depend on shell-specific commands or platform-specific path assumptions.

### 10.3 Performance strategy

Performance work should follow correctness tests, not precede them.

Potential optimizations include:

- Single-pass scanning where possible.
- Avoiding unnecessary copies of source text.
- Compact comment-node storage.
- File content hashes and incremental cache updates.
- Reusing unchanged file indexes.
- Emitting only the requested hierarchy depth.

The parser should not build large intermediate structures that the caller never requests.

---

## 11. Validation and experiments: prove that Codegos helps

This is a core part of the project, not a marketing exercise. Codegos should not claim that it saves tokens or improves coding-agent performance until controlled tests support those claims.

### 11.1 Main research question

> Does progressive comment navigation and targeted source retrieval help a coding agent complete real repository tasks with fewer context tokens and tool calls, without reducing task success or code quality?

### 11.2 Experimental conditions

Use the same model, agent configuration, task prompt, repository snapshot, and comparable tool budgets for each condition.

| Condition | Agent capabilities | What it measures |
|---|---|---|
| A — Baseline | Existing file search, text search, and file-reading tools; no Codegos | Current workflow performance |
| B — Codegos | Same tools plus Codegos outline, expand, and read | Added value of comment navigation and progressive retrieval |
| C — Codegos + BECS | Same as B, using files with optional BECS annotations where available | Additional value of explicit BECS organization |

Condition C is a later experiment; it is not a dependency for the v1 parser. For ordinary repositories without BECS annotations, the most important comparison is A versus B.

### 11.3 Task selection

Use tasks that require locating and understanding code, not only tasks where the answer is already stated in a comment.

Suggested task categories:

1. **Locate and explain:** Find the code responsible for a specified behavior and explain its operation.
2. **Targeted modification:** Change a specific behavior in a large file while preserving unrelated behavior.
3. **Bug investigation:** Locate a likely source of a reported problem and identify the relevant implementation.
4. **Follow-the-comments navigation:** Start from a high-level section and drill into the implementation using the comment hierarchy.

Use projects with different characteristics:

- Small, well-organized files (where Codegos may provide little benefit).
- Large files with useful comments and indentation.
- Large files with sparse or inconsistent comments.
- AI-generated or legacy code with mixed comment styles.
- Multiple supported programming languages.

Avoid selecting only files that are already well annotated. That would bias the experiment in favor of Codegos.

### 11.4 Metrics

Measure task quality and efficiency together.

**Primary outcome**

- Task success rate, assessed against predefined tests or review criteria.
- Correctness of the resulting patch or explanation.
- Unintended changes or regressions.

**Efficiency outcomes**

- Total input and output tokens, where the agent platform exposes them.
- Number of tool calls.
- Number of file reads and searches.
- Amount of source text retrieved.
- Wall-clock completion time.
- Codegos indexing time and incremental refresh time.

**Navigation quality**

- Whether the relevant source block was found.
- Whether retrieved ranges contained the needed implementation.
- Irrelevant lines returned per task.
- Number of unnecessary expand/read operations.

A useful composite measure is **tokens per successful task**, but it must be reported alongside success rate. Token savings are not an improvement if the agent makes more mistakes or fails more often.

### 11.5 Experimental controls

- Use clean, identical repository snapshots.
- Run multiple trials per condition; agent behavior is variable.
- Randomize or rotate condition order to reduce order effects.
- Keep model version, reasoning settings, prompts, and tool budgets constant.
- Record indexing time separately from task time; report both cold-start and cached runs.
- Do not give the agent different hints in different conditions.
- Grade code changes using tests and human review where needed.
- Publish failures and cases where Codegos provides no benefit.

### 11.6 Initial success criteria

Set quantitative targets only after a small pilot establishes a baseline. The first pilot should answer:

- Does Codegos extract comments correctly on the selected language fixtures?
- Does the hierarchy match the indentation model expected by the test cases?
- Does a line reference reliably retrieve the correct source range?
- Does progressive navigation reduce unnecessary source retrieval?
- Does it reduce tokens or tool calls without lowering task success?
- Is indexing overhead small enough that the approach remains useful for ordinary files and repeated agent operations?

Do not claim a general productivity improvement based on a handful of demonstrations. Keep the benchmark corpus and task prompts reproducible.

---

## 12. Testing strategy

### 12.1 Extraction correctness fixtures

Each supported language should have positive and negative fixtures covering:

- Line comments and block comments.
- Multiline comments and documentation comments.
- Comment markers inside single-quoted, double-quoted, raw, multiline, and interpolated strings.
- Escaped delimiters and language-specific string edge cases.
- Trailing comments after code.
- Adjacent comments and blank lines.
- Commented-out code.
- Unicode text, BOM, LF, and CRLF.
- Malformed or incomplete files.
- Very long lines and large files.

### 12.2 Hierarchy fixtures

Include fixtures for:

- Flat comments at one indentation level.
- One-level and deeply nested indentation.
- Tabs, spaces, and mixed indentation.
- Indentation jumps.
- Comments with no parent.
- Consecutive comment grouping.
- Multiline block comments.
- Comments embedded inside code blocks.
- Trailing comments.

Every fixture should have an expected normalized tree and source ranges.

### 12.3 Source retrieval fixtures

Verify that:

- `L:<line>` resolves to the intended comment node.
- A node's source range ends at the correct same-level or shallower boundary.
- Nested child comments partition larger ranges as specified.
- Small blocks return complete code.
- Large blocks return child outlines or bounded chunks as appropriate.
- Stale line references are detected after file edits.
- Retrieved code exactly matches the original source bytes/lines, subject to the documented output encoding.

### 12.4 Performance benchmarks

Benchmark representative file sizes and comment densities. Record:

- Cold scan throughput.
- Warm/cached lookup latency.
- Outline and expand latency.
- Source-read latency.
- Memory use.
- Incremental re-index cost after a small edit.

Publish hardware, operating system, compiler/runtime version, dataset, and benchmark method. Avoid isolated speed claims without reproducible conditions.

---

## 13. Development roadmap

### Phase 0 — Recover and characterize the existing prototype

- Review the current parser script and representative input files.
- Document what it already extracts correctly.
- Preserve useful behavior through fixtures before redesigning it.
- Identify current hierarchy, grouping, and source-range assumptions.

**Deliverable:** Prototype behavior inventory and initial regression fixture set.

### Phase 1 — Define the minimum comment model

- Define comment records and source coordinates.
- Define adjacent comment grouping.
- Define indentation measurement and parent-child rules.
- Define `L:<line>` references.
- Define initial source ownership boundaries.

**Deliverable:** A small written core specification and expected-output fixtures.

### Phase 2 — Reliable extraction engine

- Implement or refine the language-specific scanner.
- Prevent false comments inside strings and other non-comment constructs.
- Preserve exact source positions and indentation.
- Add diagnostics for unsupported or ambiguous cases.

**Deliverable:** Correct comment extraction for the first supported language, with tests.

### Phase 3 — Hierarchy and source mapping

- Build the indentation-based comment tree.
- Implement source-range association.
- Implement line-reference resolution and stale-index checks.
- Implement outline and one-level expansion.

**Deliverable:** A usable local comment navigator.

### Phase 4 — Adaptive retrieval and agent-friendly output

- Implement small/medium/large block behavior.
- Add output-size limits and explicit full-read/chunk options.
- Finalize compact JSON output.
- Add CLI commands for outline, expand, read, and scan.

**Deliverable:** A complete first usable Codegos workflow for one language.

### Phase 5 — Cross-language and cross-platform expansion

- Add the next language adapters using the same adapter contract.
- Run the fixture suite on Windows, Linux, and macOS.
- Add cache and incremental re-indexing only after measuring the baseline.

**Deliverable:** A tested multi-language, cross-platform release candidate.

### Phase 6 — Agent efficiency evaluation

- Build the A/B benchmark against normal search and file reading.
- Add representative repositories and repeatable coding tasks.
- Measure tokens, tool calls, time, retrieval quality, and task success.
- Revise defaults based on observed results.

**Deliverable:** A benchmark report with limitations and reproducible test assets.

### Later phase — Workspace navigation

Only after the comment navigator is reliable and useful:

- Prototype explicit import and file-reference extraction.
- Build a separate workspace dependency index.
- Add evidence-backed local and external dependency relationships.
- Evaluate whether this reduces repository exploration cost for agents.

This later module should remain separate from the local comment-navigation core.

---

## 14. Proposed repository layout

The repository can begin smaller than this and grow as the implementation stabilizes.

```text
Codegos/
├── README.md
├── LICENSE
├── SPECIFICATION.md
├── DEVELOPMENT.md
├── BENCHMARKS.md
│
├── cmd/
│   └── codegos/
│
├── internal/
│   ├── scanner/
│   ├── languages/
│   ├── comments/
│   ├── hierarchy/
│   ├── sourcemap/
│   ├── retrieval/
│   └── output/
│
├── fixtures/
│   ├── powershell/
│   ├── go/
│   ├── python/
│   └── javascript/
│
├── tests/
│   ├── extraction/
│   ├── hierarchy/
│   ├── retrieval/
│   └── integration/
│
├── benchmarks/
│   ├── datasets.md
│   ├── tasks/
│   └── results/
│
└── docs/
    ├── language-support.md
    └── design-decisions/
```

Do not create empty modules merely to match this layout. Keep the implementation structure proportional to the working code.

---

## 15. Risks and design questions to resolve through testing

1. **Indentation is not always intentional hierarchy.** Some developers indent comments only to match executable code. Codegos should reflect the indentation it finds and provide diagnostics/configuration rather than claim to know the author's intent.
2. **Adjacent comment grouping is ambiguous.** The line grouping rule must be tested against real projects and should preserve raw comments.
3. **Source ownership is a convention.** The next same-level or shallower comment is a useful boundary, but comments may not describe all code between boundaries. Keep source ranges visible and allow explicit range reads.
4. **Some languages have difficult lexical edge cases.** Support should be earned through fixtures, not inferred from a simple delimiter list.
5. **Line references become stale.** Re-scan or validate file content before reading through cached references.
6. **More hierarchy is not always better.** A compact flat outline can be the correct result when comments have no meaningful indentation.
7. **Token savings are not guaranteed.** The index itself and extra navigation calls have costs. Experiments must measure the complete task, not only the final source excerpt.
8. **Workspace dependency mapping can expand indefinitely.** Keep it out of v1 and require evidence and confidence labels when it is eventually developed.

---

## 16. Project success definition

Codegos v1 is successful when it can reliably:

- Extract real comments from its declared supported languages.
- Preserve source text, indentation, and exact line references.
- Build a predictable hierarchy from comment indentation.
- Map comment nodes to useful source ranges without analyzing program semantics.
- Let a user or agent reveal the outline progressively and retrieve a selected block.
- Run consistently across supported operating systems.
- Demonstrate, through reproducible A/B testing, whether it reduces unnecessary source retrieval and context use without harming task success.

### Guiding principle

> Extract. Organize. Navigate. Retrieve.

Codegos should make existing source code easier to explore, without demanding that developers change how they write it. BECS can enrich that experience, but the usefulness of Codegos must stand on its own.
