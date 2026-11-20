<#
.SYNOPSIS
  The fixture's unit tests: always pass (run-tests.ps1 makes a failing copy).
#>
$ErrorActionPreference = 'Stop'
$failed = @()
if ($failed) { Write-Host "Unit tests failed: $($failed -join ', ')"; exit 1 }
Write-Host 'All unit tests passed.'
