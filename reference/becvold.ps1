[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0)]
    [ValidateScript({
        if (Test-Path -Path $_ -PathType Leaf) {
            return $true
        } else {
            throw "File not found or is not a file: $_"
        }
    })]
    [string]$FilePath,

    [Parameter(Position=1)]
    [ValidateSet(1)]
    [int]$Mode = 1,

    [Parameter()]
    [Alias('LN')]
    [switch]$ShowLineNumbers,

    [Parameter()]
    [switch]$ShowMultiLineBlocks,

    # ReduceIndentThreshold/ReducedBaseIndent are no longer used for normalization
    # but kept in case they are used elsewhere or for future modes.
    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$ReduceIndentThreshold = 8,

    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$ReducedBaseIndent = 4,

    [Parameter()]
    [ValidateRange(1, 16)]
    [int]$SpacesPerLevel = 4 # Crucial for hierarchical reconstruction
)

process {
    Write-Verbose "Starting comment extraction for file: $FilePath"
    Write-Verbose "SpacesPerLevel for indent check/reconstruction: $SpacesPerLevel"

    try {
        $absolutePath = Convert-Path $FilePath -ErrorAction Stop
        Write-Verbose "Absolute path resolved to: $absolutePath"
    } catch {
        Write-Error "Failed to resolve path for '$FilePath': $_"
        return
    }
    # Use List for easier modification during initial adjustment
    $singleLineCommentsData = [System.Collections.Generic.List[PSCustomObject]]::new()
    $multiLineCommentsData = @()
    $lineNumber = 0
    $inMultiLineCommentBlock = $false
    $currentMultiLineComment = [System.Text.StringBuilder]::new()
    $multiLineStartLine = 0

    try {
        $fileContent = Get-Content -Path $absolutePath -ReadCount 0 -ErrorAction Stop

        foreach ($line in $fileContent) {
            $lineNumber++
            $trimmedLine = $line.Trim()

            # --- Multi-line block parsing ---
            if ($inMultiLineCommentBlock) {
                if ($trimmedLine.EndsWith('#>')) {
                    $contentBeforeEnd = $line -replace '#>$',''
                    [void]$currentMultiLineComment.Append($contentBeforeEnd)
                    $multiLineCommentsData += [PSCustomObject]@{
                        StartLine = $multiLineStartLine
                        EndLine   = $lineNumber
                        Text      = $currentMultiLineComment.ToString()
                    }
                    $inMultiLineCommentBlock = $false
                    [void]$currentMultiLineComment.Clear()
                    Write-Verbose "Ended multi-line comment block at line $lineNumber"
                } else {
                    [void]$currentMultiLineComment.AppendLine($line)
                }
                continue
            }
            if ($trimmedLine.StartsWith('<#')) {
                if ($trimmedLine.EndsWith('#>')) {
                     $blockContent = $trimmedLine -replace '^<#' -replace '#>$'
                     if ($blockContent.Trim().Length -gt 0) {
                         $multiLineCommentsData += [PSCustomObject]@{
                             StartLine = $lineNumber
                             EndLine   = $lineNumber
                             Text      = $blockContent
                         }
                         Write-Verbose "Stored single-line block comment from line $lineNumber"
                     } else {
                          Write-Verbose "Skipping empty single-line block comment at line $lineNumber"
                     }
                } else {
                    $inMultiLineCommentBlock = $true
                    $multiLineStartLine = $lineNumber
                    $contentAfterStart = $line -replace '^<#\s*'
                    [void]$currentMultiLineComment.Append($contentAfterStart)
                     Write-Verbose "Started multi-line comment block at line $lineNumber"
                }
                continue
            }
            # --- End Multi-line block parsing ---

            # --- Single-line comment parsing ---
            if ($line -match '^(\s*)(?:#|\/\/)\s?(.*)$') {
                $indentation = $matches[1]
                $originalCommentText = $matches[2]
                $processedCommentText = $originalCommentText

                if ($originalCommentText -match '^\s*(region|endregion)\b\s?(.*)$') {
                    $keyword = $matches[1]
                    $remainingText = $matches[2]
                    if ($keyword -match 'endregion' -and $remainingText.Trim() -eq '') {
                        Write-Verbose "Skipping empty #endregion line $lineNumber"
                        continue
                    } else {
                        $processedCommentText = $remainingText.TrimStart()
                        Write-Verbose "Processed #$keyword line $lineNumber. Remaining text: '$processedCommentText'"
                    }
                }

                if ($processedCommentText.Trim().Length -gt 0) {
                        # Add Level property, initialize later
                        $commentObject = [PSCustomObject]@{
                        LineNumber      = $lineNumber
                        Indentation     = $indentation
                        Text            = $processedCommentText
                        OriginalIndentLength = $indentation.Length
                        Level           = 0 # Initialize Level
                    }
                    $singleLineCommentsData.Add($commentObject)
                    Write-Verbose "Stored single-line comment for line ${lineNumber} (Orig Indent: $($indentation.Length)): '$($indentation)$($processedCommentText)'"
                } else {
                        Write-Verbose "Skipping line $lineNumber as processed single-line comment text is empty."
                }
            } else {
                    Write-Verbose "Line $lineNumber is not a standalone comment line or part of a block comment."
            }
             # --- End Single-line comment parsing ---
        }

         if ($inMultiLineCommentBlock) {
             Write-Warning "Multi-line comment block started at line $multiLineStartLine was not properly closed with '#>'."
             $multiLineCommentsData += [PSCustomObject]@{
                 StartLine = $multiLineStartLine
                 EndLine   = $lineNumber
                 Text      = $currentMultiLineComment.ToString() + " [Warning: Block not closed]"
             }
         }

    } catch {
        Write-Error "Error reading or processing file '$absolutePath': $_"
        return
    }

    # --- Step 1: Preliminary Indentation Adjustment (Neighbor-based) ---
    Write-Verbose "Starting preliminary indentation adjustment check..."
    for ($i = 0; $i -lt $singleLineCommentsData.Count; $i++) {
        $currentComment = $singleLineCommentsData[$i]
        $currentIndentLength = $currentComment.Indentation.Length

        if ($currentIndentLength % $SpacesPerLevel -ne 0) {
            # (Logic from previous version to find previous/next valid comments)
            $previousValidComment = $null
            for ($prevIndex = $i - 1; $prevIndex -ge 0; $prevIndex--) {
                if ($singleLineCommentsData[$prevIndex].Indentation.Length % $SpacesPerLevel -eq 0) {
                    $previousValidComment = $singleLineCommentsData[$prevIndex]; break
                }
            }
            $nextValidComment = $null
            for ($nextIndex = $i + 1; $nextIndex -lt $singleLineCommentsData.Count; $nextIndex++) {
                if ($singleLineCommentsData[$nextIndex].Indentation.Length % $SpacesPerLevel -eq 0) {
                    $nextValidComment = $singleLineCommentsData[$nextIndex]; break
                }
            }

            # (Adjustment logic including the zero-indent exception)
            $adjusted = $false
            if ($previousValidComment -ne $null -and $nextValidComment -ne $null) {
                 $prevIndent = $previousValidComment.Indentation.Length
                 $nextIndent = $nextValidComment.Indentation.Length
                 $correctIndentLength = -1

                 if (($prevIndent -eq 0 -and $nextIndent -ne 0) -or ($nextIndent -eq 0 -and $prevIndent -ne 0)) {
                     $correctIndentLength = if ($prevIndent -eq 0) { $nextIndent } else { $prevIndent }
                 } elseif ($prevIndent -eq $nextIndent) {
                     $correctIndentLength = $prevIndent
                 }

                 if ($correctIndentLength -ge 0) {
                     $newIndent = ' ' * $correctIndentLength
                     $singleLineCommentsData[$i].Indentation = $newIndent
                     Write-Verbose "Line $($currentComment.LineNumber): Preliminarily adjusted indentation from $currentIndentLength to $correctIndentLength spaces."
                     $adjusted = $true
                 }
            }
            # Log if not adjusted
            if (-not $adjusted) { Write-Verbose "Line $($currentComment.LineNumber): No preliminary adjustment made for indent $currentIndentLength." }
        }
    }
    Write-Verbose "Finished preliminary indentation adjustment check."
    # --- End Step 1 ---

    # Sort by line number BEFORE assigning levels
    $sortedSingleLineComments = $singleLineCommentsData | Sort-Object LineNumber

    # --- Step 2: Assign Hierarchical Levels ---
    Write-Verbose "Assigning hierarchical levels..."
    $levelStack = [System.Collections.Generic.Stack[int]]::new()
    foreach ($comment in $sortedSingleLineComments) {
        $currentIndent = $comment.Indentation.Length # Use potentially adjusted indent

        # Pop levels off stack if current indent is less than the top
        while ($levelStack.Count -gt 0 -and $currentIndent -lt $levelStack.Peek()) {
            [void]$levelStack.Pop()
        }

        # Push level onto stack if it's deeper than the current top (or stack is empty)
        if ($levelStack.Count -eq 0 -or $currentIndent -gt $levelStack.Peek()) {
            $levelStack.Push($currentIndent)
        }
        # Else (if currentIndent == levelStack.Peek()), it's a sibling, stack remains same

        $comment.Level = $levelStack.Count # Level is the current stack depth
        Write-Verbose "Line $($comment.LineNumber): Indent=$currentIndent, Assigned Level=$($comment.Level)"
    }
    Write-Verbose "Finished assigning hierarchical levels."
    # --- End Step 2 ---

    # --- Step 3: Reconstruct Indentation Based on Level ---
    Write-Verbose "Reconstructing indentation based on levels..."
    foreach ($comment in $sortedSingleLineComments) {
        # Level 1 = 0 spaces, Level 2 = $SpacesPerLevel spaces, etc.
        $newIndentLength = ($comment.Level - 1) * $SpacesPerLevel
        if ($newIndentLength -lt 0) { $newIndentLength = 0 } # Safety check
        $comment.Indentation = ' ' * $newIndentLength
        Write-Verbose "Line $($comment.LineNumber): Level=$($comment.Level), Reconstructed Indent=$newIndentLength spaces."
    }
    Write-Verbose "Finished reconstructing indentation."
    # --- End Step 3 ---


    # --- Output ---
    switch ($Mode) {
        1 {
            $outputLines = @()
            $hasSingleLineOutput = $false
            $hasMultiLineOutput = $false

            if ($sortedSingleLineComments.Count -gt 0) {
                 $hasSingleLineOutput = $true
                $headerText = "Single-Line Comments found in '$FilePath' (Hierarchically Re-indented"
                if ($ShowLineNumbers) { $headerText += " Line#:" }
                $headerText += ") ---"
                Write-Host "`n--- $headerText"
                $outputLines += "--- $headerText ---"

                foreach ($comment in $sortedSingleLineComments) {
                    # Now use the final, reconstructed indentation
                    if ($ShowLineNumbers) {
                        $formattedLine = "{0}: {1}{2}" -f $comment.LineNumber, $comment.Indentation, $comment.Text
                    } else {
                        $formattedLine = "{0}{1}" -f $comment.Indentation, $comment.Text
                    }
                    Write-Host $formattedLine
                    $outputLines += $formattedLine
                }
            }

             if ($ShowMultiLineBlocks -and $multiLineCommentsData.Count -gt 0) {
                 $hasMultiLineOutput = $true
                 # Multi-line block output remains unchanged
                 $multiHeader = "Multi-Line Comment Blocks found in '$FilePath'"
                 if ($ShowLineNumbers) { $multiHeader += " (Line Ranges):" }
                 Write-Host "`n--- $multiHeader ---"
                 $outputLines += "`n--- $multiHeader ---"

                 foreach ($block in $multiLineCommentsData) {
                     $blockHeaderText = if ($ShowLineNumbers) { "[$($block.StartLine)-$($block.EndLine)]:" } else { "" }
                     Write-Host "$blockHeaderText"
                     Write-Host $block.Text
                     Write-Host "---"
                     $outputLines += "$blockHeaderText"
                     $outputLines += $block.Text
                     $outputLines += "---"
                 }
             }


            if (-not $hasSingleLineOutput -and -not ($ShowMultiLineBlocks -and $multiLineCommentsData.Count -gt 0)) {
                 if ($multiLineCommentsData.Count -gt 0 -and -not $ShowMultiLineBlocks){
                    Write-Host "No single-line comments found. Multi-line blocks were parsed but not displayed (use -ShowMultiLineBlocks)."
                 } else {
                    Write-Host "No comments found in '$FilePath'."
                 }
                return
            }


            $clipboardText = $outputLines -join [Environment]::NewLine
            try {
                    Set-Clipboard -Value $clipboardText -ErrorAction Stop
                    $copiedMsg = "Successfully copied $($sortedSingleLineComments.Count) hierarchically re-indented single-line comment(s)"
                    if ($ShowMultiLineBlocks -and $multiLineCommentsData.Count -gt 0) {
                         $copiedMsg += " and $($multiLineCommentsData.Count) multi-line block(s)"
                    } elseif ($multiLineCommentsData.Count -gt 0) {
                         $copiedMsg += " (multi-line blocks parsed but not copied)"
                    }
                    if ($ShowLineNumbers) { $copiedMsg += " with line numbers/ranges" }
                    $copiedMsg += " to clipboard."
                    Write-Host "`n--- $copiedMsg ---"
            } catch {
                    Write-Warning "Could not copy content to clipboard. Error: $($_.Exception.Message)"
                    Write-Warning "Clipboard access might be restricted in this PowerShell session or environment."
            }
        }
        default {
            Write-Warning "Invalid or unimplemented mode specified: $Mode"
        }
    }
     Write-Verbose "Finished processing file: $FilePath"
}
