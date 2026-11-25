# PowerPath comment hierarchy experiment

The detached PowerPath candidate at 210d6a1 was evaluated against Codegos bc789ba. The historical Hermes source and executable pairing remains unauthenticated. These results describe local navigation only.

| From the root outline | Reference | Experimental |
|---|---|---|
| Discover Set | go 191, go 494 | go 191 |
| Expand Set | go 2453 after discovery | go 2453 after discovery |
| Read the Help dispatch | go 191, go 494, go 2560 | tail, show 2561-2566 |
| Main Command Processing expansion | 590 bytes | 2,571 bytes |
| Add closing marker expansion | 60 children, 8,748 bytes | closing marker has no navigation anchor |
| Set expansion | 1,858 bytes | 1,858 bytes |

The experimental outline has five roots. Main Command Processing remains at 191. Its 17 immediate children include Set at 2453. Set ends at its closing directive on 2560. Closing markers previously accepted by go now require show for direct retrieval. The opt-in tail command reports one generated interval, including blank lines and braces. Its 2561–2566 interval exposes the dispatch without assigning a name. It only covers a nonblank suffix following a closing marker or a file with no standalone comments. Interior undocumented intervals remain a limitation. Keep tail experimental. The measured expansion gives no reason to paginate this fixture.

Standalone PowerShell hash directives pair in lexical order, case insensitively. Whitespace between the hash and keyword leaves a normal comment. Labels do not participate in matching. A paired opener establishes a minimum hierarchy depth until its close, independent of closing indentation. Interior headings retain their indentation relationships. Unclosed openers use indentation and surplus closes are suppressed. Missing inner closes can pair with an intended outer close. A scanner without knowledge of developer intent cannot resolve those ambiguities. Grouping continues across adjacent ordinary comment lines, including block comments. Go and Python retain their existing comment syntax.

## Controls and cost

All recorded anchors, parents, child counts, text and block ends matched for Task call.go and task.go and the generated Go and Python controls. The generated PowerShell fixture mixes undocumented code with nested, sibling and malformed regions. These small authored examples provide limited evidence about AI-generated projects. Plain go still expands one level, previews short children with original line numbers, and show retrieves inclusive bounds.

Three 300 ms Go benchmark samples timed extraction plus hierarchy construction in memory. PowerPath median rose from 718 to 830 microseconds (about 16%). Task task.go moved from 224 to 223 microseconds. These local samples exclude disk and CLI startup. Profile directive classification before promoting the change. Root-package tests passed. Recursive go test also attempts to build the pre-existing netmon example, whose third-party dependencies are absent from the module.

## Reproduction

Run from this worktree root. Build the clean reference in a separate checkout at bc789ba using go build -o with the absolute destination experiment/bin/baseline.exe in this worktree. Build the branch with go build -o experiment/bin/experimental.exe . and run go test . . The executables and build cache are local artifacts.

Run ./experiment/capture.ps1 baseline and ./experiment/capture.ps1 experimental in PowerShell. Run python experiment/measure.py to traverse both outlines through the JSON CLI, verify control equality and check navigation. It expects the sibling research checkouts at ../../retrieval-research/checkouts relative to this nested worktree. The raw directory contains complete hierarchy tables and human-readable command outputs. Byte counts above use native stdout before PowerShell text conversion.

For timing, copy hierarchy_test.go into the clean reference checkout, set CODEGOS_FIXTURE to the absolute source path, and run go test . -run '^$' -bench BenchmarkSource -benchtime 300ms -count 3 in each checkout. The reference benchmark compiles against the original parser. Raw timing files list PowerPath first and Task second.
