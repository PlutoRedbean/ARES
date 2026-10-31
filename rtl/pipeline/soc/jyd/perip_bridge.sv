`timescale 1ns / 1ps
`include "autoconf.vh"
//////////////////////////////////////////////////////////////////////////////////
// perip_bridge.sv - jyd peripheral bridge with Pango-portable CDC.
//
// CDC policy (implementation in soc/pango/pipeline_cdc.v):
//   - virtual_sw_input / virtual_key_input:
//       Treated as bitwise-independent switch/key levels generated in
//       cnt_clk domain. Each bit is synchronized to clk domain using
//       pipeline_cdc_array_single.
//   - LED / SEG CPU configuration:
//       CPU writes are coherent multi-bit snapshots. The latest {seg_wdata, LED}
//       snapshot is transferred from clk domain to cnt_clk domain using a
//       four-phase bundled-data handshake (pipeline_cdc_mailbox).
//   - cnt_enable_cfg:
//       Kept in CPU domain and synchronized inside counter.v.
//   - counter value:
//       Synchronized inside counter.v by pipeline_cdc_gray.
//   - cnt_clk reset:
//       Asynchronous assert / synchronous release per clock domain.
//////////////////////////////////////////////////////////////////////////////////

module perip_bridge #(
    // Hart identity exposed at 0xA000_0FF0/0xA000_0FF4 for the multi-hart
    // CoreMark port.  The single-hart profile keeps the defaults.
    parameter [31:0] HART_ID    = 32'd0,
    parameter [31:0] HART_COUNT = 32'd1
) (
    input  wire         clk,
    input  wire         cnt_clk,
    input  wire         rst,

    input  wire         perip_valid,
    output reg           perip_ready,
    output wire         perip_rvalid,
    output wire         perip_idle,
    input  wire [31:0]  perip_addr,
    input  wire [31:0]  perip_wdata,
    input  wire         perip_wen,
    input  wire [1:0]   perip_mask,
    output reg  [31:0]  perip_rdata,
    output wire         timer_irq,

    input  wire [63:0]  virtual_sw_input,
    input  wire [7:0]   virtual_key_input,

    input  wire [7:0]   uart_rx_data,
    input  wire         uart_rx_ready,
    input  wire         uart_tx_busy,
    output wire [7:0]   uart_tx_data,
    output wire         uart_tx_start,

    output wire [39:0]  virtual_seg_output,
    output wire [31:0]  virtual_led_output,

    // Shared uncached MMIO window (multi-hart CoreMark mailbox).  Requests in
    // [0xA000_F000, 0xA000_F0FF] leave the hart through this port; the mailbox
    // drives shared_rdata combinationally in the request-accept cycle and
    // captures the write on shared_req_valid.  The existing 2-cycle MMIO
    // response pipeline carries the read data back to the core.
    input  wire [31:0]  shared_rdata,
    output wire         shared_req_valid,
    output wire         shared_req_write,
    output wire [31:0]  shared_req_addr,
    output wire [31:0]  shared_req_wdata,
    output wire [3:0]   shared_req_wstrb
);
    localparam [31:0] DRAM_ADDR_START = 32'h8010_0000;
    localparam [31:0] DRAM_ADDR_END   = 32'h8013_FFFF;
    localparam [31:0] SW0_ADDR        = 32'h8020_0000;
    localparam [31:0] SW1_ADDR        = 32'h8020_0004;
    localparam [31:0] KEY_ADDR        = 32'h8020_0010;
    localparam [31:0] SEG_ADDR        = 32'h8020_0020;
    localparam [31:0] LED_ADDR        = 32'h8020_0040;
    localparam [31:0] CNT_ADDR        = 32'h8020_0050;
    localparam [31:0] CONSOLE_ADDR    = 32'h8020_0060;
    localparam [31:0] CONSOLE_STATUS  = 32'h8020_0064;
    localparam [31:0] CONSOLE_RX      = 32'h8020_0068;
    localparam [31:0] CNT_START_CMD   = 32'h8000_0000;
    localparam [31:0] CNT_STOP_CMD    = 32'hFFFF_FFFF;

    // CoreMark compatibility window.  The benchmark image uses the ARES
    // 0xA000_xxxx device map; the jyd bridge keeps its native 0x8020 map.
    localparam [31:0] BENCH_CYCLE_LO    = 32'hA000_0050;
    localparam [31:0] BENCH_CYCLE_HI    = 32'hA000_0054;
    localparam [31:0] BENCH_UART_TX     = 32'hA000_03F8;
    localparam [31:0] BENCH_UART_STATUS = 32'hA000_03FC;

    // Hart identity and the shared mailbox window.  The mailbox itself lives
    // once in the multi-hart top; this bridge only forwards one 256-byte
    // window and tags the response as a normal MMIO read.
    localparam [31:0] HART_ID_ADDR     = 32'hA000_0FF0;
    localparam [31:0] HART_COUNT_ADDR  = 32'hA000_0FF4;
    localparam [23:0] SHARED_ADDR_TAG  = 24'hA000F0;  /* addr[31:8] */

    // Read-response source tag. Address decoding is completed when the
    // request enters the bridge; only this compact tag follows the two-cycle
    // memory response pipeline.
    localparam [2:0] RESP_NONE  = 3'd0;
    localparam [2:0] RESP_MMIO  = 3'd1;
    localparam [2:0] RESP_DRAM  = 3'd2;
    localparam [2:0] RESP_CNT   = 3'd3;
    localparam [2:0] RESP_ACCEL = 3'd4;

    localparam integer STORE_QUEUE_DEPTH = `CONFIG_STORE_BUFFER_DEPTH;
    localparam integer STORE_QUEUE_PTR_WIDTH =
        (STORE_QUEUE_DEPTH > 1) ? $clog2(STORE_QUEUE_DEPTH) : 1;
    localparam integer STORE_QUEUE_COUNT_WIDTH = $clog2(STORE_QUEUE_DEPTH + 1);

    reg  [31:0] LED;
    reg  [31:0] LED_next;
    reg  [31:0] seg_wdata;
    reg  [31:0] seg_wdata_next;
    reg         cnt_enable_cfg;
    reg         cnt_enable_cfg_next;

    wire [31:0] cnt_rdata;
    reg  [31:0] mmio_rdata;
    reg  [31:0] mmio_rdata_next;
    wire [31:0] dram_rdata;

    (* keep = "true" *) wire dram_read_hit;
    (* keep = "true" *) wire dram_write_hit;

    reg  [2:0]  response_tag_next;
    reg  [2:0]  response_tag_r;

    wire [63:0] sw_cpu;
    wire [7:0]  key_cpu;

    wire        cnt_rst;
    wire        ledseg_src_valid;
    wire [63:0] ledseg_src_data;
    wire [63:0] ledseg_cnt_data;
    wire        ledseg_cnt_valid;
    reg  [31:0] seg_wdata_cnt;
    reg  [31:0] LED_cnt;
    wire [39:0] seg_output_comb;
    reg  [39:0] seg_output_q;
    reg  [31:0] led_output_q;
    reg  [7:0]  console_rx_data;
    reg         console_rx_valid;
    wire        console_tx_ready;

`ifdef __VERILATOR__
  `ifdef ARES_SIM_REAL_UART
    `define ARES_UART_USE_REAL
  `endif
`else
  `define ARES_UART_USE_REAL
`endif

`ifdef ARES_UART_USE_REAL
    // The console uses one-entry toggle handshakes in each direction.  The
    // character data stays stable until the corresponding acknowledgement
    // returns, making the data bus a safe bundled-data CDC path.
    reg  [7:0] console_tx_data_cpu;
    reg        console_tx_req_cpu;
    (* async_reg = "true" *) reg [1:0] console_tx_ack_sync_cpu;
    (* async_reg = "true" *) reg [1:0] console_tx_req_sync_cnt;
    reg        console_tx_ack_cnt;

    reg  [7:0] console_rx_data_cnt;
    reg        console_rx_req_cnt;
    reg        console_rx_ack_cpu;
    (* async_reg = "true" *) reg [1:0] console_rx_req_sync_cpu;
    (* async_reg = "true" *) reg [1:0] console_rx_ack_sync_cnt;
    reg        uart_rx_ready_d;

    reg  [7:0] uart_tx_data_r;
    reg        uart_tx_start_r;
`endif

    reg  [17:0] store_addr_q  [0:STORE_QUEUE_DEPTH-1];
    reg  [31:0] store_wdata_q [0:STORE_QUEUE_DEPTH-1];
    reg  [1:0]  store_mask_q  [0:STORE_QUEUE_DEPTH-1];
    reg  [STORE_QUEUE_PTR_WIDTH-1:0] store_head_q;
    reg  [STORE_QUEUE_PTR_WIDTH-1:0] store_tail_q;
    reg  [STORE_QUEUE_COUNT_WIDTH-1:0] store_count_q;

    reg  [63:0] cycle_count;

    wire [31:0] perip_addr_eff =
        (perip_addr == BENCH_UART_TX)     ? CONSOLE_ADDR :
        (perip_addr == BENCH_UART_STATUS) ? CONSOLE_STATUS : perip_addr;

    // 0xA000_F000..0xA000_F0FF is the shared mailbox slot window.
    wire shared_hit = perip_addr[31:8] == SHARED_ADDR_TAG;

    wire        store_empty;
    wire        store_full;
    wire        store_enqueue;
    wire        store_dequeue;
    wire        read_accept;
    wire        dram_load_request;
    wire        dram_load_accept;
    wire        mmio_write_accept;
    reg         bram_write_valid_q;
    reg  [17:0] bram_cmd_addr_q;
    reg  [31:0] bram_cmd_wdata_q;
    reg  [3:0]  bram_cmd_wea_q;
    reg  [STORE_QUEUE_PTR_WIDTH-1:0] store_scan_index;
    reg  [3:0]  store_scan_byte_en;
    reg  [31:0] store_scan_word_data;
    reg  [3:0]  load_forward_mask_next;
    reg  [31:0] load_forward_data_next;
    wire [3:0]  staged_forward_mask;

    // Response-pipeline registers (declared here because Verilog-2001 requires
    // a declaration before the first procedural assignment).
    reg  [2:0]  response_tag_r2;
    reg         cycle_sel_next, cycle_sel_r, cycle_sel_r2;
    reg         cycle_hi_next,  cycle_hi_r,  cycle_hi_r2;
    reg  [31:0] mmio_rdata_r;
    reg  [31:0] cnt_rdata_r;
    reg  [31:0] cnt_rdata_r2;
    reg  [3:0]  load_forward_mask_r;
    reg  [3:0]  load_forward_mask_r2;
    reg  [31:0] load_forward_data_r;
    reg  [31:0] load_forward_data_r2;
    wire [31:0] load_forward_bit_mask;
    wire [31:0] dram_rdata_forwarded;

    integer entry;
    integer byte_lane;

    assign dram_read_hit  = perip_addr[31:18] == 14'b1000_0000_0001_00;
    assign dram_write_hit = perip_addr[31:18] == 14'b1000_0000_0001_00;

    function [3:0] store_byte_enable;
        input [17:0] addr;
        input [1:0]  mask;
        case (mask)
            2'b10: store_byte_enable = 4'b1111;
            2'b01: store_byte_enable = addr[1] ? 4'b1100 : 4'b0011;
            2'b00: store_byte_enable = 4'b0001 << addr[1:0];
            default: store_byte_enable = 4'b0000;
        endcase
    endfunction

    function [31:0] store_word_data;
        input [31:0] wdata;
        input [1:0]  mask;
        case (mask)
            2'b10: store_word_data = wdata;
            2'b01: store_word_data = {2{wdata[15:0]}};
            2'b00: store_word_data = {4{wdata[7:0]}};
            default: store_word_data = 32'd0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // CoreMark accelerator window.  Only the 4 KiB page decode and a single
    // response register live here; the engines keep their own pipelined /
    // multi-cycle datapaths.  A request is forwarded only when the bridge has
    // already accepted it (perip_ready), keeping the 2-cycle response tag and
    // the accelerator response aligned.
    // -------------------------------------------------------------------------
    localparam [19:0] ACCEL_MTX_PAGE = 20'hA0001;
    localparam [19:0] ACCEL_ST_PAGE  = 20'hA0002;

    wire accel_hit = (perip_addr[31:12] == ACCEL_MTX_PAGE) ||
                     (perip_addr[31:12] == ACCEL_ST_PAGE);
    wire [3:0] accel_wstrb = store_byte_enable(perip_addr[17:0], perip_mask);
    wire accel_req_valid = perip_valid && perip_ready && accel_hit;
    wire [31:0] accel_rsp_data;
    wire        accel_rsp_valid;

    pipeline_accel u_pipeline_accel (
        .clk       (clk),
        .rst       (rst),
        .req_valid (accel_req_valid),
        .req_write (perip_wen),
        .req_addr  (perip_addr),
        .req_wdata (perip_wdata),
        .req_wstrb (accel_wstrb),
        .rsp_data  (accel_rsp_data),
        .rsp_valid (accel_rsp_valid)
    );

    // The bridge store queue drains continuously into the dedicated BRAM write
    // port. The read port remains independently available to cacheable DRAM
    // loads; MMIO operations still wait for queued and staged stores.
    assign store_empty = store_count_q == 0;
    assign store_full = store_count_q == STORE_QUEUE_DEPTH;
    assign dram_load_request = perip_valid && !perip_wen && dram_read_hit;
    assign store_dequeue = (~rst) && (~store_empty);

    always @(*) begin
        perip_ready = 1'b1;
        if (perip_valid) begin
            if (perip_wen) begin
                if (dram_write_hit) begin
                    // A full queue can still accept when its head is staged.
                    perip_ready = (~store_full) || store_dequeue;
                end else begin
                    // Keep MMIO writes ordered after queued and staged stores.
                    perip_ready = store_empty && !bram_write_valid_q;
                    if (perip_addr_eff == CONSOLE_ADDR) begin
                        perip_ready = perip_ready && console_tx_ready;
                    end
                end
            end else begin
                // MMIO reads are strongly ordered after all older stores.
                // Cacheable DRAM reads use the independent BRAM read port.
                perip_ready = dram_read_hit
                            ? 1'b1
                            : store_empty && !bram_write_valid_q;
            end
        end
    end

    assign store_enqueue = perip_valid && perip_ready && perip_wen &&
                           dram_write_hit;
    assign read_accept = perip_valid && perip_ready && (~perip_wen);
    assign dram_load_accept = read_accept && dram_read_hit;
    assign mmio_write_accept = perip_valid && perip_ready && perip_wen &&
                               (~dram_write_hit);

    // Shared mailbox write port.  Reads need no request: the mailbox decodes
    // the address combinationally and the bridge samples shared_rdata in the
    // request-accept cycle just like the other MMIO sources.
    assign shared_req_valid = mmio_write_accept && shared_hit;
    assign shared_req_write = perip_wen;
    assign shared_req_addr  = perip_addr;
    assign shared_req_wdata = perip_wdata;
    assign shared_req_wstrb = store_byte_enable(perip_addr[17:0], perip_mask);

`ifdef ARES_UART_USE_REAL
    // CPU -> UART transmit path.  The CPU holds the byte and toggles a request
    // only when the previous request has been accepted by the UART domain.
    assign console_tx_ready =
        console_tx_req_cpu == console_tx_ack_sync_cpu[1];

    always @(posedge clk) begin
        if (rst) begin
            console_tx_data_cpu    <= 8'd0;
            console_tx_req_cpu     <= 1'b0;
            console_tx_ack_sync_cpu <= 2'b00;
        end else begin
            console_tx_ack_sync_cpu[0] <= console_tx_ack_cnt;
            console_tx_ack_sync_cpu[1] <= console_tx_ack_sync_cpu[0];

            if (mmio_write_accept && perip_addr_eff == CONSOLE_ADDR) begin
                console_tx_data_cpu <= perip_wdata[7:0];
                console_tx_req_cpu  <= ~console_tx_req_cpu;
            end
        end
    end

    // Reset for the peripheral clock domain: async assert, sync release.
    // The bridge has one reset input, so derive the cnt_clk-domain reset here
    // instead of releasing it asynchronously to cnt_clk on the board.
    pipeline_cdc_reset_sync u_cnt_rst (
        .clk    (cnt_clk),
        .rst_in (rst),
        .rst_out(cnt_rst)
    );

    always @(posedge cnt_clk) begin
        if (cnt_rst) begin
            console_tx_req_sync_cnt <= 2'b00;
            console_tx_ack_cnt      <= 1'b0;
            uart_tx_data_r          <= 8'd0;
            uart_tx_start_r         <= 1'b0;
        end else begin
            console_tx_req_sync_cnt[0] <= console_tx_req_cpu;
            console_tx_req_sync_cnt[1] <= console_tx_req_sync_cnt[0];
            uart_tx_start_r <= 1'b0;

            if ((console_tx_req_sync_cnt[1] != console_tx_ack_cnt) &&
                !uart_tx_busy) begin
                uart_tx_data_r     <= console_tx_data_cpu;
                uart_tx_start_r    <= 1'b1;
                console_tx_ack_cnt <= console_tx_req_sync_cnt[1];
            end
        end
    end

    // UART -> CPU receive path.  uart.sv holds rx_ready high for several
    // clocks, so accept only its rising edge.  One unread byte is retained
    // until the CPU reads CONSOLE_RX.
    always @(posedge cnt_clk) begin
        if (cnt_rst) begin
            console_rx_ack_sync_cnt <= 2'b00;
            uart_rx_ready_d         <= 1'b0;
            console_rx_data_cnt     <= 8'd0;
            console_rx_req_cnt      <= 1'b0;
        end else begin
            console_rx_ack_sync_cnt[0] <= console_rx_ack_cpu;
            console_rx_ack_sync_cnt[1] <= console_rx_ack_sync_cnt[0];
            uart_rx_ready_d <= uart_rx_ready;

            if (uart_rx_ready && !uart_rx_ready_d &&
                (console_rx_req_cnt == console_rx_ack_sync_cnt[1])) begin
                console_rx_data_cnt <= uart_rx_data;
                console_rx_req_cnt  <= ~console_rx_req_cnt;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            console_rx_req_sync_cpu <= 2'b00;
            console_rx_ack_cpu      <= 1'b0;
            console_rx_data         <= 8'd0;
        end else begin
            console_rx_req_sync_cpu[0] <= console_rx_req_cnt;
            console_rx_req_sync_cpu[1] <= console_rx_req_sync_cpu[0];

            if (console_rx_req_sync_cpu[1] != console_rx_ack_cpu) begin
                console_rx_data <= console_rx_data_cnt;
            end
            if (read_accept && perip_addr_eff == CONSOLE_RX &&
                console_rx_valid) begin
                console_rx_ack_cpu <= console_rx_req_sync_cpu[1];
            end
        end
    end

    always @(*) begin
        console_rx_valid = console_rx_req_sync_cpu[1] != console_rx_ack_cpu;
    end

    assign uart_tx_data  = uart_tx_data_r;
    assign uart_tx_start = uart_tx_start_r;`else
    import "DPI-C" function int sim_console_getchar();
    import "DPI-C" function void sim_led_write(input int value);

    // Simulation-only character sink used by the RT-Thread console driver.
    always @(posedge clk) begin
        if (!rst && mmio_write_accept && perip_addr_eff == CONSOLE_ADDR) begin
            $write("%c", perip_wdata[7:0]);
        end
        if (!rst && mmio_write_accept && perip_addr == LED_ADDR) begin
            sim_led_write(perip_wdata);
        end
    end

    // One-byte simulation RX register. The DPI side supplies scripted input
    // first and then polls the host terminal without blocking RTL execution.
    always @(posedge clk) begin : sim_console_rx
        integer next_char;

        if (rst) begin
            console_rx_data  <= 8'd0;
            console_rx_valid <= 1'b0;
        end else if (console_rx_valid) begin
            if (read_accept && perip_addr_eff == CONSOLE_RX) begin
                console_rx_valid <= 1'b0;
            end
        end else begin
            next_char = sim_console_getchar();
            if (next_char >= 0) begin
                console_rx_data  <= next_char[7:0];
                console_rx_valid <= 1'b1;
            end
        end
    end

    assign console_tx_ready = 1'b1;
    assign uart_tx_data     = 8'd0;
    assign uart_tx_start    = 1'b0;`endif
    assign staged_forward_mask =
        dram_load_request && bram_write_valid_q &&
        (bram_cmd_addr_q[17:2] == perip_addr[17:2])
            ? bram_cmd_wea_q
            : 4'd0;

    // Snapshot all older stores that overlap an accepted load. The staged
    // Port-A write has already left the queue, so it is applied first. Queue
    // entries are then visited from oldest to youngest, allowing each younger
    // matching store to overwrite the bytes supplied by older stores.
    always @(*) begin
        store_scan_index = {STORE_QUEUE_PTR_WIDTH{1'b0}};
        store_scan_byte_en = 4'd0;
        store_scan_word_data = 32'd0;
        load_forward_mask_next = 4'd0;
        load_forward_data_next = 32'd0;

        if (dram_load_request) begin
            if (bram_write_valid_q &&
                (bram_cmd_addr_q[17:2] == perip_addr[17:2])) begin
                load_forward_mask_next = bram_cmd_wea_q;
                load_forward_data_next = bram_cmd_wdata_q;
            end

            for (entry = 0; entry < STORE_QUEUE_DEPTH; entry = entry + 1) begin
                store_scan_index =
                    store_head_q + entry[STORE_QUEUE_PTR_WIDTH-1:0];
                if ((entry < store_count_q) &&
                    (store_addr_q[store_scan_index][17:2] ==
                     perip_addr[17:2])) begin
                    store_scan_byte_en = store_byte_enable(
                        store_addr_q[store_scan_index],
                        store_mask_q[store_scan_index]);
                    store_scan_word_data = store_word_data(
                        store_wdata_q[store_scan_index],
                        store_mask_q[store_scan_index]);

                    for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                        if (store_scan_byte_en[byte_lane]) begin
                            load_forward_mask_next[byte_lane] = 1'b1;
                            load_forward_data_next[byte_lane * 8 +: 8] =
                                store_scan_word_data[byte_lane * 8 +: 8];
                        end
                    end
                end
            end
        end
    end

`ifdef __VERILATOR__
    StoreBuffer_DPIC store_buffer_dpic (
        .clk                (clk),
        .rst                (rst),
        .store_enqueue      (store_enqueue),
        .store_dequeue      (store_dequeue),
        .read_accept        (read_accept),
        .read_blocked       (perip_valid && !perip_wen && !perip_ready),
        .read_conflict      (|load_forward_mask_next),
        .read_write_overlap (dram_load_accept && bram_write_valid_q),
        .read_write_same_word(
                             dram_load_accept && |staged_forward_mask),
        .read_forward_mask  (load_forward_mask_next),
        .staged_forward_mask(staged_forward_mask),
        .read_blocked_staged_write(
                             dram_load_request && !perip_ready &&
                             bram_write_valid_q),
        .store_blocked      (perip_valid && perip_wen && dram_write_hit &&
                             !perip_ready),
        .mmio_write_blocked (perip_valid && perip_wen && !dram_write_hit &&
                             !perip_ready),
        .occupancy          ({{(32-STORE_QUEUE_COUNT_WIDTH){1'b0}}, store_count_q}),
        .depth              (STORE_QUEUE_DEPTH)
    );
`endif

    always @(posedge clk) begin
        if (rst) begin
            store_head_q  <= {STORE_QUEUE_PTR_WIDTH{1'b0}};
            store_tail_q  <= {STORE_QUEUE_PTR_WIDTH{1'b0}};
            store_count_q <= {STORE_QUEUE_COUNT_WIDTH{1'b0}};
        end else begin
            if (store_enqueue) begin
                store_addr_q[store_tail_q]  <= perip_addr[17:0];
                store_wdata_q[store_tail_q] <= perip_wdata;
                store_mask_q[store_tail_q]  <= perip_mask;
                if (STORE_QUEUE_DEPTH > 1) begin
                    store_tail_q <= store_tail_q + 1'b1;
                end
            end

            if (store_dequeue) begin
                if (STORE_QUEUE_DEPTH > 1) begin
                    store_head_q <= store_head_q + 1'b1;
                end
            end

            case ({store_enqueue, store_dequeue})
                2'b10: store_count_q <= store_count_q + 1'b1;
                2'b01: store_count_q <= store_count_q - 1'b1;
                default: begin
                end
            endcase
        end
    end

    // Register only writes before the large BRAM array. Read addresses retain
    // their original direct, two-cycle path. A staged write is consumed while
    // the next store is captured, preserving one store per cycle throughput.
    always @(posedge clk) begin
        if (rst) begin
            bram_write_valid_q <= 1'b0;
            bram_cmd_addr_q  <= 18'd0;
            bram_cmd_wdata_q <= 32'd0;
            bram_cmd_wea_q   <= 4'd0;
        end else begin
            bram_write_valid_q <= store_dequeue;

            if (store_dequeue) begin
                bram_cmd_addr_q  <= store_addr_q[store_head_q];
                bram_cmd_wdata_q <= store_word_data(
                    store_wdata_q[store_head_q],
                    store_mask_q[store_head_q]);
                bram_cmd_wea_q <= store_byte_enable(
                    store_addr_q[store_head_q],
                    store_mask_q[store_head_q]);
            end else begin
                bram_cmd_wea_q <= 4'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // cnt_clk -> cpu clk: virtual SW/KEY levels.
    // These are switch/key states, so each bit is independent. This avoids
    // pretending that the whole 72-bit bus is an atomic value.
    // -------------------------------------------------------------------------
    pipeline_cdc_array_single #(
        .WIDTH        (64),
        .DEST_SYNC_FF (2),
        .INIT_SYNC_FF (0)
    ) u_sw_cdc (
        .src_clk  (cnt_clk),
        .src_in   (virtual_sw_input),
        .dest_clk (clk),
        .dest_out (sw_cpu)
    );

    pipeline_cdc_array_single #(
        .WIDTH        (8),
        .DEST_SYNC_FF (2),
        .INIT_SYNC_FF (0)
    ) u_key_cdc (
        .src_clk  (cnt_clk),
        .src_in   (virtual_key_input),
        .dest_clk (clk),
        .dest_out (key_cpu)
    );

    // -------------------------------------------------------------------------
    // CPU-domain MMIO write registers.
    // -------------------------------------------------------------------------
    always @(*) begin
        LED_next            = LED;
        seg_wdata_next      = seg_wdata;
        cnt_enable_cfg_next = cnt_enable_cfg;

        if (mmio_write_accept) begin
            case (perip_addr_eff)
                LED_ADDR: begin
                    LED_next = perip_wdata;
                end

                SEG_ADDR: begin
                    seg_wdata_next = perip_wdata;
                end

                CNT_ADDR: begin
                    if (perip_wdata == CNT_START_CMD) begin
                        cnt_enable_cfg_next = 1'b1;
                    end else if (perip_wdata == CNT_STOP_CMD) begin
                        cnt_enable_cfg_next = 1'b0;
                    end
                end

                default: begin
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            LED            <= 32'd0;
            seg_wdata      <= 32'd0;
            cnt_enable_cfg <= 1'b0;
        end else begin
            LED            <= LED_next;
            seg_wdata      <= seg_wdata_next;
            cnt_enable_cfg <= cnt_enable_cfg_next;
        end
    end

    // CPU-domain request decode. The selected source is converted to a small
    // tag here, before the response data is available. MMIO data selection is
    // folded into the same decode so the address is never decoded again on
    // the response path.
    always @(*) begin
        response_tag_next = RESP_NONE;
        mmio_rdata_next   = 32'd0;
        cycle_sel_next    = 1'b0;
        cycle_hi_next     = 1'b0;

        if (read_accept) begin
            if (dram_write_hit) begin
                response_tag_next = RESP_DRAM;
            end else if (accel_hit) begin
                response_tag_next = RESP_ACCEL;
            end else if (shared_hit) begin
                response_tag_next = RESP_MMIO;
                mmio_rdata_next   = shared_rdata;
            end else if (perip_addr == BENCH_CYCLE_LO) begin
                response_tag_next = RESP_CNT;
                cycle_sel_next    = 1'b1;
                cycle_hi_next     = 1'b0;
            end else if (perip_addr == BENCH_CYCLE_HI) begin
                response_tag_next = RESP_CNT;
                cycle_sel_next    = 1'b1;
                cycle_hi_next     = 1'b1;
            end else if (perip_addr_eff == CNT_ADDR) begin
                response_tag_next = RESP_CNT;
            end else begin
                case (perip_addr_eff)
                    HART_ID_ADDR: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = HART_ID;
                    end
                    HART_COUNT_ADDR: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = HART_COUNT;
                    end
                    SW0_ADDR: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = sw_cpu[31:0];
                    end
                    SW1_ADDR: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = sw_cpu[63:32];
                    end
                    KEY_ADDR: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = {24'd0, key_cpu};
                    end
                    SEG_ADDR: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = seg_wdata;
                    end
                    LED_ADDR: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = LED;
                    end
                    CONSOLE_STATUS: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = (perip_addr == BENCH_UART_STATUS)
                            ? {30'd0, ~console_tx_ready, console_rx_valid}
                            : {30'd0, console_tx_ready,  console_rx_valid};
                    end
                    CONSOLE_RX: begin
                        response_tag_next = RESP_MMIO;
                        mmio_rdata_next   = {24'd0, console_rx_data};
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

    // First response-data pipeline stage for MMIO reads.
    always @(posedge clk) begin
        if (rst) begin
            mmio_rdata <= 32'd0;
        end else begin
            mmio_rdata <= mmio_rdata_next;
        end
    end

    // -------------------------------------------------------------------------
    // clk -> cnt_clk: LED/SEG coherent snapshot.
    // A send event is generated only for LED/SEG writes. Data uses *_next so
    // the transferred snapshot contains the new value written in this cycle.
    // -------------------------------------------------------------------------
    assign ledseg_src_valid = (~rst) && mmio_write_accept &&
                              ((perip_addr == LED_ADDR) || (perip_addr == SEG_ADDR));
    assign ledseg_src_data  = {seg_wdata_next, LED_next};

    pipeline_cdc_mailbox #(
        .WIDTH        (64),
        .DEST_SYNC_FF (2),
        .SRC_SYNC_FF  (2),
        .INIT_SYNC_FF (0)
    ) u_ledseg_cdc (
        .src_clk    (clk),
        .src_rst    (rst),
        .src_data   (ledseg_src_data),
        .src_valid  (ledseg_src_valid),
        .src_busy   (),
        .dest_clk   (cnt_clk),
        .dest_rst   (cnt_rst),
        .dest_data  (ledseg_cnt_data),
        .dest_valid (ledseg_cnt_valid)
    );

    // Latch a transferred snapshot only when the handshake destination pulse arrives.
    // This consumes ledseg_cnt_valid explicitly and avoids using invalid intermediate data.
    always @(posedge cnt_clk) begin
        if (cnt_rst) begin
            seg_wdata_cnt <= 32'd0;
            LED_cnt       <= 32'd0;
        end else if (ledseg_cnt_valid) begin
            seg_wdata_cnt <= ledseg_cnt_data[63:32];
            LED_cnt       <= ledseg_cnt_data[31:0];
        end
    end

    // Generate seven-segment scan signals in cnt_clk domain. Therefore the
    // signals consumed by twin_controller stay in the same clock domain.
    display_seg seg_driver (
        .clk  (cnt_clk),
        .rst  (cnt_rst),
        .s    (seg_wdata_cnt),
        .seg1 (seg_output_comb[6:0]),
        .seg2 (seg_output_comb[16:10]),
        .seg3 (seg_output_comb[26:20]),
        .seg4 (seg_output_comb[36:30]),
        .ans  ({seg_output_comb[39:38], seg_output_comb[29:28],
                seg_output_comb[19:18], seg_output_comb[9:8]})
    );

    assign seg_output_comb[7]  = 1'b0;
    assign seg_output_comb[17] = 1'b0;
    assign seg_output_comb[27] = 1'b0;
    assign seg_output_comb[37] = 1'b0;

    always @(posedge cnt_clk) begin
        if (cnt_rst) begin
            seg_output_q <= 40'd0;
            led_output_q <= 32'd0;
        end else begin
            seg_output_q <= seg_output_comb;
            led_output_q <= LED_cnt;
        end
    end

    assign virtual_seg_output = seg_output_q;
    assign virtual_led_output = led_output_q;

    // -------------------------------------------------------------------------
    // BRAM access remains in CPU clock domain.
    // -------------------------------------------------------------------------
    bram_driver bram_driver_inst (
        .clk         (clk),
        .read_addr   (perip_addr[17:0]),
        .write_valid (bram_write_valid_q),
        .write_addr  (bram_cmd_addr_q),
        .write_data  (bram_cmd_wdata_q),
        .write_wea   (bram_cmd_wea_q),
        .perip_rdata (dram_rdata)
    );

    // Free-running 64-bit CPU cycle counter for the CoreMark window.
    always @(posedge clk) begin
        if (rst) cycle_count <= 64'd0;
        else     cycle_count <= cycle_count + 64'd1;
    end

    // Counter performs its own CDC internally.
    counter counter_inst (
        .cpu_clk        (clk),
        .cnt_clk        (cnt_clk),
        .rst            (rst),
        .cnt_enable_cpu (cnt_enable_cfg),
        .perip_rdata    (cnt_rdata),
        .timer_irq      (timer_irq)
    );

    always @(posedge clk) begin
        if (rst) begin
            response_tag_r  <= RESP_NONE;
            response_tag_r2 <= RESP_NONE;
            cycle_sel_r     <= 1'b0;
            cycle_sel_r2    <= 1'b0;
            cycle_hi_r      <= 1'b0;
            cycle_hi_r2     <= 1'b0;
            mmio_rdata_r     <= 32'd0;
            cnt_rdata_r      <= 32'd0;
            cnt_rdata_r2     <= 32'd0;
            load_forward_mask_r  <= 4'd0;
            load_forward_mask_r2 <= 4'd0;
            load_forward_data_r  <= 32'd0;
            load_forward_data_r2 <= 32'd0;
        end else begin
            response_tag_r  <= response_tag_next;
            response_tag_r2 <= response_tag_r;
            cycle_sel_r     <= cycle_sel_next;
            cycle_sel_r2    <= cycle_sel_r;
            cycle_hi_r      <= cycle_hi_next;
            cycle_hi_r2     <= cycle_hi_r;
            mmio_rdata_r     <= mmio_rdata;
            cnt_rdata_r      <= cnt_rdata;
            cnt_rdata_r2     <= cnt_rdata_r;
            load_forward_mask_r <=
                dram_load_accept ? load_forward_mask_next : 4'd0;
            load_forward_mask_r2 <= load_forward_mask_r;
            load_forward_data_r <= load_forward_data_next;
            load_forward_data_r2 <= load_forward_data_r;
        end
    end

    assign load_forward_bit_mask = {
        {8{load_forward_mask_r2[3]}},
        {8{load_forward_mask_r2[2]}},
        {8{load_forward_mask_r2[1]}},
        {8{load_forward_mask_r2[0]}}
    };
    assign dram_rdata_forwarded =
        (dram_rdata & ~load_forward_bit_mask) |
        (load_forward_data_r2 & load_forward_bit_mask);

    // All read sources are aligned to the BRAM array read plus output-register
    // latency: two cycles from request acceptance.
    assign perip_rvalid = response_tag_r2 != RESP_NONE;

    // Conservative fence target: no queued/staged store and no read/write
    // response in flight.  FENCE additionally waits for the core LSU idle.
    assign perip_idle = store_empty && !bram_write_valid_q && !perip_valid &&
                        !accel_rsp_valid &&
                        response_tag_r == RESP_NONE &&
                        response_tag_r2 == RESP_NONE;

    always @(*) begin
        case (response_tag_r2)
            RESP_MMIO: perip_rdata = mmio_rdata_r;
            RESP_DRAM: perip_rdata = dram_rdata_forwarded;
            RESP_CNT:  perip_rdata = cycle_sel_r2
                ? (cycle_hi_r2 ? cycle_count[63:32] : cycle_count[31:0])
                : cnt_rdata_r2;
            RESP_ACCEL: perip_rdata = accel_rsp_data;
            default:   perip_rdata = 32'd0;
        endcase
    end
endmodule
