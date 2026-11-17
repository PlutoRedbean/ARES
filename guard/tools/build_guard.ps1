# 生成 guard 板级位流（Windows + PDS 2025.2）。
#
#   powershell -ExecutionPolicy Bypass -File guard\tools\build_guard.ps1
#   powershell ... -File guard\tools\build_guard.ps1 -Project guard_board
#
# 输出：guard/generate_bitstream/guard_board_top.sbit
# 日志：guard/build/pds_guard.log（失败时脚本会打印日志结尾）
# 耗时：约 5–6 分钟（compile 10 s / synthesize ~2 min / dev_map+pnr ~2 min / 报告+位流 ~1 min）
param(
    [string]$Project = 'guard_board'
)
$ErrorActionPreference = 'Stop'

$guard = Split-Path -Parent $PSScriptRoot
$pds   = 'D:\Pango\PDS_2025.2-SP3-EN-ads\bin\pds_shell.exe'
if (-not (Test-Path $pds)) { throw "pds_shell not found: $pds" }

Push-Location $guard
try {
    New-Item -ItemType Directory -Force 'build\gen' | Out-Null
    Write-Host '[guard] generating keyword package'
    & python tools/gen_keywords.py build/gen/l1_keywords_pkg.sv
    if ($LASTEXITCODE -ne 0) { throw 'gen_keywords.py failed' }

    # L2 的 INT4 权重包也要重生成，否则改了权重还是烧旧表
    & python tools/gen_l2_weights_sv.py build/gen/l2_weights_pkg.sv
    if ($LASTEXITCODE -ne 0) { throw 'gen_l2_weights_sv.py failed' }

    $logDir = Join-Path $guard 'build'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $log = Join-Path $logDir 'pds_guard.log'

    $flow = Join-Path $guard 'fpga\pango\flow_guard.tcl'
    Write-Host "[guard] pds_shell -file $flow"
    & $pds -file $flow -project_name $Project *> $log
    $code = $LASTEXITCODE

    $txt = Get-Content $log -Raw
    if ($txt -match '=== GUARD_BUILD_DONE ===') {
        Write-Host '[guard] build done'
        # flow 结束会把位流抄到 guard/generate_bitstream/；这里再兜一遍
        $sbit = Join-Path $guard 'generate_bitstream\guard_board_top.sbit'
        if (-not (Test-Path $sbit)) {
            $sbit = Join-Path $guard 'prj_tasks\pnr_1\generate_bitstream\guard_board_top.sbit'
        }
        if (Test-Path $sbit) { Write-Host ('  bitstream: ' + $sbit) }
        else { Write-Host '  (WARNING: .sbit not found)' }
        exit 0
    }
    Write-Host "[guard] build FAILED (exit=$code); log tail:"
    Get-Content $log -Tail 40
    exit 1
}
finally {
    Pop-Location
}