//=============================================================================
// ARES pipeline SoC - private-memory AMP CoreMark top
//-----------------------------------------------------------------------------
// Phase-1 multi-hart full-accelerated CoreMark: each hart instantiates the
// proven single-hart student_top (private IROM, private perip_bridge DRAM/RAM,
// private UART/timer and private matrix/state accelerators).  DATA_OFFSET
// gives each hart a disjoint 32 KiB window in the shared simulation DPI memory
// so the same image and linker script can be reused.
//
// This profile is intentionally NOT the coherent shared-L2 profile.  It is a
// bring-up/benchmark top for validating that N full-accelerated CoreMark
// instances run concurrently; the shared-L2 CoreMark integration is the next
// step after the L2 response-ordering issue is fixed.
//=============================================================================
module pipeline_coremark_amp_top #(
    parameter integer CORES = 2,
    parameter integer DATA_STRIDE = 32'h0000_8000
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire [CORES-1:0]         core_en,

    output wire [CORES-1:0]         retire_valid,
    output wire [CORES-1:0][31:0]   retire_pc,
    output wire [CORES-1:0][31:0]   retire_pc_next,
    output wire [CORES-1:0]         retire_rd_wen,
    output wire [CORES-1:0][ 4:0]   retire_rd,
    output wire [CORES-1:0][31:0]   retire_wdata,
    output wire [CORES-1:0]         retire_is_ebreak
);
    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_hart
            wire [7:0]  uart_tx_data_unused;
            wire        uart_tx_start_unused;
            wire [31:0] led_unused;
            wire [39:0] seg_unused;

            student_top #(
                .DATA_OFFSET (g * DATA_STRIDE)
            ) u_core (
                .w_cpu_clk     (clk),
                .w_clk_50Mhz   (clk),
                .w_clk_rst     (rst | ~core_en[g]),
                .virtual_key   ({8{1'b0}}),
                .virtual_sw    ({64{1'b0}}),
                .uart_rx_data  (8'd0),
                .uart_rx_ready (1'b0),
                .uart_tx_busy  (1'b0),

                .uart_tx_data  (uart_tx_data_unused),
                .uart_tx_start (uart_tx_start_unused),

                .virtual_led   (led_unused),
                .virtual_seg   (seg_unused),

                .retire_valid    (retire_valid[g]),
                .retire_pc       (retire_pc[g]),
                .retire_pc_next  (retire_pc_next[g]),
                .retire_rd_wen   (retire_rd_wen[g]),
                .retire_rd       (retire_rd[g]),
                .retire_wdata    (retire_wdata[g]),
                .retire_is_ebreak(retire_is_ebreak[g])
            );
        end
    endgenerate

endmodule
