`timescale 1ns / 1ps
`include "autoconf.vh"
//////////////////////////////////////////////////////////////////////////////////
// perip_bridge.sv replacement, no asynchronous FIFO.
//
// CDC policy:
//   - virtual_sw_input / virtual_key_input:
//       These are treated as bitwise-independent switch/key levels generated in
//       cnt_clk domain. Each bit is synchronized to clk domain using
//       xpm_cdc_array_single.
//   - LED / SEG CPU configuration:
//       CPU writes are coherent multi-bit snapshots. The latest {seg_wdata, LED}
//       snapshot is transferred from clk domain to cnt_clk domain using
//       xpm_cdc_handshake through cdc_mailbox_xpm.
//   - cnt_enable_cfg:
//       Kept in CPU domain and synchronized inside counter.sv by xpm_cdc_single.
//   - counter value:
//       Synchronized inside counter.sv by xpm_cdc_gray.
//////////////////////////////////////////////////////////////////////////////////

module perip_bridge(
    input  logic         clk,
    input  logic         cnt_clk,
    input  logic         rst,

    input  logic         perip_valid,
    output logic         perip_ready,
    output logic         perip_rvalid,
    output logic         perip_idle,
    input  logic [31:0]  perip_addr,
    input  logic [31:0]  perip_wdata,
    input  logic         perip_wen,
    input  logic [1:0]   perip_mask,
    output logic [31:0]  perip_rdata,
    output logic         timer_irq,

    input  logic [63:0]  virtual_sw_input,
    input  logic [7:0]   virtual_key_input,

    input  logic [7:0]   uart_rx_data,
    input  logic         uart_rx_ready,
    input  logic         uart_tx_busy,
    output logic [7:0]   uart_tx_data,
    output logic         uart_tx_start,

    output logic [39:0]  virtual_seg_output,
    output logic [31:0]  virtual_led_output
);
    localparam logic [31:0] DRAM_ADDR_START = 32'h8010_0000;
    localparam logic [31:0] DRAM_ADDR_END   = 32'h8013_FFFF;
    localparam logic [31:0] SW0_ADDR        = 32'h8020_0000;
    localparam logic [31:0] SW1_ADDR        = 32'h8020_0004;
    localparam logic [31:0] KEY_ADDR        = 32'h8020_0010;
    localparam logic [31:0] SEG_ADDR        = 32'h8020_0020;
    localparam logic [31:0] LED_ADDR        = 32'h8020_0040;
    localparam logic [31:0] CNT_ADDR        = 32'h8020_0050;
    localparam logic [31:0] CONSOLE_ADDR    = 32'h8020_0060;
    localparam logic [31:0] CONSOLE_STATUS  = 32'h8020_0064;
    localparam logic [31:0] CONSOLE_RX      = 32'h8020_0068;
    localparam logic [31:0] CNT_START_CMD   = 32'h8000_0000;
    localparam logic [31:0] CNT_STOP_CMD    = 32'hFFFF_FFFF;

    // CoreMark compatibility window.  The benchmark image uses the ARES
    // 0xA000_xxxx device map; the jyd bridge keeps its native 0x8020 map.
    localparam logic [31:0] BENCH_CYCLE_LO    = 32'hA000_0050;
    localparam logic [31:0] BENCH_CYCLE_HI    = 32'hA000_0054;
    localparam logic [31:0] BENCH_UART_TX     = 32'hA000_03F8;
    localparam logic [31:0] BENCH_UART_STATUS = 32'hA000_03FC;

    // Read-response source tag. Address decoding is completed when the
    // request enters the bridge; only this compact tag follows the two-cycle
    // memory response pipeline.
    localparam logic [1:0] RESP_NONE = 2'd0;
    localparam logic [1:0] RESP_MMIO = 2'd1;
    localparam logic [1:0] RESP_DRAM = 2'd2;
    localparam logic [1:0] RESP_CNT  = 2'd3;

    localparam int STORE_QUEUE_DEPTH = `CONFIG_STORE_BUFFER_DEPTH;
    localparam int STORE_QUEUE_PTR_WIDTH =
        (STORE_QUEUE_DEPTH > 1) ? $clog2(STORE_QUEUE_DEPTH) : 1;
    localparam int STORE_QUEUE_COUNT_WIDTH = $clog2(STORE_QUEUE_DEPTH + 1);

    logic [31:0] LED;
    logic [31:0] LED_next;
    logic [31:0] seg_wdata;
    logic [31:0] seg_wdata_next;
    logic        cnt_enable_cfg;
    logic        cnt_enable_cfg_next;

    logic [31:0] cnt_rdata;
    logic [31:0] mmio_rdata;
    logic [31:0] mmio_rdata_next;
    logic [31:0] dram_rdata;

    (* keep = "true" *) logic dram_read_hit;
    (* keep = "true" *) logic dram_write_hit;

    logic [1:0]  response_tag_next;
    logic [1:0]  response_tag_r;

    logic [63:0] sw_cpu;
    logic [7:0]  key_cpu;

    logic        ledseg_src_valid;
    logic [63:0] ledseg_src_data;
    logic [63:0] ledseg_cnt_data;
    logic        ledseg_cnt_valid;
    logic [31:0] seg_wdata_cnt;
    logic [31:0] LED_cnt;
    logic [39:0] seg_output_comb;
    logic [39:0] seg_output_q;
    logic [31:0] led_output_q;
    logic [7:0]  console_rx_data;
    logic        console_rx_valid;
    logic        console_tx_ready;

`ifndef __VERILATOR__
    // The console uses one-entry toggle handshakes in each direction.  The
    // character data stays stable until the corresponding acknowledgement
    // returns, making the data bus a safe bundled-data CDC path.
    logic [7:0] console_tx_data_cpu;
    logic       console_tx_req_cpu;
    (* ASYNC_REG = "TRUE" *) logic [1:0] console_tx_ack_sync_cpu;
    (* ASYNC_REG = "TRUE" *) logic [1:0] console_tx_req_sync_cnt;
    logic       console_tx_ack_cnt;

    logic [7:0] console_rx_data_cnt;
    logic       console_rx_req_cnt;
    logic       console_rx_ack_cpu;
    (* ASYNC_REG = "TRUE" *) logic [1:0] console_rx_req_sync_cpu;
    (* ASYNC_REG = "TRUE" *) logic [1:0] console_rx_ack_sync_cnt;
    logic       uart_rx_ready_d;
`endif

    logic [17:0] store_addr_q  [0:STORE_QUEUE_DEPTH-1];
    logic [31:0] store_wdata_q [0:STORE_QUEUE_DEPTH-1];
    logic [1:0]  store_mask_q  [0:STORE_QUEUE_DEPTH-1];
    logic [STORE_QUEUE_PTR_WIDTH-1:0] store_head_q;
    logic [STORE_QUEUE_PTR_WIDTH-1:0] store_tail_q;
    logic [STORE_QUEUE_COUNT_WIDTH-1:0] store_count_q;

    logic [63:0] cycle_count;

    wire [31:0] perip_addr_eff =
        (perip_addr == BENCH_UART_TX)     ? CONSOLE_ADDR :
        (perip_addr == BENCH_UART_STATUS) ? CONSOLE_STATUS : perip_addr;

    logic        store_empty;
    logic        store_full;
    logic        store_enqueue;
    logic        store_dequeue;
    logic        read_accept;
    logic        dram_load_request;
    logic        dram_load_accept;
    logic        mmio_write_accept;
    logic        bram_write_valid_q;
    logic [17:0] bram_cmd_addr_q;
    logic [31:0] bram_cmd_wdata_q;
    logic [3:0]  bram_cmd_wea_q;
    logic [STORE_QUEUE_PTR_WIDTH-1:0] store_scan_index;
    logic [3:0]  store_scan_byte_en;
    logic [31:0] store_scan_word_data;
    logic [3:0]  load_forward_mask_next;
    logic [31:0] load_forward_data_next;
    logic [3:0]  staged_forward_mask;

    assign dram_read_hit  = perip_addr[31:18] == 14'b1000_0000_0001_00;
    assign dram_write_hit = perip_addr[31:18] == 14'b1000_0000_0001_00;

    function automatic logic [3:0] store_byte_enable(
        input logic [17:0] addr,
        input logic [1:0]  mask
    );
        unique case (mask)
            2'b10: store_byte_enable = 4'b1111;
            2'b01: store_byte_enable = addr[1] ? 4'b1100 : 4'b0011;
            2'b00: store_byte_enable = 4'b0001 << addr[1:0];
            default: store_byte_enable = 4'b0000;
        endcase
    endfunction

    function automatic logic [31:0] store_word_data(
        input logic [31:0] wdata,
        input logic [1:0]  mask
    );
        unique case (mask)
            2'b10: store_word_data = wdata;
            2'b01: store_word_data = {2{wdata[15:0]}};
            2'b00: store_word_data = {4{wdata[7:0]}};
            default: store_word_data = 32'd0;
        endcase
    endfunction

    // The bridge store queue drains continuously into the dedicated BRAM write
    // port. The read port remains independently available to cacheable DRAM
    // loads; MMIO operations still wait for queued and staged stores.
    assign store_empty = store_count_q == 0;
    assign store_full = store_count_q ==
                        STORE_QUEUE_COUNT_WIDTH'(STORE_QUEUE_DEPTH);
    assign dram_load_request = perip_valid && !perip_wen && dram_read_hit;
    assign store_dequeue = (~rst) && (~store_empty);

    always_comb begin
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

`ifdef __VERILATOR__
    import "DPI-C" function int sim_console_getchar();
    import "DPI-C" function void sim_led_write(input int value);

    // Simulation-only character sink used by the RT-Thread console driver.
    always_ff @(posedge clk) begin
        if (!rst && mmio_write_accept && perip_addr_eff == CONSOLE_ADDR) begin
            $write("%c", perip_wdata[7:0]);
        end
        if (!rst && mmio_write_accept && perip_addr == LED_ADDR) begin
            sim_led_write(perip_wdata);
        end
    end

    // One-byte simulation RX register. The DPI side supplies scripted input
    // first and then polls the host terminal without blocking RTL execution.
    always_ff @(posedge clk) begin : sim_console_rx
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
    assign uart_tx_start    = 1'b0;
`else
    // CPU -> UART transmit path.  The CPU holds the byte and toggles a request
    // only when the previous request has been accepted by the UART domain.
    assign console_tx_ready =
        console_tx_req_cpu == console_tx_ack_sync_cpu[1];

    always_ff @(posedge clk) begin
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

    always_ff @(posedge cnt_clk) begin
        if (rst) begin
            console_tx_req_sync_cnt <= 2'b00;
            console_tx_ack_cnt      <= 1'b0;
            uart_tx_data            <= 8'd0;
            uart_tx_start           <= 1'b0;
        end else begin
            console_tx_req_sync_cnt[0] <= console_tx_req_cpu;
            console_tx_req_sync_cnt[1] <= console_tx_req_sync_cnt[0];
            uart_tx_start <= 1'b0;

            if ((console_tx_req_sync_cnt[1] != console_tx_ack_cnt) &&
                !uart_tx_busy) begin
                uart_tx_data       <= console_tx_data_cpu;
                uart_tx_start      <= 1'b1;
                console_tx_ack_cnt <= console_tx_req_sync_cnt[1];
            end
        end
    end

    // UART -> CPU receive path.  uart.sv holds rx_ready high for several
    // clocks, so accept only its rising edge.  One unread byte is retained
    // until the CPU reads CONSOLE_RX.
    always_ff @(posedge cnt_clk) begin
        if (rst) begin
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

    always_ff @(posedge clk) begin
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

    assign console_rx_valid =
        console_rx_req_sync_cpu[1] != console_rx_ack_cpu;
`endif
    assign staged_forward_mask =
        dram_load_request && bram_write_valid_q &&
        (bram_cmd_addr_q[17:2] == perip_addr[17:2])
            ? bram_cmd_wea_q
            : 4'd0;

    // Snapshot all older stores that overlap an accepted load. The staged
    // Port-A write has already left the queue, so it is applied first. Queue
    // entries are then visited from oldest to youngest, allowing each younger
    // matching store to overwrite the bytes supplied by older stores.
    always_comb begin
        store_scan_index = '0;
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

            for (int entry = 0; entry < STORE_QUEUE_DEPTH; entry++) begin
                store_scan_index =
                    store_head_q + STORE_QUEUE_PTR_WIDTH'(entry);
                if ((STORE_QUEUE_COUNT_WIDTH'(entry) < store_count_q) &&
                    (store_addr_q[store_scan_index][17:2] ==
                     perip_addr[17:2])) begin
                    store_scan_byte_en = store_byte_enable(
                        store_addr_q[store_scan_index],
                        store_mask_q[store_scan_index]);
                    store_scan_word_data = store_word_data(
                        store_wdata_q[store_scan_index],
                        store_mask_q[store_scan_index]);

                    for (int byte_lane = 0; byte_lane < 4; byte_lane++) begin
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
        .occupancy          (32'(store_count_q)),
        .depth              (32'(STORE_QUEUE_DEPTH))
    );
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            store_head_q  <= '0;
            store_tail_q  <= '0;
            store_count_q <= '0;
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

            unique case ({store_enqueue, store_dequeue})
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
    always_ff @(posedge clk) begin
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
    cdc_array_single_xpm #(
        .WIDTH        (64),
        .DEST_SYNC_FF (2),
        .INIT_SYNC_FF (0)
    ) u_sw_cdc (
        .src_clk  (cnt_clk),
        .src_in   (virtual_sw_input),
        .dest_clk (clk),
        .dest_out (sw_cpu)
    );

    cdc_array_single_xpm #(
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
    always_comb begin
        LED_next            = LED;
        seg_wdata_next      = seg_wdata;
        cnt_enable_cfg_next = cnt_enable_cfg;

        if (mmio_write_accept) begin
            unique case (perip_addr_eff)
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

    always_ff @(posedge clk) begin
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
    always_comb begin
        response_tag_next = RESP_NONE;
        mmio_rdata_next   = 32'd0;
        cycle_sel_next    = 1'b0;
        cycle_hi_next     = 1'b0;

        if (read_accept) begin
            if (dram_write_hit) begin
                response_tag_next = RESP_DRAM;
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
                unique case (perip_addr_eff)
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
    always_ff @(posedge clk) begin
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

    cdc_mailbox_xpm #(
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
        .dest_rst   (rst),
        .dest_data  (ledseg_cnt_data),
        .dest_valid (ledseg_cnt_valid)
    );

    // Latch a transferred snapshot only when the handshake destination pulse arrives.
    // This consumes ledseg_cnt_valid explicitly and avoids using invalid intermediate data.
    always_ff @(posedge cnt_clk) begin
        if (rst) begin
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
        .rst  (rst),
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

    always_ff @(posedge cnt_clk) begin
        if (rst) begin
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
    always_ff @(posedge clk) begin
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

    logic [1:0]  response_tag_r2;
    logic        cycle_sel_next, cycle_sel_r, cycle_sel_r2;
    logic        cycle_hi_next,  cycle_hi_r,  cycle_hi_r2;
    logic [31:0] mmio_rdata_r;
    logic [31:0] cnt_rdata_r;
    logic [31:0] cnt_rdata_r2;
    logic [3:0]  load_forward_mask_r;
    logic [3:0]  load_forward_mask_r2;
    logic [31:0] load_forward_data_r;
    logic [31:0] load_forward_data_r2;
    logic [31:0] load_forward_bit_mask;
    logic [31:0] dram_rdata_forwarded;

    always_ff @(posedge clk) begin
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
                        response_tag_r == RESP_NONE &&
                        response_tag_r2 == RESP_NONE;

    always_comb begin
        unique case (response_tag_r2)
            RESP_MMIO: perip_rdata = mmio_rdata_r;
            RESP_DRAM: perip_rdata = dram_rdata_forwarded;
            RESP_CNT:  perip_rdata = cycle_sel_r2
                ? (cycle_hi_r2 ? cycle_count[63:32] : cycle_count[31:0])
                : cnt_rdata_r2;
            default:   perip_rdata = 32'd0;
        endcase
    end
endmodule
