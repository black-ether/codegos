[CmdletBinding(DefaultParameterSetName = 'Analyze')]
param(
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$false, ParameterSetName = 'Analyze')]
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$false, ParameterSetName = 'ShowTags')]
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$false, ParameterSetName = 'FilterByTag')]
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$false, ParameterSetName = 'RawOutline')] 
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$false, ParameterSetName = 'ExportJson')]
    [string]$FilePath,

    [Parameter(Mandatory=$true, ParameterSetName = 'ShowTags')]
    [switch]$ShowTags,

    [Parameter(Mandatory=$true, ParameterSetName = 'FilterByTag')]
    [string[]]$Tag,

    [Parameter(ParameterSetName = 'ExportJson')]
    [Parameter(ParameterSetName = 'Analyze')]
    [switch]$Full,

    [Parameter(Mandatory=$true, ParameterSetName = 'RawOutline')]
    [switch]$Raw,

    [Parameter(Position=1, ParameterSetName = 'RawOutline')]
    [ValidateSet('Full', IgnoreCase = $true)]
    [string]$RawModeDetail,

    [Parameter(Mandatory=$true, ParameterSetName = 'ExportJson')]
    [switch]$ExportJson,

    [Parameter(ParameterSetName = 'ExportJson')]
    [string]$OutputPath
)

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\ScriptAnalysisUtils.psm1')
function Get-StatValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$StatsObject, # The object to extract from (e.g., $commentStats)

        [Parameter(Mandatory)]
        [string]$PropertyName, # The name of the property to get

        [Parameter()]
        [object]$DefaultValue = 0 # Value (and type) to return on failure
    )

    # If the input object itself is null, return default immediately
    if ($null -eq $StatsObject) {
        Write-Verbose "Get-StatValue: Input object is null for property '$PropertyName'. Returning default '$DefaultValue'."
        return $DefaultValue
    }

    try {
        # Check if the property exists using PSObject.Properties for robustness
        $prop = $StatsObject.PSObject.Properties[$PropertyName]

        # Check if property exists AND its value is not $null
        if ($null -ne $prop -and $null -ne $prop.Value) {
            # Determine desired target type from DefaultValue for safe casting
            $targetType = $DefaultValue.GetType()
            try {
                 # Attempt conversion to the target type (e.g., int, double)
                 $convertedValue = [System.Convert]::ChangeType($prop.Value, $targetType)
                 Write-Verbose "Get-StatValue: Found property '$PropertyName', value '$($prop.Value)', converted to '$($convertedValue)' ($($targetType.Name))."
                 return $convertedValue
            } catch {
                 # Conversion failed, return default
                 Write-Warning "Get-StatValue: Could not convert property '$PropertyName' value '$($prop.Value)' to type '$($targetType.Name)'. Returning default '$DefaultValue'."
                 return $DefaultValue
            }
        } else {
            # Property doesn't exist or its value is $null, return default
             Write-Verbose "Get-StatValue: Property '$PropertyName' not found or its value is null. Returning default '$DefaultValue'."
            return $DefaultValue
        }
    } catch {
        # Catch any other errors during property access
        Write-Warning "Get-StatValue: Error accessing property '$PropertyName'. Returning default '$DefaultValue'. Error: $($_.Exception.Message)"
        return $DefaultValue
    }
}

if ($PSCmdlet.ParameterSetName -eq 'ShowTags') {
    # --- Logic for -ShowTags (Multi-Level Aware) ---
    Write-Verbose "Mode: ShowTags for file: $FilePath"

    # 1. Get Language Profile (Using the function that returns the new structure)
    $langProfile = Get-ScriptLanguageProfile -ProfileFilePath $FilePath
    if (-not $langProfile) { Write-Error "Could not determine a supported language profile for '$FilePath'."; return }

    # 2. Validate the expected profile structure
    if (-not $langProfile.PSObject.Properties.Name -contains 'TaggingRules' -or -not ($langProfile.TaggingRules -is [hashtable])) {
        Write-Error "The retrieved language profile for '$($langProfile.LanguageName)' is invalid (missing 'TaggingRules' hashtable)."
        return
    }

    Write-Host "`nAvailable Tags for '$($langProfile.LanguageName)' script (`"$FilePath`"):" -ForegroundColor Green

    # 3. Extract All Unique Tag Names from TaggingRules
    $uniqueTagNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $taggingRules = $langProfile.TaggingRules

    # Iterate through each level defined in TaggingRules (e.g., Level1_Structure, Level2_Identity, etc.)
    foreach ($levelKey in $taggingRules.Keys) {
        if ($taggingRules[$levelKey] -is [array]) {
            # Iterate through the rules (each rule is a hashtable @{TagName=...; Pattern=...}) within the level
            foreach ($rule in $taggingRules[$levelKey]) {
                if ($rule -is [hashtable] -and $rule.ContainsKey('TagName') -and -not [string]::IsNullOrWhiteSpace($rule.TagName)) {
                    # Add the TagName to the HashSet (duplicates are automatically handled)
                    $uniqueTagNames.Add($rule.TagName) | Out-Null
                }
            }
        }
    }
    # --- End Extraction ---

    # 4. Sort, Index, and Display
    if ($uniqueTagNames.Count -gt 0) {
        # Sort the unique names alphabetically
        $sortedTagNames = $uniqueTagNames | Sort-Object

        # Create indexed list for display
        $indexedTags = for ($i = 0; $i -lt $sortedTagNames.Count; $i++) {
            [PSCustomObject]@{
                Index = $i + 1
                Tag   = $sortedTagNames[$i]
            }
        }

        # Display using Format-Table
        Write-Host # Blank line for spacing
        $indexedTags | Format-Table -AutoSize

    } else {
        Write-Warning "No tags defined in the TaggingRules for $($langProfile.LanguageName)."
    }
    # --- End -ShowTags Logic ---

}elseif ($PSCmdlet.ParameterSetName -eq 'FilterByTag') {
    # --- Logic for -Tag (Corrected - Uses Select-String) ---
    Write-Verbose "Mode: FilterByTag for file: $FilePath with Tags: $($Tag -join ', ')"

    # 1. Get Language Profile
    $langProfile = $null
    try {
        $langProfile = Get-ScriptLanguageProfile -ProfileFilePath $FilePath
        if (-not $langProfile) { throw "Get-ScriptLanguageProfile returned null." }
        if (-not $langProfile.PSObject.Properties.Name -contains 'TaggingRules' -or -not ($langProfile.TaggingRules -is [hashtable])) { throw "Profile is missing 'TaggingRules' hashtable." }
    } catch { Write-Error "Failed to load or validate language profile: $($_.Exception.Message)"; return }
    Write-Verbose "Using profile for language: $($langProfile.LanguageName)"

    # 2. Extract All Tag Rules into a lookup table (TagName -> Pattern)
    #    Handle potential duplicate TagNames across levels - decide which pattern takes precedence (e.g., first found)
    $tagNameToPatternMap = @{}
    $uniqueTagNamesSetForValidation = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $tagLevels = @('Level1_Structure', 'Level2_Structure', 'Level2_Identity', 'Level3_StructureDetail', 'Level4_Detailed')

    foreach ($levelKey in $tagLevels) {
        if ($langProfile.TaggingRules.ContainsKey($levelKey) -and $langProfile.TaggingRules[$levelKey] -is [array]) {
            foreach ($rule in $langProfile.TaggingRules[$levelKey]) {
                if ($rule -is [hashtable] -and $rule.ContainsKey('TagName') -and -not [string]::IsNullOrWhiteSpace($rule.TagName) -and $rule.ContainsKey('Pattern')) {
                    $tagName = $rule.TagName
                    $uniqueTagNamesSetForValidation.Add($tagName) | Out-Null
                    # Store the pattern, potentially overwriting if tag name repeats (first level checked wins)
                    if (-not $tagNameToPatternMap.ContainsKey($tagName)) {
                        $tagNameToPatternMap[$tagName] = $rule.Pattern
                    }
                }
            }
        }
    }
    $allTagNamesSorted = $uniqueTagNamesSetForValidation | Sort-Object
    # --- End Extraction ---

    # 3. Resolve user-provided tags (index or name)
    $selectedCategories = [System.Collections.Generic.List[string]]::new() # Store resolved TagNames
    $invalidTags = [System.Collections.Generic.List[string]]::new()
    $processedTags = @(); if ($Tag) { $processedTags = $Tag -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 } }

    foreach ($inputTag in $processedTags) {
        $resolvedName = $null
        # Try index
        if ($inputTag -match '^\d+$' -and $allTagNamesSorted -and $allTagNamesSorted.Count -gt 0) {
             $indexNum = 0
             if ([int]::TryParse($inputTag, [ref]$indexNum) -and $indexNum -gt 0 -and $indexNum -le $allTagNamesSorted.Count) {
                 $index = $indexNum - 1; $resolvedName = $allTagNamesSorted[$index]
             }
        }
        # Try name (case-insensitive via HashSet lookup)
        if (-not $resolvedName -and $uniqueTagNamesSetForValidation.Contains($inputTag)) {
             # Find the correctly cased name from the sorted list for consistency
             $resolvedName = $allTagNamesSorted | Where-Object { $_ -eq $inputTag } | Select-Object -First 1
        }

        if ($resolvedName) { if (-not $selectedCategories.Contains($resolvedName)) { $selectedCategories.Add($resolvedName) } }
        else { $invalidTags.Add($inputTag) }
    }

    if ($invalidTags.Count -gt 0) { Write-Warning "Ignoring invalid or unknown tags: $($invalidTags -join ', ')" }
    if ($selectedCategories.Count -eq 0) { Write-Error "No valid tags selected or provided. Use -ShowTags to see available categories."; return }

    Write-Host "Filtering for tags: $($selectedCategories -join ', ')" -ForegroundColor Green
    Write-Host "`n--- Lines Matching Selected Tags ---" -ForegroundColor Yellow

    # 4. Perform Search using Select-String for each selected tag
    $resultsFound = $false
    $esc = $([char]27)
    $highlightColor = "$($esc)[1;30;42m" # Bold White on Green
    $resetColor = "$($esc)[0m"

    foreach ($categoryName in $selectedCategories) {
        # Retrieve the pattern from the map we built
        $pattern = $null
        if ($tagNameToPatternMap.ContainsKey($categoryName)) {
            $pattern = $tagNameToPatternMap[$categoryName]
        }
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            Write-Warning "No pattern defined or found for tag '$categoryName'. Skipping."
            continue
        }



        Write-Verbose "Searching for pattern: $pattern (Tag: $categoryName)"
        try {
            $matchInfos = Select-String -Pattern $pattern -Path $FilePath -CaseSensitive:$false -AllMatches

            if ($matchInfos) {
                $totalIndividualMatches = ($matchInfos | Measure-Object -Sum -Property {$_.Matches.Count}).Sum
                Write-Host "`nTag: $categoryName -> $($totalIndividualMatches) Matches Found" -ForegroundColor Cyan

                # Process matches for highlighting (Trimmed)
                foreach ($matchInfo in $matchInfos) {
                    $lineNumber = $matchInfo.LineNumber; $originalLine = $matchInfo.Line
                    $outputLine = ""; $currentIndex = 0
                    foreach ($match in $matchInfo.Matches) {
                        $fullMatchValue = $match.Value; $trimmedMatchValue = $fullMatchValue.TrimStart()
                        $leadingWhitespaceLength = $fullMatchValue.Length - $trimmedMatchValue.Length
                        $leadingWhitespace = ""; if ($leadingWhitespaceLength -gt 0) { $leadingWhitespace = $fullMatchValue.Substring(0, $leadingWhitespaceLength) }
                        $outputLine += $originalLine.Substring($currentIndex, $match.Index - $currentIndex)
                        $outputLine += $leadingWhitespace
                        $outputLine += "$($highlightColor)$($trimmedMatchValue)$($resetColor)" # Apply highlight
                        $currentIndex = $match.Index + $match.Length
                    }
                    $outputLine += $originalLine.Substring($currentIndex)
                    Write-Host ("[{0}] {1}" -f $lineNumber, $outputLine)
                }
                $resultsFound = $true
            } else { Write-Verbose "No matches found for tag '$categoryName'." }
        } catch { Write-Warning "Error searching for pattern '$pattern' (Tag: $categoryName): $_" }
    }

    if (-not $resultsFound) { Write-Host "No lines found matching any of the selected tags." -ForegroundColor Yellow }
    # --- End Search ---
    # --- End -Tag Logic ---
}elseif ($PSCmdlet.ParameterSetName -eq 'RawOutline') {
    # --- Logic for -Raw mode ---
    # Determine mode based on $RawModeDetail
    $modeToShow = 'TopLevel' # Default
    if ($PSBoundParameters.ContainsKey('RawModeDetail') -and $RawModeDetail -eq 'Full') {
        $modeToShow = 'Full'
    }

    Write-Verbose "Mode: Raw Outline for file: $FilePath (Detail: $modeToShow)"
    Write-Verbose "Getting '$modeToShow' code lines..."

    # Pass the determined $modeToShow variable to Get-CodeLines
    $codeLineObjects = Get-CodeLines -FilePath $FilePath -Mode $modeToShow
    if ($null -eq $codeLineObjects) { Write-Error "Failed to get code lines from '$FilePath'."; return }

    # --- UPDATED: Conditional Header ---
    if ($modeToShow -eq 'Full') {
         Write-Host "`n--- Full Code Content (Raw) ---" -ForegroundColor Cyan
    } else {
         Write-Host "`n--- Raw TopLevel Outline ---" -ForegroundColor Cyan
    }
    # --- END UPDATE ---

    if ($codeLineObjects.Count -gt 0) {
         $codeLineObjects | ForEach-Object { "[L:{0}] {1}" -f $_.LineNumber, $_.Content }
    } else {
         # Update message dynamically based on mode
         Write-Host "(No '$modeToShow' code lines were found by Get-CodeLines)"
    }
}elseif($PSCmdlet.ParameterSetName -in 'Analyze', 'FullAnalysis') {

    $codeLinesMode = if ($Full) { 'Full' } else { 'TopLevel' }    
    # --- Analyze Logic (Top-Level Multi-Level Tags & Report) ---
    Write-Verbose "Mode: Analyze file: $FilePath (Top-Level Multi-Level Tags & Report)"

    # 1. Get Language Profile
    $langProfile = Get-ScriptLanguageProfile -ProfileFilePath $FilePath
    if (-not $langProfile) { Write-Error "Could not determine a supported language profile for '$FilePath'."; return }
    Write-Host "Detected Language: $($langProfile.LanguageName)" -ForegroundColor Green
 

    $sectionData = $null
    $fileInfo = Get-Item -LiteralPath $FilePath # Get file info for path and time
    $sectionDataPath = $null
    $cacheDir = $null
    try {
        $scriptRoot = $PSScriptRoot; if (-not $scriptRoot) { throw "Could not determine script root directory (`$PSScriptRoot)." }
        $cacheDir = Join-Path -Path $scriptRoot -ChildPath '.breakitdown_cache' # Cache subdir name

        # Ensure cache directory exists
        if (-not (Test-Path -Path $cacheDir -PathType Container)) {
            Write-Verbose "Creating cache directory: $cacheDir"
            New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
        }

        # Create unique cache filename from hash of full file path
        $resolvedFilePath = $fileInfo.FullName
        $sha256 = [System.Security.Cryptography.SHA256Managed]::new()
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedFilePath)
        $hashBytes = $sha256.ComputeHash($utf8Bytes)
        $fileHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
        $sha256.Dispose() # Dispose crypto object

        $sectionDataPath = Join-Path -Path $cacheDir -ChildPath "$($fileHash).section.json"
        Write-Verbose "Using cache file path: $sectionDataPath"

    } catch {
        Write-Warning "Failed to determine or create cache path: $($_.Exception.Message). Caching disabled for this run."
        # Continue without caching if path fails
    }
    # --- End Cache Path Determination ---
 
     # Cache miss or invalid cache: Generate data
     if ($null -eq $sectionData) {
         Write-Verbose "Generating section data..."
         # --- Recalculate extension here ---
         $extension = $fileInfo.Extension.ToLower()
         switch ($extension) { # Now uses the correct extension
             { $_ -in '.ps1', '.psm1', '.psd1' } {
                 # Call internal PowerShell AST parser function
                 try { $sectionData = Get-ScriptSectionData -FilePath $FilePath }
                 catch { Write-Warning "Failed to generate section data using Get-ScriptSectionData: $_"; $sectionData = @() }
             }
             '.py' {
                 Write-Warning "Python section parsing not yet implemented. Skipping section data generation."
                 $sectionData = @()
             }
             # Add cases for other languages here
             default {
                 # This warning should now show the correct extension if it's unsupported
                 Write-Warning "Section data generation not supported for extension '$extension'."
                 $sectionData = @()
             }
         }
         # Save to cache if data was generated
         if ($null -ne $sectionData) {
              # ... (saving logic remains the same) ...
              Write-Verbose "Saving $($sectionData.Count) sections to cache: $sectionDataPath"; try { $sectionData | ConvertTo-Json -Depth 5 | Out-File -FilePath $sectionDataPath -Encoding UTF8 -Force } catch { Write-Warning "Failed to save section data to cache file '$sectionDataPath': $_" }
         }
     }
     # --- End Section Data Handling ---



     # 2. Get Code Lines (Mode depends on parameter set)
    Write-Verbose "Getting code lines with mode: $codeLinesMode..."
    # Rename variable: $topLevelCodeLineObjects -> $codeLineObjects
    $codeLineObjects = Get-CodeLines -FilePath $FilePath -Mode $codeLinesMode
    if ($null -eq $codeLineObjects) { Write-Error "Failed to get $codeLinesMode code lines from '$FilePath'."; return }
    Write-Verbose "Retrieved $($codeLineObjects.Count) code line objects."
    
     # 3. Get Total Original Line Count
     try { $totalOriginalLines = (Get-Content -Path $FilePath -ReadCount 0).Count; Write-Verbose "Total original lines in file: $totalOriginalLines" }
     catch { $totalOriginalLines = -1; Write-Warning "Could not get total original line count for '$FilePath': $_" }
  
     $linesForOutlineAndReport = $null # Will hold the output of Get-EffectiveLinePhases
     $phaseSpansForReport = $null  

     # Proceed only if top-level lines exist
     if ($codeLineObjects.Count -gt 0) {
            # --- 5. Add Multi-Level Tags to Top-Level Lines ---
        Write-Verbose "Adding multi-level tags to top-level code lines..."
        $taggedLinesWithRulePhase = Add-MultiLevelTags -CodeLineObjects $codeLineObjects -LanguageProfile $langProfile # MODIFIED VARIABLE NAME
        if (-not $taggedLinesWithRulePhase) { Write-Warning "Failed to add multi-level tags to lines."; $taggedLinesWithRulePhase = @() }
        # --- END Add Tags ---
        # --- NEW STEP: Determine Effective Line Phases ---
        Write-Verbose "Determining effective line phases..."
        $linesForOutlineAndReport = Get-EffectiveLinePhases -TaggedCodeLines $taggedLinesWithRulePhase -SectionData $sectionData -DefaultInitialRootPhase "Execution" # Or your preferred default
        if (-not $linesForOutlineAndReport) {
            Write-Warning "Failed to determine effective line phases."
            $linesForOutlineAndReport = @() # Ensure it's an empty array if failed
        }
         # --- NEW STEP: Calculate Phase Spans using the NEW Get-PhaseSpans ---
        Write-Verbose "Calculating phase spans with new generic function..."
        $phaseSpansForReport = Get-PhaseSpans -LinesWithFinalPhase $linesForOutlineAndReport -TotalOriginalLines $totalOriginalLines
        if (-not $phaseSpansForReport) {
            Write-Warning "Failed to calculate phase spans with new function."
            $phaseSpansForReport = @() # Ensure it's an empty array if failed
        }
    # --- Outline Title --- (Keep this as is)
        $outlineTitleDetail = if ($codeLinesMode -eq 'Full') { 'Full Code & Phase' } else { 'Top-Level Tags & Phase' }
        $titleFgColor = "$($esc)[93m" # Bright Yellow
        Write-Host ($titleFgColor + "`n--- Breakitdown Code Outline ($outlineTitleDetail) ---" + $resetColor)
    # --- Initialize variables ONLY needed for DISPLAY loop --- (Adjustments needed here)
        $previousLinePhase_ForDisplay = 'None' # This is fine
        # $currentSpanIndex = 0 # NO LONGER NEEDED for determining phase per line
        # $currentSpan = $null  # NO LONGER NEEDED for determining phase per line
        $esc = $([char]0x1b); # Keep your color definitions
        # Define $phaseColorMap as suggested previously, e.g.:
        $resetColor = "$($esc)[0m"
        $setupColor = "$($esc)[7;30;46m"
        $executionColor = "$($esc)[32;40m" # Green FG (uses default BG) - If you want a BG: "$($esc)[32;40m" (Green FG on Black BG)
        $categoryColor = "$($esc)[90m"    # Bright Black/Gray FG (uses default BG)
        $neutralColor = "$($esc)[90m"     # Same as category for Neutral phase
        $phaseUndeterminedColor = "$($esc)[35m" # Magenta FG for PhaseUndetermined (uses default BG)
        $undefinedDisplayColor = "$($esc)[35m"  # For display fallback if FinalPhaseName is null

        $phaseColorMap = @{
            "Setup"             = $setupColor
            "Execution"         = $executionColor
            "Neutral"           = $neutralColor
            "PhaseUndetermined" = $phaseUndeterminedColor
            "Undefined"         = $undefinedDisplayColor
        }
        $defaultPhaseColor = $resetColor

        # Dynamically calculate phasePrefixWidth based on actual FinalPhaseName values
        $uniquePhaseNames = $linesForOutlineAndReport.FinalPhaseName | Where-Object { -not [string]::IsNullOrEmpty($_) } | Get-Unique
        if ($uniquePhaseNames) {
            $phasePrefixWidth = ($uniquePhaseNames | ForEach-Object { "$_ -> " } | Measure-Object -Property Length -Maximum).Maximum
        } else {
            $phasePrefixWidth = "Execution -> ".Length # Fallback
        }
        
        $singleCommentMarker = $null; $escapedCommentMarker = $null # Keep this
        if ($langProfile.CommentProfile -and $langProfile.CommentProfile.ContainsKey('Single')) { $singleCommentMarker = $langProfile.CommentProfile.Single; if (-not [string]::IsNullOrEmpty($singleCommentMarker)) { $escapedCommentMarker = [regex]::Escape($singleCommentMarker) } }

        $regionSections = $sectionData | Where-Object { $_.Type -eq 'Region' } | Sort-Object StartLine # Keep
        $currentRegionIndex = 0 # Keep
        $regionStack = [System.Collections.Generic.Stack[object]]::new() # Keep
        Write-Verbose "Prepared $($regionSections.Count) region sections for header processing." # Keep

    #     # --- 6. Process and Print Tagged Top-Level Lines ---
        # CHANGE: Loop through $linesForOutlineAndReport
        foreach ($lineObj in $linesForOutlineAndReport) {
            $lineNumber = $lineObj.LineNumber      # Keep
            $originalContent = $lineObj.Content  # Keep
        
            # --- Region Boundaries Check ---
            # Check if we've passed the end of any active regions
            while ($regionStack.Count -gt 0 -and $lineNumber -gt $regionStack.Peek().EndLine) {
                $endedRegion = $regionStack.Pop()
                Write-Verbose "Line $lineNumber passed end of region '$($endedRegion.Name)' (L:$($endedRegion.StartLine)-L:$($endedRegion.EndLine)). Stack depth: $($regionStack.Count)."
                # Optional: Print a closing separator here if desired
            }
        
            # Store indent *before* checking for new region start (used for header indent)
            $headerIndent = "  " * $regionStack.Count # Use spaces for indent
        
            # Check if this line number enters any new region(s)
            while ($currentRegionIndex -lt $regionSections.Count -and $lineNumber -ge $regionSections[$currentRegionIndex].StartLine) {
                $potentialRegion = $regionSections[$currentRegionIndex]
                # Check if the line is actually WITHIN this region's bounds
                if ($lineNumber -le $potentialRegion.EndLine) {
                    # Check if it's NEWLY active (not already the top of the stack)
                    if ($regionStack.Count -eq 0 -or $regionStack.Peek() -ne $potentialRegion) {
                        # Write-Host "" # Optional blank line before header
                        $regionColor = "$($esc)[90m" # Dark Gray (Bright Black) foreground
                        Write-Host ($headerIndent + $regionColor + "--- Region: $($potentialRegion.Name) (L:$($potentialRegion.StartLine)-L:$($potentialRegion.EndLine)) ---" + $resetColor)
                        $regionStack.Push($potentialRegion)
                        Write-Verbose "Line $lineNumber entered region '$($potentialRegion.Name)'. Stack depth: $($regionStack.Count)."
                    }
                    # Stop checking further regions *for this specific line number*
                    break
                } else {
                    # Line is past this region entirely (skipped region)
                    Write-Verbose "Line $lineNumber is past skipped region '$($potentialRegion.Name)' (L:$($potentialRegion.StartLine)-L:$($potentialRegion.EndLine))."
                    $currentRegionIndex++ # Advance past the skipped region
                }
            }
            # --- End Region Boundaries Check ---
        
            # --- Calculate current indent level for the code line ---
            $indent = "" * $regionStack.Count # Use spaces for indent
        
            # # --- Find the Phase Span for the current line ---
            # # Advance span index if current line is past the currently tracked span's end
            # while ($currentSpanIndex -lt $phaseSpans.Count -and `
            #         $lineNumber -gt $phaseSpans[$currentSpanIndex].EndLine) {
            #     $currentSpanIndex++
            #     $currentSpan = $null # Reset active span pointer
            # }
            # # Assign the current span if we haven't already or if index advanced
            # if ($null -eq $currentSpan -and $currentSpanIndex -lt $phaseSpans.Count) {
            #     # Check if line number falls within this span's range
            #     if ($lineNumber -ge $phaseSpans[$currentSpanIndex].StartLine) {
            #             $currentSpan = $phaseSpans[$currentSpanIndex]
            #             # Optional: Add verbose message for debugging span changes
            #             # Write-Verbose "L:$lineNumber using Phase Span: $($currentSpan.PhaseName) x$($currentSpan.Occurrence) (L:$($currentSpan.StartLine)-L:$($currentSpan.EndLine))"
            #         }
            #     }
            # # Determine phase for display based on the found span (default if somehow outside all spans)
            $currentLinePhase = $lineObj.FinalPhaseName
            # Handle potential null/empty FinalPhaseName for display purposes, though Get-EffectiveLinePhases should populate it
            if ([string]::IsNullOrEmpty($currentLinePhase)) {
                $currentLinePhase = "Undefined" # Display fallback
            }
            # # --- End Find Phase Span ---
        
            # --- Get Tags & Filter Lines ---
            $l1Tag = $lineObj.L1StructTag
            # $l3Tag = $lineObj.L3StructTag
            # $l4Tag = $lineObj.L4DetailTag
        
            # Filter lines you don't want to display (e.g., SyntaxMarks, Logging)
            if ($l1Tag -eq 'SyntaxMarks') { # Removed 'Logging' filter here, as "Neutral" phase handles it. Adjust if needed.
              continue
          }
            # --- End Filter Lines ---
        
            # --- Format Line for Display ---
            # Strip inline comment
            $contentToPrint = $originalContent
            if ($null -ne $escapedCommentMarker) { try { $parts = $contentToPrint -split $escapedCommentMarker, 2; $contentToPrint = $parts[0].TrimEnd() } catch {} }
        
            # Determine Phase Prefix using $currentLinePhase
            $prefix = ""
            if ($previousLinePhase_ForDisplay -ne $currentLinePhase) { # Phase changed from last displayed line
                $prefix = ("$($currentLinePhase) -> ").PadRight($phasePrefixWidth)
            } else {
                $prefix = (" " * $phasePrefixWidth)
            }
            # Determine Line Color using $currentLinePhase
            $lineColor = $phaseColorMap[$currentLinePhase]
            if (-not $lineColor) { $lineColor = $defaultPhaseColor } 
            
            $l4Tag = $lineObj.L4DetailTag

            # Get annotation (L4 tag)
            $tagsToShow = @($l4Tag) | Where-Object { $null -ne $_ -and $_ -ne 'None' }
            $annotation = ""; if ($tagsToShow.Count -gt 0) { $annotation = "($($tagsToShow -join '/'))" }
            # Build colored content and annotation parts
            $coloredLineContent = "$($lineColor)$('[L:{0}] {1}' -f $lineNumber, $contentToPrint)$($resetColor)"
            $coloredAnnotation = ""; if (-not [string]::IsNullOrWhiteSpace($annotation)) { $coloredAnnotation = " $($categoryColor)$($annotation)$($resetColor)" }
        
            $lineTextPart = "$($lineColor)$('[L:{0}] {1}' -f $lineNumber, $contentToPrint)$($resetColor)"

            $annotationString = ""
            if (-not [string]::IsNullOrWhiteSpace($annotation)) {
                # The space before annotation should now reliably get default background due to $resetColor from $lineTextPart
                $annotationString = " $($categoryColor)$($annotation)$($resetColor)"
                # If space STILL has issues, try forcing default BG for the space:
                # $annotationString = "$($esc)[49m $($categoryColor)$($annotation)$($resetColor)"
            }
            # Print the final formatted line
            Write-Host ($indent + $prefix + $coloredLineContent + $coloredAnnotation)

            # --- End Format Line ---
        
            # --- Update previous phase *for display purposes* ---
            # This tracks the phase of the *last displayed line* for the next prefix calculation
            $previousLinePhase_ForDisplay = $currentLinePhase
        
        } # --- End foreach ($lineObj in $taggedLines) ---
        
        # --- Check for any remaining unclosed regions at the end ---
        if ($regionStack.Count -gt 0) {
            Write-Warning "Processing finished, but $($regionStack.Count) region(s) seem unclosed on the stack."
            # You could optionally print closing markers here based on the stack content
        }

     } else {
        Write-Host "No code lines found or extracted from '$FilePath' using mode '$codeLinesMode'." -ForegroundColor Yellow
        $linesForOutlineAndReport = @() 
        $phaseSpansForReport = @()
     }
     # --- End main IF block for processing ---

      # --- 7. Get and Display Structured Report ---
    Write-Host "`n--- Breakitdown Report ---" -ForegroundColor Yellow
    $commentStats = $null
    try {
        # Attempt to get the statistics
        $commentStats = Get-CommentInfo -FilePath $FilePath
    } catch {
        # Catch errors during the Get-CommentInfo call itself
        Write-Warning "Could not get detailed statistics from Get-CommentInfo: $_"
        # $commentStats will remain $null
    }

    # Initialize the ordered dictionary for the report
    $finalReport = [ordered]@{}

    # Check if Get-CommentInfo returned a valid object
    if ($commentStats) {
        Write-Verbose "Formatting report from Get-CommentInfo statistics."

        # --- Safely extract numeric values from $commentStats, defaulting to 0 ---
        # Use individual try/catch for each potentially missing/null property access
        $s_lines = 0; try { $s_lines = [int]$commentStats.SingleLineComments } catch { Write-Verbose "Stat missing: SingleLineComments" }
        $m_lines = 0; try { $m_lines = [int]$commentStats.MultiLineCommentLines } catch { Write-Verbose "Stat missing: MultiLineCommentLines" }
        $i_lines = 0; try { $i_lines = [int]$commentStats.InlineComments } catch { Write-Verbose "Stat missing: InlineComments" }
        $regions = 0; try { $regions = [int]$commentStats.RegionCount } catch { Write-Verbose "Stat missing: RegionCount" }
        $code_chars = 0; try { $code_chars = [int]$commentStats.TotalCodeChars } catch { Write-Verbose "Stat missing: TotalCodeChars" }
        $cmt_chars = 0; try { $cmt_chars = [int]$commentStats.TotalCommentChars } catch { Write-Verbose "Stat missing: TotalCommentChars" }
        $cmt_line_pct = 0.0; try { $cmt_line_pct = [double]$commentStats.CommentLinePercentage } catch { Write-Verbose "Stat missing: CommentLinePercentage" }
        $cmt_char_pct = 0.0; try { $cmt_char_pct = [double]$commentStats.CommentCharPercentage } catch { Write-Verbose "Stat missing: CommentCharPercentage" }
        $code_lines_est = 0; try { $code_lines_est = [int]$commentStats.CodeLines } catch { Write-Verbose "Stat missing: CodeLines" }
        $blank_lines = 0; try { $blank_lines = [int]$commentStats.BlankLines } catch { Write-Verbose "Stat missing: BlankLines" }
        $total_lines = 0; try { $total_lines = [int]$commentStats.TotalLines } catch { Write-Verbose "Stat missing: TotalLines" } # Get total lines safely too

        # --- Populate Report Fields ---
        # Assume FilePath and LanguageProfile are generally safe if $commentStats exists
        $finalReport['FilePath'] = $commentStats.FilePath
        $finalReport['LanguageProfile'] = $commentStats.LanguageProfile
        $finalReport['Total Lines'] = $total_lines

        # Use safely extracted values
        $finalReport['Code Lines (Est.)'] = $code_lines_est
        $finalReport['Comment Lines (Total)'] = $s_lines + $m_lines + $i_lines
        $finalReport['Comment Breakdown'] = "B:{0}/S:{1}/I:{2}" -f $m_lines, $s_lines, $i_lines
        $finalReport['Blank Lines'] = $blank_lines
        $finalReport['Region Count'] = $regions
        $finalReport['Code Chars (Trimmed)'] = $code_chars.ToString("N0") # Format as number with commas
        $finalReport['Comment Chars (Trimmed)'] = $cmt_chars.ToString("N0") # Format as number with commas

        # Calculate relevant token estimates safely
        $codeTokenEst = [Math]::Round($code_chars / 4)
        $commentTokenEst = [Math]::Round($cmt_chars / 4)
        $finalReport['Est. Tokens (Code/Comment)'] = "{0}/{1}" -f $codeTokenEst.ToString("N0"), $commentTokenEst.ToString("N0")

        # Format percentages safely (e.g., "15.2%")
        $finalReport['Comment Line %'] = "{0:N1}%" -f $cmt_line_pct
        $finalReport['Comment Char %'] = "{0:N1}%" -f $cmt_char_pct

    } else {
        # Handle case where Get-CommentInfo failed or returned null/empty
        Write-Warning "Detailed comment statistics could not be retrieved or were empty."
        # Add file path if available
        if ($FilePath) { $finalReport['FilePath'] = $FilePath }
        # Add total lines calculated earlier if it exists and is valid
        # Note: $totalOriginalLines was calculated much earlier. Check if it exists.
        # A safer way might be to just recalculate it here if needed.
        if ($PSBoundParameters.ContainsKey('totalOriginalLines') -and $totalOriginalLines -ge 0) {
             $finalReport['Total Lines'] = $totalOriginalLines
        } elseif (Test-Path -LiteralPath $FilePath -PathType Leaf) {
             # Fallback: Try getting total lines now
             try {
                 $lineCount = (Get-Content -LiteralPath $FilePath -ReadCount 0).Count
                 $finalReport['Total Lines'] = $lineCount
                 Write-Verbose "Calculated Total Lines as $lineCount during fallback."
            } catch {
                 Write-Warning "Could not determine total lines for fallback report."
            }
        } else {
             $finalReport['Total Lines'] = "Unknown"
        }
        $finalReport['Comment Stats'] = "Unavailable"
    }

    # --- Phase Spans Section ---
    # --- Refactored Phase Spans Section in the Report ---
    if ($phaseSpansForReport -and $phaseSpansForReport.Count -gt 0) { # Check $phaseSpans exists and is not empty
        $finalReport['--- Phase Spans ---'] = "" # Add separator key

        # Prepare total lines for percentage calculation, ensure it's not zero
        $totalLinesForPercent = 1 
        if ($totalOriginalLines -gt 0) {
            $totalLinesForPercent = $totalOriginalLines
        } elseif ($commentStats -and $commentStats.TotalLines -gt 0) { # Fallback
            $totalLinesForPercent = $commentStats.TotalLines
        }
        Write-Verbose "Using $totalLinesForPercent total lines for phase span percentage calculation."

        # Determine if any phase repeats to decide whether to show "xN"
        $maxOccurrence = ($phaseSpansForReport | Measure-Object -Property Occurrence -Maximum).Maximum
        $showOccurrence = $maxOccurrence -gt 1

        # --- Iterate through calculated spans and add to report ---
        foreach ($spanInfo in $phaseSpansForReport) { # Iterate through the new span objects
        $occurrenceSuffix = ""
        if ($showOccurrence) {
            $occurrenceSuffix = " x$($spanInfo.Occurrence)"
        }
        # $spanInfo.PhaseName will now contain your dynamic phase names ("Setup", "Execution", "Init", etc.)
        $phaseKey = "{0}{1}" -f $spanInfo.PhaseName, $occurrenceSuffix

        $percentage = ($spanInfo.SpanCount / $totalLinesForPercent) * 100
        
        $spanValue = "L:{0}-{1} ({2} lines, {3:N1} %)" -f `
            $spanInfo.StartLine, `
            $spanInfo.EndLine, `
            $spanInfo.SpanCount, `
            $percentage
        
        $finalReport[$phaseKey] = $spanValue
    }
} else {
    $finalReport['Phase Spans'] = "Not calculated (no processable code lines found or no phase transitions)."
}
    # --- End Refactored Phase Spans Section ---

    # --- Output the Final Report ---
    $finalReport | Format-Table

}elseif ($PSCmdlet.ParameterSetName -eq 'ExportJson') {
    # Determine mode based on the OPTIONAL -Full switch
    $codeLinesMode = if ($Full) { 'Full' } else { 'TopLevel' }
    Write-Verbose "Mode: ExportJson file: $FilePath (Using CodeLines Mode: $codeLinesMode)"

    # Get Language Profile, Section Data, Total Lines
    $langProfile = Get-ScriptLanguageProfile -ProfileFilePath $FilePath
     if (-not $langProfile) { Write-Error "Could not determine a supported language profile for '$FilePath'."; return }
     Write-Host "Detected Language: $($langProfile.LanguageName)" -ForegroundColor Green
    try { $sectionData = Get-ScriptSectionData -FilePath $FilePath } catch { }
    try { $totalOriginalLines = (Get-Content -Path $FilePath -ReadCount 0).Count } catch { Write-Error "Failed to get total line count for '$FilePath': $($_.Exception.Message)" }

    # Get Code Lines & Tags
    $codeLineObjects = Get-CodeLines -FilePath $FilePath -Mode $codeLinesMode
    if ($null -eq $codeLineObjects) { #... error handling ... }
    }
    $taggedLines = Add-MultiLevelTags -CodeLineObjects $codeLineObjects -LanguageProfile $langProfile
    if (-not $taggedLines) { $taggedLines = @() }

    # Get Phase Spans
    $phaseSpans = Get-PhaseSpans -TaggedCodeLines $taggedLines `
                                  -SectionData $sectionData `
                                  -TotalOriginalLines $totalOriginalLines

    # Get Comment Stats
    $commentStats = $null
    try { $commentStats = Get-CommentInfo -FilePath $FilePath } catch { Write-Warning "Failed to get comment info: $($_.Exception.Message)" }

    # --- 2. Build the Output Object Structure ---
    Write-Verbose "Building JSON output object..."

    # a) Metadata
    $metadata = @{
        sourceFilePath    = $FilePath
        analysisMode      = $codeLinesMode
        languageProfile   = $langProfile.LanguageName
        analysisTimestamp = (Get-Date).ToUniversalTime().ToString("o")
        # toolVersion     = "YourToolVersion" # Optional
    }

    # b) Statistics (Safely extract from $commentStats, default to 0/null/appropriate value)
    $statistics = [ordered]@{}
    Write-Verbose "Building statistics section..."
    # Use helper function Get-StatValue defined in the module
    $stats_total_lines      = Get-StatValue -StatsObject $commentStats -PropertyName 'TotalLines' -DefaultValue 0
    $statistics['totalLines']            = $stats_total_lines # Store for later use
    $statistics['codeLinesEst']          = Get-StatValue -StatsObject $commentStats -PropertyName 'CodeLines' -DefaultValue 0
    $stats_m_lines                       = Get-StatValue -StatsObject $commentStats -PropertyName 'MultiLineCommentLines' -DefaultValue 0
    $stats_s_lines                       = Get-StatValue -StatsObject $commentStats -PropertyName 'SingleLineComments' -DefaultValue 0
    $stats_i_lines                       = Get-StatValue -StatsObject $commentStats -PropertyName 'InlineComments' -DefaultValue 0
    $statistics['commentLinesBlock']     = $stats_m_lines
    $statistics['commentLinesSingle']    = $stats_s_lines
    $statistics['commentLinesInline']    = $stats_i_lines
    $statistics['commentLinesTotal']     = $stats_m_lines + $stats_s_lines + $stats_i_lines # Calculated
    $statistics['blankLines']            = Get-StatValue -StatsObject $commentStats -PropertyName 'BlankLines' -DefaultValue 0
    $statistics['regionCount']           = Get-StatValue -StatsObject $commentStats -PropertyName 'RegionCount' -DefaultValue 0
    $stats_code_chars                    = Get-StatValue -StatsObject $commentStats -PropertyName 'TotalCodeChars' -DefaultValue 0
    $stats_cmt_chars                     = Get-StatValue -StatsObject $commentStats -PropertyName 'TotalCommentChars' -DefaultValue 0
    $statistics['codeCharsTrimmed']      = $stats_code_chars
    $statistics['commentCharsTrimmed']   = $stats_cmt_chars
    $statistics['estTokensCode']         = [Math]::Round($stats_code_chars / 4)
    $statistics['estTokensComment']      = [Math]::Round($stats_cmt_chars / 4)
    $statistics['commentLinePercent']    = Get-StatValue -StatsObject $commentStats -PropertyName 'CommentLinePercentage' -DefaultValue 0.0
    $statistics['commentCharPercent']    = Get-StatValue -StatsObject $commentStats -PropertyName 'CommentCharPercentage' -DefaultValue 0.0


    # c) Sections (Already have $sectionData)
    $sections = if ($sectionData -is [array]) { $sectionData } else { @() }

    # d) Phase Spans (Already have $phaseSpans, ensure numeric values)
    $finalPhaseSpans = @() # Initialize as empty array
    if ($phaseSpans -is [array] -and $phaseSpans.Count -gt 0) {
         # Calculate total lines for percentage denominator safely
         $totalLinesForPercent = 1; # Default to 1 to avoid division by zero
         if ($statistics.totalLines -gt 0) {$totalLinesForPercent = $statistics.totalLines}
         Write-Verbose "Adding percentage to phase spans using $totalLinesForPercent total lines."

         # --- FIX: Use Select-Object with a Calculated Property ---
         try {
             $finalPhaseSpans = $phaseSpans | Select-Object -Property *, @{
                 Name       = 'percentage'
                 Expression = {
                     # Ensure SpanCount is treated as numeric and handle potential division by zero
                     $spanCountNum = 0; $null -ne $_.SpanCount -and [int]::TryParse($_.SpanCount, [ref]$spanCountNum) | Out-Null
                     if ($totalLinesForPercent -eq 0) { return 0.0 } # Avoid division by zero
                     return [Math]::Round((($spanCountNum / $totalLinesForPercent) * 100), 1) # Calculate and round
                 }
             }
             # Verify result (Select can sometimes return null on error)
             if ($null -eq $finalPhaseSpans -and $phaseSpans.Count -gt 0) {
                  Write-Warning "Select-Object operation for phase span percentage failed. Percentages will be missing."
                  $finalPhaseSpans = $phaseSpans # Fallback to original spans
             } elseif ($null -eq $finalPhaseSpans) {
                  $finalPhaseSpans = @() # Ensure empty array if Select failed on empty input
             }
         } catch {
              Write-Warning "Error calculating phase span percentages: $_. Using original spans without percentages."
              $finalPhaseSpans = $phaseSpans # Fallback to original spans in case of error
         }
         # --- END FIX ---

    } else {
         Write-Verbose "No phase spans found or `$phaseSpans is not an array."
         $finalPhaseSpans = @() # Ensure it's an empty array
    }

    # e) Code Lines (Requires iterating $taggedLines again to add context)
    $processedLinesList = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "Building detailed code line list (processing $($taggedLines.count) lines)..."
    # Prepare for lookups inside loop
    $currentSpanIndex_Json = 0
    $currentSpan_Json = $null
    $regionStack_Json = [System.Collections.Generic.Stack[object]]::new()
    $currentRegionIndex_Json = 0
    # Ensure $sections is used here, not raw $sectionData if it wasn't array
    $regionSections_Json = $sections | Where-Object { $_.Type -eq 'Region' } | Sort-Object StartLine # Need regions again

    foreach ($lineObj in $taggedLines) {
         $lineNum = $lineObj.LineNumber

         # Update Region Stack for this line (simplified logic needed here)
         while ($regionStack_Json.Count -gt 0 -and $lineNum -gt $regionStack_Json.Peek().EndLine){ $regionStack_Json.Pop() | Out-Null}
         while ($currentRegionIndex_Json -lt $regionSections_Json.Count -and $lineNum -ge $regionSections_Json[$currentRegionIndex_Json].StartLine){
              if ($lineNum -le $regionSections_Json[$currentRegionIndex_Json].EndLine){
                 if($regionStack_Json.Count -eq 0 -or $regionStack_Json.Peek() -ne $regionSections_Json[$currentRegionIndex_Json]){
                    $regionStack_Json.Push($regionSections_Json[$currentRegionIndex_Json])
                 }
                 break
              } else { $currentRegionIndex_Json++ }
         }
         $activeRegionNames = $regionStack_Json | ForEach-Object {$_.Name} # Get names from stack

         # Find Phase for this line (lookup in $phaseSpans)
         while ($currentSpanIndex_Json -lt $phaseSpans.Count -and $lineNum -gt $phaseSpans[$currentSpanIndex_Json].EndLine) { $currentSpanIndex_Json++; $currentSpan_Json = $null }
         if ($null -eq $currentSpan_Json -and $currentSpanIndex_Json -lt $phaseSpans.Count) { if ($lineNum -ge $phaseSpans[$currentSpanIndex_Json].StartLine) { $currentSpan_Json = $phaseSpans[$currentSpanIndex_Json] } }
         $linePhase = if ($null -eq $currentSpan_Json) { $currentSpan_Json.PhaseName } else { 'Execution' } # Default

         # Add processed line details
         $processedLinesList.Add([PSCustomObject]@{
            lineNumber = $lineNum
            content    = $lineObj.Content # Or a cleaned version
            phase      = $linePhase
            regionStack= $activeRegionNames # Array of names
            tags       = @{ # Structure the tags clearly
                l1Struct = $lineObj.L1StructTag
                l2Struct = $lineObj.L2StructTag
                l2Id     = $lineObj.L2IdTag
                l3Struct = $lineObj.L3StructTag
                l4Detail = $lineObj.L4DetailTag
             }
         })
    }

    # f) Assemble final object
    $outputObject = [PSCustomObject]@{
        metadata   = $metadata
        statistics = $statistics
        sections   = $sectionData # Use the original section data
        phaseSpans = $phaseSpans # Use the calculated spans
        codeLines  = $processedLinesList
    }

    # --- 3. Convert and Output/Save ---
    Write-Verbose "Converting final object to JSON..."
    $outputJson = $outputObject | ConvertTo-Json -Depth 10 # Adjust depth as needed

    if ($PSBoundParameters.ContainsKey('OutputPath') -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
        Write-Verbose "Writing JSON to file: $OutputPath"
        try {
            $outputJson | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
            Write-Host "JSON output successfully written to $OutputPath" -ForegroundColor Green
        } catch {
            Write-Error "Failed to write JSON to '$OutputPath': $_"
        }
    } else {
        # Write JSON directly to the pipeline (standard output)
        Write-Output $outputJson
    }
}else {
     Write-Error "Invalid parameter set specified."
}