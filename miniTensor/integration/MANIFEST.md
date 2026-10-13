# 集成清单（MANIFEST）

本文件回答三个问题：**部署了什么 / 有没有训练 / 有没有改动 CPU 核**，并把改动、证据和
复现方式集中起来。日常部署流程只看一份文档：[../README.md](../README.md)。

---

## 1. 部署状态

| 问题 | 结论 |
| --- | --- |
| YOLO 部署好了吗？ | **是。** 完整 **tiny-yolov3**（13 卷积 + 6 池化 + FPN 上采样 + 通道拼接 + 2 个检测头）在真实 Mundus/NPC 核 + RT-Thread Nano 上驱动 miniTensor 跑通，**21 个 stage 逐字节与整数 golden 一致**（3,128,301 命令 / 384,458,980 cycles / `HIT GOOD TRAP`，见 [logs/yolofull_run3.log](logs/yolofull_run3.log)） |
| 训练了吗？ | **没有训练这份模型。** `models/tiny-yolov3.onnx` 是 **keras2onnx 1.6.0** 导出的**预训练** tiny-yolov3（COCO 80 类，来自 qqwweee/keras-yolo3）。本项目只做了**推理部署 + 训练后量化（PTQ）**：fold BatchNorm、按标定得到的每层激活尺度做 INT8 量化、打包成硬件行格式。 |
| 那有什么是训练过的？ | Y6 的**小型检测器**：`integration/tools/train_detector.py` 在 32x32 合成图上**训练** 1x1 head（固定随机卷积做特征，最小二乘解），产物 `detector_float.npz` → `mt_detect`（8/8 图，commit 里的语义识别 demo）。 |
| 量化方式 | 见 [tools/pack_full.py](tools/pack_full.py)：float 前向标定 → `s_x_in = max|f_in|/127`、`s_w = max|w|/127` → `bq = round(b/(s_x_in*s_w))`、`mult/shift` 保持 float 尺度。所以 `int8 * s_out` 就是 float 值，head 可解码。 |

> 分辨率提醒：模型在 416x416 上训练，仿真跑在 **64x64**（再大代价按面积平方涨）。
> 64x64 下检测框没有实际意义，本轮证明的是**链路与数值正确**，不是识别率；识别率需要
> 更大输入/外存，见 [../handoff/archive/design/yolo_feasibility.md](../handoff/archive/design/yolo_feasibility.md)。

---

## 2. 有没有改变核心 CPU 的行为

**没有。** CPU 的 ISA、流水线、分支预测、Cache 都是原样，Chisel 核**没有重新 elaborate**：

    git -C Mundus/npc diff --stat -- scsrc vsrc/build      # 空

改动全部在**仿真测试台 / 平台层 / 内存模型**（`vsrc/testbench`、`csrc/wave`、`Makefile`）：

| 文件 | 改了什么 | 属于 |
| --- | --- | --- |
| `npc/Makefile` | miniTensor RTL 进 Verilator 文件表；`VERILATOR_RESET` 默认 0 | 仿真构建 |
| `npc/csrc/include/mem.h` | DRAM 窗口扩到 15 MiB；声明 DPI DMA | 内存模型 |
| `npc/csrc/wave/mem.cpp` | `dram[]` 扩容；`program_ROM` 加载区间；`mt_dma_read/write`；只翻译 `0x8030_0000` 别名 | 内存模型 |
| `npc/vsrc/testbench/IP/BRAM.v` | 字地址 16→22 位（仿真窗口）；FPGA 分支保持 16 位 | 内存 IP |
| `npc/vsrc/testbench/jyd/bram_driver.sv` | `__VERILATOR__` 下全窗口寻址 | 平台 |
| `npc/vsrc/testbench/jyd/perip_bridge.sv` | DRAM 译码（低 256K / 别名 / 高 12 MiB）；miniTensor MMIO `0x8020_1000`；store 地址 24 位 | 平台桥 |
| `npc/vsrc/testbench/jyd/student_top.sv` | 例化 `mt_cvxif_shim` + `mini_tensor_top` + `mt_dma_bridge` | 平台顶层 |

对 CPU 可观测的行为变化只有**地址空间**：
- DRAM 从 256 KiB 扩到 15 MiB（`0x8010_0000-0x80FF_FFFF`，只有低 256 KiB 仍可缓存）；
- 新增非缓存镜像 `0x8030_0000-0x8033_FFFF` 和 miniTensor 控制页 `0x8020_1000-0x8020_101F`；
- `VERILATOR_RESET=0`（仿真复位值；1/2 会让前端不退休，是既有平台问题，不是本次引入）。

这些都不改变核的指令行为，属于 SoC/测试台内存映射。

---

## 3. Mundus 内文件地图

### 3.1 miniTensor/（唯一真源）

    integration/
      README.md                    集成总览（状态表已更新 Y19）
      MANIFEST.md                  本文件
      bsp/                         RT-Thread 驱动与全部 mt_*.c（BSP 直接编译这里）
        mt_net.c / mt_net.h        卷积引擎；Y19 新增 SAME 池化 / 上采样 / 拼接
        mt_yolomodel.c             完整 tiny-yolov3 调度器（读 __model_start）
        mt_yolomodel_weights.h     生成的 21 层表
        mt_app.c / mt_conv.c / mt_detect.c / mt_wide.c / mt_res.c / mt_yolo.c /
        mt_yolocnn.c               既有回归
        compat/                     无 newlib 的最小 libc 头
      npc/                         shim / DMA bridge / standalone 验证（npc 直接引用）
      tools/
        pack_full.py               完整模型夹具（标定 + 打包 + golden）
        yolo_decode.py             head 解码 + NMS
        pack_model.py / pack_real.py / pack_weights.py / ...  各轮夹具
      patches/
        npc.patch                  Mundus/npc 的全部改动（git diff）
        rtthread-nano.patch        rtthread-nano 的全部改动（git diff）
      logs/                        验收证据
    models/
      tiny-yolov3.onnx             预训练模型（输入）
      ym_weights.bin               完整模型 blob（8.70 MiB，生成）
      yc_weights.bin               3 层回归 blob（生成）
    handoff/                       各轮设计记录（见 handoff/README.md）
    rtl/ tb/ Makefile              miniTensor 本体与 standalone 验证

### 3.2 Mundus/npc/

改动即 `integration/patches/npc.patch`（7 个文件，全部测试台/平台层）。恢复：

    cd $MUNDUS_HOME/npc
    git apply $MUNDUS_HOME/miniTensor/integration/patches/npc.patch

### 3.3 Mundus/rtthread-nano/

改动即 `integration/patches/rtthread-nano.patch`：

| 文件 | 改动 |
| --- | --- |
| `rt-thread/bsp/MundusJyd/Makefile` | 引入 `MT_HOME/integration/bsp` 源文件与两个权重 blob |
| `rt-thread/bsp/MundusJyd/linker.ld` | DRAM 256K→192K；`.weights`+`.model` 共用一个 12 MiB 区；导出 `__model_start` |
| `rt-thread/bsp/MundusJyd/coremark/finsh_compat.c` | 无 newlib 的 finsh 兼容层（早期工作） |

恢复：

    cd $MUNDUS_HOME/rtthread-nano
    git apply $MUNDUS_HOME/miniTensor/integration/patches/rtthread-nano.patch

> 补丁是**参考**，不是唯一入口：miniTensor 的 `.c/.h/.sv` 由外部仓库直接引用
> `miniTensor/integration/`，只有 Makefile / linker.ld 需要落在外仓库里。

---

## 4. 一键复现

    # 夹具
    cd $MUNDUS_HOME/miniTensor
    .venv/bin/python integration/tools/pack_full.py

    # 固件
    cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd
    make CROSS_COMPILE=riscv64-unknown-elf- \
      MUNDUS_HOME=$MUNDUS_HOME \
      NPC_HOME=$MUNDUS_HOME/npc MT_WITH_COREMARK=0 image

    # 完整模型（约 20-30 分钟）
    cd $MUNDUS_HOME/miniTensor
    JYD_CONSOLE_CMDS='mt_yolomodel;quit' ./integration/run_jyd_sim.sh

    # 现有回归冒烟（mt_net / mt_yolocnn / mt_conv）
    JYD_CONSOLE_CMDS='mt_net;mt_yolocnn;mt_conv;quit' ./integration/run_jyd_sim.sh

    # 解码
    cd $MUNDUS_HOME/miniTensor
    .venv/bin/python integration/tools/yolo_decode.py

---

## 5. 验收证据（integration/logs/）

| 日志 | 内容 |
| --- | --- |
| `baseline_mt_gemm.log` | 改动前基线：`mt_gemm` PASS |
| `r19.log` | 上一轮遗留：`mt_net` 在 `divu`（`0x80001338`）上崩，本次已修 |
| `yolofull_run1.log` | 本轮的同一个崩溃，定位到 pooling 的整除 |
| `yolofull_run2.log` | 首次 21/21 逐字节通过（crude 量化） |
| `yolofull_run3.log` | **最终**：标定量化版 21/21 通过，384,458,980 cycles |
| `regress_smoke.log` | 既有回归 `mt_net` / `mt_yolocnn` / `mt_conv` 全 PASS |
| `relocated_smoke.log` | miniTensor 并入 `Mundus/miniTensor` 后，一键脚本 `mt_gemm` PASS |
| `repro_yolofull.log` | 并入后按 README 从干净固件构建复现完整模型：21/21 逐字节通过，384,458,980 cycles |
| `verify_mtgemm.log` | 清空全部构建产物后，按 README 2.5/3/4/5/6 原样执行：从零 Verilator 构建 + `mt_gemm` PASS |
| `verify_readme_step6.log` | README 第 6 节原命令（`run_jyd_sim.sh` + `mt_yolomodel`）从干净状态跑通：21/21，`HIT GOOD TRAP` |
