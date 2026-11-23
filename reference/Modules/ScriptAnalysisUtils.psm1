function Get-ScriptLanguageProfile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$false)]
        [string]$ProfileFilePath
    )

    # Validate file existence
    if (-not (Test-Path -Path $ProfileFilePath -PathType Leaf)) {
        Write-Error "File not found: $ProfileFilePath"
        return $null
    }

    # Get the file extension
    $extension = [System.IO.Path]::GetExtension($ProfileFilePath).ToLower()

    # Define profiles based on the extension
    $languageProfile = $null
    switch ($extension) {
        '.ps1' {
            # --- Programmatic Definition for PowerShell Multi-Level Profile ---
            Write-Verbose "DEBUG: Building PowerShell multi-level profile..."
            $languageProfile = @{ LanguageName = "PowerShell" }
            $taggingRules = @{}

            # Define Comment Profile for filtering within tagger
            $languageProfile['CommentProfile'] = @{
                Single = '#'
                MultiStart = '<#'; MultiEnd = '#>'
            }

            # --- Define Tagging Rules ---
            # Level 1: Basic line structure
            $taggingRules['Level1_Structure'] = @(
                @{ TagName = 'SyntaxMarks'; Pattern = '^\s*[\{\}\(\);]+\s*(#.*)?$'; AssignedPhase = "Neutral" }
                # Default 'Code' handled in tagging function
            )

            # Level 2: Code structure
            $taggingRules['Level2_Structure'] = @(
                @{ TagName = 'block'; Pattern = '[\{\(\:]\s*(#.*)?$' } # Ends with {, (, : before optional comment
                # @{ TagName = 'multi-steps'; Pattern = ';(?=...)' } # Placeholder
                # Default 'step' handled in tagging function
            )

            # Level 2: Code Identity
            $l2Keywords = @('if', 'elseif', 'else', 'switch', 'for', 'foreach', 'while', 'do', 'try', 'catch', 'finally', 'trap', 'function', 'class', 'enum', 'param', 'begin', 'process', 'end', 'dynamicparam', 'using', 'return', 'break', 'continue')
            $taggingRules['Level2_Identity'] = @(
                @{ TagName = 'SysLogic'; Pattern = "(?i)^\s*($($l2Keywords | ForEach-Object {[regex]::Escape($_)} | Join-String -Separator '|'))\b" }
                @{ TagName = 'SysLogic'; Pattern = '^\s*[a-zA-Z][\w-]*-[a-zA-Z][\w-]*\b' } # Native Cmdlets
                # Default 'UserLogic' handled in tagging function
            )

            # Level 3: Detailed Structure (Order matters -> use [ordered])
            $l3Categories = [ordered]@{}
            # TagName                      Pattern                                                                                                     AssignedPhase
            # -------                      -------                                                                                                     -------------
            $l3Categories['Attribute']            = @{ Pattern = '(?i)^\s*\[';                                       AssignedPhase = "Setup"                 }
            $l3Categories['ParamBlock']           = @{ Pattern = '(?i)^\s*param\s*\(';                               AssignedPhase = "BlockContext:Setup"    }
            $l3Categories['FunctionDefinition']   = @{ Pattern = '(?i)^\s*function\s+';                             AssignedPhase = "BlockContext:Setup"    }
            $l3Categories['ClassEnumDefinition']  = @{ Pattern = '(?i)^\s*(class|enum)\b';                          AssignedPhase = "BlockContext:Setup"    }
            $l3Categories['VariableAssignment']   = @{ Pattern = '^\s*\$((global|script|local|private|variable):)?[a-zA-Z_][\w-]*\s*(=|\+=|-=|\*=|/=|%=)\s*'; AssignedPhase = "Setup" }
            $l3Categories['ControlFlow']          = @{ Pattern = '(?i)^\s*(if|elseif|else|switch|for|foreach|while|do|try|catch|finally|trap|break|continue|return|exit)\b'; AssignedPhase = "Neutral" } # The keyword itself
            $l3Categories['CommandInvocation']    = @{ Pattern = '^\s*[a-zA-Z][\w-]*-[a-zA-Z][\w-]*\b';              AssignedPhase = "Execution"             } # General commands

            $taggingRules['Level3_StructureDetail'] = @($l3Categories.GetEnumerator() | ForEach-Object {
                @{
                    TagName = $_.Name
                    Pattern = $_.Value.Pattern # Access Pattern from the nested hashtable
                    AssignedPhase = $_.Value.AssignedPhase # Access AssignedPhase
                    # Preserve other properties if any, e.g., $_.Value.Comment
                }
            })
            # Default L3 'ExpressionOrUnknown' will not have an AssignedPhase, resulting in "PhaseUndetermined"
            # if no more specific L4 rule with an AssignedPhase matches.

            # Level 4: Detailed Semantics
            $taggingRules['Level4_Detailed'] = @(
                @{ TagName = 'UserInput';            Pattern = '(?i)Read-Host';                                          AssignedPhase = "Execution" },
                @{ TagName = 'DotSource';            Pattern = '(?i)^\s*\.\s+.+\.ps1\b';                                 AssignedPhase = "Setup"     }, # Typically setup
                @{ TagName = 'GlobalVarInit';        Pattern = '^\s*\$global:[a-zA-Z_][\w]*\s*=';                         AssignedPhase = "Setup"     },
                @{ TagName = 'ScriptVarInit';        Pattern = '^\s*\$script:[a-zA-Z_][\w]*\s*=';                          AssignedPhase = "Setup"     },
                @{ TagName = 'DataInput';            Pattern = '(?i)Get-Content|Import-Csv|ConvertFrom-Json';              AssignedPhase = "Neutral"   }, # Can be setup or exec, so Neutral to inherit
                @{ TagName = 'ConsoleOutput';        Pattern = '(?i)Write-Host|Write-Output';                              AssignedPhase = "Execution" }, # Or Neutral if used for verbose setup
                @{ TagName = 'DataOutput';           Pattern = '(?i)Set-Content|Add-Content|Export-Csv|ConvertTo-Json|Out-File'; AssignedPhase = "Execution" },
                @{ TagName = 'Config';               Pattern = '(?i)Get-Config|Set-Config|pp_settings\.json';              AssignedPhase = "Setup"     }, # Often setup
                @{ TagName = 'DependencyInput';      Pattern = '(?i)Import-Module';                                      AssignedPhase = "Setup"     },
                @{ TagName = 'ExitPoint';            Pattern = '(?i)^\s*(return|exit)\b.*';                                AssignedPhase = "Execution" }, # Or Neutral, as it can end any phase
                @{ TagName = 'ErrorHandlingKeyword'; Pattern = '(?i)^\s*(try|catch|finally|trap)\b';                     AssignedPhase = "Neutral"   }, # The keywords themselves
                @{ TagName = 'Logging';              Pattern = '(?i)Write-(Verbose|Debug|Warning|Error|Information)';      AssignedPhase = "Neutral"   }
            )
            # Any L4 rule above *without* an AssignedPhase key will lead to "PhaseUndetermined"
            # if it's the winning rule for phase hint.

            $languageProfile['TaggingRules'] = $taggingRules
            Write-Verbose "DEBUG: Finished building PS profile. TaggingRules Keys: $($taggingRules.Keys -join ', ')"

        } # End .ps1 case

        '.py' {
            # --- Programmatic Definition for Python Multi-Level Profile ---
            Write-Verbose "DEBUG: Building Python multi-level profile..."
            $languageProfile = @{ LanguageName = "Python" } # Add DefaultPhaseForRulesWithoutHint here too if desired
            $taggingRules = @{}
            $languageProfile['CommentProfile'] = @{ Single = '#'; MultiStart = '"""'; MultiEnd = '"""'; AltMultiStart = "'''"; AltMultiEnd = "'''" }

            # L1
            $taggingRules['Level1_Structure'] = @(
                @{ TagName = 'SyntaxMarks'; Pattern = '^\s*[\(\):]+\s*(#.*)?$'; AssignedPhase = "Neutral" }
            )
            # L2 Structure
            $taggingRules['Level2_Structure'] = @(
                @{ TagName = 'block'; Pattern = ':\s*(#.*)?$' } # No AssignedPhase
            )
            # L2 Identity
            $l2PyKeywords = @('if', 'elif', 'else', 'for', 'while', 'try', 'except', 'finally', 'with', 'def', 'class', 'import', 'from', 'return', 'yield', 'pass', 'break', 'continue', 'assert')
            $taggingRules['Level2_Identity'] = @(
                @{ TagName = 'SysLogic'; Pattern = "(?i)^\s*($($l2PyKeywords | ForEach-Object {[regex]::Escape($_)} | Join-String -Separator '|'))\b" } # No AssignedPhase
            )
            # L3 Structure Detail (Ordered)
            $l3PyCategories = [ordered]@{}
            $l3PyCategories['Import']             = @{ Pattern = '^\s*(import|from)\s+';                AssignedPhase = "Setup" }
            $l3PyCategories['Decorator']          = @{ Pattern = '^\s*@';                               AssignedPhase = "Setup" } # Decorators modify definitions
            $l3PyCategories['FunctionDefinition'] = @{ Pattern = '^\s*def\s+';                           AssignedPhase = "BlockContext:Setup" }
            $l3PyCategories['ClassDefinition']    = @{ Pattern = '^\s*class\s+';                         AssignedPhase = "BlockContext:Setup" }
            $l3PyCategories['VariableAssignment'] = @{ Pattern = '^\s*[a-zA-Z_][\w]*\s*(=|\+=|-=|\*=|/=|%=|:=)\s*'; AssignedPhase = "Setup" }
            $l3PyCategories['ControlFlow']        = @{ Pattern = '^\s*(if|elif|else|for|while|try|except|finally|with|pass|break|continue|assert|yield|return)\b'; AssignedPhase = "Neutral" }
            $l3PyCategories['ExpressionStatement']= @{ Pattern = '^\s*[a-zA-Z_][\w]*(\.[a-zA-Z_][\w]*|\(.*\)).*'; AssignedPhase = "Execution" } # General expressions
            $taggingRules['Level3_StructureDetail'] = @($l3PyCategories.GetEnumerator() | ForEach-Object { @{ TagName = $_.Name; Pattern = $_.Value.Pattern; AssignedPhase = $_.Value.AssignedPhase } })

            # L4 Detailed
            $taggingRules['Level4_Detailed'] = @(
                @{ TagName = 'DataOutput'; Pattern = 'print\(.*'; AssignedPhase = "Execution" } # Corrected pattern to match 'print('
            )

            $languageProfile['TaggingRules'] = $taggingRules
            Write-Verbose "DEBUG: Finished building PY profile. TaggingRules Keys: $($taggingRules.Keys -join ', ')"

        } # End .py case

        default {
            Write-Warning "Unsupported file extension for language profiling: $extension"
            return $null
        }
    } # End switch statement

    # --- Resolve Aliases ---
    $resolvedProfile = $null
    if ($languageProfile -is [hashtable]) {
        $resolvedProfile = $languageProfile # It's already a profile
    } elseif ($languageProfile -is [string] -and $languageProfile.StartsWith('.')) {
        # It's an alias string, look up the target
        $targetExtension = $languageProfile
        Write-Verbose "Resolving profile alias: '$extension' -> '$targetExtension'"
        # Need to re-call recursively or lookup in a pre-loaded structure.
        # Simplest for now: assume switch runs again (less efficient but works)
        # Or better: load ALL profiles first, then select/resolve.
        # Let's stick to simpler for now, assuming alias target exists.
        switch ($targetExtension) {
             '.ps1' { $resolvedProfile = $switch[$targetExtension] } # Access previously evaluated block
             '.py'  { $resolvedProfile = $switch[$targetExtension] }
             # Add other potential alias targets
             default { Write-Warning "Alias target '$targetExtension' for '$extension' not found." }
        }
        if ($resolvedProfile -is [string]) { # Check if alias points to another alias (prevent loops later)
             Write-Warning "Alias loop detected or invalid alias target for '$extension'."
             return $null
        }

    }
    # --- End Alias Resolution ---


    # Final validation of the RESOLVED profile
    if ($null -eq $resolvedProfile) {
         Write-Warning "No valid profile resolved for extension '$extension'."
         return $null
    }
    if (-not $resolvedProfile.PSObject.Properties.Name -contains 'LanguageName' -or
        -not $resolvedProfile.PSObject.Properties.Name -contains 'CommentProfile' -or -not ($resolvedProfile.CommentProfile -is [hashtable]) -or
        -not $resolvedProfile.PSObject.Properties.Name -contains 'TaggingRules' -or -not ($resolvedProfile.TaggingRules -is [hashtable])) {
         Write-Error "The resolved language profile for '$extension' is invalid (missing required keys like LanguageName, CommentProfile, TaggingRules)."
         return $null
    }

    Write-Verbose "DEBUG: Returning profile for language: $($resolvedProfile.LanguageName)"
    return $resolvedProfile # Return the final profile object
}
function Get-EffectiveLinePhases {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$TaggedCodeLines, # Array from Add-MultiLevelTags, includes .LineNumber, .RuleAssignedPhase, .L3StructTag

        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$SectionData,     # Output from Get-ScriptSectionData (sorted by StartLine)

        [Parameter()]
        [string]$DefaultInitialRootPhase = "Execution" # Default phase if first lines are Neutral/Undetermined
    )

    Write-Verbose "Entering Determine-EffectiveLinePhases. Processing $($TaggedCodeLines.Count) lines."

    $linesWithFinalPhase = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    # Stack to keep track of active block phases. Each item could be a hashtable:
    # @{ PhaseName = "Setup"; EndLine = 25; SectionType = "FunctionDefinition" }
    $phaseContextStack = [System.Collections.Stack]::new()
    
    $previousLineFinalPhase = $DefaultInitialRootPhase # Tracks the last resolved non-Neutral/non-Undetermined phase at the current effective level

    # Optimization: Create a lookup for SectionData by StartLine and Type for faster block identification
    # This is especially useful if $SectionData can be large.
    # Key: "Line<LineNumber>_Type<SectionType>" (e.g., "Line10_TypeFunctionDefinition")
    # Value: The section object itself
    $sectionLookup = @{}
    foreach ($section in $SectionData) {
        $lookupKey = "Line$($section.StartLine)_Type$($section.Type)"
        $sectionLookup[$lookupKey] = $section
    }
    Write-Verbose "Created section lookup table with $($sectionLookup.Count) entries."

    foreach ($currentLineObj in $TaggedCodeLines) {
        $lineNumber = $currentLineObj.LineNumber
        $rulePhaseHint = $currentLineObj.RuleAssignedPhase # This comes from Add-MultiLevelTags
        $l3StructTag = $currentLineObj.L3StructTag     # Needed to identify block type for context hints

        $effectiveLinePhase = $null # This will be the FinalPhaseName for the current line

        # 1. Block End Check: See if current line number is past the end of the current block context
        if ($phaseContextStack.Count -gt 0) {
            $topContext = $phaseContextStack.Peek()
            if ($lineNumber -gt $topContext.EndLine) {
                Write-Verbose "Line ${lineNumber}: Exiting block context '$($topContext.PhaseName)' (type '$($topContext.SectionType)') which ended at L$($topContext.EndLine)."
                $phaseContextStack.Pop() | Out-Null
                # After popping, the new $previousLineFinalPhase should ideally be the phase of the now-current context,
                # or the $previousLineFinalPhase from before entering the popped block if stack becomes empty.
                # For simplicity, $previousLineFinalPhase will naturally update based on line processing.
            }
        }

        # 2. Block Start Check & Context Update:
        # Check if the current line's rule hint defines a new block context.
        if ($rulePhaseHint -and $rulePhaseHint.StartsWith("BlockContext:")) {
            $actualBlockPhaseName = $rulePhaseHint.Substring("BlockContext:".Length) # e.g., "Setup"
            
            # Find the corresponding section in $SectionData to get its EndLine
            # The L3StructTag of the current line should match the Type of the section
            $lookupKey = "Line${lineNumber}_Type${l3StructTag}"
            $blockSection = $null
            if ($sectionLookup.ContainsKey($lookupKey)) {
                $blockSection = $sectionLookup[$lookupKey]
            }

            if ($null -ne $blockSection) {
                Write-Verbose "Line ${lineNumber}: Entering block context '$actualBlockPhaseName' (type '$($blockSection.Type)') from L$lineNumber to L$($blockSection.EndLine) due to hint '$rulePhaseHint'."
                $phaseContextStack.Push(@{
                    PhaseName   = $actualBlockPhaseName
                    StartLine   = $lineNumber
                    EndLine     = $blockSection.EndLine
                    SectionType = $blockSection.Type # Store type for precise end checking
                })
                $effectiveLinePhase = $actualBlockPhaseName # The line starting the block is part of that block's phase
            } else {
                Write-Warning "Line ${lineNumber}: Rule hint '$rulePhaseHint' suggested a block context for L3 tag '$l3StructTag', but no matching section found in SectionData starting at this line."
                # Fallback: Treat the hint as a direct phase if no block found, or default to neutral-like behavior
                # For now, let it fall through to next logic, which might treat it as a direct phase or neutral.
            }
        }

        # 3. Determine Effective Phase (if not already set by a BlockContext starting on this line)
        if ($null -eq $effectiveLinePhase) {
            if ($rulePhaseHint -eq "Neutral" -or $rulePhaseHint -eq "PhaseUndetermined" -or [string]::IsNullOrEmpty($rulePhaseHint)) {
                # Neutral, Undetermined, or Empty hint: Inherit
                if ($phaseContextStack.Count -gt 0) {
                    $effectiveLinePhase = $phaseContextStack.Peek().PhaseName
                    Write-Verbose "Line ${lineNumber}: Hint is '$rulePhaseHint'. Inheriting phase '$effectiveLinePhase' from block context."
                } else {
                    $effectiveLinePhase = $previousLineFinalPhase # Inherit from previous line if no block context
                    Write-Verbose "Line ${lineNumber}: Hint is '$rulePhaseHint'. No block context. Inheriting phase '$effectiveLinePhase' from previous line."
                }
            } elseif ($rulePhaseHint -and -not $rulePhaseHint.StartsWith("BlockContext:")) {
                # It's a direct phase name (e.g., "Setup", "Execution")
                $effectiveLinePhase = $rulePhaseHint
                Write-Verbose "Line ${lineNumber}: Hint is direct phase '$effectiveLinePhase'."
            } else {
                # Fallback if $rulePhaseHint was a BlockContext that wasn't found, or some other unhandled case.
                # Default to inheriting from previous line or initial default.
                 if ($phaseContextStack.Count -gt 0) {
                    $effectiveLinePhase = $phaseContextStack.Peek().PhaseName
                } else {
                    $effectiveLinePhase = $previousLineFinalPhase
                }
                Write-Verbose "Line ${lineNumber}: Fallback. Effective phase '$effectiveLinePhase'."
            }
        }
        
        # Ensure $effectiveLinePhase is not null if it's the first line and was neutral/undetermined
        if ($null -eq $effectiveLinePhase) {
            $effectiveLinePhase = $DefaultInitialRootPhase
            Write-Verbose "Line ${lineNumber}: Effective phase was null, defaulting to initial root phase '$effectiveLinePhase'."
        }

        $currentLineObj | Add-Member -MemberType NoteProperty -Name 'FinalPhaseName' -Value $effectiveLinePhase -Force
        $linesWithFinalPhase.Add($currentLineObj)

        # Update $previousLineFinalPhase for the next iteration's inheritance logic
        # Only update if the current line's phase isn't considered "transparent" like Neutral might be
        # For simplicity now, always update. More sophisticated logic could be:
        # if ($rulePhaseHint -ne "Neutral" -and $rulePhaseHint -ne "PhaseUndetermined") { $previousLineFinalPhase = $effectiveLinePhase }
        $previousLineFinalPhase = $effectiveLinePhase

    } # End foreach line

    Write-Verbose "Exiting Determine-EffectiveLinePhases. Processed $($linesWithFinalPhase.Count) lines."
    return $linesWithFinalPhase.ToArray()
}
function Format-AnalysisReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.List[object]]$PhaseBlocks,

        [Parameter(Mandatory=$true)]
        [int]$SingleCommentCount,

        [Parameter(Mandatory=$true)]
        [int]$BlockCommentCount, # Represents MultiLineCommentLines

        # --- NEW PARAMETER ---
        [Parameter(Mandatory=$true)]
        [int]$InlineCommentCount,
        # --- END NEW PARAMETER ---

        [Parameter(Mandatory=$true)]
        [int]$EmptyLineCount,

        [Parameter(Mandatory=$true)]
        [int]$TotalOriginalLines,

        [Parameter(Mandatory=$true)]
        [int]$CodeCharCount,

        [Parameter(Mandatory=$true)]
        [int]$CommentCharCount,

        [Parameter(Mandatory=$true)]
        [int]$TotalCharCount, # Represents Code + Comment Chars

        [Parameter(Mandatory=$true)]
        [int]$CodeTokenEstimate,

        [Parameter(Mandatory=$true)]
        [int]$CommentTokenEstimate,

        [Parameter(Mandatory=$true)]
        [int]$TotalCodeCommentTokenEstimate,

        [Parameter(Mandatory=$true)]
        [int]$TotalCharTokenEstimate
    )

    # --- Configuration ---
    $maxBars = 20
    $labelWidth = -12; $barWidth = -20; $countWidth = 10; $rangeWidth = -15
    $charLabelWidth = -18; $charCountWidth = 15; $tokenWidth = -15

    # --- Helper Function for Bar Calculation ---
    function Get-BarString ([int]$itemCount, [int]$totalValue, [int]$maxWidth) {
        if ($totalValue -eq 0) { return "".PadRight($maxWidth) }
        $percentage = $itemCount / $totalValue
        $numBars = [Math]::Round($percentage * $maxWidth)
        if ($numBars -gt $maxWidth) { $numBars = $maxWidth }
        if ($numBars -lt 0) { $numBars = 0 }
        return ('█' * $numBars).PadRight($maxWidth)
    }

    # --- Print Header ---
    Write-Host "`n--- Analysis Report ---" -ForegroundColor Yellow

    # --- Print Phase Blocks ---
    foreach ($block in $PhaseBlocks) {
        $phaseLabel = $block.PhaseName; $lineCount = $block.HeaderCount
        $startNum = $block.StartLN
        # Check if SpanEndLN property exists, otherwise fallback to EndLN
        $endNum = if ($block.PSObject.Properties.Name -contains 'SpanEndLN') { $block.SpanEndLN } else { $block.EndLN }
        $lineRange = ""
        if ($startNum -eq $endNum) {
            $lineRange = "[L:{0}]" -f $startNum
        } else {
            $lineRange = "[L:{0}-{1}]" -f $startNum, $endNum
        }
        $bar = Get-BarString -itemCount $lineCount -totalValue $TotalOriginalLines -maxWidth $maxBars
        $formatString = "{0,$labelWidth}  {1,$barWidth}  {2,$countWidth}  {3,$rangeWidth}"
        Write-Host ($formatString -f $phaseLabel, $bar, "$lineCount lines", $lineRange)
    }

    # --- UPDATED: Print Comments (Including Inline) ---
    # Total comment lines = full single lines + lines within blocks + lines with inline comments
    $totalCommentLinesForBar = $SingleCommentCount + $BlockCommentCount + $InlineCommentCount
    $commentLabel = "Comments"
    # Detailed count string
    $commentCountString = "B:{0}/S:{1}/I:{2}" -f $BlockCommentCount, $SingleCommentCount, $InlineCommentCount
    $commentBar = Get-BarString -itemCount $totalCommentLinesForBar -totalValue $TotalOriginalLines -maxWidth $maxBars
    $formatString = "{0,$labelWidth}  {1,$barWidth}  {2,$countWidth}  {3,$rangeWidth}"
    Write-Host ($formatString -f $commentLabel, $commentBar, "$totalCommentLinesForBar lines", "($commentCountString)") # Show total and breakdown
    # --- END UPDATED ---

    # --- Print Empty Lines ---
    $emptyLabel = "Empty"; $emptyCountString = "$EmptyLineCount lines"
    $emptyBar = Get-BarString -itemCount $EmptyLineCount -totalValue $TotalOriginalLines -maxWidth $maxBars
    $formatString = "{0,$labelWidth}  {1,$barWidth}  {2,$countWidth}"
    Write-Host ($formatString -f $emptyLabel, $emptyBar, $emptyCountString)

    # --- Print Separator ---
    $totalDisplayWidth = [Math]::Abs($labelWidth) + [Math]::Abs($barWidth) + [Math]::Abs($countWidth) + [Math]::Abs($rangeWidth) + 6
    Write-Host ("-" * $totalDisplayWidth)

    # --- Print Total Lines ---
    $totalLabel = "Total Lines:"
    $paddingBeforeTotalCount = [Math]::Abs($labelWidth) + 2 + [Math]::Abs($barWidth) + 2
    Write-Host ("{0}{1}{2}" -f $totalLabel, (" " * ($paddingBeforeTotalCount - $totalLabel.Length)), ("{0,$countWidth}" -f $TotalOriginalLines))

    # --- Print Total Characters (Code+Comment) ---
    $totalCharLabel = "Total Chars:" # Renamed label slightly
    $totalTokenString = "[$($TotalCharTokenEstimate.ToString("N0")) tokens]"
    $paddingBeforeTotalCharCount = [Math]::Abs($labelWidth) + 2 + [Math]::Abs($barWidth) + 2
    $paddingBeforeTotalToken = [Math]::Abs($countWidth) + 2
    Write-Host ("{0}{1}{2}{3}{4}" -f $totalCharLabel, `
                                        (" " * ($paddingBeforeTotalCharCount - $totalCharLabel.Length)), `
                                        ("{0,$countWidth}" -f $TotalCharCount.ToString("N0")), ` # Uses Code+Comment Chars
                                        (" " * $paddingBeforeTotalToken), `
                                        ("{0,$tokenWidth}" -f $totalTokenString))

    # --- Print Detailed Character Counts ---
    Write-Host # Add a blank line for separation
    Write-Host "Character Counts:" -ForegroundColor Yellow

    # Code Chars
    $codeCharLabel = "  Code:"; $codeTokenString = "[$($CodeTokenEstimate.ToString("N0")) tokens]"
    Write-Host ("{0,$charLabelWidth} {1,$charCountWidth} {2,$tokenWidth}" -f $codeCharLabel, $CodeCharCount.ToString("N0"), $codeTokenString)

    # Comment Chars
    $commentCharLabel = "  Comments:"; $commentTokenString = "[$($CommentTokenEstimate.ToString("N0")) tokens]"
    Write-Host ("{0,$charLabelWidth} {1,$charCountWidth} {2,$tokenWidth}" -f $commentCharLabel, $CommentCharCount.ToString("N0"), $commentTokenString)

    # Combined Code + Comment Chars
    $combinedCodeCommentCharCount = $CodeCharCount + $CommentCharCount
    $combinedCharLabel = "  Combined:"; $combinedTokenString = "[$($TotalCodeCommentTokenEstimate.ToString("N0")) tokens]"
    Write-Host ("{0,$charLabelWidth} {1,$charCountWidth} {2,$tokenWidth}" -f $combinedCharLabel, $combinedCodeCommentCharCount.ToString("N0"), $combinedTokenString)
    # --- END Detailed Character Counts ---

}
function Add-MultiLevelTags {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$CodeLineObjects,

        [Parameter(Mandatory = $true)]
        [hashtable]$LanguageProfile
    )

    # --- Validate Profile ---
    if ($null -eq $LanguageProfile -or
        -not $LanguageProfile.ContainsKey('TaggingRules') -or -not ($LanguageProfile.TaggingRules -is [hashtable])) {
        Write-Error "Add-MultiLevelTags: Invalid LanguageProfile provided (Missing TaggingRules)."
        return $null
    }
    $TaggingRules = $LanguageProfile.TaggingRules
    # --- End Validation ---

    $outputCodeLines = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Line-by-Line Tagging ---
    foreach ($lineObj in $CodeLineObjects) {
        $Line = $lineObj.Content
        $TrimmedLine = $Line.Trim()

        if ($TrimmedLine.Length -eq 0) { # Skip blank lines if any got through
            # If you still want to output blank lines but without tags,
            # you could add $lineObj to $outputCodeLines here and then 'continue'
            # For now, skipping them entirely from the output of this function.
            continue
        }

        # --- Initialize Tags, Rule Objects, and Phase Hint ---
        $l1StructTag = 'Code'; $l2StructTag = $null; $l2IdTag = $null; $l3StructTag = $null; $l4DetailTag = 'None'
        
        # Variables to store the rule objects that matched for each level
        $l1RuleThatMatched = $null
        $l2SRuleThatMatched = $null
        $l2IdRuleThatMatched = $null
        $l3RuleThatMatched = $null
        $l4RuleThatMatched = $null

        # Initialize the phase hint for the line - THIS IS THE DEFAULT
        $determinedRulePhaseHint = "PhaseUndetermined"

        $contentForMatch = $Line.TrimStart(); $trimmedContentForMatch = $TrimmedLine

        # L1
        if ($TaggingRules.ContainsKey('Level1_Structure')) {
            foreach ($rule_l1 in $TaggingRules.Level1_Structure) { # Renamed $rule to $rule_l1 for clarity
                try {
                    if ($trimmedContentForMatch -match $rule_l1.Pattern) {
                        $l1StructTag = $rule_l1.TagName
                        $l1RuleThatMatched = $rule_l1 # Capture the L1 rule object
                        break
                    }
                } catch { Write-Warning "Regex error L1 ($($rule_l1.TagName)): $($_.Exception.Message)" }
            }
        }

        if ($l1StructTag -eq 'Code') {
            # L1 was default 'Code', so $l1RuleThatMatched will be $null here.
            # L2 Structure
            $l2StructTag = 'step' # Default L2S tag
            if ($TaggingRules.ContainsKey('Level2_Structure')) {
                foreach ($rule_l2s in $TaggingRules.Level2_Structure) {
                    try {
                        if ($trimmedContentForMatch -match $rule_l2s.Pattern) {
                            $l2StructTag = $rule_l2s.TagName
                            $l2SRuleThatMatched = $rule_l2s # Capture L2S rule
                            break
                        }
                    } catch { Write-Warning "Regex error L2S ($($rule_l2s.TagName)): $($_.Exception.Message)" }
                }
            }
            # L2 Identity
            $l2IdTag = 'UserLogic' # Default L2I tag
            if ($TaggingRules.ContainsKey('Level2_Identity')) {
                foreach ($rule_l2i in $TaggingRules.Level2_Identity) {
                    try {
                        if ($contentForMatch -match $rule_l2i.Pattern) {
                            $l2IdTag = $rule_l2i.TagName
                            $l2IdRuleThatMatched = $rule_l2i # Capture L2I rule
                            break
                        }
                    } catch { Write-Warning "Regex error L2I ($($rule_l2i.TagName)): $($_.Exception.Message)" }
                }
            }
            # L3 Structure Detail
            $l3StructTag = 'ExpressionOrUnknown' # Default L3 tag
            if ($TaggingRules.ContainsKey('Level3_StructureDetail')) {
                foreach ($rule_l3 in $TaggingRules.Level3_StructureDetail) {
                    try {
                        if ($contentForMatch -match $rule_l3.Pattern) {
                            $l3StructTag = $rule_l3.TagName
                            $l3RuleThatMatched = $rule_l3 # Capture L3 rule
                            break
                        }
                    } catch { Write-Warning "Regex error L3 ($($rule_l3.TagName)): $($_.Exception.Message)" }
                }
            }
            # L4 Detailed
            $l4DetailTag = 'None' # Default L4 tag
            if ($TaggingRules.ContainsKey('Level4_Detailed')) {
                foreach ($rule_l4 in $TaggingRules.Level4_Detailed) {
                    try {
                        if ($Line -match $rule_l4.Pattern) { # Uses original $Line for L4
                            $l4DetailTag = $rule_l4.TagName
                            $l4RuleThatMatched = $rule_l4 # Capture L4 rule
                            break
                        }
                    } catch { Write-Warning "Regex error L4 ($($rule_l4.TagName)): $($_.Exception.Message)" }
                }
            }
        }

        # --- Determine final RuleAssignedPhase based on precedence ---
        # $determinedRulePhaseHint is already "PhaseUndetermined" by default.

        if ($null -ne $l1RuleThatMatched) {
            # A specific L1 rule (e.g., 'SyntaxMarks') matched.
            # Its phase hint (if it exists) takes precedence. L2-L4 phase hints are ignored in this case.
            if ($l1RuleThatMatched.ContainsKey('AssignedPhase')) { # Using ContainsKey for direct hashtable key check
                $determinedRulePhaseHint = $l1RuleThatMatched.AssignedPhase
            }
            # If $l1RuleThatMatched exists but has no 'AssignedPhase', $determinedRulePhaseHint remains "PhaseUndetermined".
        } else {
            # No specific L1 rule matched, so $l1StructTag must have remained 'Code' (and $l1RuleThatMatched is $null).
            # Proceed with L2-L4 precedence (L4 > L3 > L2I > L2S).
            # $determinedRulePhaseHint is still "PhaseUndetermined" at this point.

            # Check L2S (lowest precedence among L2-L4 for overriding "PhaseUndetermined")
            if ($null -ne $l2SRuleThatMatched -and $l2SRuleThatMatched.ContainsKey('AssignedPhase')) {
                $determinedRulePhaseHint = $l2SRuleThatMatched.AssignedPhase
            }
            # Check L2I (overrides L2S if it has a hint)
            if ($null -ne $l2IdRuleThatMatched -and $l2IdRuleThatMatched.ContainsKey('AssignedPhase')) {
                $determinedRulePhaseHint = $l2IdRuleThatMatched.AssignedPhase
            }
            # Check L3 (overrides L2s if it has a hint)
            if ($null -ne $l3RuleThatMatched -and $l3RuleThatMatched.ContainsKey('AssignedPhase')) {
                $determinedRulePhaseHint = $l3RuleThatMatched.AssignedPhase
            }
            # Check L4 (highest precedence, overrides L2s and L3 if it has a hint)
            if ($null -ne $l4RuleThatMatched -and $l4RuleThatMatched.ContainsKey('AssignedPhase')) {
                $determinedRulePhaseHint = $l4RuleThatMatched.AssignedPhase
            }
        }

        # Add L1-L4 tags to the existing object
        $lineObj | Add-Member -MemberType NoteProperty -Name 'L1StructTag'       -Value $l1StructTag       -Force
        $lineObj | Add-Member -MemberType NoteProperty -Name 'L2StructTag'       -Value $l2StructTag       -Force
        $lineObj | Add-Member -MemberType NoteProperty -Name 'L2IdTag'           -Value $l2IdTag           -Force
        $lineObj | Add-Member -MemberType NoteProperty -Name 'L3StructTag'       -Value $l3StructTag       -Force
        $lineObj | Add-Member -MemberType NoteProperty -Name 'L4DetailTag'       -Value $l4DetailTag       -Force
        # Add the NEW RuleAssignedPhase property
        $lineObj | Add-Member -MemberType NoteProperty -Name 'RuleAssignedPhase' -Value $determinedRulePhaseHint -Force
        
        # --- BEGIN DEBUGGING OUTPUT (Optional - Remove after testing) ---
        # Write-Host ("Line {0}: L1='{1}' (Rule: {2}), L2S='{3}' (Rule: {4}), L2I='{5}' (Rule: {6}), L3='{7}' (Rule: {8}), L4='{9}' (Rule: {10}) -> PhaseHint='{11}' -- {12}" -f `
        #     $lineObj.LineNumber, `
        #     $l1StructTag, $l1RuleThatMatched.TagName, `
        #     $l2StructTag, $l2SRuleThatMatched.TagName, `
        #     $l2IdTag, $l2IdRuleThatMatched.TagName, `
        #     $l3StructTag, $l3RuleThatMatched.TagName, `
        #     $l4DetailTag, $l4RuleThatMatched.TagName, `
        #     $determinedRulePhaseHint, `
        #     $lineObj.Content)
        # --- END DEBUGGING OUTPUT ---

        $outputCodeLines.Add($lineObj)
    } # End line processing loop

    return $outputCodeLines.ToArray()
}
function Get-CommentInfo {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias("FullName")]
        [string]$FilePath,

        [Parameter()]
        [hashtable]$CommentProfiles = @{
            # PowerShell
            '.ps1' = @{ Single = '#'; MultiStart = '<#'; MultiEnd = '#>'; RegionStart = '#region' }
            '.psd1'= @{ Single = '#'; MultiStart = '<#'; MultiEnd = '#>'; RegionStart = '#region' }
            '.psm1'= @{ Single = '#'; MultiStart = '<#'; MultiEnd = '#>'; RegionStart = '#region' }
            # Python
            '.py'  = @{ Single = '#'; MultiStart = '"""'; MultiEnd = '"""'; AltMultiStart = "'''"; AltMultiEnd = "'''" } # Simple """/''' block check
            # C#
            '.cs'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/'; RegionStart = '#region'; DocComment = '///'}
            # C / C++
            '.c'   = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            '.cpp' = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            '.h'   = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            # JavaScript / TypeScript / JSON (loosely)
            '.js'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            '.ts'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            '.jsonc'=@{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' } # JSON with Comments
            # Rust
            '.rs'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/'; DocComment = '///'; ModDocComment = '//!' }
            # Java
            '.java'= @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            # HTML / XML
            '.html'= @{ MultiStart = '' }
            '.xml' = @{ MultiStart = '' }
            # SQL
            '.sql' = @{ Single = '--'; MultiStart = '/*'; MultiEnd = '*/' }
            # Shell / Bash / Config files
            '.sh'  = @{ Single = '#' }
            '.bash'= @{ Single = '#' }
            '.conf'= @{ Single = '#' }
            '.ini' = @{ Single = ';' } # Often ; or #
            '.properties' = @{ Single = '#' }
             # Ruby
            '.rb'  = @{ Single = '#'; MultiStart = '=begin'; MultiEnd = '=end' }
        }
    )

    begin {
        # Initialization if needed across multiple files in pipeline
    }

    process {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            Write-Error "File not found or is a directory: '$FilePath'"
            return
        }

        # Resolve the full path
        $ResolvedPath = (Resolve-Path -LiteralPath $FilePath).Path
        $Extension = [System.IO.Path]::GetExtension($ResolvedPath).ToLower()

        if (-not $CommentProfiles.ContainsKey($Extension)) {
            Write-Warning "No comment profile found for extension '$Extension' in file '$ResolvedPath'. Cannot analyze comments."
            return
        }

        $CProfile = $CommentProfiles[$Extension]
        $LanguageProfileName = $Extension

        # Get file content
        try {
            $Lines = Get-Content -LiteralPath $ResolvedPath
        }
        catch {
            Write-Error "Error reading file '$ResolvedPath': $($_.Exception.Message)"
            return
        }

        # Initialize counters
        $TotalLines = $Lines.Count
        $BlankLines = 0
        $SingleLineComments = 0 # Starts with comment marker
        $InlineComments = 0     # Code before comment marker on the same line
        $MultiLineCommentBlocks = 0
        $MultiLineCommentLines = 0
        $RegionCount = 0
        $TotalCommentChars = 0
        $TotalCommentTokens = 0
        $TotalCodeChars = 0     # <<< NEW COUNTER
        $InsideMultiLineComment = $false
        $CurrentMultiStart = $null # To handle Python's """ and '''

        # --- Line-by-Line Analysis ---
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $Line = $Lines[$i]
            $TrimmedLine = $Line.Trim()
            $LineProcessed = $false # Flag to check if line was handled as comment/blank

            # Count blank lines
            if ($TrimmedLine.Length -eq 0) {
                $BlankLines += 1
                $LineProcessed = $true
                # No contribution to code or comment chars
            }

            # --- Multi-line Comment Logic ---
            if (-not $LineProcessed -and $InsideMultiLineComment) {
                $MultiLineCommentLines += 1
                # Count comment chars/tokens for the whole line
                $TotalCommentChars += $TrimmedLine.Length
                $TotalCommentTokens += ($TrimmedLine -split '\s+' | Where-Object { $_ }).Count
                # No contribution to code chars

                # Check for end marker
                $MultiEndMarker = $CProfile.MultiEnd
                if ($CurrentMultiStart -eq $CProfile.AltMultiStart) {
                    $MultiEndMarker = $CProfile.AltMultiEnd
                }

                if ($CProfile.ContainsKey('MultiEnd') -and $null -ne $MultiEndMarker -and $TrimmedLine.Contains($MultiEndMarker)) { # Use Contains for simplicity, EndsWith might be too strict
                    # Basic check: does the line contain the end marker?
                    # A robust parser would handle cases like '/* comment */ code' or ' text """ more text '.
                    # This simple check assumes the line ends the comment if the marker is present.
                    $InsideMultiLineComment = $false
                    $CurrentMultiStart = $null
                    # Potential code after the end marker on the same line is ignored for simplicity here.
                }
                $LineProcessed = $true # This line was part of a multi-line comment block
            }

            # Check for start of multi-line comment (Standard and Alternate like Python)
            if (-not $LineProcessed) {
                $PotentialStarts = @{}
                if ($CProfile.ContainsKey('MultiStart') -and $null -ne $CProfile.MultiStart) { $PotentialStarts[$CProfile.MultiStart] = $CProfile.MultiEnd }
                if ($CProfile.ContainsKey('AltMultiStart') -and $null -ne $CProfile.AltMultiStart) { $PotentialStarts[$CProfile.AltMultiStart] = $CProfile.AltMultiEnd }

                foreach ($StartMarker in $PotentialStarts.Keys) {
                    $MultiStartIndex = $TrimmedLine.IndexOf($StartMarker)

                    # Check if the marker is at the beginning of the trimmed line
                    if ($MultiStartIndex -eq 0) {
                        $MultiLineCommentBlocks += 1
                        $MultiLineCommentLines += 1
                        # No code chars added from this line unless it ends on the same line (handled below)

                        # Extract comment text on this starting line
                        $CommentTextOnStartLine = $TrimmedLine.Substring($StartMarker.Length)
                        $EndMarker = $PotentialStarts[$StartMarker]

                        # Check if it *also* ends on the same line
                        if ($null -ne $EndMarker -and $CommentTextOnStartLine.EndsWith($EndMarker)) {
                             # It's a single-line multi-line comment block, e.g., /* comment */ or """ comment """
                            $CommentTextOnStartLine = $CommentTextOnStartLine.Substring(0, $CommentTextOnStartLine.Length - $EndMarker.Length)
                            # Stays outside multi-line state
                            $CurrentMultiStart = $null
                        } else {
                            # It continues on the next line
                            $InsideMultiLineComment = $true
                            $CurrentMultiStart = $StartMarker
                        }

                        $CleanedCommentText = $CommentTextOnStartLine.Trim()
                        $TotalCommentChars += $CleanedCommentText.Length
                        $TotalCommentTokens += ($CleanedCommentText -split '\s+' | Where-Object { $_ }).Count

                        $LineProcessed = $true
                        break # Processed as multiline start
                    }
                    # Note: This logic doesn't handle code *before* a multiline start marker on the same line (e.g. code /* comment */).
                }
            }


            # --- Region Logic ---
            # Check *before* single line comments if the region marker itself is a comment (like #region)
             if (-not $LineProcessed -and $CProfile.ContainsKey('RegionStart') -and $null -ne $CProfile.RegionStart -and $TrimmedLine.StartsWith($CProfile.RegionStart)) {
                $RegionCount += 1
                # Let it fall through to be potentially counted as a single-line comment if marker matches
            }

             # --- Doc Comment Logic (like C# /// or Rust /// //!) ---
             # Treat these as single-line comments for counting purposes
             if (-not $LineProcessed) {
                 $DocCommentMarkers = @()
                 if ($CProfile.ContainsKey('DocComment') -and $null -ne $CProfile.DocComment) {$DocCommentMarkers += $CProfile.DocComment}
                 if ($CProfile.ContainsKey('ModDocComment') -and $null -ne $CProfile.ModDocComment) {$DocCommentMarkers += $CProfile.ModDocComment}

                 if ($DocCommentMarkers.Count -gt 0) {
                     foreach($DocMarker in $DocCommentMarkers) {
                         if ($TrimmedLine.StartsWith($DocMarker)) {
                             $SingleLineComments += 1 # Count as single-line full comment
                             $CommentText = $TrimmedLine.Substring($DocMarker.Length).Trim()
                             $TotalCommentChars += $CommentText.Length
                             $TotalCommentTokens += ($CommentText -split '\s+' | Where-Object { $_ }).Count
                             # No code chars added
                             $LineProcessed = $true
                             break
                         }
                     }
                 }
             }

            # --- Single-Line / Inline Comment Logic ---
            if (-not $LineProcessed -and $CProfile.ContainsKey('Single') -and $null -ne $CProfile.Single) {
                $SingleMarker = $CProfile.Single
                $CommentIndex = $Line.IndexOf($SingleMarker) # Use original line for index accuracy

                if ($CommentIndex -ge 0) {
                    # Check if there's non-whitespace code *before* the marker
                    $CodeBeforeComment = $Line.Substring(0, $CommentIndex).Trim()
                    $CommentText = $Line.Substring($CommentIndex + $SingleMarker.Length).Trim()

                    if ($CodeBeforeComment.Length -gt 0) {
                        # Inline comment
                        $InlineComments += 1
                        # Add code part chars
                        $TotalCodeChars += $CodeBeforeComment.Length
                        # Add comment part chars/tokens
                        $TotalCommentChars += $CommentText.Length
                        $TotalCommentTokens += ($CommentText -split '\s+' | Where-Object { $_ }).Count
                    }
                    else {
                        # Full single-line comment
                        $SingleLineComments += 1
                         # Add comment part chars/tokens
                        $TotalCommentChars += $CommentText.Length
                        $TotalCommentTokens += ($CommentText -split '\s+' | Where-Object { $_ }).Count
                        # No code chars added
                    }
                    $LineProcessed = $true # This line contained a single-line or inline comment
                }
            }

            # --- Pure Code Line ---
            # If the line wasn't blank or handled by any comment logic above, it's code.
            if (-not $LineProcessed) {
                 # Add the trimmed line length as code characters
                $TotalCodeChars += $TrimmedLine.Length
            }

        } # End line processing loop

        # --- Final Calculations ---
        # Note: Inline comment lines are counted in TotalLines but NOT subtracted from CodeLines calculation below.
        # Their code part contributes to TotalCodeChars, comment part to TotalCommentChars.
        $CodeLines = $TotalLines - $BlankLines - $SingleLineComments - $MultiLineCommentLines
        # Ensure code lines isn't negative (e.g., empty file or only comments)
        if ($CodeLines -lt 0) { $CodeLines = 0 }

        # Calculate percentage of lines containing any form of comment
        $TotalCommentAffectedLines = $SingleLineComments + $InlineComments + $MultiLineCommentLines
        $CommentLinePercentage = 0
        if ($TotalLines -gt 0) {
            $CommentLinePercentage = [Math]::Round(($TotalCommentAffectedLines / $TotalLines * 100), 2)
        }

        # Calculate percentage of characters that are comments <<< NEW
        $TotalAllChars = $TotalCodeChars + $TotalCommentChars
        $CommentCharPercentage = 0
        if ($TotalAllChars -gt 0) {
            $CommentCharPercentage = [Math]::Round(($TotalCommentChars / $TotalAllChars * 100), 2)
        }


        # --- Output Object ---
        $Result = [ordered]@{
            FilePath              = $ResolvedPath
            LanguageProfile       = $LanguageProfileName
            TotalLines            = $TotalLines
            BlankLines            = $BlankLines
            CodeLines             = $CodeLines # Lines excluding blank, full single, and multi-line comments
            SingleLineComments    = $SingleLineComments # Line starts with marker
            InlineComments        = $InlineComments    # Code precedes marker on line
            MultiLineCommentBlocks= $MultiLineCommentBlocks # Number of /*...*/ or """...""" blocks etc.
            MultiLineCommentLines = $MultiLineCommentLines # Total lines within multiline blocks
            RegionCount           = $RegionCount
            TotalCodeChars        = $TotalCodeChars     # Characters considered code (trimmed)
            TotalCommentChars     = $TotalCommentChars  # Characters within comment markers (trimmed)
            TotalCommentTokens    = $TotalCommentTokens # Words within comment markers
            CommentCharPercentage = $CommentCharPercentage # Percentage of chars that are comments
            CommentLinePercentage = $CommentLinePercentage # Percentage of lines touched by comments
        }

        Write-Output ([PSCustomObject]$Result)
    }

    end {
        # Cleanup if needed
    }
}
function Get-CodeLines {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias("FullName")]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('TopLevel', 'Full')]
        [string]$Mode,

        [Parameter()]
        [int]$StartLine = 0, # Default 0 means start from beginning

        [Parameter()]
        [int]$EndLine = 0,   # Default 0 means go to end

        [Parameter()]
        [hashtable]$CommentProfiles = @{
            # Default profiles copied from Get-CommentInfo - Users can override
            '.ps1' = @{ Single = '#'; MultiStart = '<#'; MultiEnd = '#>'; RegionStart = '#region' }; '.psd1'= @{ Single = '#'; MultiStart = '<#'; MultiEnd = '#>'; RegionStart = '#region' }; '.psm1'= @{ Single = '#'; MultiStart = '<#'; MultiEnd = '#>'; RegionStart = '#region' }
            '.py'  = @{ Single = '#'; MultiStart = '"""'; MultiEnd = '"""'; AltMultiStart = "'''"; AltMultiEnd = "'''" }
            '.cs'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/'; RegionStart = '#region'; DocComment = '///'}
            '.c'   = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }; '.cpp' = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }; '.h'   = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            '.js'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }; '.ts'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }; '.jsonc'=@{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            '.rs'  = @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/'; DocComment = '///'; ModDocComment = '//!' }
            '.java'= @{ Single = '//'; MultiStart = '/*'; MultiEnd = '*/' }
            '.html'= @{ MultiStart = ''; MultiEnd = '' }; '.xml' = @{ MultiStart = ''; MultiEnd = '' } # Simplified HTML/XML
            '.sql' = @{ Single = '--'; MultiStart = '/*'; MultiEnd = '*/' }
            '.sh'  = @{ Single = '#' }; '.bash'= @{ Single = '#' }; '.conf'= @{ Single = '#' }; '.ini' = @{ Single = ';' }; '.properties' = @{ Single = '#' }
            '.rb'  = @{ Single = '#'; MultiStart = '=begin'; MultiEnd = '=end' }
        }
    )

    process {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { Write-Error "File not found or is a directory: '$FilePath'"; return $null }
        $ResolvedPath = (Resolve-Path -LiteralPath $FilePath).Path
        $Extension = [System.IO.Path]::GetExtension($ResolvedPath).ToLower()
        if (-not $CommentProfiles.ContainsKey($Extension)) { Write-Warning "No comment profile found for extension '$Extension'. Comment filtering might be inaccurate."; $CProfile = @{} }
        else { $CProfile = $CommentProfiles[$Extension] }
        try { $Lines = Get-Content -LiteralPath $ResolvedPath } catch { Write-Error "Error reading file '$ResolvedPath': $($_.Exception.Message)"; return $null }

        # --- Pre-calculate Multi-Line Comment Ranges IF a range is specified ---
        $multiCommentLineNumSet = [System.Collections.Generic.HashSet[int]]::new()
        $useRangeFiltering = ($StartLine -gt 0 -or $EndLine -gt 0)
        $effectiveEndLine = if ($EndLine -gt 0) { $EndLine } else { $Lines.Count } # Determine effective end line

        if ($useRangeFiltering) {
            Write-Verbose "Range specified ($StartLine - $effectiveEndLine). Getting multi-line comment ranges..."
            $multiLineRanges = Get-MultiLineCommentRanges -FilePath $ResolvedPath -CommentProfile $CProfile
            if ($null -ne $multiLineRanges) {
                foreach ($range in $multiLineRanges) {
                    for ($ln = $range.StartLine; $ln -le $range.EndLine; $ln++) {
                        # Add all line numbers within comment blocks to the set
                        $multiCommentLineNumSet.Add($ln) | Out-Null
                    }
                }
                Write-Verbose "Pre-calculated $($multiCommentLineNumSet.Count) lines within multi-line comment blocks."
            } else {
                 Write-Warning "Failed to get multi-line comment ranges. Multi-line comment filtering within range may be inaccurate."
            }
        }
        # --- End Pre-calculation ---


        $codeLinesList = [System.Collections.Generic.List[PSCustomObject]]::new()
        # Note: We still need to track $InsideMultiLineComment even if pre-calculating,
        # because the pre-calculation doesn't handle single-line comments or blanks.
        $InsideMultiLineComment = $false
        $CurrentMultiStart = $null

        # --- Line-by-Line Analysis ---
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $lineNumber = $i + 1
            $Line = $Lines[$i]
            $TrimmedLine = $Line.Trim()
            $isCodeLine = $true # Assume code unless filtered

            # 1. Apply Range Filter (Skip if outside specified range)
            if ($useRangeFiltering) {
                if (($StartLine -gt 0 -and $lineNumber -lt $StartLine) -or ($effectiveEndLine -gt 0 -and $lineNumber -gt $effectiveEndLine)) {
                    # Still need to track multiline state even if outside range
                    # Check for start marker (simplified)
                    if (-not $InsideMultiLineComment) {
                         $PotentialStarts = @{}; if ($CProfile.ContainsKey('MultiStart') -and $null -ne $CProfile.MultiStart) { $PotentialStarts[$CProfile.MultiStart] = $CProfile.MultiEnd }; if ($CProfile.ContainsKey('AltMultiStart') -and $null -ne $CProfile.AltMultiStart) { $PotentialStarts[$CProfile.AltMultiStart] = $CProfile.AltMultiEnd }
                         if ($PotentialStarts.Count -gt 0) { foreach ($StartMarker in $PotentialStarts.Keys) { if ($TrimmedLine.StartsWith($StartMarker)) { $InsideMultiLineComment = $true; $CurrentMultiStart = $StartMarker; break } } }
                    }
                    # Check for end marker (simplified)
                    elseif ($InsideMultiLineComment) {
                        $MultiEndMarker = $CProfile.MultiEnd; if ($CurrentMultiStart -eq $CProfile.AltMultiStart) { $MultiEndMarker = $CProfile.AltMultiEnd }
                        if ($CProfile.ContainsKey('MultiEnd') -and $null -ne $MultiEndMarker -and $TrimmedLine.Contains($MultiEndMarker)) { $InsideMultiLineComment = $false; $CurrentMultiStart = $null }
                    }
                    continue # Skip to next line as it's outside the desired range
                }
            }

            # 2. Skip blank lines
            if ($TrimmedLine.Length -eq 0) { $isCodeLine = $false; continue }

            # 3. Handle Multi-line Comments (using pre-calculated set if available)
            if ($useRangeFiltering) {
                 # If using range, check the pre-calculated set
                 if ($multiCommentLineNumSet.Contains($lineNumber)) {
                     $isCodeLine = $false
                     continue # Skip this line, it's part of a multi-line comment block
                 }
                 # If not in the set, it's not part of a pre-identified block, proceed to other checks
            } else {
                 # If NOT using range, use the original state tracking logic
                 if ($InsideMultiLineComment) {
                     $isCodeLine = $false
                     $MultiEndMarker = $CProfile.MultiEnd; if ($CurrentMultiStart -eq $CProfile.AltMultiStart) { $MultiEndMarker = $CProfile.AltMultiEnd }
                     if ($CProfile.ContainsKey('MultiEnd') -and $null -ne $MultiEndMarker -and $TrimmedLine.Contains($MultiEndMarker)) { $InsideMultiLineComment = $false; $CurrentMultiStart = $null }
                     continue
                 }
                 $PotentialStarts = @{}; if ($CProfile.ContainsKey('MultiStart') -and $null -ne $CProfile.MultiStart) { $PotentialStarts[$CProfile.MultiStart] = $CProfile.MultiEnd }; if ($CProfile.ContainsKey('AltMultiStart') -and $null -ne $CProfile.AltMultiStart) { $PotentialStarts[$CProfile.AltMultiStart] = $CProfile.AltMultiEnd }
                 $multiLineStartedHere = $false
                 if ($PotentialStarts.Count -gt 0) { foreach ($StartMarker in $PotentialStarts.Keys) { if ($TrimmedLine.StartsWith($StartMarker)) { $isCodeLine = $false; $multiLineStartedHere = $true; $EndMarker = $PotentialStarts[$StartMarker]; if ($null -ne $EndMarker -and $TrimmedLine.EndsWith($EndMarker) -and $TrimmedLine.Length -gt ($StartMarker.Length + $EndMarker.Length -1)) { $InsideMultiLineComment = $false; $CurrentMultiStart = $null } else { $InsideMultiLineComment = $true; $CurrentMultiStart = $StartMarker }; break } } }
                 if ($multiLineStartedHere) { continue }
            }

            # 4. Check for Doc Comments (Treat as full comments)
            $docCommentStartedHere = $false; $DocCommentMarkers = @(); if ($CProfile.ContainsKey('DocComment') -and $null -ne $CProfile.DocComment) {$DocCommentMarkers += $CProfile.DocComment}; if ($CProfile.ContainsKey('ModDocComment') -and $null -ne $CProfile.ModDocComment) {$DocCommentMarkers += $CProfile.ModDocComment}
            if ($DocCommentMarkers.Count -gt 0) { foreach($DocMarker in $DocCommentMarkers) { if ($TrimmedLine.StartsWith($DocMarker)) { $isCodeLine = $false; $docCommentStartedHere = $true; break } } }
            if ($docCommentStartedHere) { continue }

            # 5. Check for Single-Line Comments (Full line only)
            if ($CProfile.ContainsKey('Single') -and $null -ne $CProfile.Single) {
                $SingleMarker = $CProfile.Single; $CommentIndex = $Line.IndexOf($SingleMarker)
                if ($CommentIndex -ge 0) { $CodeBeforeComment = $Line.Substring(0, $CommentIndex).Trim(); if ($CodeBeforeComment.Length -eq 0) { $isCodeLine = $false; continue } }
            }

            # 6. If it's still considered a code line, check Mode
            if ($isCodeLine) {
                $isTopLevel = $Line -match '^\S'
                if ($Mode -eq 'Full' -or ($Mode -eq 'TopLevel' -and $isTopLevel)) {
                    $codeLinesList.Add([PSCustomObject]@{ LineNumber = $lineNumber; Content = $Line })
                }
            }

        } # End line processing loop

        # ... (rest of function: warning, return) ...
         if ($InsideMultiLineComment) { Write-Warning "File ended while inside a multi-line comment." } # This warning might be less relevant if using range filter
         return $codeLinesList.ToArray()

    } # End process block
}
function Get-ScriptSectionData {

    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$FilePath
    )

    # Validate file existence
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        Write-Error "File not found: $FilePath"
        return $null
    }
    # Ensure it's likely a PowerShell file (basic check)
    if ($FilePath -notmatch '\.ps(m|d)?1$') {
        Write-Warning "File '$FilePath' does not appear to be a PowerShell script (.ps1, .psm1, .psd1). AST parsing might fail or produce unexpected results."
    }

    # --- Parse the file into an AST and Tokens ---
    $parseErrors = $null
    $tokens = $null
    $ast = $null
    try {
        Write-Verbose "Parsing file '$FilePath' into AST and Tokens..."
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$parseErrors)
    } catch {
        Write-Error "Failed to parse file '$FilePath' into AST: $($_.Exception.Message)"
        return $null
    }

    if ($parseErrors) {
        Write-Warning "Encountered errors during AST parsing for '$FilePath':"
        $parseErrors | ForEach-Object { Write-Warning "  Line $($_.Extent.StartLineNumber): $($_.Message)" }
    }

    if ($null -eq $ast) {
        Write-Error "AST parsing resulted in a null object for '$FilePath'."
        return $null
    }

    # --- Find and Process AST Nodes ---
    $sections = [System.Collections.Generic.List[PSCustomObject]]::new()

    $astTypeMap = @{
        'ParamBlockAst'         = 'ParamBlock'
        'FunctionDefinitionAst' = 'FunctionDefinition'
        'ClassDefinitionAst'    = 'ClassEnumDefinition'
        'EnumDefinitionAst'     = 'ClassEnumDefinition'
        'IfStatementAst'        = 'If'
        'ForEachStatementAst'   = 'ForEach'
        'ForStatementAst'       = 'For'
        'WhileStatementAst'     = 'While'
        'DoWhileStatementAst'   = 'DoWhile'
        'SwitchStatementAst'    = 'Switch'
        'TryStatementAst'       = 'Try'
        'CatchClauseAst'        = 'Catch'
        'FinallyClauseAst'      = 'Finally'
    }
    $namedAstTypes = @('FunctionDefinitionAst', 'ClassDefinitionAst', 'EnumDefinitionAst') -as [System.Collections.Generic.HashSet[string]]

    $findAllCondition = { $args[0].GetType().Name -in $astTypeMap.Keys }
    $foundNodes = $ast.FindAll($findAllCondition, $true)

    Write-Verbose "Found $($foundNodes.Count) relevant AST nodes."

    foreach ($node in $foundNodes) {
        $nodeTypeName = $node.GetType().Name
        $sectionType = $astTypeMap[$nodeTypeName]
        $sectionName = $null
        if ($namedAstTypes.Contains($nodeTypeName)) {
            try { $sectionName = $node.Name } catch {}
        }
        $startLine = $node.Extent.StartLineNumber
        $endLine = $node.Extent.EndLineNumber
        $sections.Add([PSCustomObject]@{
            Type      = $sectionType
            Name      = $sectionName
            StartLine = $startLine
            EndLine   = $endLine
        })
    }

    # --- Add Region Parsing Logic (Using Extent.Text) ---
    Write-Verbose "Parsing comment tokens for #region blocks using Extent.Text..."
    $regionStack = [System.Collections.Generic.Stack[PSCustomObject]]::new()
    $regionCount = 0

    if ($null -ne $tokens) {
        $commentTokens = $tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment }
        Write-Verbose "Found $($commentTokens.Count) comment tokens to check."

        foreach ($token in $commentTokens) {
            $tokenStartLine = $token.Extent.StartLineNumber
            # --- FIX: Use Extent.Text as Content is unreliable ($null) ---
            $commentText = $token.Extent.Text
            # --- End FIX ---

            # Trim the text obtained from Extent.Text
            $trimmedCommentText = $commentText.Trim()

            # Match against the trimmed text from Extent.Text
            if ($trimmedCommentText -match '^\s*#\s*region\b(.*)') {
                $regionName = $matches[1].Trim()
                $regionStack.Push([PSCustomObject]@{ Name = $regionName; StartLine = $tokenStartLine })
                Write-Verbose "  [L:$tokenStartLine] Found #region '$regionName'. Stack depth: $($regionStack.Count)."
            }
            elseif ($trimmedCommentText -match '^\s*#\s*endregion\b') {
                if ($regionStack.Count -gt 0) {
                    $regionStartInfo = $regionStack.Pop()
                    $regionSection = [PSCustomObject]@{
                        Type      = 'Region'
                        Name      = $regionStartInfo.Name
                        StartLine = $regionStartInfo.StartLine
                        EndLine   = $tokenStartLine
                    }
                    $sections.Add($regionSection)
                    $regionCount++
                    Write-Verbose "  [L:$tokenStartLine] Found #endregion. Closed '$($regionSection.Name)' (L:$($regionSection.StartLine)-L:$tokenStartLine). Stack depth: $($regionStack.Count)."
                } else {
                    Write-Warning "  [L:$tokenStartLine] Found #endregion without matching #region."
                }
            }
        } # End foreach token

        # Check for unclosed regions
        if ($regionStack.Count -gt 0) {
            Write-Warning "Found $($regionStack.Count) unclosed #region blocks at the end of the file:"
            $regionStack | ForEach-Object { Write-Warning "  Unclosed region '$($_.Name)' started at L:$($_.StartLine)" }
        }
        Write-Verbose "Finished region parsing. Added $regionCount completed #region blocks."

    } else {
         Write-Warning "Tokens were not available, skipping region parsing."
    }
    # --- END Region Parsing Logic ---

    # Sort the final list by start line number
    $sortedSections = $sections | Sort-Object -Property StartLine

    Write-Verbose "Returning data for $($sortedSections.Count) sections."
    return $sortedSections
}
function Get-PhaseSpans {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$LinesWithFinalPhase, # Each object has .LineNumber, .FinalPhaseName

        [Parameter(Mandatory = $true)]
        [int]$TotalOriginalLines # Total lines in the original script file
    )

    Write-Verbose "Entering simplified Get-PhaseSpans. Processing $($LinesWithFinalPhase.Count) lines with FinalPhaseName."

    $phaseSpansOutput = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($LinesWithFinalPhase.Count -eq 0) {
        Write-Verbose "No lines with FinalPhaseName provided. Returning empty span list."
        return $phaseSpansOutput.ToArray()
    }

    # Initialize counters and state for the first span
    $phaseOccurrenceCounter = @{} # Stores counts for each unique PhaseName string
    
    $currentSpanStartLine = $LinesWithFinalPhase[0].LineNumber
    $currentSpanName = $LinesWithFinalPhase[0].FinalPhaseName
    if ([string]::IsNullOrEmpty($currentSpanName)) {
        # Handle case where first line might have an empty/null FinalPhaseName (should ideally not happen)
        Write-Warning "First line has an empty or null FinalPhaseName. Treating as 'UndefinedPhase'."
        $currentSpanName = "UndefinedPhase"
    }

    # Loop from the second line to detect changes
    for ($i = 1; $i -lt $LinesWithFinalPhase.Count; $i++) {
        $currentLineFinalPhase = $LinesWithFinalPhase[$i].FinalPhaseName
        if ([string]::IsNullOrEmpty($currentLineFinalPhase)) {
            Write-Warning "Line $($LinesWithFinalPhase[$i].LineNumber) has an empty or null FinalPhaseName. Treating as 'UndefinedPhase'."
            $currentLineFinalPhase = "UndefinedPhase"
        }

        if ($currentLineFinalPhase -ne $currentSpanName) {
            # Phase has changed, finalize the previous span
            $previousSpanEndLine = $LinesWithFinalPhase[$i-1].LineNumber # End line is the previous line
            $spanCount = $previousSpanEndLine - $currentSpanStartLine + 1

            if (-not $phaseOccurrenceCounter.ContainsKey($currentSpanName)) {
                $phaseOccurrenceCounter[$currentSpanName] = 0
            }
            $phaseOccurrenceCounter[$currentSpanName]++
            $occurrence = $phaseOccurrenceCounter[$currentSpanName]

            $phaseSpansOutput.Add([PSCustomObject]@{
                PhaseName  = $currentSpanName
                StartLine  = $currentSpanStartLine
                EndLine    = $previousSpanEndLine
                SpanCount  = $spanCount
                Occurrence = $occurrence
            })
            Write-Verbose "  Span Calculated: $currentSpanName (x$occurrence) L:$currentSpanStartLine - L:$previousSpanEndLine ($spanCount lines)"

            # Start a new span
            $currentSpanStartLine = $LinesWithFinalPhase[$i].LineNumber
            $currentSpanName = $currentLineFinalPhase
        }
    }

    # Add the very last span after the loop finishes
    if ($LinesWithFinalPhase.Count -gt 0) { # Ensure there was at least one line
        $lastSpanEndLine = $TotalOriginalLines # Last span goes to the end of the file
        if ($LinesWithFinalPhase[-1].LineNumber -gt $lastSpanEndLine) {
             if ($currentSpanStartLine -gt $TotalOriginalLines -and $TotalOriginalLines -ge 0) {
                 $lastSpanEndLine = $LinesWithFinalPhase[-1].LineNumber;
                 Write-Warning "Current span start L$($currentSpanStartLine) is past TotalOriginalLines ($TotalOriginalLines). Capping last span end at L$($lastSpanEndLine)."
             } else {
                # If TotalOriginalLines is -1 (unknown), use the last line's number
                if ($TotalOriginalLines -lt 0) { $lastSpanEndLine = $LinesWithFinalPhase[-1].LineNumber}
             }
        }
         if ($lastSpanEndLine -lt $currentSpanStartLine) { # Sanity check if start line somehow got past end line
            $lastSpanEndLine = $currentSpanStartLine
        }


        $spanCount = $lastSpanEndLine - $currentSpanStartLine + 1

        if (-not $phaseOccurrenceCounter.ContainsKey($currentSpanName)) {
            $phaseOccurrenceCounter[$currentSpanName] = 0
        }
        $phaseOccurrenceCounter[$currentSpanName]++
        $occurrence = $phaseOccurrenceCounter[$currentSpanName]

        $phaseSpansOutput.Add([PSCustomObject]@{
            PhaseName  = $currentSpanName
            StartLine  = $currentSpanStartLine
            EndLine    = $lastSpanEndLine
            SpanCount  = $spanCount
            Occurrence = $occurrence
        })
        Write-Verbose "  Span Calculated (Last): $currentSpanName (x$occurrence) L:$currentSpanStartLine - L:$lastSpanEndLine ($spanCount lines)"
    }

    Write-Verbose "Exiting simplified Get-PhaseSpans. Returning $($phaseSpansOutput.Count) spans."
    return $phaseSpansOutput.ToArray()
}
function Get-MultiLineCommentRanges {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [hashtable]$CommentProfile
    )

    # Validate profile minimally for multi-line markers
    if (-not $CommentProfile.ContainsKey('MultiStart') -or -not $CommentProfile.ContainsKey('MultiEnd')) {
        Write-Verbose "Comment profile does not contain MultiStart/MultiEnd keys for '$FilePath'. Cannot find multi-line blocks if these specific keys are intended for the primary pair."
        # Allow processing if alt pairs exist or if user expects empty due to this.
    }

    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        Write-Error "File not found: $FilePath"
        return $null
    }

    try {
        $Lines = Get-Content -Path $FilePath
    } catch {
        Write-Error "Error reading file '$FilePath': $($_.Exception.Message)"
        return $null
    }

    $commentRanges = [System.Collections.Generic.List[PSCustomObject]]::new()
    $InsideMultiLineComment = $false
    $currentBlockStartLine = 0
    $CurrentMultiStartMarker = $null

    $multiLinePairs = [System.Collections.Generic.List[object]]::new()
    if ($CommentProfile.ContainsKey('MultiStart') -and $CommentProfile.ContainsKey('MultiEnd') -and $null -ne $CommentProfile.MultiStart -and $null -ne $CommentProfile.MultiEnd -and $CommentProfile.MultiStart -ne '' -and $CommentProfile.MultiEnd -ne '') {
        $multiLinePairs.Add(@{ Start = $CommentProfile.MultiStart; End = $CommentProfile.MultiEnd })
    }
    if ($CommentProfile.ContainsKey('AltMultiStart') -and $CommentProfile.ContainsKey('AltMultiEnd') -and $null -ne $CommentProfile.AltMultiStart -and $null -ne $CommentProfile.AltMultiEnd -and $CommentProfile.AltMultiStart -ne '' -and $CommentProfile.AltMultiEnd -ne '') {
        $multiLinePairs.Add(@{ Start = $CommentProfile.AltMultiStart; End = $CommentProfile.AltMultiEnd })
    }

    if ($multiLinePairs.Count -eq 0) {
        Write-Verbose "No valid MultiStart/MultiEnd pairs (non-null, non-empty) found in profile for '$FilePath'. Cannot find multi-line blocks."
        return @()
    }

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $lineNumber = $i + 1
        $Line = $Lines[$i]
        $TrimmedLine = $Line.Trim()

        if ($TrimmedLine.Length -eq 0) { continue } # Skip blank lines

        # --- PRIORITY 1: If inside a multi-line comment, look for its end. ---
        if ($InsideMultiLineComment) {
            $ExpectedEndMarker = $null
            # Find the End marker corresponding to the CurrentMultiStartMarker
            foreach ($pairCheck in $multiLinePairs) {
                if ($pairCheck.Start -eq $CurrentMultiStartMarker) {
                    $ExpectedEndMarker = $pairCheck.End
                    break
                }
            }

            # Check if line contains the expected end marker
            if ($null -ne $ExpectedEndMarker -and $TrimmedLine.IndexOf($ExpectedEndMarker) -ne -1) {
                $commentRanges.Add([PSCustomObject]@{
                    StartLine = $currentBlockStartLine
                    EndLine   = $lineNumber
                })
                $InsideMultiLineComment = $false
                $CurrentMultiStartMarker = $null
                # Note: This assumes the rest of the line after ExpectedEndMarker is not starting a new comment.
            }
            # Regardless of finding the end marker on this line, this line is part of the current comment block.
            # Continue to the next line.
            continue
        }

        # --- PRIORITY 2: If not inside a comment, look for a new start marker. ---
        # This part is reached only if $InsideMultiLineComment was false for this line.
        
        foreach ($pair in $multiLinePairs) {
            $StartMarker = $pair.Start
            $EndMarker = $pair.End # EndMarker for this specific StartMarker

            if ($TrimmedLine.StartsWith($StartMarker)) {
                # Line starts with a potential comment marker.
                
                # Check if it also ends on the same line.
                # Content of the potential comment is what's after the StartMarker.
                $contentAfterStartMarker = $TrimmedLine.Substring($StartMarker.Length)
                $endMarkerPosInContent = $contentAfterStartMarker.IndexOf($EndMarker)

                if ($endMarkerPosInContent -ne -1) {
                    # Yes, it's a single-line block comment (e.g., <# ... #>)
                    $commentRanges.Add([PSCustomObject]@{
                        StartLine = $lineNumber
                        EndLine   = $lineNumber
                    })
                    # $InsideMultiLineComment remains false. $CurrentMultiStartMarker remains null.
                    # This line has been processed for this type of comment.
                } else {
                    # No, it's the start of a multi-line comment that does not end on this line.
                    $InsideMultiLineComment = $true
                    $currentBlockStartLine = $lineNumber     # Record where this current multi-line block started
                    $CurrentMultiStartMarker = $StartMarker  # Record which marker started it
                }
                
                # Whether it was a single-line block or the start of a multi-line block,
                # we've processed the first start marker found on this line according to $multiLinePairs order.
                # So, break from the foreach ($pair in $multiLinePairs) loop.
                break 
            }
        } # End foreach $pair

        # If a multi-line comment block was *just started* on this line,
        # (i.e., $InsideMultiLineComment became true AND it was for the current $lineNumber),
        # then continue to the next line.
        if ($InsideMultiLineComment -and $currentBlockStartLine -eq $lineNumber) {
            continue
        }
        # If it was a single-line block, $InsideMultiLineComment is false, so this 'if' is false.
        # The loop will naturally proceed to the next line.
    } # End line processing loop

    if ($InsideMultiLineComment) {
        Write-Warning "File '$FilePath' ended while inside a multi-line comment that started on line $currentBlockStartLine (using marker '$CurrentMultiStartMarker')."
        # Optionally, add the partial range:
        # $commentRanges.Add([PSCustomObject]@{ StartLine = $currentBlockStartLine; EndLine = $Lines.Count })
    }

    return $commentRanges.ToArray()
}
Export-ModuleMember -Function *