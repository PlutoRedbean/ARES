//=============================================================================
// ARES pipeline SoC v2 - parameterized private-memory AMP top
//-----------------------------------------------------------------------------
// CORES=2/4 harts with private copies of the read-only instruction image, private
// per-hart data/accelerators and one shared uncached mailbox.
//
//   * IROM and the optional set-associative I-cache live inside student_top.
//   * DRAM: each hart owns a private 32 KiB window inside its local BRAM
//     address space, selected by DATA_OFFSET = hart * DATA_STRIDE.
//   * MMIO: UART/timer/cycle counter and the matrix/state accelerators stay
//     private per hart inside student_top.
//   * Mailbox: one shared uncached window at 0xA000_F000 (slot h per hart)
//     plus the hart id at 0xA000_0FF0.
//   * RTOS_AI gives hart 0 its own larger image, console RX and miniTensor.
//
// No L2, no coherence, no atomics.  Code memory is read-only, so the I$s
// need no coherence or FENCE.I invalidation.
//=============================================================================
`include "autoconf.vh"

module pipeline_amp_top #(
    parameter integer CORES             = 2,
    parameter integer DATA_STRIDE       = 32'h0000_8000,
    parameter integer USE_ICACHE        = 1,
    parameter integer ICACHE_LINES      = 256,
    parameter integer ICACHE_LINE_BYTES = 64,
    // Per-hart private DRAM geometry.  Every hart owns one DATA_STRIDE window
    // (0x8000 = 32 KiB => 13 word-address bits) inside its own BRAM, so the
    // AMP build only needs 2**DRAM_AW words per hart instead of the
    // single-hart 256 KiB.  Keep DRAM_AW = log2(DATA_STRIDE/4).
    parameter integer DRAM_AW           = 13,
    parameter         DRAM_INIT_FILE    = "build/pipeline/dram_amp.hex",
    parameter         IROM_INIT_FILE    = "build/pipeline/irom.hex",
    parameter         RTOS_AI           = 1'b0,
    parameter         HART0_IROM_FILE   = "build/rtos_amp/irom.hex",
    parameter         HART0_DRAM_FILE   = "build/rtos_amp/dram.hex"
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
    output wire [CORES-1:0]         retire_is_ebreak,

    // Board console/debug.  Only hart 0 is brought out; the other harts'
    // UART streams are private to the simulation/debug environment.
    output wire                     uart_tx,
    output wire [31:0]              led,
    input  wire                     periph_clk,
    input  wire                     periph_rst,
    input  wire                     uart_rx,
    output wire                     rx_full,
    output wire                     rx_overflow,
    input  wire                     pixel_clk, pixel_rst, pixel_vsync, pixel_de,
    input  wire [15:0]              pixel_rgb565
);
    localparam integer MEM_AW = `CONFIG_IROM_ADDR_WIDTH + 1;

    // Elaboration-time guard: a hart's BRAM must cover its whole DATA_STRIDE
    // window, otherwise the address slice in pipeline_bram.v would alias two
    // different words onto the same entry and only the benchmark CRC would
    // notice.  DRAM_AW larger than needed is merely wasteful, so only the
    // undersized case is an error.
    generate
        if ((1 << DRAM_AW) * 4 < DATA_STRIDE) begin : g_dram_geometry_error
            DRAM_AW_is_smaller_than_the_hart_window u_geometry_error ();
        end
    endgenerate

    // Boot flag from the shared mailbox: it clears its 64-word window one word
    // per cycle through its own write port (no reset on the 2,048-bit array).
    // Every hart is held in reset until that walk completes.
    wire                    mbox_init_done;

    // Per-hart UART/LED wires.  Hart 0's UART drives the board pin.
    wire [CORES-1:0][7:0]   hart_uart_tx_data;
    wire [CORES-1:0]        hart_uart_tx_start;
    wire [CORES-1:0]        hart_uart_tx_busy;
    wire [CORES-1:0][31:0]  hart_led;
    wire [CORES-1:0][39:0]  hart_seg;

    // Shared uncached mailbox port, one request port per hart.
    wire [CORES-1:0]        mbox_req_valid;
    wire [CORES-1:0]        mbox_req_write;
    wire [CORES-1:0][31:0]  mbox_req_addr;
    wire [CORES-1:0][31:0]  mbox_req_wdata;
    wire [CORES-1:0][ 3:0]  mbox_req_wstrb;
    wire [CORES-1:0][31:0]  mbox_rsp_data;
    wire [7:0] rx_data;
    wire rx_ready;
    wire [CORES-1:0] rx_consumed;

    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_hart
            localparam HOST = RTOS_AI && g == 0;
            wire hart_rst = rst | ~core_en[g] | ~mbox_init_done;
            wire mt_valid, mt_ready, mt_write;
            wire [31:0] mt_addr, mt_wdata, mt_rdata;
            wire [3:0] mt_wstrb;
            if (HOST) begin : g_mt
                wire camera_sel = mt_addr[31:28] == 4'hd;
                wire tensor_ready;
                wire [31:0] tensor_rdata, camera_rdata;
                reg camera_read_q, camera_read_r2;

                assign mt_ready = camera_sel ? !hart_rst : tensor_ready;
                assign mt_rdata = camera_read_r2 ? camera_rdata : tensor_rdata;

                always @(posedge clk) begin
                    camera_read_q <= !hart_rst && mt_valid && mt_ready && !mt_write && camera_sel;
                    camera_read_r2 <= camera_read_q;
                end

                pipeline_amp_minitensor u_mt (
                    .clk(clk), .rst(hart_rst), .cpu_valid(mt_valid && !camera_sel),
                    .cpu_ready(tensor_ready), .cpu_write(mt_write), .cpu_addr(mt_addr),
                    .cpu_wdata(mt_wdata), .cpu_wstrb(mt_wstrb), .cpu_rdata(tensor_rdata)
                );

                pipeline_amp_camera u_camera (
                    .pixel_clk(pixel_clk), .pixel_rst(pixel_rst),
                    .pixel_vsync(pixel_vsync), .pixel_de(pixel_de), .pixel_rgb565(pixel_rgb565),
                    .clk(clk), .rst(rst), .cpu_valid(mt_valid && mt_ready && camera_sel),
                    .cpu_write(mt_write), .cpu_addr(mt_addr), .cpu_rdata(camera_rdata)
                );
            end else begin : g_no_mt
                assign mt_ready = 1'b0;
                assign mt_rdata = 32'b0;
            end
            student_top #(
                .DATA_OFFSET     (g * DATA_STRIDE),
                .HART_ID         (g),
                .HART_COUNT      (CORES),
                .EXTERNAL_IROM   (0),
                .USE_ICACHE      (USE_ICACHE),
                .ICACHE_SETS     (ICACHE_LINES / 4),
                .ICACHE_WAYS     (4),
                .ICACHE_LINE_BYTES (ICACHE_LINE_BYTES),
                .DRAM_AW         (HOST ? 15 : DRAM_AW),
                .DRAM_INIT_FILE  (HOST ? HART0_DRAM_FILE : DRAM_INIT_FILE),
                .IROM_INIT_FILE  (HOST ? HART0_IROM_FILE : IROM_INIT_FILE),
                .IROM_WORD_AW    (HOST ? 14 : MEM_AW),
                .MT_MMIO         (HOST)
            ) u_core (
                .w_cpu_clk     (clk),
                .w_clk_50Mhz   (HOST ? periph_clk : clk),
                .w_clk_rst     (hart_rst),
                .virtual_key   ({8{1'b0}}),
                .virtual_sw    ({64{1'b0}}),
                .uart_rx_data  (HOST ? rx_data : 8'd0),
                .uart_rx_ready (HOST && rx_ready),
                .uart_rx_consumed(rx_consumed[g]),
                .uart_tx_busy  (hart_uart_tx_busy[g]),

                .uart_tx_data  (hart_uart_tx_data[g]),
                .uart_tx_start (hart_uart_tx_start[g]),

                .virtual_led   (hart_led[g]),
                .virtual_seg   (hart_seg[g]),

                .retire_valid    (retire_valid[g]),
                .retire_pc       (retire_pc[g]),
                .retire_pc_next  (retire_pc_next[g]),
                .retire_rd_wen   (retire_rd_wen[g]),
                .retire_rd       (retire_rd[g]),
                .retire_wdata    (retire_wdata[g]),
                .retire_is_ebreak(retire_is_ebreak[g]),

                .irom_req_valid  (),
                .irom_req_addr   (),
                .irom_req_ready  (1'b1),
                .irom_rsp_valid  (1'b0),
                .irom_rsp_data   (32'b0),
                .irom_rsp_ready  (),
                .irom_flush      (),

                .shared_rdata     (mbox_rsp_data[g]),
                .shared_req_valid (mbox_req_valid[g]),
                .shared_req_write (mbox_req_write[g]),
                .shared_req_addr  (mbox_req_addr[g]),
                .shared_req_wdata (mbox_req_wdata[g]),
                .shared_req_wstrb (mbox_req_wstrb[g]),
                .mt_req_valid(mt_valid), .mt_req_ready(mt_ready), .mt_req_write(mt_write),
                .mt_req_addr(mt_addr), .mt_req_wdata(mt_wdata), .mt_req_wstrb(mt_wstrb),
                .mt_rdata(mt_rdata)
            );
        end
    endgenerate

    pipeline_coremark_mbox #(
        .CORES     (CORES)
    ) u_mbox (
        .clk       (clk),
        .rst       (rst),
        .req_valid (mbox_req_valid),
        .req_write (mbox_req_write),
        .req_addr  (mbox_req_addr),
        .req_wdata (mbox_req_wdata),
        .req_wstrb (mbox_req_wstrb),
        .rsp_data  (mbox_rsp_data),
        .init_done (mbox_init_done)
    );

    // ------------------------------------------------------------------
    // Only hart 0 drives the UART. The RTOS board uses the 50 MHz peripheral
    // clock for UART and RTOS ticks. The benchmark counter uses the CPU clock.
    // ------------------------------------------------------------------
    wire [7:0] uart_raw_data;
    wire       uart_raw_ready;
    wire       uart_tx_busy;

    assign hart_uart_tx_busy[0] = uart_tx_busy;

    genvar gu;
    generate
        for (gu = 1; gu < CORES; gu = gu + 1) begin : g_uart_unused
            assign hart_uart_tx_busy[gu] = 1'b0;
        end
    endgenerate

    uart #(
        .CLK_FREQ  (RTOS_AI ? 50_000_000 : 100_000_000),
        .BAUD_RATE (115_200)
    ) u_uart (
        .clk      (RTOS_AI ? periph_clk : clk),
        .rst_n    (RTOS_AI ? ~periph_rst : ~rst),
        .rx       (RTOS_AI ? uart_rx : 1'b1),
        .rx_data  (uart_raw_data),
        .rx_ready (uart_raw_ready),
        .tx       (uart_tx),
        .tx_data  (hart_uart_tx_data[0]),
        .tx_start (hart_uart_tx_start[0]),
        .tx_busy  (uart_tx_busy)
    );

    generate
        if (RTOS_AI) begin : g_rx
            pipeline_uart_rx_fifo u_rx_fifo (
                .cpu_clk(clk), .cpu_rst(rst), .consumed(rx_consumed[0]),
                .clk(periph_clk), .rst(periph_rst),
                .raw_data(uart_raw_data), .raw_ready(uart_raw_ready),
                .data(rx_data), .ready(rx_ready), .full(rx_full), .overflow(rx_overflow)
            );
        end else begin : g_no_rx
            assign rx_data = 8'b0;
            assign rx_ready = 1'b0;
            assign rx_full = 1'b0;
            assign rx_overflow = 1'b0;
        end
    endgenerate

    assign led = hart_led[0];
endmodule
