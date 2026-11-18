set -e
cd /mnt/e/qs/ScreenSense/guard
rsync -a rtl sim ~/gr/
rsync -a build/gen/ ~/gr/build/gen/
cd ~/gr
verilator --binary --timing -j 2 -O2 -Wno-fatal --top-module tb_ner_doc -Ibuild/gen --Mdir build/obj_d -o Vd \
  build/gen/l1_keywords_pkg.sv build/gen/l2_entity_tables.sv build/gen/l2_ner_cfg.sv \
  build/gen/l2_ner_rom.sv build/gen/l2_ner_vocab.sv rtl/l2/l2_entity.sv rtl/l2/l2_ner.sv \
  rtl/l1/l1_digit_engine.sv rtl/l1/l1_text_engines.sv rtl/l1/l1_keyword_match.sv \
  rtl/l1/l1_engine.sv rtl/l1/l1_redact.sv sim/tb_ner_doc.sv 2>&1 | grep -E "^%Error" | head -4 || true
timeout 900 ./build/obj_d/Vd +file=sim/doc_case.txt > /tmp/doc.hex 2>&1 || true
python3 /mnt/e/qs/ScreenSense/guard/decode_hex.py
