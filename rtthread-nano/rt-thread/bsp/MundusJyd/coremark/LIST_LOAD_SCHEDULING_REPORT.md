# CoreMark 链表加载调度 A/B 报告

测试日期：2026-08-03

## 结论

保留 core_list_find() 的类型化加载调度改写。相同 100 次 CoreMark
仿真中，Total ticks 从 14,859,652 降至 14,536,678，减少 322,974
ticks（2.17%）；Iterations/Sec 从 2018.889810 提高至 2063.745238
（2.22%）。

这个改写没有让两个 load 在同一拍发射。Mundus 的两个访存指令存在
sharedMemoryConflict，仍然每拍最多发射一个 load。调度的作用是把
独立的 next 加载放在 info 指针加载与依赖 info 的字段加载之间：

~~~asm
lw  a4,4(a5)    # candidate->info
lw  a3,0(a5)    # candidate->next，独立工作占据下一发射周期
lh  a4,2(a4)    # 使用已经就绪的 info
~~~

生成器使用 candidate->info 和 candidate->next 两个 C 内存操作数，
没有硬编码结构成员偏移；若上游 core_list_find() 的源码形状变化，
生成器会直接失败，避免静默误改。

## 测试条件

- NPC：MundusJyd，300 MHz
- 分支预测器：TAGE-R-L
- 编译器：GCC 15.2.0
- CoreMark iterations：100
- CRC：调用点内联自定义指令
- Matrix：N=9 专用 ikj/9 累加器 + MULBE
- 统计窗口：LED0，仅包含 CoreMark

基线与优化版分别使用独立构建目录：

~~~text
/tmp/MundusJyd-list-ab-baseline-20260803
/tmp/MundusJyd-list-ab-memop-20260803
~~~

## 总体结果

| 指标 | 基线 | 最终优化版 | 变化 |
|---|---:|---:|---:|
| Total ticks | 14,859,652 | 14,536,678 | -322,974 (-2.17%) |
| Total time | 0.049532 s | 0.048456 s | -2.17% |
| Iterations/Sec | 2018.889810 | 2063.745238 | +2.22% |
| 仿真统计周期 | 14,894,780 | 14,572,410 | -322,370 (-2.16%) |
| Guest instructions | 21,035,455 | 21,784,786 | +749,331 (+3.56%) |
| IPC | 1.412270 | 1.494934 | +5.85% |
| 双发射率 | 59.01% | 55.25% | -3.76 pp |

动态指令数增加，是因为提前保留 next 后，未命中路径需要一次寄存器
搬运。尽管如此，等待周期的大幅下降使总 ticks 减少。双发射率降低不
代表退化：优化版的单发射有效工作和退休 IPC 都更高。

## 冒险变化

| 指标 | 基线 | 最终优化版 | 变化 |
|---|---:|---:|---:|
| issue-operand 主阻塞周期 | 1,178,073 | 50,067 | -95.75% |
| load 生产者阻塞源周期 | 1,270,253 | 142,638 | -88.77% |
| AGU 消费者阻塞源周期 | 1,270,252 | 142,637 | -88.77% |
| issue-load-port 周期 | 0 | 0 | 不变 |

issue-load-port 仍为 0，证明优化没有把 load-use 问题转移成 load
端口冻结。基线中排名前四的链表查找阻塞 PC 共约 111.6 万个阻塞源
周期；最终版中它们不再出现在前十热点。

## 正确性

官方 EEMBC 源文件未修改，并通过 make verify-coremark-source：

~~~text
core_list_join.c: OK
core_main.c: OK
core_matrix.c: OK
core_state.c: OK
core_util.c: OK
coremark.h: OK
~~~

两版 CRC 均一致：

~~~text
crclist   = 0xe714
crcmatrix = 0x1fd7
crcstate  = 0x8e3a
crcfinal  = 0x988c
~~~

仿真以 CoreMark finished with result 0 和 HIT GOOD TRAP 结束。

100 次只用于快速、确定性的 A/B 比较，运行时间不足 10 秒，所以
CoreMark 会打印 Errors detected。该提示来自最短运行时间检查，不是
CRC 错误；这组数据不能直接作为符合 CoreMark 报告规则的正式成绩。

## 实现位置

- scripts/generate_list_schedule.py：只转换构建目录中的 CRC 生成源
- Makefile：在 CRC 生成之后、编译之前接入链表调度生成器
- core_portme.h：输出中标记 list:load-scheduled

最终保留的是类型化内存操作数版本。曾测试过带全局 memory 屏障的
版本，其 Total ticks 为 14,556,691；由于比最终版慢 20,013 ticks，
未保留。
