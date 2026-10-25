# rtl/soc/test - SoC-level self-checking benches

| File | Role |
|---|---|
| `tb_mt_irq.sv` | `ares_mt_host_adapter` + behavioural CV-X-IF slave: need_work/done/accept_err/kick_err IRQ, mask/ack, status-clear, HART_ID (26 checks). |
| `tb_mt_cpu_irq.sv` | Real `student_top` frontend/IROM + adapter: CPU enables MEIE, traps on `mip.MEIP`, handler checks `mcause=0x8000000B`, ACKs need_work and exits with a0=0 (38 retires with the real frontend). |
| `tb_clint.sv` | `soc_clint` per-hart MSIP/MTIMECMP/MTIME, timer compare, 64-bit carry, byte strobes and single-outstanding response behavior (56 checks). |
| `tb_plic.sv` | `soc_plic` 32 sources / 2 contexts: priority, enable, threshold, claim/complete, level gateway re-pend, tie-break and context independence (88 checks). |

Run from the repository root:

```bash
make unit-mt-irq
make unit-mt-cpu-irq
make unit-clint
make unit-plic
```
