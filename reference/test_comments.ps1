# test_comments.ps1
Write-Host "Start"
<#
This is block comment 1
It spans multiple lines.
#>
$x = 5
Write-Host "Middle" # Inline
<# Another block #> # Single-line block
$y = 10
<#
Final block
#>
Write-Host "End"