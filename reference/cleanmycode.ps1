param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath
)
try {
    $resolvedPath = Get-Item -Path $FilePath -ErrorAction Stop | 
                   Select-Object -ExpandProperty FullName
    $originalContent = Get-Content -Path $resolvedPath -Raw
}
catch {
    Write-Error "File not found or invalid path: $FilePath"
    exit 1
}
$tokens = @()
$errors = @()
# Parse content to identify comments
$null = [System.Management.Automation.Language.Parser]::ParseInput(
    $originalContent,
    [ref]$tokens,
    [ref]$errors
)

if ($errors) {
    Write-Warning "Input file contains parsing errors. Results might be incomplete."
}

# Create a list of comment ranges to remove
$commentRanges = $tokens | 
    Where-Object { $_.Kind -eq 'Comment' } |
    Sort-Object { $_.Extent.StartOffset } -Descending |
    ForEach-Object { $_.Extent }

# Remove comments from original content while preserving formatting
$contentBuilder = [System.Text.StringBuilder]::new($originalContent)
foreach ($range in $commentRanges) {
    $contentBuilder.Remove($range.StartOffset, $range.EndOffset - $range.StartOffset) | Out-Null
}

# Process cleaned content
$cleanedContent = $contentBuilder.ToString()
$finalLines = $cleanedContent -split "\r?\n" | 
    Where-Object { $_.Trim() -ne '' }

# Create output path
$outputPath = Join-Path -Path (Split-Path $resolvedPath -Parent) `
    -ChildPath "$(Split-Path $resolvedPath -LeafBase)_cleaned.ps1"

# Write output preserving original line endings
if ($finalLines.Count -gt 0) {
    $finalLines -join "`r`n" | Out-File -FilePath $outputPath -Encoding utf8
    Write-Host "Cleaned file created at: $outputPath"
}
else {
    Write-Warning "No content remained after cleaning"
}