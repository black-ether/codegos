[CmdletBinding(DefaultParameterSetName = 'ListComments')]
param(
# --- Common Parameters (All Sets) ---
[Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0, ParameterSetName = 'ListComments')]
[Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0, ParameterSetName = 'TreeView')]
[Parameter(Mandatory=$true, ValueFromPipeline=$true, Position=0, ParameterSetName = 'MarkdownSections')]
[ValidateScript({
    # Ensure the path exists and is a file (not a directory)
    if (Test-Path -Path $_ -PathType Leaf) { return $true } else { throw "File not found or is not a file: $_" }
})]
[string]$FilePath,

[Parameter(ParameterSetName = 'ListComments')]
[Parameter(ParameterSetName = 'TreeView')]
[Alias('LN')]
[switch]$ShowLineNumbers,

[Parameter(ParameterSetName = 'ListComments')]
[switch]$ShowMultiLineBlocks,

[Parameter(ParameterSetName = 'ListComments')]
[Parameter(ParameterSetName = 'TreeView')] 
[Alias('SHOW')]
[ValidateRange(1, [int]::MaxValue)] # Ensure it's a positive integer
[int]$ShowCodeAroundLine,

[Parameter(ParameterSetName = 'ListComments')]
[ValidateRange(1, 16)] # Reasonable range for spaces per indent level
[int]$SpacesPerLevel = 4,

[Parameter(ParameterSetName = 'ListComments')]
[switch]$Raw,

# --- TreeView Set Specific Parameter ---
[Parameter(Mandatory=$true, ParameterSetName = 'TreeView')] # Mandatory for this set
[switch]$Tree,

# --- Markdown Set Specific Parameter ---
[Parameter(Mandatory=$true, ParameterSetName = 'MarkdownSections')] # Mandatory for this set
[switch]$Markdown
    # --- Unused Parameters ---
    # These were in the original but marked as unused. Removing for clarity unless needed later.
    # [Parameter(ParameterSetName = 'ListComments')]
    # [ValidateRange(0, 100)]
    # [int]$ReduceIndentThreshold = 8,
    # [Parameter(ParameterSetName = 'ListComments')]
    # [ValidateRange(0, 100)]
    # [int]$ReducedBaseIndent = 4,
)

# --- Main Script Process Block ---
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\CommentVisUtils.psm1')

Write-Verbose "Parameter Set used: $($PSCmdlet.ParameterSetName)"
Write-Verbose "Starting processing for file: '$FilePath'"

# Determine SpacesPerLevel (needed for level calculation regardless of output format)
$effectiveSpacesPerLevel = if ($PSCmdlet.ParameterSetName -eq 'ListComments' -and $PSBoundParameters.ContainsKey('SpacesPerLevel')) { $SpacesPerLevel } else { 4 }
Write-Verbose "Effective SpacesPerLevel for hierarchy calculation: $effectiveSpacesPerLevel"

# Resolve the absolute path
try {
    $absolutePath = Convert-Path -LiteralPath $FilePath -ErrorAction Stop
    Write-Verbose "Absolute path resolved to: '$absolutePath'"
} catch {
    Write-Error "Failed to resolve path for '$FilePath'. Error: $($_.Exception.Message)"
    return
}

# --- Determine Language Profile ---
$languageProfile = $null
try {
    # Call the enhanced function
    $languageProfile = Get-LanguageProfile -FilePath $absolutePath -ErrorAction Stop
    if ($languageProfile.Warning) {
        # Display the warning if the default profile was used
        Write-Warning $languageProfile.Warning
    }
} catch {
    Write-Error "Failed to determine language profile for '$absolutePath'. Error: $($_.Exception.Message)"
    return
}
if ($null -eq $languageProfile) {
     Write-Error "Language profile could not be determined for '$absolutePath'."
     return
}
Write-Verbose "Using language profile: $($languageProfile.Name)" # Added verbose message
# Initialize data structures
$singleLineCommentsData = [System.Collections.Generic.List[PSCustomObject]]::new()
$multiLineCommentsData = [System.Collections.Generic.List[PSCustomObject]]::new()
$lineNumber = 0
$inMultiLineCommentBlock = $false
$currentMultiLineComment = [System.Text.StringBuilder]::new()
$multiLineStartLine = 0
$fileContent = $null # Will hold the file lines as an array

$activeBlockStartMarker = $null # Keep track of which start marker initiated the block
$activeBlockEndMarker = $null  

# --- File Reading and Parsing ---
try {
    # *** CORRECTED FILE READING ***
    # Read directly into a string array. Get-Content handles line endings.
    $fileContent = Get-Content -Path $absolutePath -ErrorAction Stop

    # Handle edge cases: empty file or single-line file
    if ($null -eq $fileContent) { # File is empty
        $fileContent = @() # Ensure it's an empty array
        Write-Warning "File '$absolutePath' is empty or could not be read."
    } elseif ($fileContent -is [string]) { # File has only one line
        $fileContent = @($fileContent) # Convert the single string to an array with one element
    }
    # Now $fileContent is guaranteed to be a string array

    Write-Verbose "Successfully read $($fileContent.Count) lines from '$absolutePath'."

    # --- Start Parsing Lines ---
    $lineNumber = 0 # Reset line number for array processing
    foreach ($line in $fileContent) {
        $lineNumber++ # Increment line number (1-based)
        $trimmedLine = $line.Trim()

        # --- Multi-line Comment Parsing ---
        if ($inMultiLineCommentBlock) {
            if ($trimmedLine.EndsWith($activeBlockEndMarker)) {
                # End of block found
        
                $contentBeforeEnd = $line -replace "$([regex]::Escape($activeBlockEndMarker))$"
        
                [void]$currentMultiLineComment.Append($contentBeforeEnd)
                $multiLineCommentsData.Add([PSCustomObject]@{
                    StartLine = $multiLineStartLine
                    EndLine   = $lineNumber
                    Text      = $currentMultiLineComment.ToString().Trim()
                    LanguageProfile = $languageProfile.Name
                })
                $inMultiLineCommentBlock = $false
                [void]$currentMultiLineComment.Clear()
        
                Write-Verbose "Closed multi-line comment block [$($languageProfile.Name)] started with '$activeBlockStartMarker' at line $lineNumber. Start: $multiLineStartLine."
        
                $activeBlockStartMarker = $null
                $activeBlockEndMarker = $null
        
            } else {
                # Line is inside the block
                [void]$currentMultiLineComment.AppendLine($line)
            }
            continue # Skip single-line check for lines inside multi-line block
        }

        # Check for start of multi-line block
        # --- State Check: Potentially Starting a Multi-line Comment Block ---
        # Iterate through all defined BlockStart markers for the language
        $blockStartedThisLine = $false
        # Check only if BlockStart array is not empty or null
        if ($null -ne $languageProfile.BlockStart -and $languageProfile.BlockStart.Count -gt 0) {
            for ($i = 0; $i -lt $languageProfile.BlockStart.Count; $i++) {
                $blockStartMarker = $languageProfile.BlockStart[$i]
                # Ensure BlockEnd array exists and has a corresponding element
                $blockEndMarker = if ($null -ne $languageProfile.BlockEnd -and $i -lt $languageProfile.BlockEnd.Count) {
                                    $languageProfile.BlockEnd[$i]
                            } else {
                                    # Handle cases where BlockEnd might be missing or mismatched (shouldn't happen with current profiles)
                                    Write-Warning "Mismatch or missing BlockEnd marker for BlockStart '$blockStartMarker' in profile '$($languageProfile.Name)'."
                                    $null # Or handle error appropriately
                            }

                # Skip if markers are null/empty (safety check)
                if ([string]::IsNullOrEmpty($blockStartMarker) -or [string]::IsNullOrEmpty($blockEndMarker)) {
                    continue
                }

                if ($trimmedLine.StartsWith($blockStartMarker)) {
                    # Check for single-line block: """ comment """ or <# comment #>
                    # Ensure length check accounts for potentially longer markers like """
                    if ($trimmedLine.EndsWith($blockEndMarker) -and $trimmedLine.Length -ge ($blockStartMarker.Length + $blockEndMarker.Length)) {
                        # Extract content between markers using regex, escaping markers
                        $pattern = "^\s*$([regex]::Escape($blockStartMarker))\s*(.*?)\s*$([regex]::Escape($blockEndMarker))\s*$"
                        if ($trimmedLine -match $pattern) {
                            $blockContent = $matches[1]
                            if ($blockContent.Trim().Length -gt 0) {
                                $multiLineCommentsData.Add([PSCustomObject]@{
                                    StartLine = $lineNumber
                                    EndLine   = $lineNumber
                                    Text      = $blockContent.Trim()
                                    LanguageProfile = $languageProfile.Name # Add profile context
                                })
                                Write-Verbose "Found single-line multi-line comment [$($languageProfile.Name)] using '$blockStartMarker' at line $lineNumber."
                                $blockStartedThisLine = $true # Mark as handled
                                break # Stop checking other block markers for this line
                            }
                            # If content is empty, still treat as handled block start/end
                            $blockStartedThisLine = $true
                            break
                        }
                        # If regex fails but markers match, treat as start of multi-line block (edge case)
                    }
                    # If not a single-line block, start a multi-line block
                    if (-not $blockStartedThisLine) {
                        $inMultiLineCommentBlock = $true
                        $multiLineStartLine = $lineNumber
                        $activeBlockStartMarker = $blockStartMarker # Remember which marker started it
                        $activeBlockEndMarker = $blockEndMarker   # Remember corresponding end marker

                        # Get content on starting line *after* the start marker, escaping marker for regex
                        $contentAfterStart = $line -replace "^$([regex]::Escape($blockStartMarker))\s*", ''
                        [void]$currentMultiLineComment.Append($contentAfterStart)
                        Write-Verbose "Opened multi-line comment block [$($languageProfile.Name)] with '$blockStartMarker' at line $lineNumber."
                        $blockStartedThisLine = $true # Mark as handled
                        break # Stop checking other block markers for this line
                    }
                }
            } # End for loop through BlockStart markers
        } # End if BlockStart exists

        # If a block comment started on this line, skip single-line checks
        if ($blockStartedThisLine) {
            continue
        }
        

        # --- Single-line Comment Parsing ---
            # --- State Check: Potentially a Single-line Comment ---
        # NOTE: This section STILL DOES NOT account for string literals.
        # Proper handling requires a stateful parser using $languageProfile.StringDelimiters etc.
        $singleLineFound = $false
        $skipAdd = $false # Flag to skip adding if it's an empty #endregion etc.

        # Check only if SingleLine array is not empty or null
        if ($null -ne $languageProfile.SingleLine -and $languageProfile.SingleLine.Count -gt 0) {
            foreach ($singleLineMarker in $languageProfile.SingleLine) {
                # Skip if marker is null/empty
                if ([string]::IsNullOrEmpty($singleLineMarker)) {
                    continue
                }

                $escapedMarker = [regex]::Escape($singleLineMarker)
                # Regex: Start of line, optional whitespace (G1), the marker, optional space, the rest (G2)
                $regexPattern = "^(\s*)(?:$escapedMarker)\s?(.*)$"

                if ($line -match $regexPattern) {
                    $indentation = $matches[1]
                    $originalCommentText = $matches[2]
                    $processedCommentText = $originalCommentText
                    $skipAdd = $false # Reset skip flag for each potential marker match

                    $regionStartKeyword = $languageProfile.RegionStart
                    $regionEndKeyword = $languageProfile.RegionEnd
                    $matchOperator = if ($languageProfile.CaseSensitiveKeywords) { "-cmatch" } else { "-match" }
                    $regionProcessed = $false # Flag to track if region logic modified the text
    
                    # Check for Region Start Keyword
                    if (-not [string]::IsNullOrEmpty($regionStartKeyword)) {
                        # Pattern to find keyword at start of comment text, capturing text after (Group 1)
                        $regionStartPattern = "^\s*$([regex]::Escape($regionStartKeyword))\b\s?(.*)$"
    
                        # Perform the match that captures the text *after* the keyword
                        if ($originalCommentText -match $regionStartPattern) {
                            # Store the potentially captured text BEFORE doing the case check
                            $textAfterRegionStart = $matches[1]
    
                            # Now, verify the keyword itself using the correct case sensitivity
                            $keywordPattern = "^\s*$([regex]::Escape($regionStartKeyword))\b"
                            # Use the profile's preferred operator for case check
                            if ($originalCommentText -match $keywordPattern) {
                                Write-Verbose "Detected region start keyword [$($languageProfile.Name)] at line $lineNumber."
                                # Use the stored text from the earlier match
                                $processedCommentText = $textAfterRegionStart.TrimStart()
                                $regionProcessed = $true # Mark that we handled a region keyword
                            }
                        }
                    }
    
                    # Check for End Region Keyword, but ONLY if start wasn't processed
                    if (-not $regionProcessed -and -not [string]::IsNullOrEmpty($regionEndKeyword)) {
                        # Pattern to find keyword at start of comment text, capturing text after (Group 1)
                        $regionEndPattern = "^\s*$([regex]::Escape($regionEndKeyword))\b\s?(.*)$"
    
                        # Perform the match that captures the text *after* the keyword
                        if ($originalCommentText -match $regionEndPattern) {
                            # Store the potentially captured text BEFORE doing the case check
                            $textAfterRegionEnd = $matches[1]
    
                            # Now, verify the keyword itself using the correct case sensitivity
                            $keywordPattern = "^\s*$([regex]::Escape($regionEndKeyword))\b"
                            # Use the profile's preferred operator for case check
                            if ($originalCommentText -match $keywordPattern) {
                                # Check if the remaining text is empty
                                if ($textAfterRegionEnd.Trim() -eq '') {
                                    Write-Verbose "Skipping empty end-region equivalent [$($languageProfile.Name)] at line $lineNumber."
                                    $skipAdd = $true # Set flag to skip adding this comment entirely
                                } else {
                                    Write-Verbose "Detected region end keyword [$($languageProfile.Name)] at line $lineNumber."
                                    # Use the stored text from the earlier match
                                    $processedCommentText = $textAfterRegionEnd.TrimStart()
                                    # $regionProcessed = $true # Not strictly needed here, but consistent
                                }
                            }
                        }
                    }
                    # --- End Region Handling ---
    
                    # Add the comment only if there's actual text after processing AND skip flag is not set
                    if (-not $skipAdd -and $processedCommentText.Trim().Length -gt 0) {
                       # ... (rest of the code to add the comment object) ...
                       # This part should remain the same
                            $commentObject = [PSCustomObject]@{
                                LineNumber         = $lineNumber
                                Indentation        = $indentation
                                Text               = $processedCommentText
                                OriginalIndentLength = $indentation.Length
                                Level              = 0 # Placeholder
                                OriginalLine       = $line
                                LanguageProfile    = $languageProfile.Name # Add profile context
                            }
                            $singleLineCommentsData.Add($commentObject)
                            Write-Verbose "Found single-line comment [$($languageProfile.Name)] using '$singleLineMarker' at line $lineNumber. Indent: $($indentation.Length), Text: '$processedCommentText'"
    
                    } elseif (-not $skipAdd) {
                         # ... (rest of the code to write verbose for skipping empty comment) ...
                         # This part should remain the same
                         Write-Verbose "Skipping empty single-line comment [$($languageProfile.Name)] using '$singleLineMarker' at line $lineNumber."
                    }
    
                    # Found a single-line comment with this marker, no need to check others on this line
                    $singleLineFound = $true
                    break # Exit the foreach ($singleLineMarker) loop

                    # Add the comment only if there's actual text after processing AND skip flag is not set
                    if (-not $skipAdd -and $processedCommentText.Trim().Length -gt 0) {
                        $commentObject = [PSCustomObject]@{
                            LineNumber         = $lineNumber
                            Indentation        = $indentation
                            Text               = $processedCommentText
                            OriginalIndentLength = $indentation.Length
                            Level              = 0 # Placeholder
                            OriginalLine       = $line
                            LanguageProfile    = $languageProfile.Name # Add profile context
                        }
                        $singleLineCommentsData.Add($commentObject)
                        Write-Verbose "Found single-line comment [$($languageProfile.Name)] using '$singleLineMarker' at line $lineNumber. Indent: $($indentation.Length), Text: '$processedCommentText'"
                    } elseif (-not $skipAdd) {
                        # Log skipping if the comment was present but empty after processing (and not skipped for other reasons)
                        Write-Verbose "Skipping empty single-line comment [$($languageProfile.Name)] using '$singleLineMarker' at line $lineNumber."
                    }

                    # Found a single-line comment with this marker, no need to check others on this line
                    $singleLineFound = $true
                    break # Exit the foreach ($singleLineMarker) loop
                } # End if ($line -match $regexPattern)
            } # End foreach ($singleLineMarker)
        } # End if SingleLine exists
    }

    # Check if a multi-line block was left open
    if ($inMultiLineCommentBlock) {
        # MODIFIED Write-Warning line:
        Write-Warning "Multi-line comment block [$($languageProfile.Name)] started with '$activeBlockStartMarker' at line $multiLineStartLine was not properly closed with '$activeBlockEndMarker'."

        # Add the incomplete block with a warning
        $multiLineCommentsData.Add([PSCustomObject]@{
            StartLine = $multiLineStartLine
            EndLine   = $lineNumber # Ends at the last line of the file
            Text      = $currentMultiLineComment.ToString().Trim() + " [Warning: Block not closed]"
            LanguageProfile = $languageProfile.Name # Add profile context
        })
    }
} catch {
    Write-Error "Error reading or processing file '$absolutePath'. Error: $($_.Exception.Message)"
    return 
}

# Write-Host "`n--- RAW Multi-line Comments ---" -ForegroundColor Yellow
# $multiLineCommentsData | Format-List
# Write-Host "--- END RAW Multi-line Comments ---`n" -ForegroundColor Yellow


# Sort single-line comments by line number for predictable processing
$sortedSingleLineComments = $singleLineCommentsData | Sort-Object LineNumber

# --- Conditionally Apply Custom Comment Filter via Function ---

# Determine if filtering should be skipped (Raw mode active AND in ListComments set)
# Use .IsPresent for safer checking of switch parameters
$skipFiltering = ($PSCmdlet.ParameterSetName -eq 'ListComments' -and $Raw.IsPresent)

if (-not $skipFiltering) {
    Write-Verbose "Applying custom comment filtering using Select-SingleLineComment function..."
    # Call the function - it contains all filtering logic and verbose/host messages internally
    $sortedSingleLineComments = Select-SingleLineComment -InputObject $sortedSingleLineComments -LanguageProfile $languageProfile
} else {
    # Raw output logic for the ListComments set (this part remains the same)
    Write-Verbose "Raw output mode selected for ListComments. Skipping custom comment filtering."
    Write-Host "`n--- Raw Single-Line Comments from '$FilePath' ---"
    if ($sortedSingleLineComments.Count -gt 0) {
        foreach ($comment in $sortedSingleLineComments) {
            $originalLineIndex = $comment.LineNumber - 1
            if ($originalLineIndex -ge 0 -and $originalLineIndex -lt $fileContent.Count) {
                Write-Host $fileContent[$originalLineIndex]
            } else {
                Write-Warning "Could not retrieve original line for comment detected at line $($comment.LineNumber)"
            }
        }
    } else {
        Write-Host "(No single-line comments found)"
    }
    if ($ShowMultiLineBlocks -and $multiLineCommentsData.Count -gt 0) {
        $multiHeader = "Multi-Line Comment Blocks in '$FilePath'"
        if ($ShowLineNumbers) { $multiHeader += " (LN Ranges Appended)" }
        Write-Host "`n--- $multiHeader ---"
        foreach ($block in $multiLineCommentsData | Sort-Object StartLine) {
            $blockText = $block.Text
            $blockLines = $blockText -split '\r?\n'
            $blockHeader = "Block Lines $($block.StartLine)-$($block.EndLine)"
            if($ShowLineNumbers){ Write-Host "<# ($blockHeader)" } else { Write-Host "<#" }
            foreach($line in $blockLines){ Write-Host "   $line" }
            Write-Host "#>"; Write-Host "---"
        }
    } elseif ($multiLineCommentsData.Count -gt 0 -and -not $ShowMultiLineBlocks) {
         Write-Host "`n(Multi-line blocks exist but -ShowMultiLineBlocks was not specified)"
    }
    Write-Verbose "Finished raw output."
}
# --- End Conditional Comment Filter ---

# --- Preliminary Indentation Adjustment (Attempt to fix inconsistencies) ---
# It looks at neighbors with 'valid' indentation (multiple of SpacesPerLevel) to guess the intended indent.
Write-Verbose "Starting preliminary indentation adjustment check (using $effectiveSpacesPerLevel spaces per level)..."
for ($i = 0; $i -lt $sortedSingleLineComments.Count; $i++) {
    $currentComment = $sortedSingleLineComments[$i]
    $currentIndentLength = $currentComment.OriginalIndentLength # Check original indent

    # Only check/adjust if indentation is NOT a multiple of the effective spaces per level
    if ($effectiveSpacesPerLevel -gt 0 -and $currentIndentLength % $effectiveSpacesPerLevel -ne 0) {
        Write-Verbose "Line $($currentComment.LineNumber): Indentation ($currentIndentLength) is non-standard multiple of $effectiveSpacesPerLevel. Checking neighbors..."
        $previousValidComment = $null
        # Look backwards for the nearest comment with standard indentation
        for ($prevIndex = $i - 1; $prevIndex -ge 0; $prevIndex--) {
            if ($sortedSingleLineComments[$prevIndex].OriginalIndentLength % $effectiveSpacesPerLevel -eq 0) {
                $previousValidComment = $sortedSingleLineComments[$prevIndex]
                break
            }
        }
        $nextValidComment = $null
         # Look forwards for the nearest comment with standard indentation
        for ($nextIndex = $i + 1; $nextIndex -lt $sortedSingleLineComments.Count; $nextIndex++) {
            if ($sortedSingleLineComments[$nextIndex].OriginalIndentLength % $effectiveSpacesPerLevel -eq 0) {
                $nextValidComment = $sortedSingleLineComments[$nextIndex]
                break
            }
        }

        # Attempt adjustment only if we found both a valid previous and next neighbor
        if ($null -ne $previousValidComment -and $null -ne $nextValidComment) {
            $prevIndent = $previousValidComment.OriginalIndentLength
            $nextIndent = $nextValidComment.OriginalIndentLength
            $correctIndentLength = -1 # Default to invalid

            # If neighbors have the same standard indent, use that
            if ($prevIndent -eq $nextIndent) {
                $correctIndentLength = $prevIndent
                Write-Verbose "Line $($currentComment.LineNumber): Both valid neighbors have indent $prevIndent."
            }
            # Heuristic: If one neighbor is at indent 0 and the other isn't, maybe the current one belongs with the non-zero one? (Less reliable)
            # else if (($prevIndent -eq 0 -and $nextIndent -ne 0) -or ($nextIndent -eq 0 -and $prevIndent -ne 0)) {
            #     $correctIndentLength = if ($prevIndent -eq 0) { $nextIndent } else { $prevIndent }
            #     Write-Verbose "Line $($currentComment.LineNumber): One neighbor at 0, using other neighbor's indent ($correctIndentLength)."
            # }
            # Add more heuristics here if needed, e.g., closest indent?

            # If we determined a likely correct indent and it's different from the current one
            if ($correctIndentLength -ge 0 -and $correctIndentLength -ne $currentIndentLength) {
                $newIndent = ' ' * $correctIndentLength
                # Update the Indentation property used for level calculation, but keep OriginalIndentLength
                $sortedSingleLineComments[$i].Indentation = $newIndent
                Write-Verbose "Line $($currentComment.LineNumber): Preliminarily adjusting indentation for level calculation from $currentIndentLength to $correctIndentLength spaces based on neighbors."
            } else {
                 # If neighbors didn't help, keep the original non-standard indent for calculation
                 $sortedSingleLineComments[$i].Indentation = ' ' * $currentIndentLength
                 Write-Verbose "Line $($currentComment.LineNumber): Could not determine standard indent from neighbors ($prevIndent, $nextIndent) or adjustment not needed. Using original $currentIndentLength for level calculation."
            }
        } else {
            # If couldn't find both neighbors, keep original indent for calculation
             $sortedSingleLineComments[$i].Indentation = ' ' * $currentIndentLength
             Write-Verbose "Line $($currentComment.LineNumber): Could not find valid neighbors before and after. Using original $currentIndentLength for level calculation."
        }
    } else {
         # Indent is already standard or SpacesPerLevel is 0, use original indent
         $sortedSingleLineComments[$i].Indentation = ' ' * $currentIndentLength
         Write-Verbose "Line $($currentComment.LineNumber): Indentation ($currentIndentLength) is standard multiple of $effectiveSpacesPerLevel or check skipped. Using for level calculation."
    }
}
Write-Verbose "Finished preliminary indentation adjustment check."


# --- Hierarchical Level Assignment (Merged: Stack-based + Region Adjustment) ---
Write-Verbose "Assigning hierarchical levels using stack-based relative depth + region adjustment..."

# Initialize the stack for tracking indentation levels (from old script)
$levelStack = [System.Collections.Generic.Stack[int]]::new()
$isInRegionContext = $false

# Ensure $fileContent is accessible in this scope
if ($null -eq $fileContent) {
    Write-Error "File content is not available for region detection during level assignment."
    return
}

# Process comments sorted by line number
foreach ($comment in $sortedSingleLineComments) {
    # --- Retrieve Original Line for Region Detection ---
    $originalLineIndex = $comment.LineNumber - 1
    $originalLine = '' # Default to empty
    if ($originalLineIndex -ge 0 -and $originalLineIndex -lt $fileContent.Count) {
        $originalLine = $fileContent[$originalLineIndex]
    } else {
        Write-Warning "Could not retrieve original line for comment at line $($comment.LineNumber)"
    }

    # --- Region Context Check (End Region FIRST) ---
    # Check if the *current* line marks the end of a region. If so, exit the context *before* processing this line's level.
    if ($originalLine -match '^\s*#\s*endregion\b') {
        $isInRegionContext = $false
        Write-Verbose "Line $($comment.LineNumber): Detected #endregion, exiting region context."
    }

    # --- Stack-Based Level Calculation ---
    # Use the potentially adjusted indentation length (after preliminary adjustment)
    $currentIndent = $comment.Indentation.Length

    # Pop levels off stack if current indent is less than the top (moving out)
    while ($levelStack.Count -gt 0 -and $currentIndent -lt $levelStack.Peek()) {
        Write-Verbose "Line $($comment.LineNumber): Current indent ($currentIndent) < Stack top ($($levelStack.Peek())). Popping stack."
        [void]$levelStack.Pop()
    }

    # Push level onto stack if it's deeper than the current top (or stack is empty) (moving in)
    if ($levelStack.Count -eq 0 -or $currentIndent -gt $levelStack.Peek()) {
         Write-Verbose "Line $($comment.LineNumber): Current indent ($currentIndent) > Stack top (or stack empty). Pushing indent onto stack."
        $levelStack.Push($currentIndent)
    }
    # Else (if currentIndent == levelStack.Peek()), it's a sibling, stack remains same

    # Level based on stack depth
    $stackBasedLevel = $levelStack.Count
    Write-Verbose "Line $($comment.LineNumber): Indent=$currentIndent, Stack depth gives base Level=$stackBasedLevel"

    # --- Apply Region Context Adjustment ---
    $finalLevel = $stackBasedLevel # Start with the stack-based level
    if ($isInRegionContext) {
        Write-Verbose "Line $($comment.LineNumber): Inside region context, incrementing stack-based level $stackBasedLevel by 1."
        $finalLevel++
    }

    # --- Assign Final Level ---
    $comment.Level = $finalLevel
    Write-Verbose "Line $($comment.LineNumber): --> Assigned Final Level=$($comment.Level) (RegionContext: $isInRegionContext)"

    # --- Region Context Check (Start Region LAST) ---
    # Check if the *current* line marks the start of a region. If so, enter the context for the *next* lines.
    if ($originalLine -match '^\s*#\s*region\b') {
        $isInRegionContext = $true
        Write-Verbose "Line $($comment.LineNumber): Detected #region, entering region context for subsequent lines."
    }
}
Write-Verbose "Finished assigning hierarchical levels."
# --- End Hierarchical Level Assignment ---


# --- Output Generation ---

# --- TreeView Parameter Set ---
if ($PSCmdlet.ParameterSetName -eq 'TreeView') {
    Write-Host "`n--- Comment Tree for '$FilePath' ---"
    Write-Host ""
    if ($sortedSingleLineComments.Count -eq 0) { Write-Host "(No single-line comments found)"; return }

    # Initialize List for clipboard content
    $outputLinesForClipboard = [System.Collections.Generic.List[string]]::new()
    # Add Header to clipboard list as well
    $outputLinesForClipboard.Add("--- Comment Tree for '$FilePath' ---")
    $outputLinesForClipboard.Add("") # Match blank line after header

    # Use HashSet to keep track of levels that still have siblings below the current point
    $activeLevelsWithMoreSiblings = [System.Collections.Generic.HashSet[int]]::new()
    # $treeOutputLines = [System.Collections.Generic.List[string]]::new()
    $PrefixMiddle = "├── "
    $PrefixLast   = "╰── "
    $IndentMiddle = "│   "
    $IndentLast   = "    "

    Write-Verbose "Generating Tree View..."
    for ($i = 0; $i -lt $sortedSingleLineComments.Count; $i++) {
        $comment = $sortedSingleLineComments[$i]; $level = $comment.Level
        if ($level -lt 1) {
            Write-Verbose "Skipping comment at Line $($comment.LineNumber) with invalid calculated level $level for TreeView."
            continue
        }

        # Determine if this comment is the last among its direct siblings *from this point forward*
        $isLast = IsLastSibling $i $sortedSingleLineComments

        # Build the indentation prefix based on active levels
        $prefixIndent = ""
        for ($k = 1; $k -lt $level; $k++) {
            # If calculating the indent for the FIRST level column (k=1),
            # force it to use spaces to visually isolate root branches.
            if ($k -eq 1) {
                $prefixIndent += $IndentLast # Always "    " for k=1 column
            }
            # For deeper level columns (k=2, 3, ...), use the standard logic.
            else {
                $prefixIndent += if ($activeLevelsWithMoreSiblings.Contains($k)) { $IndentMiddle } else { $IndentLast }
            }
        }

        # Determine the connector for this node
        $connector = if ($isLast) { $PrefixLast } else { $PrefixMiddle }

        $removed = $activeLevelsWithMoreSiblings.RemoveWhere([Predicate[int]]{ param($item) $item -ge $level })

        # Determine if the vertical line for the *current* level needs to continue downwards
        $keepLevelActive = $false
        if (-not $isLast) {
            $keepLevelActive = $true

            # *** ADDED CHECK specifically for Level 1 ***

            if ($level -eq 1) {
                $nextIndex = $i + 1
                # Check if a next item exists and if it is also Level 1
                if ($nextIndex -lt $sortedSingleLineComments.Count -and $sortedSingleLineComments[$nextIndex].Level -eq 1) {
                    $keepLevelActive = $false
                }
            }
        }

        # If the determination is to keep the level active, add it back to the set.
        if ($keepLevelActive) {
            [void]$activeLevelsWithMoreSiblings.Add($level)
            # Optional: Add verbose logging
            # Write-Verbose "Tree Line ($i): Keeping level $level active."
        }
        $postUpdateActiveLevelsString = $activeLevelsWithMoreSiblings | Sort-Object | Out-String -Stream | ForEach-Object {$_.Trim()} | Where-Object {$_} | Out-String
        if ($postUpdateActiveLevelsString) { $postUpdateActiveLevelsString = ($postUpdateActiveLevelsString.Trim() -split '\s+' ) -join ',' } else { $postUpdateActiveLevelsString = '' } # Format as comma-separated
        # Write the verbose log line showing the state AFTER the update logic
        Write-Verbose "Tree Line ($i) POST-UPDATE: Level=$level, IsLast=$isLast, KeepActive=$keepLevelActive, ActiveLevels Now=[$postUpdateActiveLevelsString]"
        # *** END: Added Verbose Logging ***

        # Assemble the output line
        if ($level -eq 1) {
            # Root Level (Level 1): Indent with 4 spaces, no connector prefix.
            $baseCommentLine = (' ' * 4) + $comment.Text
        }
        else {
            # Deeper Levels (Level 2+): Use calculated indent and connector.
            # $prefixIndent accounts for ancestors' vertical lines.
            # $connector is PrefixLast or PrefixMiddle based on whether this node is the last sibling.
             $baseCommentLine = "{0}{1}{2}" -f $prefixIndent, $connector, $comment.Text
        }

        # Add Line number if requested
        $formattedCommentLine = if ($ShowLineNumbers) { "{0} [L:{1}]" -f $baseCommentLine, $comment.LineNumber } else { $baseCommentLine }

        # [void]$treeOutputLines.Add($formattedCommentLine)
        $outputLinesForClipboard.Add($formattedCommentLine)
        Write-Host $formattedCommentLine

         # --- BEGIN ADDED CODE FOR CONTEXT ---
        # Check if context should be displayed for this node
        if ($PSBoundParameters.ContainsKey('ShowCodeAroundLine') -and $comment.LineNumber -eq $ShowCodeAroundLine) {
            Write-Verbose "Tree Line ($i): Matched target L$($ShowCodeAroundLine). Looking for code block following it."

            # Find the line number of the *next* comment in the sorted list
            $nextCommentLineNum = $null
            $nextCommentIndex = $i + 1 # Index of the potential next comment

            if ($nextCommentIndex -lt $sortedSingleLineComments.Count) {
                # Found a subsequent comment
                $nextCommentLineNum = $sortedSingleLineComments[$nextCommentIndex].LineNumber
                Write-Verbose "Tree Line ($i): Next comment found at index $nextCommentIndex, L$nextCommentLineNum."
            } else {
                # This is the last comment in the list
                Write-Verbose "Tree Line ($i): This is the last comment. Will show code to end of file."
                # Use a value just beyond the end of the file to signify "go to the end"
                $nextCommentLineNum = $fileContent.Count + 1
            }

            # Calculate the range of lines to display: AFTER current comment, BEFORE next comment
            $startLineNumToShow = $comment.LineNumber + 1
            $endLineNumToShow = $nextCommentLineNum - 1

            # Convert to 0-based array indices and clamp within file bounds
            $startIndex = [Math]::Max(0, $startLineNumToShow - 1)
            $endIndex = [Math]::Min($fileContent.Count - 1, $endLineNumToShow - 1)

            Write-Verbose "Tree Line ($i): Fetching code block from file indices $startIndex to $endIndex (Lines $($startIndex+1) to $($endIndex+1))"

            # Ensure there's a valid range of lines to display
            if ($startIndex -le $endIndex) {
                # Calculate prefixes for attaching the block visually below the current comment node
                # (This prefix logic remains the same as we developed before)
                $contextIndicatorPrefix = ""
                $codeLinePrefix = ""
                if ($level -eq 1) {
                    $baseIndent = ' ' * 4
                    $contextIndicatorPrefix = $baseIndent + $IndentLast + '└─ '
                    $codeLinePrefix = $baseIndent + $IndentLast + '   '
                } else { # Level > 1
                    # $isLast and $prefixIndent are already calculated for the main comment node
                    $continuationSegment = if (-not $isLast) { $IndentMiddle } else { $IndentLast }
                    $contextIndicatorPrefix = $prefixIndent + $continuationSegment + '└─ '
                    $codeLinePrefix = $prefixIndent + $continuationSegment + '   '
                }
                Write-Verbose "Tree Line ($i): Using prefixes Indicator='$contextIndicatorPrefix', Code='$codeLinePrefix'"

                # Add the "Code block:" indicator line
                # [void]$treeOutputLines.Add($contextIndicatorPrefix + "Code block:")
                Write-Host ($contextIndicatorPrefix + "Code block:")
                $outputLinesForClipboard.Add($contextIndicatorPrefix + "Code block:")

                # Loop through the calculated line indices and add the actual code lines
                for ($lineIndex = $startIndex; $lineIndex -le $endIndex; $lineIndex++) {
                    $currentLineContent = $fileContent[$lineIndex]
                    # Add the code line with its proper prefix
                    # [void]$treeOutputLines.Add($codeLinePrefix + $currentLineContent)
                    Write-CodeLineColored -line $currentLineContent -IndentPrefix $codeLinePrefix
                    $outputLinesForClipboard.Add($codeLinePrefix + $currentLineContent)
                }
            } else {
                # Handle the case where there are no lines between this comment and the next
                Write-Verbose "Tree Line ($i): No code lines found between L$($comment.LineNumber) and next comment (L$($nextCommentLineNum))."
                # Optionally add a note - reuse the prefix calculation from above
                 $contextIndicatorPrefix = ""
                 if ($level -eq 1) { $contextIndicatorPrefix = (' ' * 4) + $IndentLast + '└─ ' }
                 else { $continuationSegment = if (-not $isLast) { $IndentMiddle } else { $IndentLast }; $contextIndicatorPrefix = $prefixIndent + $continuationSegment + '└─ ' }
                #  [void]$treeOutputLines.Add($contextIndicatorPrefix + "(No code between comments)")
                Write-Host ($contextIndicatorPrefix + "(No code between comments)")
                $outputLinesForClipboard.Add($contextIndicatorPrefix + "(No code between comments)")
            }
        }
        # *** FIX: Replace % alias with ForEach-Object ***
        $activeLevelsString = $activeLevelsWithMoreSiblings | Sort-Object | Out-String -Stream | ForEach-Object {$_.Trim()} | Where-Object {$_} | Out-String # Get non-empty, trimmed items
        if ($activeLevelsString) { $activeLevelsString = ($activeLevelsString.Trim() -split '\s+' ) -join ',' } else { $activeLevelsString = '' } # Format as comma-separated
        Write-Verbose "Tree Line ($i): Level=$level, IsLast=$isLast, ActiveLevels=[$activeLevelsString], Prefix='$($prefixIndent)$($connector)', Text='$($comment.Text)'"

    }
    # Print the generated tree lines
    # $treeOutputLines | ForEach-Object { Write-Host $_ }
    Write-Host ""
    Write-Verbose "Finished TreeView output generation."

    # --- Final Clipboard Logic for TreeView (Copied and Modified from ListComments) ---
    # Check if we collected anything beyond the initial header+blank line
    if ($outputLinesForClipboard.Count -gt 2) {
        $clipboardText = $outputLinesForClipboard -join [Environment]::NewLine
        try {
            Set-Clipboard -Value $clipboardText -ErrorAction Stop
            # Build a confirmation message specific to TreeView
            $copiedMsg = "Copied TreeView output"
            if ($PSBoundParameters.ContainsKey('ShowCodeAroundLine')) {
                # Try to get the targeted line number if the parameter exists
                $targetLineNum = $null
                if ($PSBoundParameters.ContainsKey('ShowCodeAroundLine')) {$targetLineNum = $ShowCodeAroundLine}
                $copiedMsg += " (including code block after L$targetLineNum)"
            }
            if ($ShowLineNumbers) { $copiedMsg += " with line numbers" }
            $copiedMsg += " to clipboard."
            Write-Host "`n--- $copiedMsg ---"
        } catch {
            Write-Warning "Could not copy TreeView output to clipboard: $($_.Exception.Message)"
            Write-Warning "Clipboard access might be restricted in this environment, or the content might be too large."
        }
    } elseif ($sortedSingleLineComments.Count -gt 0) {
        # Handle case where comments were found but nothing specific copied (e.g., -show not used)
        Write-Verbose "No specific content marked for clipboard in TreeView mode (e.g., -show not used or target not found)."
    }
    # --- End Clipboard Logic ---
}

# --- ListComments Parameter Set ---
elseif ($PSCmdlet.ParameterSetName -eq 'ListComments' -and -not $Raw) {
    # Reconstruct Indentation Based on Level for output (using specified or default SpacesPerLevel)
    Write-Verbose "Reconstructing indentation based on levels for list view (using $SpacesPerLevel spaces per level)..."
    foreach ($comment in $sortedSingleLineComments) {
        # Level 1 has 0 indent, Level 2 has 1*SpacesPerLevel, etc.
        $newIndentLength = ($comment.Level - 1) * $SpacesPerLevel
        # Ensure indent length is not negative if level calculation was odd
        if ($newIndentLength -lt 0) { $newIndentLength = 0 }
        $comment.Indentation = ' ' * $newIndentLength
    }
    Write-Verbose "Finished reconstructing indentation."

    $outputLinesForClipboard = [System.Collections.Generic.List[string]]::new()
    $hasSingleLineOutput = $false; $hasMultiLineOutput = $false

    # --- Single-Line Comments Output ---
    if ($sortedSingleLineComments.Count -gt 0) {
        $hasSingleLineOutput = $true
        $headerText = "Single-Line Comments in `n'$FilePath' (Re-indented"
        if ($ShowLineNumbers) { $headerText += " - LN Appended" }
        $headerText += ") ---"
        Write-Host "`n--- $headerText"
        Write-Host""
        $outputLinesForClipboard.Add("--- $headerText ---")

        for ($i = 0; $i -lt $sortedSingleLineComments.Count; $i++) {
            $comment = $sortedSingleLineComments[$i]
            # Format: Indent + Text
            $baseCommentLine = "{0}{1}" -f $comment.Indentation, $comment.Text
            # Add Line Number if requested
            $formattedCommentLine = if ($ShowLineNumbers) { "{0} [L:{1}]" -f $baseCommentLine, $comment.LineNumber } else { $baseCommentLine }
            Write-Host $formattedCommentLine
            $outputLinesForClipboard.Add($formattedCommentLine)

            # Code injection logic...
            # Check if the -ShowCodeAroundLine parameter was used AND it matches the current comment's line number
            # Check if code injection is requested for this comment's line number
            # Check if code injection is requested for this comment's line number
            if ($PSBoundParameters.ContainsKey('ShowCodeAroundLine') -and $comment.LineNumber -eq $ShowCodeAroundLine) {
                Write-Verbose "Injecting code after line $($comment.LineNumber)."

                # Determine code block boundaries
                $nextComment = if ($i -lt ($sortedSingleLineComments.Count - 1)) { $sortedSingleLineComments[$i + 1] } else { $null }
                $codeStartLine = $comment.LineNumber + 1
                $codeEndLine = if ($nextComment) { $nextComment.LineNumber - 1 } else { $fileContent.Count }

                # Check if a valid line range exists
                if ($codeStartLine -le $codeEndLine) {
                    Write-Verbose "Potential code range: Lines $codeStartLine-$codeEndLine."

                    # Calculate valid 0-based indices
                    $startIndex = [Math]::Max(0, $codeStartLine - 1)
                    $endIndex = [Math]::Min($fileContent.Count - 1, $codeEndLine - 1)

                    # Ensure indices form a valid range
                    if ($startIndex -le $endIndex) {
                        # Extract raw lines and filter out empty/whitespace lines
                        $rawCodeLines = $fileContent[$startIndex..$endIndex]
                        $codeLinesToInject = $rawCodeLines | Where-Object { $_.Trim().Length -gt 0 }

                        # Proceed only if non-empty lines remain
                        if ($codeLinesToInject.Count -gt 0) {
                            Write-Verbose "Injecting $($codeLinesToInject.Count) non-empty lines from range $codeStartLine-$codeEndLine."

                            # --- Calculate indentation and dynamic separator ---
                            $indentPrefix = $comment.Indentation + (' ' * $SpacesPerLevel)
                            $separatorLine = $indentPrefix # Default to just indent if calculation fails
                            $separatorChar = '-'
                            $fallbackSeparatorLength = 10

                            try {
                                $windowWidth = $Host.UI.RawUI.WindowSize.Width
                                # Calculate width available AFTER indentation
                                $availableWidth = $windowWidth - $indentPrefix.Length

                                if ($availableWidth -gt 0) {
                                    # Normal case: Create separator using available width
                                    $separatorLine = $indentPrefix + ($separatorChar * $availableWidth)
                                } elseif ($windowWidth -gt 0) {
                                    # Edge case: Indent wider than window, just fill window ignoring indent
                                    $separatorLine = $separatorChar * $windowWidth
                                } else {
                                    # Fallback if window width is zero/negative
                                    $separatorLine = $indentPrefix + ($separatorChar * $fallbackSeparatorLength)
                                }
                            } catch {
                                # Fallback if $Host.UI properties fail (e.g., non-interactive)
                                Write-Warning "Could not determine window width for dynamic separator. Using fixed length."
                                $separatorLine = $indentPrefix + ($separatorChar * $fallbackSeparatorLength)
                            }

                            # --- Print Top Separator ---
                            Write-Host $separatorLine

                            # --- Process and output each non-empty code line ---
                            $codeLinesToInject | ForEach-Object {
                                $originalLine = $_
                                $prefix = $indentPrefix

                                # Pass the original line AND the indent prefix
                                Write-CodeLineColored -line $originalLine -IndentPrefix $prefix
                                
                                $lineForClipboard = "$prefix$originalLine"
                                $outputLinesForClipboard.Add($lineForClipboard)
                            }

                            # --- Print Bottom Separator ---
                            Write-Host $separatorLine
                            # Note: Adding dynamic separator to clipboard might not be desirable.

                        } else {
                            Write-Verbose "No non-empty code lines found in range $codeStartLine-$codeEndLine."
                        }
                    } else {
                        Write-Verbose "Invalid code range indices after adjustment: [$startIndex..$endIndex]."
                    }
                } else {
                    Write-Verbose "No code lines exist between comments/EOF (Lines $codeStartLine-$codeEndLine)."
                }
            }
        }
    } # End if ($sortedSingleLineComments.Count -gt 0)

    # --- Multi-Line Comments Output ---
    if ($ShowMultiLineBlocks -and $multiLineCommentsData.Count -gt 0) {
        $hasMultiLineOutput = $true
        $multiHeader = "Multi-Line Comment Blocks in '$FilePath'"
        if ($ShowLineNumbers) { $multiHeader += " (LN Ranges Appended)" }
        Write-Host "`n--- $multiHeader ---"
        # Sort blocks by start line for consistent output
        foreach ($block in $multiLineCommentsData | Sort-Object StartLine) {
            $blockText = $block.Text
            # Split the block text into lines, handling both Windows and Unix line endings
            $blockLines = $blockText -split '\r?\n'
            $blockHeader = "Block Lines $($block.StartLine)-$($block.EndLine)"

            # Output block header
            if($ShowLineNumbers){ Write-Host "<# ($blockHeader)" } else { Write-Host "<#" }
            # Output each line within the block, indented slightly
            foreach($line in $blockLines){ Write-Host "   $line" }
            # Output block footer
            Write-Host "#>"; Write-Host "---" # Separator between blocks
        }
    } # End if ($ShowMultiLineBlocks)

    # --- Final Checks and Clipboard ---
    if (-not $hasSingleLineOutput -and -not ($ShowMultiLineBlocks -and $multiLineCommentsData.Count -gt 0)) {
            # No single lines found, and either multi-lines weren't requested or none were found
            if ($multiLineCommentsData.Count -gt 0 -and -not $ShowMultiLineBlocks){
                Write-Host "`nNo single-line comments found. Multi-line blocks were parsed but not displayed (use -ShowMultiLineBlocks)."
            } else {
                Write-Host "`nNo comments found in '$FilePath'."
            }
            return # Exit gracefully
    }

    # Attempt to copy the collected single-line comments (and injected code) to clipboard
    if ($outputLinesForClipboard.Count -gt 0) {
            # Join the collected lines with the environment's newline character
            $clipboardText = $outputLinesForClipboard -join [Environment]::NewLine
            try {
                Set-Clipboard -Value $clipboardText -ErrorAction Stop
                # Build a confirmation message
                $copiedMsg = "Copied output"
                if ($hasSingleLineOutput) { $copiedMsg += " (single-line comments" }
                if ($PSBoundParameters.ContainsKey('ShowCodeAroundLine')) { $copiedMsg += "/injected code" }
                if ($hasSingleLineOutput -or $PSBoundParameters.ContainsKey('ShowCodeAroundLine')) { $copiedMsg += ")" }
                if ($ShowLineNumbers) { $copiedMsg += " with line numbers" }
                if ($ShowMultiLineBlocks -and $hasMultiLineOutput) { $copiedMsg += ". Multi-line blocks displayed but not copied" }
                $copiedMsg += " to clipboard."
                Write-Host "`n--- $copiedMsg ---"
            } catch {
                Write-Warning "Could not copy to clipboard: $($_.Exception.Message)"
                Write-Warning "Clipboard access might be restricted in this environment, or the content might be too large."
            }
    } elseif ($hasMultiLineOutput) {
            # Only multi-line blocks were shown (not copied)
            Write-Host "`n--- Multi-line blocks displayed but not copied to clipboard. ---"
    }
} # End ListComments

# --- MarkdownSections Parameter Set ---
elseif ($PSCmdlet.ParameterSetName -eq 'MarkdownSections') {
    Write-Verbose "Starting Markdown generation process..."
    $outputFilePath = $null
    try {
        $sourceInfo = Get-Item -LiteralPath $absolutePath -ErrorAction Stop
        $outputFileName = "$($sourceInfo.BaseName).md"
        $outputFilePath = Join-Path -Path $sourceInfo.DirectoryName -ChildPath $outputFileName
        Write-Verbose "Markdown output path determined: '$outputFilePath'"
    } catch {
        Write-Error "Could not determine output path based on '$absolutePath'. Error: $($_.Exception.Message)"
        return 
    }
    $allItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($block in $multiLineCommentsData) {
        $allItems.Add([PSCustomObject]@{
            Type      = 'Multi'
            StartLine = $block.StartLine
            EndLine   = $block.EndLine
            Text      = $block.Text
            Level     = 0
        })
    }
    foreach ($comment in $sortedSingleLineComments) {
        $allItems.Add([PSCustomObject]@{
            Type      = 'Single'
            StartLine = $comment.LineNumber
            EndLine   = $comment.LineNumber
            Text      = $comment.Text
            Level     = $comment.Level
        })
    }
    $sortedAllItems = $allItems | Sort-Object StartLine
    $totalItems = $sortedAllItems.Count
    Write-Verbose "Combined and sorted $totalItems comment items."
    if ($totalItems -eq 0) {
        Write-Host "No comments (single or multi-line) found in '$FilePath'. No Markdown file will be generated."
        return
    }
    $markdownOutput = [System.Text.StringBuilder]::new()
    # Max line number width calculation removed - no longer needed
    Write-Verbose "Generating Markdown content..." # Updated verbose message
    for ($i = 0; $i -lt $totalItems; $i++) {
        $currentItem = $sortedAllItems[$i]
        $isFirstItemOverall = ($i -eq 0)
        # Processing message kept for consistency, though line numbers aren't output
        Write-Verbose "Processing Item $i/$($totalItems-1) - Type: $($currentItem.Type), StartLine: $($currentItem.StartLine), Level: $($currentItem.Level)"
        if ($currentItem.Type -eq 'Multi') {
            if (-not $isFirstItemOverall) {
                [void]$markdownOutput.AppendLine("`n---`n")
            }
            [void]$markdownOutput.AppendLine($currentItem.Text)
            Write-Verbose "  Appended multi-line comment text."
        }
        elseif ($currentItem.Type -eq 'Single') {
            $level = $currentItem.Level
            $markdownPrefix = ""
            # Using the H4 mapping for Levels 1-3 as provided in the user's snippet
            switch ($level) {
                1 { $markdownPrefix = "#### " }
                2 { $markdownPrefix = "#### " }
                3 { $markdownPrefix = "#### " }
                4 { $markdownPrefix = "###### " }
                {$_ -ge 5} {
                    $indentDepth = $level - 4
                    $indent = '  ' * $indentDepth # Note: Original used non-breaking space ' ', changed back to regular space ' '
                    $markdownPrefix = "$indent- "
                }
                default {
                    Write-Warning "Comment at line $($currentItem.StartLine) has unexpected level $level. Treating as basic list item."
                    $markdownPrefix = "- "
                }
            }
            if (-not $isFirstItemOverall) {
                 [void]$markdownOutput.AppendLine()
            }
            [void]$markdownOutput.Append($markdownPrefix).AppendLine($currentItem.Text)
            Write-Verbose ("  Appended single-line comment as Markdown '{0}'" -f $markdownPrefix.Trim())
        }
        $codeStartLine = $currentItem.EndLine + 1
        $codeEndLine = $fileContent.Count
        if (($i + 1) -lt $totalItems) {
            $nextItem = $sortedAllItems[$i + 1]
            $codeEndLine = $nextItem.StartLine - 1
        }
        if ($codeStartLine -le $codeEndLine) {
            $startIndex = $codeStartLine - 1
            $endIndex = $codeEndLine - 1
            if ($startIndex -lt 0) { $startIndex = 0 }
            if ($endIndex -ge $fileContent.Count) { $endIndex = $fileContent.Count - 1 }
            if ($startIndex -le $endIndex) {
                $numCodeLines = ($endIndex - $startIndex) + 1
                Write-Verbose ("  Found code block to append: Lines {0}-{1} ({2} lines)" -f $codeStartLine, $codeEndLine, $numCodeLines)
                # Corrected fence ```powershell
                [void]$markdownOutput.AppendLine("`n``````powershell")
                for ($lineIdx = $startIndex; $lineIdx -le $endIndex; $lineIdx++) {
                    # Original line number calculation removed
                    $codeLine = if($lineIdx -ge 0 -and $lineIdx -lt $fileContent.Count) { $fileContent[$lineIdx] } else { "--Error reading line--" }
                    # Line number formatting removed
                    # Append code line directly to preserve indentation
                    [void]$markdownOutput.AppendLine($codeLine)
                }
                [void]$markdownOutput.AppendLine("``````")
            } else {
                Write-Verbose "  Skipping code block: Invalid index range [$startIndex..$endIndex] after bounds check."
            }
        } else {
            Write-Verbose "  Skipping code block: No lines found between current comment (EndLine $($currentItem.EndLine)) and next item/EOF (Effective Code EndLine: $codeEndLine)."
        } 
    } 
    Write-Verbose "Finished generating Markdown content string. Writing to file '$outputFilePath'..."
    try {
        $markdownContent = $markdownOutput.ToString()
        Set-Content -Path $outputFilePath -Value $markdownContent -Encoding UTF8 -ErrorAction Stop
        Write-Host "Successfully generated Markdown documentation:"
        Write-Host $outputFilePath -ForegroundColor Green
    } catch {
        Write-Error "Failed to write Markdown file to '$outputFilePath'. Error: $($_.Exception.Message)"
    }
    Write-Verbose "Finished Markdown generation process."
}