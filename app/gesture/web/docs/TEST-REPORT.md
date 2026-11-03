# ARES 验收记录

- 日期：2026-11-01
- 环境：Windows 11、Node.js v24.21.0、pnpm 11.28.5、Chrome 156.0.8078.47
- GPU：NVIDIA GeForce RTX 5060 Laptop（ANGLE / Direct3D11）

## 1. 单元测试

```powershell
npm test
```

```text
✓ tests/commands.test.ts    (8 tests)
✓ tests/lineParser.test.ts  (9 tests)
✓ tests/stateMachine.test.ts (16 tests)

Test Files  3 passed (3)
Tests       33 passed (33)
```

覆盖内容：

- P01–P07：分片、CRLF、大小写 / 空白、空行、超长行、非 ASCII；
- S01–S13：粘性状态、模式循环、BOOT 暂存、ULTIMATE 锁定 / 打断、RESET；
- 去重冷却：MODE 400 ms、ULTIMATE 5 s、START 1 s、默认 300 ms。

## 2. 类型检查与构建

```powershell
npm run typecheck
npm run build
```

```text
tsc --noEmit: 0 errors
vite build:
  dist/index.html                 5.04 kB │ gzip: 1.90 kB
  dist/assets/index-DDZE6sl1.css 13.79 kB │ gzip: 3.85 kB
  dist/assets/index-76V2hyEG.js 607.83 kB │ gzip: 157.01 kB
```

构建产物已用 `vite preview`（<http://127.0.0.1:4173>）实际加载验证。

## 3. 浏览器端到端（假串口）

```powershell
node tools/mock-serial-test.mjs
# 或对生产构建：
$env:ARES_URL='http://127.0.0.1:4173/?debug=1'; node tools/mock-serial-test.mjs
```

用 CDP 注入一个虚拟 Web Serial 端口，字节从 `ReadableStream` 进入真实的
`WebSerialLink → LineParser → CommandBus → StateMachine → HUD` 链路。

```text
PASS 串口连接状态: connected
PASS START 后进入 BOOT: BOOT
PASS BOOT 中 FIST 暂存: FIST
PASS BOOT 结束执行 FIST: COMPRESS
PASS FIST 后 MODE: MODE_PLANET
PASS 再次 MODE 循环到 DNA: MODE_DNA
PASS POINT 进入 TRACK: TRACK
PASS CONFIRM 叠加层: CONFIRM
PASS CONFIRM 结束回 READY: READY
PASS 未知指令不影响状态: READY
PASS ULTIMATE 叠加层: ULTIMATE
PASS ULTIMATE 中 RESET: IDLE
PASS 键盘 1 触发 START: BOOT
PASS 键盘 2 触发 FIST: COMPRESS
PASS HUD 手势同步: 握拳 · FIST

15/15 通过
```

## 4. 视觉验收

截图位于 `docs/images/`，均由生产构建 + 无头 Chrome（CDP）实际渲染：

| 状态 | 文件 |
| --- | --- |
| 首屏 | `start.png` |
| READY | `ready.png` |
| COMPRESS | `compress.png` |
| TRACK | `track.png` |
| MODE_PLANET | `planet.png` |
| MODE_DNA | `dna.png` |
| MODE_SOC | `soc.png` |
| CONFIRM | `confirm.png` |
| ULTIMATE | `ultimate.png` |

## 5. 性能

### 5.1 硬件加速（重要）

本机默认 Chrome 配置里 `hardware_acceleration_mode.enabled = false`，WebGL 会走
Microsoft Basic Render Driver（软件渲染），4K 全屏 + Bloom 会非常卡。

- 演示页建议使用独立的浏览器配置启动（`%LOCALAPPDATA%\ARES-Holo\chrome-profile`），
  实测该配置使用 NVIDIA RTX 5060 / D3D11；
- 页面检测到软件渲染时会自动切到 LOW，并在首屏显示红色警告；
- 手动打开默认浏览器时，建议在 `Chrome 设置 → 系统 → 使用图形加速` 中开启。

### 5.2 画质档位

| 档位 | DPR 上限 | Bloom | 粒子 | 星星 | 爆炸粒子 |
| --- | --- | --- | --- | --- | --- |
| HIGH | 2 | 1.0× | 12000 | 4200 | 3200 |
| MEDIUM | 1.25 | 0.7× | 70% | 70% | 80% |
| LOW | 1 | 关闭 | 45% | 50% | 55% |

帧率连续 2.5 s 低于 50 / 45 时自动降档；也可用 `?quality=low`、调试面板“画质”
或首屏“性能优先”手动切换。

### 5.3 实测

- 独立配置、1600×900 HIGH：240 FPS，p95 4.3 ms；
- 独立配置、2560×1600（canvas 3840×2400）HIGH：240 FPS；
- 软件渲染（Microsoft Basic Render Driver）、1600×900 LOW：约 45 FPS。

> 无头/独立配置下 rAF 不锁垂直同步，240 FPS 用于说明渲染负载低；
> 真实浏览器会按显示器刷新率呈现。软件渲染的 45 FPS 是“关闭硬件加速”场景的对照。

## 6. 未覆盖项（需真机）

- 真实 USB-TTL / 盘古 200Pro+ 板端串口联调；
- 物理拔插 USB-TTL 的断线 / 重连提示；
- 真实用户手势触发的全屏与音频解锁（无头环境无法验证）；
- 投影仪色域 / 亮度调校。

建议现场按计划 W01–W15 手工验收表逐项检查。
