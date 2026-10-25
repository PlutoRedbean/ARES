# rtl/soc/test - SoC-level self-checking benches

| File | Role |
|---|---|
| `tb_mt_irq.sv` | `ares_mt_host_adapter` + behavioural CV-X-IF slave: need_work/done/accept_err/kick_err IRQ, mask/ack, status-clear, HART_ID (26 checks). |
| `tb_mt_cpu_irq.sv` | Real `student_top` + adapter + `fe_model`: CPU enables MEIE, traps on `mip.MEIP`, handler checks `mcause=0x8000000B`, ACKs need_work and exits with a0=0 (35 retires). |

Run from the repository root:

```bash
make unit-mt-irq
make unit-mt-cpu-irq
```
