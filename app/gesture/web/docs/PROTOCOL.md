# ARES 串口协议

- 版本：v1.0（与 `docs/ares-holo-serial-plan.md` 一致）
- 物理层：UART / USB-TTL，115200 8N1，无流控，3.3 V TTL，ASCII
- 方向：板端 → PC（单向；网页不发送 ACK，也不需要板端等待）
- 编码：ASCII；一行一条指令，`\n`（`0x0A`）结尾，兼容 `\r\n`

## 1. 帧格式

| 规则 | 说明 |
| --- | --- |
| 行结束 | `\n`；`\r\n` 也接受 |
| 大小写 | 不敏感，统一转大写 |
| 空白 | 首尾空格 / Tab 忽略 |
| 空行 | 忽略，不改变状态 |
| 单行长度 | 最多 64 字节；超长整行丢弃到下一个换行 |
| 非 ASCII | 整行忽略（例如误发中文、乱码） |
| 未知指令 | 忽略并记录到调试面板 |
| 校验和 | 无（单向、短距、低速） |
| 坐标扩展 | 预留 `POINT x y`，x / y ∈ [0, 1000] |

## 2. 指令表

| 手势 | 指令 | 类型 | 效果 | 退出 |
| --- | --- | --- | --- | --- |
| 张开手掌 | `START` | 事件 | 粒子汇聚、Logo 出现（2.5 s） | 动画结束 → `READY` |
| 握拳 | `FIST` | 粘性 | 全息球收缩、蓄力发光 | 收到任何非 `FIST` 指令 |
| 食指 | `POINT` | 粘性 | 激光、扫描、准星 | 收到任何非 `POINT` 指令 |
| V 字 | `MODE` | 粘性 + 循环 | 星球 → DNA → SoC → 星球 | 收到任何非 `MODE` 指令 |
| 竖起拇指 | `CONFIRM` | 瞬时 | 能量波、HUD 展开（1.5 s） | 1.5 s 后 → `READY` |
| 特殊手势 | `ULTIMATE` | 瞬时 / 最高优先级 | 粒子爆炸、闪白、震动（3.0 s） | 3.0 s 后 → `READY` |
| 复位 | `RESET` | 事件 | 立即清空 → `IDLE` | 需要 `START` 重新启动 |
| 手离开取景框 | `IDLE` | 事件 | 退出粘性状态，回到待机 `READY` | 立即（`BOOT`/`CONFIRM` 期间忽略） |

板端约定：**每个手势只发一行**。网页端仍会做去重兜底。

## 3. 去重与冷却

同一条指令在冷却窗口内重复到达时只执行一次。

| 指令 | 冷却 |
| --- | --- |
| 默认 | 300 ms |
| `START` | 1000 ms |
| `FIST` | 1000 ms |
| `POINT` | 500 ms |
| `MODE` | 400 ms |
| `CONFIRM` | 1000 ms |
| `ULTIMATE` | 5000 ms |
| `RESET` | 300 ms |
| `IDLE` | 400 ms |

特殊重复语义：

- `COMPRESS` 中重复 `FIST` → 只做一次蓄力脉冲；
- `TRACK` 中重复 `POINT` → 只做一次扫描脉冲；
- `MODE_*` 中重复 `MODE` → 循环到下一个模型；
- `ULTIMATE` 播放期间除 `RESET` 外全部忽略。

## 4. 状态与转移

基础状态（持久）：

`IDLE` `READY` `COMPRESS` `TRACK` `MODE_PLANET` `MODE_DNA` `MODE_SOC`

叠加状态（瞬时）：

`BOOT`（2.5 s） `CONFIRM`（1.5 s） `ULTIMATE`（3.0 s）

| 当前基础状态 | `FIST` | `POINT` | `MODE` | `CONFIRM` | `ULTIMATE` | `START` |
| --- | --- | --- | --- | --- | --- | --- |
| `IDLE` | 忽略 | 忽略 | 忽略 | 忽略 | 忽略 | `BOOT` → `READY` |
| `READY` | → `COMPRESS` | → `TRACK` | → `MODE_PLANET` | `CONFIRM` → `READY` | `ULTIMATE` → `READY` | `BOOT` → `READY` |
| `COMPRESS` | 蓄力脉冲 | 退出 → `TRACK` | 退出 → `MODE_PLANET` | 退出 → `CONFIRM` | 退出 → `ULTIMATE` | `BOOT` → `READY` |
| `TRACK` | 退出 → `COMPRESS` | 扫描脉冲 | 退出 → `MODE_PLANET` | 退出 → `CONFIRM` | 退出 → `ULTIMATE` | `BOOT` → `READY` |
| `MODE_PLANET` | 退出 → `COMPRESS` | 退出 → `TRACK` | → `MODE_DNA` | 退出 → `CONFIRM` | 退出 → `ULTIMATE` | `BOOT` → `READY` |
| `MODE_DNA` | 退出 → `COMPRESS` | 退出 → `TRACK` | → `MODE_SOC` | 退出 → `CONFIRM` | 退出 → `ULTIMATE` | `BOOT` → `READY` |
| `MODE_SOC` | 退出 → `COMPRESS` | 退出 → `TRACK` | → `MODE_PLANET` | 退出 → `CONFIRM` | 退出 → `ULTIMATE` | `BOOT` → `READY` |

补充：

- `RESET` 在任意状态（包括 `ULTIMATE` 播放中）立即清空到 `IDLE`，不播放过场；
- `IDLE` 是"空画面"：手离开取景框时由板端/桥接发出，退出 `COMPRESS / TRACK / MODE_*` 回到 `READY`；
  `ULTIMATE` 播放期间忽略，`BOOT / CONFIRM` 期间忽略（动画结束本来就会回 `READY`），`IDLE` 状态下无动作；
- 退出粘性状态时先回 `READY`，视觉做 0.3 s 交叉淡出，再执行新指令；
- `BOOT` / `CONFIRM` 期间到达的其他指令只保留最后一条，动画结束后执行；
- `CONFIRM` / `ULTIMATE` 结束回 `READY`，不回之前的压缩 / 跟踪状态。

## 5. 字节示例

| 指令 | 十六进制 |
| --- | --- |
| `START\n` | `53 54 41 52 54 0A` |
| `FIST\n` | `46 49 53 54 0A` |
| `POINT\n` | `50 4F 49 4E 54 0A` |
| `MODE\n` | `4D 4F 44 45 0A` |
| `CONFIRM\n` | `43 4F 4E 46 49 52 4D 0A` |
| `ULTIMATE\n` | `55 4C 54 49 4D 41 54 45 0A` |
| `RESET\n` | `52 45 53 45 54 0A` |
| `POINT 500 250\n` | `50 4F 49 4E 54 20 35 30 30 20 32 35 30 0A` |

## 6. 时序示例

**握拳后切模式**

```text
FIST   → COMPRESS（球体收缩、蓄力）
MODE   → 先退出到 READY（0.3 s 淡出），再进入 MODE_PLANET
```

**握拳后确认**

```text
FIST    → COMPRESS
CONFIRM → 退出压缩，播放能量波，1.5 s 后回 READY
```

**启动动画期间收到握拳**

```text
START → BOOT（2.5 s）
FIST  → 暂存
BOOT 结束 → READY → 执行 FIST → COMPRESS
```

**ULTIMATE 打断确认**

```text
CONFIRM → ULTIMATE（立即打断）→ 3.0 s → READY
```

## 7. 调试发送

### Windows PowerShell（先关闭串口助手 / 网页）

```powershell
$port = New-Object System.IO.Ports.SerialPort 'COM5', 115200, 'None', 8, 'One'
$port.NewLine = "`n"
$port.Open()
$port.WriteLine('START')
Start-Sleep -Milliseconds 3000
$port.WriteLine('FIST')
$port.Close()
```

### Python

```python
import serial, time

with serial.Serial('COM5', 115200, timeout=1) as ser:
    ser.write(b'START\n')
    time.sleep(3)
    ser.write(b'FIST\n')
```

> 网页连接串口时会独占 COM 口。想用上面的脚本联调，请先关闭网页标签页，
> 或反过来：先关闭串口助手，再让网页连接。

## 8. 扩展约定

| 方向 | 协议改动 |
| --- | --- |
| 食指坐标跟踪 | 发送 `POINT x y`（0–1000）；网页会把坐标映射到舞台平面 |
| 按住 / 松开 | 增加 `FIST_ON` / `FIST_OFF`、`POINT_ON` / `POINT_OFF`，状态机加超时释放 |
| 更多模式 | 在 `src/scene/modes/` 增加模型，扩展 `MODE` 循环列表 |
| 录制 / 回放 | 把指令流存为 JSON（时间戳 + 行），按时间回放 |
| 手势桥接 | 板子只输出 `hand: rock/paper/scissors` 时，用 `tools/gesture-bridge` 翻译成本协议的指令，经本机 SSE 推给页面（见 [GESTURE-BRIDGE.md](GESTURE-BRIDGE.md)）；页面用 `?bridge=<端口>` 指定，`?bridge=off` 关闭 |

新增指令时同步修改：

1. `src/app/commands.ts` 的 `COMMANDS` / `COMMAND_META` / 冷却表；
2. `src/app/stateMachine.ts` 的转移规则；
3. `tests/` 增加对应用例；
4. 本文件的指令表与字节示例。
