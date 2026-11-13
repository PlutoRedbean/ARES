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

`ai start` 开始实时识别，`ai stop` 停止识别。串口输出 `hand: rock`、`hand: paper`、`hand: scissors` 或 `hand: none`，兼容原有 gesture-bridge。有效类别需要连续三帧确认，串口按 RT-Thread tick 限制在约 10 Hz。相机端将中心 640×480 裁剪为 320×240 灰度，通过两个片上缓冲向 hart0 交接完整帧。AI 复制固定 ROI 后释放帧缓冲。

## Pango 板级流程

```sh
make pipeline-rtos-amp-pango-lint
pds_shell -file fpga/pango/pipeline/flow_pipeline_rtos_amp.tcl -project_name pipeline_rtos_amp
```

PDS 工程在 `build/pds_rtos_amp/` 生成，使用 PG2L200H 板卡约束、100 MHz CPU 和 50 MHz 外设时钟。配置位流后，用 115200 8N1 串口连接 MSH。摄像头使用板卡的 CMOS1 接口。首次上板应检查 SCCB 初始化、三类手势及网页联动，并核对统一位流的资源占用和时序。HDMI 预览与 OSD 不在该顶层。

板上测量可从 `coremark start` 和 `coremark start 20000 validation` 开始。默认每 hart 20,000 次、总计 80,000 次迭代。检查两组种子的 CRC 和各自计时是否达到 10 秒，再记录性能种子下的聚合吞吐。若计时不足，可提高每 hart 的迭代数。仿真的短跑标有 `CoreMark short run`，用于功能校验。与仓库的 120 MHz 裸机数据对比时，记录统一位流实测的时钟、运行环境和编译选项。
