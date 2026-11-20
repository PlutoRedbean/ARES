# RT-Thread、miniTensor 与四 hart CoreMark

统一 AMP 顶层在 hart0 启动 RT-Thread Nano、MSH 和 miniTensor 驱动。hart1–3 启动同一份常驻 worker 固件，各自使用私有内存和 CoreMark 加速器。两份固件链接到相同入口 `0x80000000`，按 hart 装入各自的片上指令 RAM。板级流程将初始化文件随位流加载，串口提供 MSH 命令。

| 资源 | 用途 |
| --- | --- |
| hart0 的 64 KiB 指令 RAM、128 KiB 数据 RAM | RT-Thread、AI 推理代码与权重、CoreMark 主线程和 context 0 |
| hart1–3 各自的 32 KiB 指令 RAM、32 KiB 数据 RAM | 常驻 CoreMark worker，分别执行 context 1–3 |
| `0x10000000–0x1000FFFF`、`0xE0000000–0xE000001F` | hart0 与 miniTensor DMA 共享的 64 KiB 非缓存工作区，以及 miniTensor 寄存器 |
| `0xD0003000` / `0xD0100000–0xD014AFFF` | 完整帧就绪与释放寄存器，及 320×240 灰度帧的逐像素读取窗口 |
| `0xA000F000–0xA000F0FF` | 共享 mailbox，按轮次派发任务和回收 CRC |

MSH 在 hart0 发起 AI 或 CoreMark 任务。实时识别在帧边界暂停，确认 miniTensor 已空闲后开始跑分。四个 context 共享一次起止计时，RT-Thread tick 保持开启。跑分结束后，先前处于运行状态的 AI 会从新帧恢复。

## 构建和仿真

```sh
make rtos-amp-image
make pipeline-rtos-amp
make pipeline-rtos-amp-test
```

镜像、链接 map 和验收日志位于 `build/rtos_amp/`。验收通过仿真 OV5640 DVP 字节流输入手势，检查实时手势串口行、两轮四 hart CRC、AI 自动恢复和内置图推理自检。

```text
ai start
ai status
coremark start 1
ai stop
ai selftest
```

`ai start` 开始实时识别，`ai stop` 停止识别。当前 AMP 固件以 `G` 行输出稳定类别、原始类别、三个分数、分差和标志位。类别为 `0 idle`、`1 defense`、`2 point`，`-1` 表示未知或无效。有效类别需要连续三帧确认，串口按 RT-Thread tick 限制在约 10 Hz。相机端将中心 640×480 区域降采样为 320×240 灰度，通过两个片上缓冲向 hart0 交接完整帧。AI 复制固定 ROI 后释放帧缓冲。

计划中的 PC 识别路径沿用上述动作，在 FPGA 侧新增全视野 320×180 亮度统计。分工、接口和验收步骤见 [ARES 手势识别的 FPGA 与 PC 分工实施方案](gesture_pc_cv.md)。

## Pango 板级流程

```sh
make pipeline-rtos-amp-pango-lint
pds_shell -file fpga/pango/pipeline/flow_pipeline_rtos_amp.tcl -project_name pipeline_rtos_amp
```

PDS 工程在 `build/pds_rtos_amp/` 生成，使用 PG2L200H 板卡约束、100 MHz CPU 和 50 MHz 外设时钟。配置位流后，用 115200 8N1 串口连接 MSH。摄像头使用板卡的 CMOS1 接口。首次上板应检查 SCCB 初始化、三类手势及网页联动，并核对统一位流的资源占用和时序。HDMI 预览与 OSD 不在该顶层。

板上测量可从 `coremark start` 和 `coremark start 20000 validation` 开始。默认每 hart 20,000 次、总计 80,000 次迭代。检查两组种子的 CRC 和各自计时是否达到 10 秒，再记录性能种子下的聚合吞吐。若计时不足，可提高每 hart 的迭代数。仿真的短跑标有 `CoreMark short run`，用于功能校验。与仓库的 120 MHz 裸机数据对比时，记录统一位流实测的时钟、运行环境和编译选项。

## Guard 串口脱敏

hart0 启动 RTT 时会注册 `guard` 命令并启动一个等待请求的静态线程。模型 ROM 在 FPGA 中。Guard 的 L2 使用当前工程的 4×4 GEMM 源码，在 Guard 时钟域内单独实例化。

在 115200 8N1 终端关闭本地回显，然后输入以下命令。

```text
guard status
guard selftest
guard start
```

看到 `GUARD READY` 后再发送正文。例：发送测试行 `13800138000` 和 LF，返回 `*******8000` 以及含 `mobile=001` 的一行审计。FinSH 在会话期间等待，Guard 直接按字节读写 UART。会话需要独占串口，若实时 AI 已开启，先执行 `ai stop`；等待已有的推理自检或 CoreMark 完成后再进入。帧以 LF 结束，没有 LF 时从最后一个输入字节起空闲 2.6 秒提交。每帧收到完整的 `[guard] … mode=1` 后再发下一帧。帧边界按 Ctrl+]（单字节 `0x1D`）返回 MSH，随后可执行 `ai selftest`。

上位机沿用 `app/guard/tools/serial_host.py` 或 `app/guard/web/` 的协议。先在 MSH 进入会话，再把串口交给上位机；每次板卡复位后重新进入。上位机默认按标点切成至多 56 字节的短帧，适用于独立位流和统一位流。掩码保留原始字节长度，UART 层将 LF 输出为 CRLF。姓名、地址使用 NER，结果依赖输入上下文。

### 构建与验证

从仓库根目录运行：

```sh
make pipeline-guard-mmio-test
make pipeline-rtos-guard-test
make pipeline-rtos-amp-test
make pipeline-rtos-amp-pango-prep
```

前两项分别验证规则模式的 MMIO 背压和带 NER 的完整 RTT 串口。第三项回归原有手势和四 hart CoreMark。最后一项生成固件、Pango 文件表和 ROM，包括 `build/gen/ner_*.hex`。运行本页 PDS 板级流程时使用同一份源码根目录和 `build/`，流程会把 ROM 复制到 PDS 工程的 `build/gen/`。统一 SoC 的顶层为 `pipeline_rtos_amp_board_top`。输入用例和 UART 验收日志位于 `build/rtos_amp/`。

### hart0 寄存器

Guard 占用 `0xE0001000–0xE000100F`，按 32 位对齐访问。每次提交一帧，收到结束标记后再开始下一帧。

| 偏移 | 读写 | 语义 |
| --- | --- | --- |
| `0x0` | 读 | 位 0 可写，位 1 有输出，位 2 帧处理中，位 3 上一帧有错误，位 4 启用 NER |
| `0x4` | 写 | 低 8 位送一个正文字节，包括作为正文的 LF |
| `0x8` | 写 | 排在先前字节之后的帧尾标记，无额外正文字节 |
| `0xC` | 读 | 弹出一个输出。位 8 为 0 时低 8 位是字节，位 8 为 1 表示正文和审计均已读完，此时位 9 是帧错误；空读返回 `0x80000000` |

驱动在送入数据的同时排空输出 FIFO。板载 UART 接收 FIFO 的溢出标志保持到板卡复位；发生丢字节后，审计行以 `ovf=001` 标记结果。Guard 源码基线为 `origin/guard@5c2049e6387fd8b361e4847b9e2390a1646fa307`。
