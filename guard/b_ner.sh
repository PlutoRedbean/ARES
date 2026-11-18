set -e
cd /mnt/e/qs/ScreenSense/guard
rm -rf ~/gn7 && mkdir -p ~/gn7/build/gen
rsync -a host tools rtl sim models data ~/gn7/
rsync -a build/gen/ ~/gn7/build/gen/
cd ~/gn7
ls build/gen | head -5
verilator --binary --timing -j 2 -O2 -Wno-fatal --top-module tb_l2_ner -Ibuild/gen --Mdir build/obj_ner -o Vner \
  build/gen/l2_ner_rom.sv build/gen/l2_ner_vocab.sv rtl/l2/l2_ner.sv sim/tb_l2_ner.sv 2>&1 | grep -E "^%Error" | head -10 || true
if [ -x build/obj_ner/Vner ]; then ./build/obj_ner/Vner +dir=build/ner_vectors 2>&1 | tail -12; else echo NO_BIN; fi