# A2a：L2 参考模型与定向验证（2026-10-27）

> 范围：docs/next_steps_implementation_plan.md §2 A2 的前半。口径遵循
> [D-A2 / D-A3](m1_closure_decisions.md)。
> 基线：base_core HEAD 3084ba8 加本轮工作区改动。
> 本记录只说明 A2a 的交付与证据；A2b（随机反压、3 seed 长跑、覆盖导出）与 L2-M1 整体关闭不在此列。

## 1. 交付内容

| 位置 | 内容 |
| --- | --- |
| rtl/l2/test/l2_ref_model.sv | 参考模型 + 检查器：持有 backing memory 与黄金镜像，驱动存储侧握手 |
| rtl/l2/test/tb_l2_ref.sv | 定向序列 + 最终排空/回扫，33 项检查 |
| scripts/test_l2_ref_faults.py | 故障注入：把 5 个可信的 RTL 缺陷注入 l2_top，要求 TB 全部报错 |
| Makefile | tb_l2_ref 并入 unit-l2 门禁；新增 test-l2-ref-faults |

运行：

    make unit-l2                 # 三个 L2 TB：17 + 33 + 4 checks
    make test-l2-ref-faults      # 4 个突变必须全部被检出

## 2. 参考模型检查什么

按 D-A3 把检查分成三层，替换策略只做抽象校验：

| 层 | 检查 | 失败计数 |
| --- | --- | --- |
| 数据面（严格） | 每笔已接受读恰好一次响应、发往正确的端口，数据等于受理时的黄金 beat；每笔已接受写的字节使能合并进黄金镜像 | err_data / err_owner |
| 写回（严格） | 脏写回的 16 B beat 必须等于黄金行；地址与字节使能必须合法 | err_wb |
| 替换（抽象） | victim 写回必须与其后的 refill 属于同一 set；不比对选中哪一个 way | err_wb |
| 地址（守卫） | 所有上层受理地址、refill 与写回地址必须落在 [0x8000_0000, +1 MiB)；越界立即 $fatal，而不是被 addr[23:4] 静默折回 | 直接终止 |

关键性质：**错误的写回不会更新黄金/backing**，因此污染不能被后续正确流量掩盖；最终的
「每 set 4 个新 tag 排空 + 回扫全部 touched 行」会把所有脏行挤出缓存，迫使它们从 backing
重新取数——写回丢失或写回数据错误都会在回扫时暴露为数据不一致。

存储侧由模型自己驱动，因此天然带有确定性反压与读延迟（当前 RD_STALL=2、WR_STALL=1、
MEM_LAT=2 个额外周期），定向用例在存在反压的条件下通过。

## 3. 定向覆盖（33 项）

| 场景 | 验证点 |
| --- | --- |
| 冷复位中途打断 refill | 复位后无残留响应、L2 回到 idle，随后访问正常 |
| 干净 refill / 跨端口命中 | 返回 backing 数据；第二个端口命中同一行 |
| c0 写→读、c1 读，c1 写→c0 读 | 跨端口可见性与角色互换 |
| write-allocate + 部分字节使能 | 使能字节被写入，未使能字节保持原值 |
| 同 set 六个 tag | 两次以上替换、脏写回、被驱逐行重新 refill 后数据不变 |
| 稀疏字节使能 0x8001 / 0x000F | 只改指定字节，中间字节保留 |
| 64 B 行按 4 个 beat 拼装 | 每个 beat 独立写入与读回 |
| 响应接收停顿 | ready 拉低期间 valid 与 payload 保持稳定 |
| i0 取指端口读 | 只读端口与数据端口共享同一行 |
| 排空 + 回扫 | 脏数据确实到达 backing；最终镜像一致 |
| 计数器 | hit + miss == 已接受事务数；末尾无 outstanding 读 |

## 4. 检查器判别力（故障注入，5/5 检出）

| 注入缺陷 | 检出方式 |
| --- | --- |
| 写回地址被异或 0x40（写回落到相邻 set） | 写回数据与黄金行不符 |
| 读 miss 返回错误 beat（条件取反） | 响应数据与黄金 beat 不符 |
| 装配时不清脏位（脏行永不写回） | 排空回扫时读到旧 backing 数据 |
| 字节使能条件取反 | 部分写后的读回数据与黄金不符 |
| victim tag 被置成全 1（写回地址越出窗口） | 越界守卫直接终止：写回地址 0xfffffc00 不在窗口内 |

基线（未改 RTL）必须先通过，否则脚本直接失败；因此每个突变失败只能归因于注入的缺陷。
这一步是必要的：SPEC-D13 记录的正是「TB 全绿但不能区分对错」的失效模式。

## 5. 仍未完成（A2b）

1. 随机反压：模型当前是确定性 stall；A2b 加入按 seed 的随机 ready/valid 停顿。
2. 3 个固定 seed × 每 seed 四端口合计 100 万笔已接受事务（D-A2 口径）。
3. 覆盖统计导出：FSM 六状态与必要转移、owner/way/beat 分布、stall 周期。
4. 慢回归入口 make test-l2-stress（不进 make all）。
5. CoreMark TB 侧的同款越界守卫暂缓：该 TB 没有 MMIO 模型，0xA000_xxxx 之类的访问目前
   无法与「桩折叠」区分，属 A2b/SPEC-M7 的取舍。

## 6. 本轮改动

新增：rtl/l2/test/l2_ref_model.sv、rtl/l2/test/tb_l2_ref.sv、scripts/test_l2_ref_faults.py、
docs/m1_a2_l2_ref_results.md。
修改：Makefile（ARES_L2_UNIT_TBS、tb_l2_ref 源文件映射、test-l2-ref-faults）、
docs/next_steps_implementation_plan.md（A2 部分状态）。
