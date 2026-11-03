# ARES · 全息手势交互页

> Web Serial + Three.js + Vite + TypeScript
> 串口收到一行 ASCII 指令 → 浏览器状态机 → 程序化全息特效。

本工程是 `docs/ares-holo-serial-plan.md` 的实现版本，工程根目录即计划中的 `ares-holo/`。

## Logo 设计：WAR CORE · 战神核心

![ARES Logo](docs/images/logo.png)

一个标志同时表达两个 ARES：

- **ARES basecore**：六边形芯片封装 + 两侧引脚 + 电路节点；
- **战神 Ares**：科林斯式头盔、盔冠和长矛；
- 盔冠被画成**带节点的电路走线**，把“战神”和“处理器”缝在同一根线上；
- 长矛斜穿芯片，字标 `A` 的顶点本身就是矛尖；
- 底部一小段希腊回纹，保留古希腊词源 `Ἀρης` 的出处；
- 字标 A / R / E / S 为几何切割体，R、E、S 上嵌入电路节点；
- 青 → 紫渐变对应全息界面的主色。

| 资产 | 用途 |
| --- | --- |
| `public/ares-logo.svg` | 首屏、3D 粒子 Logo 采样源 |
| `public/ares-mark.svg` | HUD 左上角品牌标 |
| `public/favicon.svg` | 浏览器标签页图标 |

首屏配合 **WAR CORE · 战神核心** 的副标，明确双关；3D 粒子 Logo 直接从 SVG
采样，因此和静态品牌标完全同源。

![启动画面](docs/images/start.png)

## 1. 效果一览

| 状态 | 预览 |
| --- | --- |
| `READY` 粒子 Logo | ![READY](docs/images/ready.png) |
| `COMPRESS` 能量压缩 | ![COMPRESS](docs/images/compress.png) |
| `TRACK` 激光 / 扫描 | ![TRACK](docs/images/track.png) |
| `MODE_PLANET` 星球 | ![PLANET](docs/images/planet.png) |
| `MODE_DNA` 双螺旋 | ![DNA](docs/images/dna.png) |
| `MODE_SOC` 芯片 | ![SOC](docs/images/soc.png) |
| `CONFIRM` 确认 | ![CONFIRM](docs/images/confirm.png) |
| `ULTIMATE` 爆发 | ![ULTIMATE](docs/images/ultimate.png) |

六种手势 + `RESET`，全部视觉资产程序化生成，无 GLB / 贴图 / 音频文件。

## 2. 快速开始（Windows 11）

### 2.1 环境

- 只需要 Node.js LTS（建议 20.19+ / 22+ / 24+）与 pnpm/npm；构建产物在 `dist/`。
- 菜单 `make web-build`（工程根目录）等价于 `cd web && pnpm install && pnpm build`。
- 浏览器：Chrome 或 Edge（必须是 Chromium 内核）。
- 可选：USB-TTL 3.3 V 模块（CH340 / CP2102 / FT232 等）。

```powershell
node -v
npm -v
```

### 2.2 开发运行

```powershell
cd app/gesture/web
npm install
npm run dev
```

打开 <http://127.0.0.1:5173>。

> 不要双击 `index.html` 用 `file://` 打开。Web Serial 和 ES Module 都要求
> `localhost` 或 https 安全上下文。

### 2.3 构建与演示

```powershell
npm run build
npm run preview
```

打开 <http://127.0.0.1:4173>。

也可以只用 PowerShell 起静态服务器看已有构建（`tools/serve-dist.ps1`），
不依赖 Node：

```powershell
powershell -ExecutionPolicy Bypass -File tools/serve-dist.ps1
```

> **不要双击 `index.html`。** 浏览器需要 `localhost` / https 安全上下文，
> `file://` 下 Web Serial 不可用。

### 2.4 首次连接

1. 点击“启动演示”；
2. 浏览器进入全屏、解锁音频；
3. 弹出串口选择框，选择 USB-TTL 对应的 COM 口；
4. 点击“连接串口”也可单独连接；
5. 若弹窗被取消，页面仍可用键盘 / 演示模式运行。

已授权过的端口会优先直接打开，因此关掉标签页再打开时可以快速重连。

> 串口授权按“来源”保存：`127.0.0.1:5173`（dev）和 `127.0.0.1:4173`（preview）
> 是两个不同来源，换端口后首次连接需要重新选择一次 COM 口。
> 同理，`localhost` 与 `127.0.0.1` 也视为不同来源。

## 3. 串口接线

| 板端 | USB-TTL |
| --- | --- |
| `uart_tx`（3.3 V TTL） | `RX` |
| `GND` | `GND` |

- 115200 / 8N1 / 无流控 / ASCII；
- 不要接 5 V 或 RS232 电平；
- 先用串口助手确认能收到 `START` 等整行，再打开网页；
- 浏览器会占用 COM 口，联调时关闭串口助手，且只开一个标签页。

完整协议见 **[docs/PROTOCOL.md](docs/PROTOCOL.md)**。

```text
START\n
FIST\n
POINT\n
MODE\n
CONFIRM\n
ULTIMATE\n
RESET\n
```

## 4. 无硬件调试

| 方式 | 用法 |
| --- | --- |
| 键盘 | `1` START · `2` FIST · `3` POINT · `4` MODE · `5` CONFIRM · `6` ULTIMATE · `0` RESET |
| 调试面板 | `?debug=1`，或按 `d` / 点“调试”；可手工输入指令 |
| 鼠标模拟 | 进入 `TRACK` 后按住 `Alt` 移动鼠标，模拟 `POINT x y` |
| 自动演示 | `?demo=1` 按固定节奏轮播全部效果 |
| 快速场景 | `?scene=ready｜compress｜track｜planet｜dna｜soc｜confirm｜ultimate` |
| 自动开始 | `?autostart=1` 跳过首屏（不请求全屏与串口） |
| 画质档位 | `?quality=high｜medium｜low`；首屏也有“性能优先（低画质）”按钮 |
| 手动切画质 | 调试面板“画质”按钮循环切换；帧率持续偏低时也会自动降档 |

快捷键：`d` 调试面板、`f` 全屏、`m` 静音。

调试面板显示串口状态、端口、最近 50 条原始行 / 解析结果 / 是否忽略、当前状态、
FPS、粒子数、Bloom、画质档位，并提供复位、重连、全屏、静音、Bloom、画质、清空日志按钮。

## 4.1 板子手势直接驱动页面（gesture-bridge）

板子（`gesture` 固件，`make fw-cam`）每 100 ms 吐一行 `hand: rock / paper / scissors`，网页只认
`START / FIST / MODE`。中间由 `tools/gesture-bridge/` 翻译：

    板子 --USB-TTL--> COM9 ==> gesture_bridge.py ==> http://127.0.0.1:8765/events ==> 页面

一个 COM 口只能被一个进程打开，所以由它独占串口，网页不再走 Web Serial，而是连本机 SSE
（浏览器原生 `EventSource`，断线自动重连）。

**完整流程**（三个终端，顺序无所谓，后连上的一方会自动补上）：

```bash
# 1) 固化 + 固件（工程根目录，Windows 上走 PDS 与 upload.ps1）
make fw-cam

# 2) 手势桥接：独占 COM9，开 SSE :8765
python web/tools/gesture-bridge/gesture_bridge.py

# 3) 页面
cd web && pnpm install && pnpm dev
```

| 场景 | 干什么 |
| --- | --- |
| 板子已烧好 | 跳过第 1 步 |
| 只想看页面 | 只跑第 3 步，串口面板里手动连 Web Serial |

页面底部会弹出「手势桥接已连接 127.0.0.1:8765」，左侧 HUD 的 GESTURE / STATE 会跟着手势变。

| 手势 | 状态 | 短按 0.2 s（进状态） | 长按 0.9 s（状态里的第二招） |
| --- | --- | --- | --- |
| 握拳 `rock` | 蓄力 | `FIST` 压缩 | `ULTIMATE` 爆发 |
| 张开手掌 `paper` | 启动 | `START` 开场 | `CONFIRM` 确认 |
| 剪刀 `scissors` | 模型 | `MODE` 星球/DNA/芯片 | `POINT` 激光 |
| 手离开 0.8 s | 待机 | `IDLE` 回待机 | — |

保持时 HUD 会在 GESTURE 下面显示状态名和进度条（`0.6s / 0.9s`，满格就放第二招）：

![保持进度条](docs/images/bridge-hold.png)

![桥接·握拳](docs/images/bridge-compress.png)
![桥接·V 字切模式](docs/images/bridge-planet.png)

> 想把剪刀换成 `ULTIMATE`（终极爆发）或 `CONFIRM`，改 `tools/gesture-bridge/config.ini`
> 的 `[gesture]` 段即可，不用重烧固件。页面也可以用 `?bridge=8766` 换端口、
> `?bridge=off` 关掉这条通道。细节见 [docs/GESTURE-BRIDGE.md](docs/GESTURE-BRIDGE.md)。

## 5. 架构

```text
串口字节
  → LineParser（拆行、trim、大写、长度 / ASCII 校验）
  → parseCommandLine（指令枚举、POINT x y）
  → CommandBus（去重 / 冷却）
  → StateMachine（基础状态 + 瞬时叠加层，纯函数、可单测）
  → EffectDirector（把状态事件翻译成 Three.js 表现）
  → Stage / 各 Effect / HUD
```

| 模块 | 职责 |
| --- | --- |
| `src/serial/lineParser.ts` | 字节流拆行、归一化、超长 / 非 ASCII 丢弃 |
| `src/serial/WebSerialLink.ts` | 打开端口、读循环、断线、重连、状态回调 |
| `src/app/commands.ts` | 指令表、归一化、去重 / 冷却 `CommandBus` |
| `src/app/stateMachine.ts` | `IDLE / READY / COMPRESS / TRACK / MODE_*` + `BOOT / CONFIRM / ULTIMATE` |
| `src/app/EffectDirector.ts` | 状态与场景对象的唯一映射层 |
| `src/app/AppController.ts` | 主循环、串口事件、键盘、演示、HUD 同步 |
| `src/scene/` | Stage、星空、粒子 Logo、全息球、三种模式 |
| `src/fx/` | 激光扫描、能量波、爆炸、扫描转场 |
| `src/ui/` | HUD、DebugPanel |
| `src/audio/Synth.ts` | WebAudio 程序化音效 |

### 状态机规则（摘录）

- 默认状态 `READY`；`IDLE` 只在启动前 / `RESET` 后。
- `START` 从任意状态回 `IDLE`，播放 2.5 s `BOOT`，结束进入 `READY`。
- `FIST / POINT / MODE_*` 是粘性状态，保持到下一条指令。
- 收到不属于当前粘性状态的指令：先逻辑退出到 `READY`，0.3 s 交叉淡出，再执行。
- 重复 `FIST / POINT` 只做脉冲；重复 `MODE` 循环星球 → DNA → SoC。
- 模式切换时旧模型先退场（约 0.1 s），新模型再淡入，避免两个模型叠加。
- `CONFIRM` 1.5 s、`ULTIMATE` 3.0 s，结束回 `READY`。
- `ULTIMATE` 可打断 `BOOT / CONFIRM`，播放期间只接受 `RESET`。
- `BOOT / CONFIRM` 期间其他指令只保留最后一条，动画结束后执行。
- `IDLE` 下除 `START / RESET` 外全部忽略。

时间、颜色、粒子数、Bloom 参数集中在 **`src/config.ts`**。

## 6. 测试

```powershell
npm test          # Vitest：33 个单元测试
npm run typecheck # tsc --noEmit
npm run build     # 类型检查 + 生产构建
```

单元测试覆盖：

- 行解析 P01–P07：分片、CRLF、大小写、空行、超长、非 ASCII；
- 状态机 S01–S13：粘性退出、模式循环、BOOT 暂存、ULTIMATE 锁定 / 打断；
- 去重冷却：MODE 400 ms、ULTIMATE 5 s、START 1 s 等。

浏览器端到端（需要本机 Chrome + 调试端口）：

```powershell
# 终端 1
npm run dev
# 终端 2：无头 Chrome 打开 CDP
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless=new --remote-debugging-port=9222 about:blank
# 终端 3
node tools/mock-serial-test.mjs
# 也可指定 preview 地址
$env:ARES_URL='http://127.0.0.1:4173/?debug=1'; node tools/mock-serial-test.mjs
```

该脚本注入一个假 Web Serial 端口，通过真实的 `WebSerialLink → LineParser →
CommandBus → StateMachine → HUD` 链路发送字节，验证 15 项串口 / 键盘行为。
完整记录见 **[docs/TEST-REPORT.md](docs/TEST-REPORT.md)**。

截图工具：`node tools/cdp-shot.mjs <url> <out.png> <waitMs> [--hide-start]`。

## 7. 性能

**先确认硬件加速。** WebGL 如果走到软件渲染（`SwiftShader` / Microsoft Basic
Render Driver），4K 全屏下会非常卡。建议用独立的浏览器配置打开演示页；
如果手动用默认浏览器打开，请在
`Chrome 设置 → 系统 → 使用图形加速` 中开启并重启浏览器。

已实现的多级优化：

- 三档画质 `high / medium / low`：
  - `high`：DPR ≤ 2、Bloom 全强度、12000 粒子；
  - `medium`：DPR ≤ 1.25、Bloom 0.7 倍、粒子 70%；
  - `low`：DPR ≤ 1、关闭 Bloom、粒子 45%；
- 帧率连续低于 50 / 45 时自动降档，首屏可直接点“性能优先”；
- 启动时预编译全部 shader，避免第一次模式切换 / ULTIMATE 卡一下；
- 平时关闭 glitch 后处理 pass，只在 ULTIMATE 时启用；
- 页面隐藏时暂停渲染，`dt` 截断到 0.05 s；
- Bloom 半分辨率，粒子使用 `Points` / `InstancedMesh`，降档只改 drawRange。

实测（RTX 5060 Laptop、Chrome 156）：

- 独立配置、2560×1600 全屏（canvas 3840×2400）、HIGH：240 FPS（无头/无垂直同步）；
- 同一机器关闭硬件加速（Microsoft Basic Render Driver）、1600×900、LOW：约 45 FPS；
  这就是默认配置下“动画非常卡”的典型原因。

若仍然掉帧：`?debug=1` → “画质”切到 LOW，或直接打开
`http://127.0.0.1:4173/?quality=low`。

## 8. 常见问题

| 现象 | 处理 |
| --- | --- |
| 页面没有“连接串口” | 换 Chrome / Edge；确认不是 `file://` |
| 选端口后打不开 | 关闭串口助手 / 其他标签页；重插 USB-TTL |
| 打开成功但无数据 | TX/RX 接反、未共地、波特率不是 115200 |
| 收到乱码 | 电平不对；确认 3.3 V TTL，不要接 RS232 |
| 拔插后连不上 | 点“重新连接”；或重新选择端口 |
| 全屏 / 音频被拦截 | 必须通过“启动演示”按钮触发；或按 F11 |
| 动画卡顿 / 掉帧 | 先确认 Chrome 硬件加速已开启；用独立浏览器配置启动；或点“性能优先” |
| 打开后提示“软件渲染” | 浏览器关闭了硬件加速：设置 → 系统 → 使用图形加速，重启浏览器 |
| 关闭标签页再打开 | 已授权端口会自动复用；否则重新选择 |
| dev 切到 preview 后要重新选串口 | 授权按来源（端口）保存，重新选择一次即可 |
| 多标签页抢串口 | 只保留一个 ARES 标签页 |

## 9. 目录

```text
web/                          # 手势应用的上位机（ARES 全息页）
├── index.html
├── package.json
├── vite.config.ts
├── tsconfig.json
├── public/
│   ├── ares-logo.svg          # 首屏 / 3D 粒子 Logo
│   ├── ares-mark.svg          # HUD 品牌标
│   └── favicon.svg
├── src/
│   ├── main.ts
│   ├── config.ts
│   ├── style.css
│   ├── app/                  # AppController / stateMachine / commands / EffectDirector
│   ├── serial/               # lineParser / WebSerialLink / serialTypes
│   ├── scene/                # Stage / Starfield / LogoParticles / HoloSphere / modes
│   ├── fx/                   # LaserScan / EnergyWave / Explosion / Transition
│   ├── audio/Synth.ts
│   └── ui/                   # Hud / DebugPanel
├── tests/                    # lineParser / stateMachine / commands
├── tools/                    # CDP 截图、假串口端到端测试、免 Node 静态服务器
│   ├── gesture-bridge/       # 板子手势 -> 本页（串口 -> SSE，Python）
│   └── gesture-e2e.mjs       # 桥接 -> 页面的端到端观察/截图
├── docs/
│   ├── PROTOCOL.md
│   ├── GESTURE-BRIDGE.md
│   └── images/
└── dist/                     # npm run build 产物
```
