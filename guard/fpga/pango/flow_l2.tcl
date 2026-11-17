# L2 INT4 语义层单独综合/布线：面积与时序（不参与板级位流）
# ASCII only（PDS 的 tcl 解析器按系统代码页读脚本）
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]
cd $root

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_constraint [file join $here "l2.fdc"]
add_design [file join $root "build" "gen" "l1_keywords_pkg.sv"]
add_design [file join $root "vendor" "minitensor" "rtl" "tensor" "tensor_pkg.sv"]
add_design [file join $root "vendor" "minitensor" "rtl" "tensor" "MXU" "Systolic_Array" "tensor_pe.sv"]
add_design [file join $root "vendor" "minitensor" "rtl" "tensor" "MXU" "Systolic_Array" "tensor_systolic_array.sv"]
add_design [file join $root "vendor" "minitensor" "rtl" "tensor" "MXU" "INT8_GEMM" "tensor_gemm_core.sv"]
add_design [file join $root "rtl" "l1" "l1_keyword_match.sv"]
add_design [file join $root "rtl" "l2" "l2_features.sv"]
add_design [file join $root "rtl" "l2" "l2_int4_gemm.sv"]
add_design [file join $root "rtl" "l2" "l2_semantic_top.sv"]
compile -top_module {l2_semantic_top} -verilog_standard SystemVerilog
synthesize -ads
dev_map
pnr -seed 2
puts {=== L2_BUILD_DONE ===}