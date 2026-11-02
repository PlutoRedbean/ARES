#!/usr/bin/env python3
"""Use inferred Pango RAMs and the behavioral PLL in RTOS simulation."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
text = (root / 'rtl/pipeline/pipeline_pango.f').read_text()
text = text.replace('rtl/pipeline/board/pipeline_pll.v', 'rtl/pipeline/board/pipeline_pll_sim.v')
(root / 'build/rtos/sim.f').write_text(text + '\nrtl/pipeline/board/pipeline_rtos_board_top.v\n')
