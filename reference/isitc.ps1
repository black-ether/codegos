function Get-CommentInfo {
    <#
    .SYNOPSIS
        Analyzes a file and provides statistics about comments and code based on the file extension.
    .DESCRIPTION
        This function reads a specified file, determines the language based on the extension,
        and parses its content to count different types of comments (single-line, inline, multi-line/docstrings),
        regions, total comment characters, total comment tokens (words), total code characters, total code lines,
        the percentage of comment lines, and the percentage of comment characters within the script.

        It has built-in profiles for common languages like PowerShell, Python, C#, JavaScript, Rust, C/C++, etc.
    .PARAMETER FilePath
        The path to the source code file to analyze. This parameter is mandatory and accepts pipeline input.
    .PARAMETER CommentProfiles
        A hashtable defining comment patterns for file extensions. You can override or add profiles.
        Each profile should be a hashtable with keys like 'Single', 'MultiStart', 'MultiEnd', 'RegionStart'.
        Example: @{ '.myext' = @{ Single = '--'; MultiStart = '{-'; MultiEnd = '-}' } }
    .EXAMPLE
        Get-CommentInfo -FilePath "C:\Scripts\MyScript.ps1"

        Description: Analyzes the 'MyScript.ps1' PowerShell file.
    .EXAMPLE
        Get-ChildItem -Path "C:\Projects\MyApp" -Include *.py -Recurse | Get-CommentInfo

        Description: Analyzes all Python files found recursively in 'C:\Projects\MyApp'.
    .EXAMPLE
        Get-CommentInfo -FilePath "C:\Code\main.rs"

        Description: Analyzes the 'main.rs' Rust file.
    .EXAMPLE
        $customProfiles = @{
            '.log' = @{ Single = 'INFO:' } # Define a simple profile for .log files
        }
        Get-CommentInfo -FilePath "C:\Logs\app.log" -CommentProfiles $customProfiles

        Description: Analyzes a log file using a custom comment profile.
    .OUTPUTS
        PSCustomObject
        Returns an object containing the comment and code statistics for the analyzed file.
        Properties include: FilePath, LanguageProfile, TotalLines, BlankLines, CodeLines, SingleLineComments,
        InlineComments, MultiLineCommentBlocks, MultiLineCommentLines, RegionCount, TotalCodeChars, TotalCommentChars,
        TotalCommentTokens, CommentCharPercentage, CommentLinePercentage.
    .NOTES
        - The function performs simple text pattern matching. It might misinterpret comment markers
          that appear inside string literals or complex code constructs.
        - "Code Lines" are calculated as Total Lines - Blank Lines - Full Single-Line Comments - Multi-Line Comment Lines.
          Lines with inline comments are still counted as code lines.
        - "Total Code Chars" includes characters on code lines, excluding the comment part of inline comments. Trimmed line length is used.
        - "Comment Line Percentage" is calculated as (SingleLineComments + InlineComments + MultiLineCommentLines) / TotalLines.
        - "Comment Char Percentage" is calculated as TotalCommentChars / (TotalCodeChars + TotalCommentChars).
        - Token counting splits comments by whitespace.
    .LINK
        Get-Content
        Test-Path
        [System.IO.Path]
    #>
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