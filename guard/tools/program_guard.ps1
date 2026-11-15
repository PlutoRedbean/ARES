# 烧写 guard 板级位流（JTAG）。
#
#   powershell -ExecutionPolicy Bypass -File guard\tools\program_guard.ps1
#   powershell ... -File guard\tools\program_guard.ps1 -Bitstream guard\generate_bitstream\guard_board_top.sbit
#   powershell ... -File guard\tools\program_guard.ps1 -KeepServer
#
# 流程：确保 cdt_js（JTAG 服务器）在 60000 端口 -> cdt_cfg 跑
# fpga/pango/program_guard.tcl -> 扫描链 -> 下发 .sbit。
#
# 三个老坑（都在脚本/资源里处理了）：
#   1. cdt_cfg 的 -args 会吃掉反斜杠：位流路径必须绝对路径 + 正斜杠；
#   2. tcl 必须 ASCII-only，且只能有一个 %s 占位（中文注释会让 Tcl 吞掉换行，
#      报 'can't read "port": no such variable'）；
#   3. cdt_cfg 把日志写到 <cwd>\log\cfg.log 而不是 stdout，判定要看那个文件。
param(
    [string]$Bitstream = '',
    [switch]$KeepServer
)
$ErrorActionPreference = 'Stop'

$guard = Split-Path -Parent $PSScriptRoot
$bin   = 'D:\Pango\PDS_2025.2-SP3-EN-ads\bin'
$js    = Join-Path $bin 'cdt_js.exe'
$cfg   = Join-Path $bin 'cdt_cfg.exe'
$port  = 60000

foreach ($exe in @($js, $cfg)) {
    if (-not (Test-Path $exe)) { throw "找不到 $exe（PDS 装在这里吗？）" }
}

# 位流：默认取最新的一份
if (-not $Bitstream) {
    $Bitstream = Get-ChildItem (Join-Path $guard 'generate_bitstream') -Filter '*.sbit' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $Bitstream) {
        $Bitstream = Join-Path $guard 'prj_tasks\pnr_1\generate_bitstream\guard_board_top.sbit'
    }
}
if (-not (Test-Path $Bitstream)) {
    throw ("位流不存在：{0}；先跑 tools\build_guard.ps1 生成。" -f $Bitstream)
}
$abs  = ((Resolve-Path $Bitstream).Path) -replace '\\', '/'
$size = (Get-Item (Resolve-Path $Bitstream).Path).Length
Write-Host ("[guard] bitstream : {0}  ({1:N0} B)" -f $abs, $size)
if ($size -lt 1000000) { Write-Warning '位流小于 1 MB，可能不是完整的 .sbit' }

# JTAG 服务器
$serverProc = Get-Process cdt_js -ErrorAction SilentlyContinue
if (-not $serverProc) {
    Start-Process -FilePath $js -ArgumentList '-port', $port -WorkingDirectory $guard -WindowStyle Hidden
    Start-Sleep -Seconds 4
    Write-Host "[guard] started cdt_js on port $port"
} else {
    Write-Host "[guard] cdt_js already running (pid $($serverProc.Id)); 假设它监听 $port"
    Write-Host '        如果连接失败，先 taskkill /IM cdt_js.exe /F 再重跑。'
}

# 下发（cdt 的日志落在 <cwd>\log\cfg.log，先清掉旧的）
Set-Location $guard
$cfgLog = Join-Path $guard 'log\cfg.log'
if (Test-Path $cfgLog) { Remove-Item $cfgLog -Force }
Write-Host '[guard] cdt_cfg -file fpga\pango\program_guard.tcl ...'

# cdt_cfg 是 GUI 子系统的 exe：用管道调用不会等它，拿到的是空输出/空退出码。
# 必须 Start-Process -Wait，然后再去读它写的 log\cfg.log。
$tclAbs = Join-Path $guard 'fpga\pango\program_guard.tcl'
$proc   = Start-Process -FilePath $cfg -ArgumentList @('-file', $tclAbs, '-args', $abs) -Wait -PassThru -NoNewWindow
$code   = $proc.ExitCode

# 日志可能比进程晚落盘一点点，最多等 3 秒
for ($i = 0; $i -lt 30; $i++) {
    if (Test-Path $cfgLog) { break }
    Start-Sleep -Milliseconds 100
}

$transcript = ''
if (Test-Path $cfgLog) { $transcript = Get-Content $cfgLog -Raw }
if ($transcript) {
    Write-Host '--- cdt_cfg transcript (tail) ---'
    ($transcript -split "`r?`n") | Select-Object -Last 14 | ForEach-Object { Write-Host ('  ' + $_) }
}

$hasErr = $transcript -match '(?m)^\s*E:'
$scanOk = $transcript -match 'PG2L200H'
$progOk = $transcript -match 'cfg_program.*successfully'
$ok     = (-not $hasErr) -and $scanOk -and ($code -eq 0)

if ($ok) {
    Write-Host '[guard] PROGRAM OK -- 板上 led[7] 应该常亮（PLL 锁定），led[3] 应该灭' -ForegroundColor Green
    Write-Host '        接着按 docs\board-bringup.md 第 4 步做串口第一测。'
} else {
    Write-Host ("[guard] PROGRAM FAILED (exit={0}, scan={1}, prog={2}, err={3})" -f $code, $scanOk, $progOk, $hasErr) -ForegroundColor Red
    if ($transcript -match 'get_cable_paras' -and -not ($transcript -match 'Cable index')) {
        Write-Host '=> 没检测到 JTAG 下载器（The cable List 为空）。先解决硬件连接，再谈位流。' -ForegroundColor Yellow
    }
    if (-not $scanOk) {
        Write-Host '=> 扫描链里没有 PG2L200H：板子没上电 / JTAG 线松 / 驱动没装。' -ForegroundColor Yellow
    }
    Write-Host '检查清单：'
    Write-Host '  1. JTAG 下载器插好了吗？设备管理器里能看到 Pango USB Cable 吗？'
    Write-Host '  2. 板子供电/开关打开了吗？transcript 里 "The cable List" 应该是空的才算没接。'
    Write-Host '  3. 扫描不到 PG2L200H = 线/驱动/板子供电问题，不是位流问题。'
    Write-Host '  4. 端口要一致：cdt_js -port 60000 与 tcl 里 cfg_connect -port 60000。'
    Write-Host '  5. tcl 必须 ASCII-only 且只有一个 %s（别往注释里写 %s）。'
    if (-not $KeepServer) { Get-Process cdt_js -ErrorAction SilentlyContinue | Stop-Process -Force }
    exit 1
}

if (-not $KeepServer) {
    Get-Process cdt_js -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host '[guard] cdt_js stopped（下次烧写会重新起）'
}
exit 0
