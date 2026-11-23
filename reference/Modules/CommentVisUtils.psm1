function IsLastSibling {
    param(
        [Parameter(Mandatory=$true)]
        [int]$Index,
        [Parameter(Mandatory=$true)]
        [System.Collections.IList]$CommentsList # Use IList for flexibility (covers arrays, lists)
    )
    # Input validation
    if ($Index -lt 0 -or $Index -ge $CommentsList.Count) {
        Write-Warning "IsLastSibling: Index $Index out of bounds (List count: $($CommentsList.Count)). Assuming not last."
        return $false # Or throw an error depending on desired strictness
    }

    $currentLevel = $CommentsList[$Index].Level
    # Iterate through subsequent comments
    for ($j = $Index + 1; $j -lt $CommentsList.Count; $j++) {
        $nextLevel = $CommentsList[$j].Level
        # If we find another comment at the same level, the current one isn't the last.
        if ($nextLevel -eq $currentLevel) { return $false }
        # If we find a comment at a higher level (parent), the current one is the last among its siblings.
        if ($nextLevel -lt $currentLevel) { return $true }
        # If we find a comment at a deeper level (child), continue checking further siblings.
    }
    # If we reach the end of the list without finding another sibling at the same level or a parent, it's the last.
    return $true
}
function Write-CodeLineColored {
    param (
        [string]$line,
        [string]$IndentPrefix # Pass indent separately
    )

    # --- Color Definitions for Write-Host ---
    # Using standard PowerShell color names
    $ColorString   = 'Green'    # Or 'BrightGreen' etc.
    $ColorKeyword  = 'Yellow'
    $ColorVariable = 'Cyan' 
    $ColorNumber   = 'Magenta'
    $ColorOperator = 'Gray'     # Or 'DarkGray'
    $ColorComment  = 'White' 
    $ColorDefault  = $Host.UI.RawUI.ForegroundColor # Get current default

    # --- Token Regex Patterns ---
    # Order matters for overlap precedence
    $tokenPatterns = @(
        @{Type='Comment';  Regex='(#.*)'} 
        @{Type='String';   Regex='(".*?\"|''.*?'')'}
        @{Type='Variable'; Regex='(\$(\w+(\.\w+)*)|\{[^}]+\})'} 
        @{Type='Keyword';  Regex='\b(if|else|foreach|return|Write-Host|Write-Verbose|param|function|string|int|bool|true|false|null|switch|case|default|while|do|until|try|catch|finally|throw)\b'}
        @{Type='Number';   Regex='\b(\d+(\.\d+)?)\b'} 
        @{Type='Operator'; Regex='[-=+\*\/%&|!<>.,:;\[\]{}()@]+'} 
    )

    $allMatches = [System.Collections.Generic.List[object]]::new()
    foreach ($patternInfo in $tokenPatterns) {
        try {
            $regexMatches = [regex]::Matches($line, $patternInfo.Regex)
            foreach ($match in $regexMatches) {
                if ($match.Success -and $match.Length -gt 0) {
                     $allMatches.Add([PSCustomObject]@{Type = $patternInfo.Type; Index = $match.Index; Length = $match.Length; Value = $match.Value})
                }
            }
        } catch { Write-Warning "Regex error for type $($patternInfo.Type): $($_.Exception.Message)" }
    }

    $sortedMatches = $allMatches | Sort-Object Index
    $filteredMatches = [System.Collections.Generic.List[object]]::new()
    $lastIndexProcessed = 0
    foreach ($match in $sortedMatches) {
        if ($match.Index -ge $lastIndexProcessed) {
            $filteredMatches.Add($match)
            $lastIndexProcessed = $match.Index + $match.Length
        }
    }

    # --- Write line piece by piece ---
    Write-Host $IndentPrefix -NoNewline # Print indent first

    $currentIndex = 0
    foreach ($match in $filteredMatches) {
        # Write text BEFORE the current match (using default color)
        if ($match.Index -gt $currentIndex) {
            $subString = $line.Substring($currentIndex, $match.Index - $currentIndex)
            Write-Host $subString -ForegroundColor $ColorDefault -NoNewline
        }

        # Determine color for this match
        $foregroundColor = $ColorDefault # Fallback
        switch ($match.Type) {
            'Comment'  { $foregroundColor = $ColorComment }
            'String'   { $foregroundColor = $ColorString }
            'Keyword'  { $foregroundColor = $ColorKeyword }
            'Variable' { $foregroundColor = $ColorVariable }
            'Number'   { $foregroundColor = $ColorNumber }
            'Operator' { $foregroundColor = $ColorOperator }
        }

        # Write the colored match content
        Write-Host $match.Value -ForegroundColor $foregroundColor -NoNewline 

        # Update current position
        $currentIndex = $match.Index + $match.Length
    }

    # Write any remaining text after the last match (using default color)
    # This call adds the final newline for the whole line.
    if ($currentIndex -lt $line.Length) {
        $subString = $line.Substring($currentIndex)
        Write-Host $subString -ForegroundColor $ColorDefault
    } else {
         # Ensure a newline if the last match ended exactly at the end of the line
         Write-Host "" 
    }
}
function Select-SingleLineComment {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$LanguageProfile,

        [Parameter(Mandatory = $true, Position = 0)] # Changed line
        [System.Object[]]
        $InputObject
    )

    # Process the entire input collection at once, similar to the original script flow
    # Using begin/process/end might be slightly more idiomatic for pipeline functions,
    # but this mirrors the original logic more closely since sorting happens first.
    end {
        $commentsToFilter = $InputObject # InputObject contains all items when used in 'end' block

        Write-Verbose "Entering Select-SingleLineComment Function..."# Added -Verbose switch propagation
        $unfilteredCommentCount = $commentsToFilter.Count
        Write-Verbose "Function received $unfilteredCommentCount comments to filter."

        # --- Define Exclusion Patterns (Local to function) ---
        $excludeRawPattern3 = '^\s*#\s---'
        $excludeRawPattern4 = '^\s*#\S\S*$'
        $excludeRawPattern5 = '^\s*(?:#|\/\/)[^a-zA-Z0-9\s][a-zA-Z]{3,}'
        $excludeRawPattern6 = '^\s*(?:#|\/\/)[^a-zA-Z0-9\s](?=[a-zA-Z0-9]*[a-zA-Z])[a-zA-Z0-9]{3,}'
        $excludeHashSpaceLetter = '^\s*#\s+[a-zA-Z]'
        $excludeHash3PlusLetter = '^\s*#[a-zA-Z]{3,}'

        # --- Apply Filter Pass 1 (Regex Exclusions) ---
        Write-Verbose "Applying filter Pass 1 (Regex Exclusions)..." 
        Write-Verbose "Using Exclude Patterns: P3='$excludeRawPattern3', P4='$excludeRawPattern4', P5='$excludeRawPattern5', P6='$excludeRawPattern6', HSL='$excludeHashSpaceLetter', H3L='$excludeHash3PlusLetter'"

        $commentsAfterFirstFilter = $commentsToFilter | Where-Object {
            $originalLine = $_.OriginalLine
            # Assume non-null OriginalLine based on upstream processing, or handle if needed:
            # if ($null -eq $originalLine) { Write-Warning "OriginalLine missing for comment at $($_.LineNumber), keeping."; return $true }

            $matchesExclusion = ($originalLine -match $excludeRawPattern3) -or `
                                ($originalLine -match $excludeRawPattern4) -or `
                                ($originalLine -match $excludeRawPattern5) -or `
                                ($originalLine -match $excludeRawPattern6) -or `
                                ($originalLine -match $excludeHashSpaceLetter) -or `
                                ($originalLine -match $excludeHash3PlusLetter)

            -not $matchesExclusion # Keep if it does NOT match any exclusion
        }
        $filteredCountFirstPass = $unfilteredCommentCount - $commentsAfterFirstFilter.Count
        Write-Verbose "Filtered out $filteredCountFirstPass comments in Pass 1."

        # --- Apply Filter Pass 2 (Alphanumeric Check) ---
        Write-Verbose "Applying filter Pass 2 (Alphanumeric Check on first 1-3 chars)..."
        $commentsBeforeSecondFilter = $commentsAfterFirstFilter.Count

        $finalFilteredComments = $commentsAfterFirstFilter | Where-Object {
            $line = $_.OriginalLine
            if ([string]::IsNullOrWhiteSpace($line)) { return $false }

            $trimmedLine = $line.TrimStart()
            $markerOffset = 0
            $markerFound = $false

            if ($null -ne $LanguageProfile.SingleLine -and $LanguageProfile.SingleLine.Count -gt 0) {
                # Loop through markers from the profile parameter
                foreach ($marker in $LanguageProfile.SingleLine) {
                    # Skip if marker is null/empty (safety check)
                    if ([string]::IsNullOrEmpty($marker)) { continue }
            
                    if ($trimmedLine.StartsWith($marker)) {
                        $markerOffset = $marker.Length
                        $markerFound = $true
                        # $actualMarker = $marker # Optional
                        break # Found the marker for this line
                    }
                }
            } else {
                # Handle case where the profile is missing SingleLine markers (shouldn't happen)
                Write-Warning "Language profile '$($LanguageProfile.Name)' is missing SingleLine definitions."
                return $false # Filter out if we can't determine the marker
            }

            # If no marker (shouldn't happen if input is only comments), filter out
            if (-not $markerFound) { return $false }

            $textAfterMarker = $trimmedLine.Substring($markerOffset)
            if ($textAfterMarker.Length -eq 0) { return $false }

            $charsToTest = $textAfterMarker.Substring(0, [System.Math]::Min($textAfterMarker.Length, 3))
            $containsAlphanumeric = $charsToTest -match '[a-zA-Z0-9]'

            # Keep if alphanumeric is found
            return $containsAlphanumeric
        }

        $filteredCountSecondPass = $commentsBeforeSecondFilter - $finalFilteredComments.Count
        # Use Write-Host for this summary message like the original script
        Write-Verbose "Filtered out $filteredCountSecondPass additional comments based on alphanumeric check (first 1-3 chars after marker)."

        # --- Apply Filter Pass 3 (Content must contain letters) ---
        Write-Verbose "Applying filter Pass 3 (Comment text must contain letters)..."
        $commentsBeforeThirdFilter = $finalFilteredComments.Count # Input is the result from Pass 2

        # Re-assign to the same variable to chain the filtering
        $finalFilteredComments = $finalFilteredComments | Where-Object {
            $line = $_.OriginalLine
            $trimmedLine = $line.TrimStart()
            $markerOffset = 0
            $markerFound = $false

            # Same logic to find marker and offset as Pass 2
            if ($null -ne $LanguageProfile.SingleLine -and $LanguageProfile.SingleLine.Count -gt 0) {
                # Loop through markers from the profile parameter
                foreach ($marker in $LanguageProfile.SingleLine) {
                    # Skip if marker is null/empty (safety check)
                    if ([string]::IsNullOrEmpty($marker)) { continue }
            
                    if ($trimmedLine.StartsWith($marker)) {
                        $markerOffset = $marker.Length
                        $markerFound = $true
                        # $actualMarker = $marker # Optional
                        break # Found the marker for this line
                    }
                }
            } else {
                # Handle case where the profile is missing SingleLine markers (shouldn't happen)
                Write-Warning "Language profile '$($LanguageProfile.Name)' is missing SingleLine definitions."
                return $false # Filter out if we can't determine the marker
            }

            # If marker somehow missing, filter out (shouldn't happen after Pass 2)
            if (-not $markerFound) { return $false }

            $textAfterMarker = $trimmedLine.Substring($markerOffset)

            # Important: Also filter out comments that are *only* whitespace after marker
            if ($textAfterMarker.Trim().Length -eq 0) { return $false }

            # --- NEW RULE IMPLEMENTATION ---
            # Check if the entire comment text contains at least one letter (case-insensitive)
            $containsLetter = $textAfterMarker -match '[a-zA-Z]'

            # Keep the comment ($true) only if it contains a letter
            return $containsLetter
            # --- END NEW RULE ---
        }

        $filteredCountThirdPass = $commentsBeforeThirdFilter - $finalFilteredComments.Count
        Write-Verbose "Filtered out $filteredCountThirdPass comments in Pass 3 (text lacked letters)."

        # The final Write-Verbose and return statement will now use the result of Pass 3
        Write-Verbose "Select-SingleLineComment Function returning $($finalFilteredComments.Count) comments."
        # Output the final filtered collection
        return $finalFilteredComments
    } # Closes the end {} block
}
function Get-LanguageProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$FilePath
    )

    # --- Define Language Profiles ---
    # Store profiles in a hashtable for easy lookup
    $profiles = @{
        # PowerShell Profile
        powershell = @{
            Name                  = 'PowerShell'
            SingleLine            = @('#')            # Array for consistency
            BlockStart            = @('<#')           # Array for consistency
            BlockEnd              = @('#>')           # Array for consistency
            RegionStart           = 'region'
            RegionEnd             = 'endregion'
            StringDelimiters      = @("'", '"')       # Single and double quotes
            EscapeCharacter       = '`'               # Backtick escape
            CaseSensitiveKeywords = $false            # #region is case-insensitive
            Warning               = $null
        }

        # Python Profile
        python = @{
            Name                  = 'Python'
            SingleLine            = @('#')            # Standard single-line comment
            BlockStart            = @('"""', "'''")   # Triple-double and triple-single quotes
            BlockEnd              = @('"""', "'''")   # Match BlockStart for triple quotes
            RegionStart           = $null             # No standard equivalent
            RegionEnd             = $null             # No standard equivalent
            StringDelimiters      = @("'", '"', '"""', "'''") # All quote types
            EscapeCharacter       = '\'               # Backslash escape
            CaseSensitiveKeywords = $true             # N/A for regions, but Python keywords are generally case-sensitive
            Warning               = $null
        }

        # Default Profile (Fallback - uses PowerShell syntax as the base)
        default = @{
            Name                  = 'Default (PowerShell Syntax)'
            SingleLine            = @('#')
            BlockStart            = @('<#')
            BlockEnd              = @('#>')
            RegionStart           = 'region'
            RegionEnd             = 'endregion'
            StringDelimiters      = @("'", '"')
            EscapeCharacter       = '`'
            CaseSensitiveKeywords = $false
            # Warning message placeholder - will be customized
            Warning               = "Language profile for extension '{0}' not found. Using default (PowerShell) syntax. Results may be inaccurate."
        }
    }

    # --- Determine Profile ---
    $selectedProfile = $null
    $extension = '' # Initialize extension variable

    try {
        # Get the file extension (e.g., ".ps1", ".py"). ToLower() ensures case-insensitivity.
        $extension = ([System.IO.Path]::GetExtension($FilePath)).ToLower()
    } catch {
        Write-Warning "Could not determine file extension for '$FilePath'. Error: $($_.Exception.Message). Using default profile."
        $selectedProfile = $profiles.default
        # Customize the warning message
        $selectedProfile.Warning = "Could not determine file extension for '$FilePath'. Using default (PowerShell) syntax. Results may be inaccurate."
        return $selectedProfile # Return the default profile directly
    }

    # Select profile based on the extension
    switch ($extension) {
        '.ps1' {
            Write-Verbose "Detected PowerShell file extension ('.ps1')."
            $selectedProfile = $profiles.powershell
        }
        '.py' {
            Write-Verbose "Detected Python file extension ('.py')."
            $selectedProfile = $profiles.python
        }
        # Add more cases here for other languages later:
        # '.js' { $selectedProfile = $profiles.javascript }
        # '.java' { $selectedProfile = $profiles.java }
        default {
            # Get the default profile template
            $selectedProfile = $profiles.default
            # Format the specific warning message for this extension
            $warningMessage = $selectedProfile.Warning -f $extension
            Write-Warning $warningMessage
            # Update the warning message in the profile object being returned
            $selectedProfile.Warning = $warningMessage
        }
    }

    Write-Verbose "Selected language profile: $($selectedProfile.Name) for file '$FilePath'"
    return $selectedProfile
}
Export-ModuleMember -Function *