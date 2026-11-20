#!/usr/bin/env pwsh
# PowerShell entry point: forwards every argument to run.sh in the same folder.
#
#   .\run.ps1 web
#   .\run.ps1 web --no-browser --port 8788
#   .\run.ps1 serial -p COM9 --ports
#
# run.sh owns the platform logic, so Windows / WSL / Linux share one launcher.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$candidates = @()
if (${env:ProgramFiles}) {
    $candidates += (Join-Path ${env:ProgramFiles} "Git\bin\bash.exe")
}
if (${env:ProgramFiles(x86)}) {
    $candidates += (Join-Path ${env:ProgramFiles(x86)} "Git\bin\bash.exe")
}
if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
}
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git -and $git.Source) {
    $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
    $candidates += (Join-Path $gitRoot "bin\bash.exe")
}

$bash = $null
foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $bash = $candidate
        break
    }
}
if (-not $bash) {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) { $bash = $cmd.Source }
}
if (-not $bash) {
    throw "bash not found: install Git for Windows, or run 'bash run.sh web' inside WSL."
}

Push-Location $here
try {
    if (-not $Rest -or $Rest.Count -eq 0) {
        $Rest = @("help")
    }
    & $bash "./run.sh" @Rest
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
