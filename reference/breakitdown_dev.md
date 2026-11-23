# breakitdown_dev.ps1 — Developer Documentation

Status: IN DEVELOPMENT (do not treat as stable)
Script: `C:\Users\ncode\scripts\Black-Ether Code Visualizer\breakitdown_dev.ps1` (882 lines, ~50 KB)
Stable sibling: `breakitdown.ps1` (same folder). Older lineage: `becv*.ps1`, `scv.ps1`, `isitc.ps1`, `archive\`.
Doc verified against live runs on 2026-11-21, PowerShell 7.6.10, Windows 11.

---

## 1. What it does

Breakitdown is a console code-outliner / static-analysis CLI for script files. Given a
source file it:

1. Detects the language from the file extension and loads a regex "language profile".
2. Strips blank lines, full-line comments, and multi-line comment blocks; extracts either
   top-level code lines (column-0 lines) or all code lines (`-Full`).
3. Tags every extracted line with a 4-level tag taxonomy (structure / identity /
   structure-detail / semantic detail) using ordered regex rules.
4. Assigns each line an execution *phase* (Setup / Execution / Neutral /
   PhaseUndetermined), using rule hints plus AST block context (e.g. everything inside a
   `param()` block or function definition inherits "Setup").
5. Renders a colorized, line-numbered outline with phase-change prefixes, `#region`
   headers, and L4 tag annotations, followed by a statistics report (line/char counts,
   comment breakdown, comment %, rough token estimates, phase spans with line ranges
   and percentages).

It is a read-only analyzer of the TARGET file. The only writes it makes are its own
cache files under `.breakitdown_cache\` next to the script (see §7).

### Modes (parameter sets)

| Mode | Invocation | What you get | Dev status |
|---|---|---|---|
| Analyze (default) | `.\breakitdown_dev.ps1 <file>` | Colored outline + report table | Works, with bugs (§8) |
| Analyze full | `.\breakitdown_dev.ps1 <file> -Full` | Same, but all code lines, not just top-level | Works |
| ShowTags | `.\breakitdown_dev.ps1 <file> -ShowTags` | Numbered list of all tag names for the file's language | Works |
| FilterByTag | `.\breakitdown_dev.ps1 <file> -Tag <name-or-index>[,...]` | Matching lines, ANSI-highlighted, with line numbers and match counts | Works |
| RawOutline | `.\breakitdown_dev.ps1 <file> -Raw [Full]` | Plain `[L:n] content` lines, no tags/colors (`Full` = all code lines) | Works |
| ExportJson | `.\breakitdown_dev.ps1 <file> -ExportJson [-OutputPath out.json] [-Full]` | JSON: metadata, statistics, sections, phaseSpans, per-line tags | BROKEN in dev (§8.1); emits JSON but sections/phaseSpans/phase are null |

`-Tag` accepts tag names (case-insensitive) or the 1-based indexes shown by `-ShowTags`,
comma-separated, e.g. `-Tag ConsoleOutput,7`. Unknown tags are warned and skipped.
All modes support `-Verbose` (heavy debug tracing inside the module).

Examples:

```powershell
cd 'C:\Users\ncode\scripts\Black-Ether Code Visualizer'
.\breakitdown_dev.ps1 .\test_comments.ps1                 # outline + report
.\breakitdown_dev.ps1 .\cleanmycode.ps1 -Full             # every code line
.\breakitdown_dev.ps1 .\test_comments.ps1 -ShowTags       # 22 tags for PowerShell
.\breakitdown_dev.ps1 .\test_comments.ps1 -Tag 6,16       # ConsoleOutput + Logging
.\breakitdown_dev.ps1 .\test_comments.ps1 -Raw Full       # plain full code dump
.\breakitdown_dev.ps1 .\cleanmycode.ps1 -ExportJson -OutputPath out.json
```

---

## 2. Dependencies

Everything is local. No PSGallery modules, no network access, no installers.

| Dependency | Path / type | Required? | Notes |
|---|---|---|---|
| `ScriptAnalysisUtils.psm1` | `Modules\ScriptAnalysisUtils.psm1` (~80 KB, 1452 lines) | YES — hard | Imported at script line 34 via `$PSScriptRoot\Modules\...`. Exports all functions (`Export-ModuleMember -Function *`). Script will not run without it. |
| `LanguageProfiles.psd1` | `Modules\LanguageProfiles.psd1` | NO — currently unused | Legacy data-file profile design (PowerShell/Python/Rust/C++ categories). The current module builds profiles programmatically instead; this file is NOT loaded anywhere. Kept for reference/future use. |
| `CommentVisUtils.psm1` | `Modules\CommentVisUtils.psm1` | NO | Used by the older visualizer scripts, not by breakitdown_dev. |
| `ScriptAnalysisUtils_backup.psm1` | `Modules\` | NO | Backup of the module as of May 2025 (matches the stable breakitdown.ps1 era). |
| .NET BCL | built into PowerShell | YES | `SHA256Managed`, `HashSet[string]`, `Stack[object]`, `Convert`, `Regex`, and the PowerShell AST parser (`System.Management.Automation.Language.Parser`). |
| Built-in cmdlets | — | YES | `Select-String`, `Get-Content`, `ConvertTo-Json`, `Format-Table`, `Join-String` (module), etc. |

### Module functions consumed by the script

| Function | Role |
|---|---|
| `Get-ScriptLanguageProfile -ProfileFilePath` | Builds the language profile (comment markers + 4-level TaggingRules) from the file extension. Only `.ps1` and `.py` are implemented; everything else returns null. |
| `Get-CodeLines -FilePath -Mode TopLevel|Full` | Comment/blank filtering + line extraction. TopLevel = lines matching `^\S` (no leading whitespace). Supports optional StartLine/EndLine range (unused by this script). |
| `Add-MultiLevelTags -CodeLineObjects -LanguageProfile` | Applies L1–L4 regex rules per line; emits `L1StructTag, L2StructTag, L2IdTag, L3StructTag, L4DetailTag, RuleAssignedPhase`. |
| `Get-ScriptSectionData -FilePath` | PowerShell AST parse: maps ParamBlock/Function/Class/Enum/If/For/ForEach/While/DoWhile/Switch/Try/Catch/Finally nodes to `{Type,Name,StartLine,EndLine}` sections; also parses `#region`/`#endregion` comment tokens into Region sections. PowerShell-only. |
| `Get-EffectiveLinePhases -TaggedCodeLines -SectionData [-DefaultInitialRootPhase]` | Resolves each line's final phase using rule hints + a block-context stack (e.g. `BlockContext:Setup` from param/function headers applies until the AST section's EndLine). |
| `Get-PhaseSpans -LinesWithFinalPhase -TotalOriginalLines` | Collapses consecutive same-phase lines into spans `{PhaseName,StartLine,EndLine,SpanCount,Occurrence}`. NOTE: current signature — the dev script's ExportJson branch still calls an older signature (§8.1). |
| `Get-CommentInfo -FilePath` | Comment/code statistics: single/multi/inline comment lines, blank lines, regions, trimmed code/comment char counts, percentages. Has built-in comment profiles for ~20 extensions. |
| `Get-MultiLineCommentRanges` | Helper for range-filtered comment detection (internal to module). |

Script-local helper: `Get-StatValue` (lines 35–82) — null-safe, type-converting property
reader used to build the JSON statistics block.

---

## 3. Running environment requirements

- OS: Windows (tested Windows 11). Paths and cache layout are Windows-style; the logic
  itself is platform-neutral PowerShell.
- PowerShell: **7+ required** (verified on 7.6.10 at `C:\Program Files\PowerShell\7\pwsh`).
  Windows PowerShell 5.1 is NOT sufficient: the module uses `Join-String`, which does not
  exist in 5.1 (verified missing on this host's 5.1.26100). No other version-sensitive
  syntax is used, but 7.x is the supported target.
- Terminal: ANSI/VT-capable console for the colored output (Windows Terminal, or conhost
  with VT processing — pwsh 7 enables this by default). In a non-VT host the escape
  sequences print as garbage; `-Raw` mode is the plain-text fallback.
- Execution policy: must allow running local scripts (`RemoteSigned` or looser, or
  `Unblock-File` if the file is marked from-the-internet). No admin rights needed.
- Filesystem: read access to the target file; WRITE access to the script's own directory
  (it creates `.breakitdown_cache\` there on Analyze runs). If cache creation fails it
  warns and continues without caching.
- No network, no external tools, no Python/Node, no environment variables, no config
  files required.

---

## 4. Language support (actual, verified)

| Extension | Profile/tags | AST sections | Comment stats | Verdict |
|---|---|---|---|---|
| `.ps1` | Yes (PowerShell, 22 tags) | Yes | Yes | Fully supported |
| `.py` | Yes (Python profile) | No — explicitly "not yet implemented" warning | Yes | Outline/tags work; no block-context phases |
| `.psm1`, `.psd1` | NO — `Get-ScriptLanguageProfile` has no case for them (verified: "Unsupported file extension" error) | (would work) | Yes | BROKEN entry point despite being PowerShell; module switch only handles `.ps1`/`.py` |
| anything else | No | No | `Get-CommentInfo` knows ~20 extensions, but the script errors out at profile detection first | Unsupported |

The unused `LanguageProfiles.psd1` contains Rust/C++ category definitions — aspirational,
not wired in.

---

## 5. Tag taxonomy (PowerShell profile)

- L1 Structure: `SyntaxMarks` (pure braces/parens/semicolons; filtered from the outline)
  vs default `Code`.
- L2 Structure: `block` (line ends with `{`, `(`, `:`) vs default `step`.
- L2 Identity: `SysLogic` (keywords + Verb-Noun cmdlets) vs default `UserLogic`.
- L3 StructureDetail (ordered, first match wins): Attribute, ParamBlock,
  FunctionDefinition, ClassEnumDefinition, VariableAssignment, ControlFlow,
  CommandInvocation; fallback ExpressionOrUnknown.
- L4 Detailed: UserInput, DotSource, GlobalVarInit, ScriptVarInit, DataInput,
  ConsoleOutput, DataOutput, Config, DependencyInput, ExitPoint, ErrorHandlingKeyword,
  Logging.

Phases: rules carry `AssignedPhase` hints (Setup / Execution / Neutral, or
`BlockContext:Setup` for block headers). Neutral inherits the surrounding phase;
unmatched lines become PhaseUndetermined. `Get-EffectiveLinePhases` combines hints with
AST block boundaries; `Get-PhaseSpans` groups runs into spans. Token estimates are a
chars/4 heuristic, not a real tokenizer.

---

## 6. Data flow (Analyze mode)

```
FilePath
  -> Get-ScriptLanguageProfile        (extension -> profile)
  -> cache path = SHA256(full path)   (.breakitdown_cache\<hash>.section.json)
  -> Get-ScriptSectionData            (AST sections + #regions; .ps1 only)
  -> [save sections to cache JSON]    (write-only; never read back — see §8.4)
  -> Get-CodeLines -Mode TopLevel|Full
  -> Add-MultiLevelTags
  -> Get-EffectiveLinePhases          (needs non-null SectionData)
  -> Get-PhaseSpans
  -> display loop: region stack headers/indent, phase prefixes, ANSI colors,
     L4 annotations, inline comments stripped, SyntaxMarks lines skipped
  -> Get-CommentInfo -> report hashtable -> Format-Table
```

ExportJson follows the same pipeline but serializes
`{metadata, statistics, sections, phaseSpans, codeLines[]}` with `ConvertTo-Json -Depth 10`
to `-OutputPath` or stdout. (Currently degraded — §8.1.)

---

## 7. Cache behavior

- Location: `<script dir>\.breakitdown_cache\`
- Key: SHA256 of the target's RESOLVED FULL PATH (not content) -> `<hash>.section.json`.
- Content: section data from `Get-ScriptSectionData`, `ConvertTo-Json -Depth 5`, UTF-8.
- Written on every Analyze run that produces sections. NEVER read back: the dev script
  has no cache-load or staleness-check logic, so the cache is currently write-only dead
  weight (§8.4). Files accumulate indefinitely; safe to delete the whole folder.
- Two different files with the same path at different times share a key; editing a file
  does not invalidate anything (because nothing is ever loaded).

---

## 8. Known issues / dev-state notes (all verified by running unless marked "code review")

1. **ExportJson is broken against the current module.** Line 722 calls
   `Get-PhaseSpans -TaggedCodeLines ... -SectionData ...`, but the module (updated
   2025-11-28, after this script's 2025-05-14 date) now requires
   `-LinesWithFinalPhase -TotalOriginalLines`. Verified error: "A parameter cannot be
   found that matches parameter name 'TaggedCodeLines'". Result: JSON still emitted but
   `phaseSpans: null`, `sections: null`, every line `phase: null`. Fix: run
   `Get-EffectiveLinePhases` first (as Analyze does) and call the new signature.
2. **Inverted phase condition in ExportJson**, line 837:
   `$linePhase = if ($null -eq $currentSpan_Json) { $currentSpan_Json.PhaseName } else { 'Execution' }`
   — reads a property off null when the span IS null, and hardcodes 'Execution' when a
   span exists. Condition is backwards.
3. **Analyze outline dies on files with no AST sections.** `Get-ScriptSectionData`
   returns nothing for a file with no param/function/control-flow/region constructs;
   `$sectionData` stays null; `Get-EffectiveLinePhases -SectionData $null` fails mandatory
   binding ("Cannot bind argument ... because it is null"), so the outline is empty and
   phase spans are skipped. The statistics report still prints. Verified on
   `test_comments.ps1`. Fix: coerce to `@()` and/or make the module parameter accept
   empty/null.
4. **Cache is write-only** (§7): no load path, no invalidation, path-keyed not
   content-keyed. Either implement read-back + content-hash invalidation or remove it.
5. **`$esc` used before defined in Analyze.** Line 398 builds the outline title color
   from `$esc`, which is only assigned at line 404. Verified: literal `[93m` prints
   before the outline title instead of a color change. (Code review + live output.)
6. **Null-check no-op in ExportJson**, lines 716–717:
   `if ($null -eq $codeLineObjects) { #... error handling ... }` — the closing brace is
   inside the comment; the stray `}` on line 717 closes the if, leaving an empty body.
   Parses fine (verified with the AST parser) but the guard does nothing.
7. **`.psm1`/`.psd1` rejected at profile detection** (§4) even though the rest of the
   pipeline treats them as PowerShell. Add alias cases to `Get-ScriptLanguageProfile`.
8. **Dead parameter-set reference**: line 286 checks `'FullAnalysis'`, which is not a
   declared parameter set (harmless; `-Full` within Analyze is the real mechanism).
9. **Inline-comment stripping is string-unaware** (line 520): splits on the comment
   marker anywhere in the line, so a `#` inside a quoted string truncates the displayed
   code. Display-only issue. (Code review.)
10. **Duplicate/dead display variables**: `$coloredLineContent` vs `$lineTextPart` and
    `$coloredAnnotation` vs `$annotationString` are built twice (lines 539–550); only
    the first pair is printed. Leftover from color-debugging. (Code review.)
11. **FilterByTag level list is hardcoded** (line 157) to the five current level keys;
    new levels in a profile would be silently ignored there (ShowTags iterates all keys,
    so the two modes can disagree). Duplicate tag names across levels: first level wins.
    (Code review.)
12. Report's `LanguageProfile` field shows the extension (`.ps1`), not the language
    name, because `Get-CommentInfo` reports it that way. Cosmetic. (Verified in output.)

Module/script sync warning: `Modules\ScriptAnalysisUtils.psm1` was modified 2025-11-28,
months after this dev script and its backup. The stable `breakitdown.ps1` (2025-05-13)
predates the module change too — check it against the new `Get-PhaseSpans` signature
before trusting either. `ScriptAnalysisUtils_backup.psm1` is the May-era module.

---

## 9. Verification commands (run 2026-11-21, all from the script folder)

```powershell
pwsh -NoLogo -Command '& ".\breakitdown_dev.ps1" .\test_comments.ps1'            # report OK, outline empty (issue 3)
pwsh -NoLogo -Command '& ".\breakitdown_dev.ps1" .\cleanmycode.ps1'              # outline + phases + spans OK
pwsh -NoLogo -Command '& ".\breakitdown_dev.ps1" .\test_comments.ps1 -ShowTags'  # 22 tags listed
pwsh -NoLogo -Command '& ".\breakitdown_dev.ps1" .\test_comments.ps1 -Tag ConsoleOutput,7'  # 3 matches
pwsh -NoLogo -Command '& ".\breakitdown_dev.ps1" .\test_comments.ps1 -Raw'       # 4 top-level lines
pwsh -NoLogo -Command '& ".\breakitdown_dev.ps1" .\test_comments.ps1 -ExportJson' # JSON with null spans (issue 1)
```

Parse check (both files parse clean — the bugs above are runtime/logic, not syntax):

```powershell
$t=$null;$e=$null
[System.Management.Automation.Language.Parser]::ParseFile("$PWD\breakitdown_dev.ps1",[ref]$t,[ref]$e)
$e   # empty = no syntax errors
```

---

## 10. File map

```
Black-Ether Code Visualizer\
  breakitdown_dev.ps1                  <- this script (dev)
  breakitdown.ps1                      <- stable sibling (May 2025)
  becv.ps1 / becvN.ps1 / becvN2.ps1 / becvold.ps1 / scv.ps1 / isitc.ps1  <- earlier lineage
  cleanmycode.ps1                      <- comment-stripper utility (good test target)
  test_comments.ps1                    <- 14-line comment edge-case fixture
  Modules\
    ScriptAnalysisUtils.psm1           <- REQUIRED engine (current, Nov 2025)
    ScriptAnalysisUtils_backup.psm1    <- May 2025 backup
    LanguageProfiles.psd1              <- legacy/unused profile data file
    CommentVisUtils.psm1               <- used by older visualizers only
  .breakitdown_cache\                  <- write-only section cache (deletable)
  archive\                             <- old versions
  .git\                                <- repo
```
