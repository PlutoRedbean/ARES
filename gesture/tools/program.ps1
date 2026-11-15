# Flash a bitstream over JTAG.  Usage: program.ps1 <path-to.sbit>
#
# Two gotchas, both learned the hard way:
#   1. cdt_cfg needs the path with FORWARD slashes; backslashes get eaten
#      by the -args/Tcl substitution and the file ends up 'not readable'.
#   2. The JTAG server (cdt_js) must be running; port 60000 is the default
#      used by the Pangu tooling.
param([Parameter(Mandatory=$true)][string]$Bitstream)
$ErrorActionPreference = 'Stop'
$bin  = 'D:\Pango\PDS_2025.2-SP3-EN-ads\bin'
$here = $PSScriptRoot
if (-not (Test-Path $Bitstream)) { throw "bitstream not found: $Bitstream" }
$abs  = ((Resolve-Path $Bitstream).Path) -replace '\\', '/'
'bitstream: ' + $abs

if (-not (Get-Process cdt_js -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath (Join-Path $bin 'cdt_js.exe') -ArgumentList '-port','60000' -WindowStyle Hidden
    Start-Sleep -Seconds 4
    'started cdt_js on port 60000'
} else { 'cdt_js already running' }

& (Join-Path $bin 'cdt_cfg.exe') -file (Join-Path $here 'program.tcl') -args $abs
'exit: ' + $LASTEXITCODE
