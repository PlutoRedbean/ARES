# guard/web —— 浏览器演示台

接线面板式的单页应用：左边选样例，中间发文本看板子处理，右边看脱敏结果与审计行。
页面本身是纯静态的；**烧写、串口占用和 IMU 接管由本地 `tools/board_server.py` 托管**
（浏览器不能直接调 `cdt_cfg`，也不能结束别的进程）。

```powershell
# 推荐：run.sh 自动选 Windows / WSL / Git Bash 的 Python，并打开浏览器
cd app/guard
bash run.sh web

# PowerShell 原生入口（内部还是调 run.sh）
.\run.ps1 web

# 或者只起服务、不自动开浏览器
bash run.sh web --no-browser --port 8788
py -3.11 tools/board_server.py --port 8788
```

浏览器打开 **http://127.0.0.1:8788**，用 **Chrome / Edge**（Web Serial 只在这两个里可用；
`http://127.0.0.1` 属于安全上下文，可以直接开串口）。只做回放、不烧写时，也可以用
`make web` / `python -m http.server` 托管；但 IMU 接管和烧写会提示本地服务未启动。

## 四条数据来源

| 模式 | 数据来源 | 需要板子 | 说明 |
|---|---|---|---|
| **串口实时** | Web Serial → 板子 | ✅ | 点「连接串口」选 COM 口（115200），再点发送 |
| **板上实测回放** | `demos.js` | ❌ | 5 条样例的真板回显，演示动画用 |
| **本地规则预览** | `engine.js` | ❌ | 浏览器里的 L1 规则 + 词典实体层，任意文本即时预览 |
| **IMU 手柄** | 本地服务 → xbox-controller | ✅ | 一键收串口、切 IMU 遥测、拉起虚拟手柄 |

面板上的数字全部来自这四条路径，没有随机生成的“气氛数据”。

## 文件

| 文件 | 作用 |
|---|---|
| `index.html` | 页面结构（SVG 板卡图：PG2L200H / ARES core / miniTensor / NER / L1） |
| `style.css` | 全部视觉：旋转 logo、电流走线、芯片脉冲、流水线跑马、逐字揭示 |
| `app.js` | 控制面：串口收发、分帧、审计解析、动画调度、数字渲染、IMU 接管 |
| `engine.js` | 浏览器版 L1 + 词典实体层（与 `host/golden` 逐条对齐，**不含 NER**） |
| `data.js` | 静态资料：板卡参数、资源占用、分层说明（改板子后要同步） |
| `demos.js` | **生成物**：`tools/gen_web_demos.py` 从 `examples/demo*.txt` 生成 |
| `favicon.svg` | 图标 |

## 串口协议（与 `tools/serial_host.py` 一致）

1. 文本按句末标点切帧（`。！？；`），过长再按 `，、：）` 切，**每片 ≤ 56 字节**；
2. 逐帧发送：`文本 + LF`，等回显 + 审计行；
3. 板子回：脱敏正文 + `\r\n` + `[guard] n=... id18=... mode=...`；
4. 前端把每帧的正文拼起来、审计计数相加，最后展示汇总。

> 为什么要切帧：板子对 **>64 字节**的帧会提前收帧（摘要行插进正文），这是 RTL 侧待修的
> 问题，见 `../TODO.md`。切帧是上位机的规避手段，不是协议要求。

## 烧写

RTT 控制台右侧的 **FLASH / 烧写** 卡会从 `/api/board/bitstreams` 列出 `build/` 和 `prj_tasks/` 下的
`.sbit`，默认选最新的一份。点「烧写位流」后：

1. 如果串口已连接，先断开；
2. `POST /api/board/program`；
3. `board_server.py` 调用 `tools/program_guard.ps1`（`cdt_js` + `cdt_cfg`）；
4. 烧写日志和 `The done bit is 1` 直接回显在 RTT 终端里。

浏览器不能自己调 `cdt_cfg`，所以这个按钮必须通过本地 `board_server.py` 才能用；用
`python -m http.server` 打开时烧写卡会提示“本地烧写服务未启动”。

## RTT 控制台

导航栏的「RTT 控制台」是独立页面。连接串口后停在 `msh >`，不会自动进入 Guard。页面提供：

- **一键全流程**：`ps` → `ai selftest` → `coremark start 2000` → `guard selftest` → 进入 Guard，右侧流程条逐步点亮；
- MSH：`ps`、`tick`、`irq`、LED；
- AI：`ai status/selftest/start/stop`；
- CoreMark：quick / 20k per hart / validation，完整报告直接进终端，右侧同时解析 `Total ticks` / `Iterations` / `CoreMark/MHz` / PASS；
- Guard：`guard status/selftest`、「进入 Guard」、「退出 Guard 回 MSH」；
- 任意命令输入框（如 `imu status`）。

终端区显示**实际发送的命令**和板子的**原始回读**，包括 CoreMark 的全部行。所有按钮只在 MSH 模式可用；进入 Guard 后 MSH 按钮锁定，退出后恢复。

「进入 Guard」发送 `guard start`，等 `GUARD READY`；「退出 Guard 回 MSH」发送 `0x1D`（Ctrl+]），等 `GUARD EXIT` / `msh >`，**串口保持连接**。直接关闭标签页不会发送退出字节，板子会停在 Guard 会话里。

## IMU 手柄 / 一键接管串口

导航栏的「IMU 手柄」把串口从浏览器、Guard 会话和串口助手里收回来，交给
`app/imu/xbox-controller`：

1. **断开本页 Web Serial**，并通过 `BroadcastChannel("ares-guard-serial")` 通知其它 ARES 标签页一起释放；
2. `board_server.py` 扫描 Windows 进程：命令行里明确带该 COM 口、或进程名属于已知串口工具（`sscom` / PuTTY / RT-Thread / 旧 xbox-controller …）的进程会被结束；
3. 打开串口：板子在 Guard 会话就发 `0x1D` 退出，再发 `ai stop`、`imu start`；
4. 以 `--imu-port <port> --stdin-cmd` 启动 `app/imu/xbox-controller/run.py`，日志实时回显；
5. 「停止手柄」先借宿主串口发 `imu stop`，再结束进程；「仅释放串口」只清占口程序，不启动手柄。

页面上的 **dry-run** 只打印摇杆/按键状态，不写 ViGEmBus，适合先验证链路。占口扫描
只在这个 COM **确实存在且被占用**时才做；COM 不存在时一个进程都不会结束。接管沿用
「数据链路」页的波特率（板子默认 115200；3 Mbaud 只用于仿真通路）。

多个串口时页面优先选 **CP210x / CH340**（盘古板的 USB-UART 常见型号），并在输入框
下方显示完整描述，例如 `COM5 · Silicon Labs CP210x USB to UART Bridge`。如果页面
提示“被占用但没识别到进程”，通常是本页或其它标签页的 Web Serial 还开着，先点顶部
「断开」或关闭 RTT 控制台标签页。

| 接口 | 作用 |
|---|---|
| `GET /api/serial/ports` | 列串口 + xbox-controller 环境（Python / pyserial / PyYAML / vgamepad / profiles） |
| `GET /api/serial/holders?port=COM9` | 端口状态 `open/busy/missing/error` + 疑似占口进程 |
| `POST /api/serial/release` | 只结束占口进程并验证端口可打开 |
| `GET /api/imu/status` | 控制器进程、pid、运行时长、日志尾部、串口列表 |
| `POST /api/imu/takeover` | 一键接管：释放串口 → 退出 Guard → `ai stop` → `imu start` → 启动宿主 |
| `POST /api/imu/stop` | 停止宿主，并向板子补发 `imu stop` |

占口进程的判定在服务端：**浏览器、终端、系统进程永远不会被结束**，启动本服务的
祖先进程也会被排除；已知串口工具名单可以用 `--kill-names "sscom,putty,rtthread"` 覆盖。
不在名单里的自定义工具，只要命令行里带 `--port COM9` / `-p COM9` 也会被识别。

## 已知边界

| 现象 | 原因 |
|---|---|
| 本地预览认不出裸人名/裸地址 | `engine.js` 没有 NER（浏览器里不跑 CNN） |
| 页面连上串口后，命令行工具打不开 COM9 | Web Serial 独占端口；点「断开」或用完关页面 |
| 逐字节的 `*` 会显示成一个 `＊` | 前端按字符折叠，和 `serial_host.py` 的渲染规则一致 |
| IMU 接管提示“串口不存在” | 板子/驱动没枚举出该 COM；先刷新列表，别手填错号 |
| 接管后提示“没有看到 imu started” | 当前位流没有 IMU 线程（或板子还在跑自检）；换 AMP 位流，等自检结束 |
| 另一个浏览器标签页占着串口 | 它不会收到本页的 Web Serial；关掉那个标签页，或让页面由同一个 `board_server.py` 托管 |
| xbox-controller 运行时 RTT 控制台连不上 | 预期：虚拟手柄宿主独占 COM；先在 IMU 页「停止手柄」 |

## 改完东西要做什么

```powershell
python tools/gen_web_demos.py   # examples/ 变了就重新生成 demos.js（或 make web-demos）
```

改了板子（资源/时序/端口）之后，同步 `data.js` 顶部的 `board` / `resources` 两段。
