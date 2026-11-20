# ARES 手势识别的 FPGA 与 PC 分工实施方案

ARES 保留空闲（`idle`）、举盾（`defense`）和指向（`point`）三种动作。FPGA 输出完整彩色视频，同时在 **320×180、8 位的亮度图**上计算分块帧差。PC 复用 Immersive Controller 的 MediaPipe Hands 和 Pose，从彩色画面提取关键点并判定动作。举盾和指向都是可持续的姿态，人在启动前已经摆好姿势，或保持姿势直到画面静止，PC 都应能识别。

## 数据路径和复用边界

```text
OV5640 → FPGA 解出 RGB565（1280×720，全视野）
          ├─ DDR3 帧缓冲 → HDMI 720p30 → USB 采集卡 → PC 彩色帧
          │                                          └─ Hands / Pose → ARES 动作
          └─ 320×180 亮度图 → 分块帧差 → UART 运动摘要 → PC 调试叠加
```

| 部分 | 已有实现 | 本方案的改动 |
| --- | --- | --- |
| FPGA 彩色视频 | AMP+HDMI 顶层已将同一份 `pixel_rgb565` 同时接入 SoC 和视频通路。 | 在解码后分出运动统计支路。视频采集、DDR3 帧缓冲和 HDMI 输出连续运行，统计端独立消费像素。 |
| FPGA 运动统计 | AMP 相机模块已有 RGB565 转亮度逻辑。旧手势固件有相邻帧取绝对差和变化区域计算，可作为软件参考。 | 亮度和帧差覆盖整幅 16:9 画面。已有 320×240 灰度窗口裁取了中心区域，直接复用其坐标会丢掉画面外围。 |
| PC 视觉 | Immersive Controller 的 `pc_host/core/cv_process.py` 已包含 OpenCV 取帧、镜像、Hands/Pose 推理、骨架绘制和肘角计算。参考版本为 `0b0f0c2`。 | 把采集卡作为视频源，提取关键点处理部分，接入 ARES 的动作规则和状态输出。手机 UDP、虚拟手柄及游戏动作映射属于独立的上层应用。 |

板级接入见 [AMP+HDMI 顶层](../rtl/pipeline/board/pipeline_rtos_amp_hdmi_board_top.sv) 和 [AMP 相机采样](../rtl/pipeline/soc/amp/pipeline_amp_camera.sv)。旧算法的参照入口为 [mt_track.c 中的 trk_grab 和 build_mask](../app/gesture/firmware/app/mt_track.c)。

## FPGA 运动统计

1. **生成亮度图。** 沿用现有 RGB565 通道扩展，按 `Y = (77R + 150G + 29B) >> 8` 得到 8 位亮度。首版建议对每个 4×4 原图区域的 16 个亮度值取整平均，1280×720 正好缩成 320×180，并保留完整视野。
2. **计算块强度。** 把亮度图划成 **16 列 × 9 行**，共 **144 块**。每块 **20×20**，含 400 个亮度样本。逐像素计算相邻两帧亮度绝对差。块强度取该块差值总和除以 400 后向下取整，全图强度取全图差值总和除以 57,600 后向下取整，两者范围均为 0–255。
3. **标记变化区域。** 块强度大于阈值 `T` 时置位。输出全图强度、置位块数和 **18 字节**位图，可同时表示互相分离的两处变化。按从上到下、从左到右编号，块号为 `16 × 行 + 列`，首块对应首字节最低位。阈值用固定机位的静止录像和动作录像标定。
4. **保存前帧。** 一帧亮度历史占 **57,600 字节（56.25 KiB）**。可在像素侧按地址读出旧亮度、累加差值后写入新亮度，避免由 hart0 逐像素搬运。复位或遇到残帧后，先收满一帧重建历史，再发布有效帧差。每帧结束时一次性交接统计摘要，供固件通过 UART 发送。

**串口只传摘要。** 建议首版使用独立文本行 `M1 <frame_seq> <valid> <mean_diff> <active_count> <mask_hex>`。位图按字节顺序编码成 36 个十六进制字符。PC 通过帧号检查跳帧。HDMI 采集卡和串口各有缓冲，不能用两路数据的到达顺序认定它们对应同一帧。首版用最新有效摘要作调试叠加，摘要中断时清除叠加，彩色视频继续驱动识别。逐帧核对算法时，由仿真按帧号对照同一份 RGB565 输入。

## PC 动作判定

PC 对每个取来推理的彩色帧运行 Hands/Pose，负载较高时优先处理最新完整帧。先保留 Immersive 的镜像与颜色转换，并用左右手实拍核对方向。运动位图使用相机原始坐标，显示在镜像画面上时，块列号相应变为 `15 − 列号`。

| 输出 | 首版判定依据 | 状态表现 |
| --- | --- | --- |
| `0 idle` | 关键点可见，姿态符合 ARES 的空闲参考样例。 | 主动放下手并回到空闲姿态后，确认并输出空闲。 |
| `1 defense` | 复用 Immersive 的肩、肘、腕几何计算。根据 ARES 原举盾样例确定用手、屈肘角和手腕高度。 | 只要举盾姿态持续成立，就保持举盾。 |
| `2 point` | 用手指关节角度确认食指伸展、其余手指收拢。用朝上和侧向指的样例校准。 | 从静止启动即可进入指向，食指保持伸展时持续输出。 |
| `-1 unknown` | 无人、判定所需关键点缺失、姿态有歧义或视频断流。 | 释放上一个动作，重新获得有效画面后再确认。 |

以当前 AMP 的三帧确认作为基线。每次得到不同的有效候选，重新累计连续帧数，确认前输出未知。持续收到同一已确认姿态时保持状态。**运动强度和变化区域只提供辅助信息**，首次进入、静止保持和退出动作均由彩色帧中的姿态证据决定。首版先观察运动分布，后续若用于提示重新定位，应与纯关键点基线比较误释放和恢复时间。

PC 对外沿用 `raw` 和 `stable` 的类别编号。如需适配 AMP 原有约 10 Hz 的 `G` 行消费者，先确认其是否依赖三个 INT8 类别分数、分差及标志位。几何判定有自己的量纲，需要分数的消费者应明确约定新字段或协议版本。模型原来的分差阈值 4 仅适用于原 CNN。[当前 G 行与三帧确认实现](../rtthread-nano/rt-thread/bsp/ARES/amp/gesture.c)

## 实施顺序与验收

| 顺序 | 实施内容 | 验收依据 |
| --- | --- | --- |
| 1. 建立视频与动作基线 | 用现有 S2 视频通路接 HDMI 转 USB 采集卡，录下原 ARES 操作者的空闲、举盾、指向和离场。保留静止保持、侧向指以及手指和肘部可见的片段。 | 确认 PC 实际取得完整视野，核对帧率、颜色、左右方向和横条干扰。S2 已有实板出图及摄像头横条记录。[板测记录](../fpga/pango/README.md) |
| 2. 验证 PC 动作 | 离线回放同一批录像，记录关键点、原始类别和稳定类别，然后接采集卡实时运行。 | 人先摆好姿势再启动时可进入动作。持续举盾或指向时不误释放。放下手可回到空闲，遮挡或离场可转为未知。 |
| 3. 验证 FPGA 统计 | 在 AMP+HDMI 接入亮度与统计旁路，以相同输入、阈值和取整规则对照软件参考。 | 两帧相同时强度和位图为零。只改变一个对齐块时核对块号、强度和置位数。全画面亮度等量变化时核对全图均值。首帧及残帧后的重新建帧行为符合约定。 |
| 4. 联调整机 | 同屏显示骨架、动作和运动位图。回放背景有人走动、全局光照变化、串口统计中断及视频断流场景。 | 分别记录动作进入耗时、静止保持期间误释放次数、放下手后的释放耗时。停用运动摘要后仍能识别三种动作，视频断流后能释放已激活动作。 |

## 运行与回放

从仓库根目录构建 AMP 固件并准备 PDS 文件表。在安装 PDS 的主机上运行已有的 AMP+HDMI 布局布线脚本，顶层为 `pipeline_rtos_amp_hdmi_board_top`。

```sh
make pipeline-rtos-amp-pango-prep
pds_shell -file fpga/pango/pipeline/flow_pipeline_rtos_amp_hdmi_pnr.tcl -project_name pipeline_rtos_amp_hdmi_pnr
```

将板上 OV5640 的 HDMI 输出接到 USB 采集卡。PC 端沿用 Immersive Controller `0b0f0c2` 的镜像、BGR 转 RGB、Hands/Pose 和骨架绘制。依赖固定在提供 Solutions 接口的版本，Pose 采用轮子内附的 full 模型，可离线推理。[MediaPipe 0.10.21](https://pypi.org/project/mediapipe/0.10.21/) · [Pose 模型选择](https://github.com/google-ai-edge/mediapipe/blob/v0.10.21/mediapipe/python/solutions/pose.py)

```sh
python3.12 -m venv build/gesture-pc-env
. build/gesture-pc-env/bin/activate
python -m pip install -r app/gesture/pc/requirements.txt
python app/gesture/pc/run.py --camera 0
```

`--camera` 取 OpenCV 设备编号。显示窗口中按 Q 或 Esc 退出。需要运动叠加时先让板端回到 MSH 提示符，关闭占用串口的终端，再加上 `--serial /dev/ttyUSB0`（Windows 可用 `--serial COM9`）。PC 向 115200 8N1 串口写入 `motion` 命令，正常退出时发送 Ctrl+] 交回 MSH。也可以用终端手工运行 `motion` 查看原始行。板端 CNN 在 `ai start` 命令下运行，进入运动摘要会话前用 `ai stop` 停止它。

标准输出为每个推理帧一行 JSON。核心字段为 `frame`、`t`（秒）、`raw`、`stable` 和 `event`。实时模式的 `t` 来自 PC 取帧时钟，回放模式使用视频时间戳。`inference_ms` 是每帧的 PC 处理耗时，实时模式也记录 `capture_to_result_ms`。可选的 `motion.seq` 属于 FPGA 相机时钟域。最新有效摘要保留 0.5 秒，收到无效摘要或串口断开时清除。视频读取失败或停顿 0.5 秒会输出 `video_lost` 和 `stable=-1`，设备恢复后重新累计三帧。视频结束会输出 `end` 和 `stable=-1`。原 AMP 的 `G` 行包含 CNN 分数，PC 通过 JSON 的类别字段提供几何判定结果。

### 采集基线与动作标定

先保存采集卡的原始方向录像，核对四角、颜色、实际帧率和横条。以下是 Linux V4L2 设备示例，设备号和输入格式按采集卡调整，按 Q 结束录制。

```sh
ffmpeg -f v4l2 -framerate 30 -video_size 1280x720 -i /dev/video0 -c:v ffv1 baseline.mkv
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate -of default=nw=1 baseline.mkv
python app/gesture/pc/run.py --video baseline.mkv --headless --landmarks > baseline.jsonl
```

回放逐帧推理。`--landmarks` 保存镜像后的 Pose 像素坐标与可见度，以及手部图像归一化坐标、左右手标签和三维手关节。实时采集优先消费最新帧，输出的 `frame` 跳号可用来检查取帧负载。

| 姿态 | 当前几何基线 |
| --- | --- |
| 举盾 | 默认使用镜像输入中的 Pose 右肩、右肘、右腕（12、14、16），与参考工程选点一致。鼻和三关节可见度均须大于 0.5，腕低于鼻且高于肘，肘角小于 90°。实拍左右手后可用 `--shield-side left`、`right` 或 `either` 选择。 |
| 指向 | 依据手部三维坐标，食指近端关节角至少 155°、远端至少 145°，中、无名、小指各有一个关节角不超过 115°。拇指尖到中指掌指关节的距离不超过掌宽。举盾和指向证据同时成立时输出未知。 |
| 空闲 | 两侧肩、肘、腕均可见，腕低于肘、肘低于肩，两个肘角均至少 145°。缺失的关节不计作已放下的手。 |

用原操作者分别录制静止启动、持续保持、主动放下、遮挡、离场、侧向指和背景走动。按录像时间人工标注 `start,end,label` 三列 CSV，时间区间左闭右开，标签可取 `idle`、`defense`、`point`、`unknown`。例如：

```csv
start,end,label
0,3,point
3,5,idle
5,7,unknown
```

```sh
python app/gesture/pc/score.py baseline.jsonl intervals.csv
```

每段输出首次确认时间 `enter_ms` 和确认后的误释放次数 `false_releases`。相邻标注段还记录从切换时刻到释放前一已激活动作的 `previous_release_ms`。未确认的动作返回 `null`，同一段内连续丢失多帧计一次误释放。用相同录像分别接入和停用串口，比较 `raw/stable` 序列；改变背景光照和运动摘要只应影响叠加。现场还需记录采集卡拔插后的释放与恢复，以及从实际动作发生到界面显示的延时。

### FPGA 摘要接口与回归

顶层综合参数 `MOTION_THRESHOLD` 默认 12，作为固定机位标定的起点。先观察静止时误置位块数和动作时的覆盖范围，再确定上板阈值。分别保存同一机位的静止和运动录像，以下命令按候选阈值列出至少有一块活动的帧比例，以及每帧平均活动块数。两段录像均使用完整 1280×720 原始方向。这里的 RGB565 由采集卡解码后的颜色重新量化，可用来缩小标定范围，最终值用板端 M1 行复核。

```sh
python app/gesture/pc/calibrate_motion.py still.mkv movement.mkv --thresholds 4 8 12 16 24
```

帧号从 1 开始，按 32 位回绕，首帧、残帧和重建历史的首个完整帧发送 `valid=0`，其余字段清零。两端使用既有跨时钟域 mailbox 交接整份摘要。固件读取慢时允许跳帧。有效行示例中只有左上角和右下角两块各变化 255 级：

```text
M1 2 1 3 2 010000000000000000000000000000000080
```

| hart0 地址 | 语义 |
| --- | --- |
| `0xD0003020` | 读 bit 1 为硬件存在，bit 0 为有新摘要。写入时锁存最新摘要供后续读取，并清除本次就绪。 |
| `0xD0003024` | 已锁存的帧号。 |
| `0xD0003028` | bit 16 为有效，bit 15…8 为活动块数，bit 7…0 为全图平均帧差。 |
| `0xD000302C–0xD000303C` | 由低到高五个字，最低地址的最低位为块 0，最后一个字仅低 16 位有效。 |

```sh
python3 -m unittest discover -s app/gesture/pc
make pipeline-gesture-motion-test
make pipeline-gesture-uart-test
make pipeline-rtos-amp-test
```

第一项检查动作确认、指向旋转、遮挡、取帧超时与运动位图。第二项用 NumPy 从同一批原始 RGB565 输入独立计算期望值，按帧核对 20 组结果，覆盖阈值取整、全图亮度变化、边角、残帧、复位与读取跨帧。第三项经过仿真 DVP、hart0 固件、UART 引脚和 PC 解析器验证 `M1`。最后一项回归板端 CNN 和四 hart CoreMark。

本次离线冒烟使用 MediaPipe 的指向测试照片，在 30 fps 录像中依次放入 12 帧原图、12 帧旋转 90° 的图和 12 帧空画面。第 3 帧确认指向，对应录像时间 67 ms。第 3 至第 24 帧持续输出指向，首个空画面即释放。向伪串口送入全图活动摘要再拔断，全部 36 帧的类别与禁用串口时一致。这些数值用于复核 PC 软件链路。原操作者的三类实拍、采集卡画质以及 PDS 时序和资源占用仍待实板验收。[测试图](https://storage.googleapis.com/mediapipe-assets/pointing_up.jpg)
