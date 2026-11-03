# 手势桥接（gesture-bridge）

> 板子手势 -> 本页。串口独占在 Python 侧，页面通过本机 SSE 收指令。

## 1. 为什么不让网页自己开串口

| 问题 | 说明 |
| --- | --- |
| 板子说的不是网页的语言 | 板子只会打 `hand: rock / paper / scissors`，页面只认 `START / FIST / MODE` |
| 串口只能一个进程占用 | 桥接器独占 COM9 之后，网页就不能再开同一个口；反过来也一样 |
| 想保留板子的调试输出 | `scores / margin` 这些行留着，方便现场看识别质量 |

所以要一层翻译，而且翻译放在串口这一侧（Python），页面只多一个输入源。

## 2. 链路

    板子 OV5640 + INT8 网络
      │ 10 Hz 文本：hand: rock scores 11 -15 0 margin 11 shown rock
      ▼
    COM9 @115200
      │
    tools/gesture-bridge/gesture_bridge.py
      │ 解析 -> 连续 2 行判定 -> 手势映射 -> 400 ms 冷却
      ▼
    http://127.0.0.1:8765/events   (text/event-stream)
      │
    src/serial/BridgeLink.ts  (EventSource，断线自动重连)
      ▼
    parseCommandLine -> CommandBus -> StateMachine -> EffectDirector

页面源码侧只加了 `src/serial/BridgeLink.ts` 和 `AppController` 里的一小段接线，
串口（Web Serial）与键盘两条老通道完全没动。

## 3. 手势映射：一个手势 = 一个状态

三个手势各对应一个状态，短按进状态，继续按住就在这个状态里放第二招。

| 手势 | 状态 | 短按 0.2 s | 长按 0.9 s |
| --- | --- | --- | --- |
| ✊ 握拳 | **蓄力** | `FIST` 压缩 | `ULTIMATE` 爆发 |
| ✋ 张开手掌 | **启动** | `START` 开场 | `CONFIRM` 确认 |
| ✌ 剪刀 | **模型** | `MODE` 星球 / DNA / 芯片 | `POINT` 激光 |
| 手离开 1.2 s | **待机** | `IDLE` | — |

状态名和阈值都在 `config.ini` 的 `[hold]` 段：

    [hold]
    short_ms = 200          # 进状态的阈值
    long_ms = 900           # 第二招的阈值
    rock_state = 蓄力        # 状态在界面上叫什么
    rock_long = ULTIMATE    # 长按放什么；IGNORE = 没有第二招
    paper_state = 启动
    paper_long = CONFIRM
    scissors_state = 模型
    scissors_long = POINT

HUD 顶上显示状态名，下面那条是保持进度（`0.6s / 1.2s`），满格瞬间放第二招：

![保持进度条](images/bridge-hold.png)


## 4. 启动

完整流程是三件事（板子掉电后位流就没了，所以默认每次都烧）：

    1) 烧位流 + 传固件（约 40 秒）：工程根目录 make fw-cam（并走 PDS 流程）
    2) 起桥接（读 COM9，开 :8765）：python web/tools/gesture-bridge/gesture_bridge.py
    3) 起页面：cd web && pnpm install && pnpm dev

分开跑也行（顺序无所谓，后连上的一方自动补上）：

    # 终端 1
    python web/tools/gesture-bridge/gesture_bridge.py
    # 看到这两行就绪：
    #   SSE 服务：http://127.0.0.1:8765/events
    #   串口已打开：COM9 @115200 8N1

    # 终端 2
    cd web && pnpm dev

页面先开就显示「手势桥接未连接」并每 3 秒重试，桥接器起来后自动连上。

## 5. 判定规则

板子 10 Hz 上报（每 100 ms 一行），桥接器按下面的规则出指令：

    confirm_reports = 3      # 连续 3 行同手势 = 约 0.3 秒出手（偏稳）
    cooldown_ms = 800        # 两条指令最小间隔
    report_gap_ms = 500      # 静默 0.5 秒 = 手已离开，重新上膛
    idle_after_ms = 1200     # 手离开 1.2 秒才退回待机

手离开取景框后板子会继续打 `hand: none`，所以复位只要 0.1 秒左右；
`report_gap_ms` 是"连 none 都不打了"时的兜底。

| 想要 | 改法 |
| --- | --- |
| 一碰就触发（更灵敏，可能误触） | `confirm_reports = 2` |
| 还要更稳（要停 0.4 秒） | `confirm_reports = 4` |
| 连续触发更快 | `cooldown_ms = 400` |
| 复位更快 | `report_gap_ms = 300`、`idle_after_ms = 800` |

## 6. 自检与验收

```powershell
# 1) 纯逻辑：不用板子、不用浏览器
python tools\gesture-bridge\gesture_bridge.py --self-test
#   PASSED，期望/实际都是 START FIST FIST MODE START

# 2) 不开服务，只看翻译结果
python tools\gesture-bridge\gesture_bridge.py --replay tools\gesture-bridge\sample_hand_lines.txt --replay-interval 0.1 --no-server

# 3) 看服务状态（页面连了几个、推了多少条）
curl http://127.0.0.1:8765/status

# 4) 真页面端到端（需要先起 dist 静态服务 + 桥接器 + 带调试端口的 Chrome）
node tools\gesture-e2e.mjs "http://127.0.0.1:4173/?quality=low" 18
```

第 4 步实测时间线（回放 10 Hz 样例，页面 `?quality=low` 无头 Chrome）：

    t=0.22s base=IDLE     overlay=BOOT        gesture=张开手掌 · START
    t=2.93s base=COMPRESS overlay=NONE        gesture=握拳 · FIST
    t=3.26s base=MODE_PLANET overlay=NONE     gesture=V 字 · MODE
    t=4.00s base=IDLE     overlay=BOOT        gesture=张开手掌 · START

也就是说：指令到达后 0.2~0.3 秒页面就切到对应效果，START 的 2.5 秒开场动画会被
后续指令排队，播完立刻执行。

## 7. 故障排查

| 现象 | 处理 |
| --- | --- |
| 页面一直「手势桥接未连接」 | 桥接器没起 / 端口不是 8765；看桥接器窗口有没有 `SSE 服务` 那行 |
| 桥接器窗口报 `端口 8765 起不来` | 端口被占：`--http-port 8766`，页面用 `?bridge=8766` |
| 桥接器报 `串口打开失败（拒绝访问）` | 有别的程序占着 COM9（串口助手 / `watch_serial.ps1` / 上一个没退干净的），关掉即可，它会每秒重试 |
| 页面有反应但很迟钝 | 固件不是 10 Hz 那版；重新执行 `make fw-cam` 并确认 `build/fw/cam/app.bin` 是最新的 |
| 手势换不过来 | 必须"离开取景框 0.5 秒"再回来；直接从一个手势换到另一个不会触发（防误触） |
| 想临时回退到纯键盘/串口 | 页面加 `?bridge=off` |

## 8. 文件

| 文件 | 作用 |
| --- | --- |
| `tools/gesture-bridge/gesture_bridge.py` | 串口 -> 判定 -> SSE 服务（只用标准库 + pyserial） |
| `tools/gesture-bridge/config.ini` | 串口、映射、判定参数、服务端口 |
| `tools/gesture-bridge/start-bridge.bat` | 双击启动（顺便装 pyserial） |
| `tools/gesture-bridge/sample_hand_lines.txt` | 10 Hz 回放样例 |
| `src/serial/BridgeLink.ts` | 页面侧 EventSource 客户端 |
| `src/app/AppController.ts` | 接线：bridge 行 -> dispatch(source='bridge') |
| `tools/gesture-e2e.mjs` | CDP 端到端观察 + 截图 |
