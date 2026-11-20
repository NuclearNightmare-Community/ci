<#
.SYNOPSIS
  A clean script: no PSScriptAnalyzer Error or Warning under the shared settings (Write-Host is allowed).
#>
param([string] $Name = 'Fixture')
$ErrorActionPreference = 'Stop'
Write-Host "hello $Name"
