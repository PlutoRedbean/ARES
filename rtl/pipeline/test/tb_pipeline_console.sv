//=============================================================================
// ARES pipeline SoC - Pango console/CDC path test
//-----------------------------------------------------------------------------
// This TB compiles WITHOUT __VERILATOR__ so it exercises the same RTL path as
// the Pango board:
//   * generic CDC (no XPM) in perip_bridge / counter
//   * real UART toggle-handshake console path
//   * LED/SEG mailbox transfer
//   * asynchronous CPU (100 MHz) / peripheral (50 MHz) resets
//
// The DRAM is the inferred Pango BRAM initialized from build/pipeline/dram.hex;
// the core is not instantiated, so this is a fast directed test.
//=============================================================================
`timescale 1ns / 1ps

module tb_pipeline_console(
    input  wire clk,      // 100 MHz CPU clock
    input  wire rst,      // active high
    output reg  done,
    output reg  [31:0] errors
);
    localparam logic [31:0] SW0_ADDR   = 32'h8020_0000;
    localparam logic [31:0] LED_ADDR   = 32'h8020_0040;
    localparam logic [31:0] BENCH_UART = 32'hA000_03F8;
    localparam logic [31:0] BENCH_CYCLE_LO = 32'hA000_0050;
    localparam integer BIT_CYCLES = 434;   // 50 MHz / 115200

    // Frozen CoreMark image: first IROM and DRAM words (see image.json hashes).
    localparam [31:0] IROM_WORD0 = 32'h0000_0413;
    localparam [31:0] IROM_WORD1 = 32'h0014_0117;
    localparam [31:0] DRAM_WORD0 = 32'h6e6e_7552;

    reg cnt_clk;

    always @(posedge clk) begin
        cnt_clk <= ~cnt_clk;
    end

    wire        perip_valid;
    wire        perip_ready;
    wire        perip_rvalid;
    wire        perip_idle;
    wire [31:0] perip_addr;
    wire [31:0] perip_wdata;
    wire        perip_wen;
    wire [1:0]  perip_mask;
    wire [31:0] perip_rdata;
    wire [63:0] virtual_sw;
    wire [7:0]  uart_tx_data;
    wire        uart_tx_start;
    wire        uart_tx_busy;
    wire [39:0] virtual_seg;
    wire [31:0] virtual_led;
    wire        timer_irq;

    // Drive CPU-side requests procedurally so the TB can issue MMIO ops.
    reg         req_valid;
    reg  [31:0] req_addr;
    reg  [31:0] req_wdata;
    reg         req_wen;
    reg  [1:0]  req_mask;

    assign perip_valid = req_valid;
    assign perip_addr  = req_addr;
    assign perip_wdata = req_wdata;
    assign perip_wen   = req_wen;
    assign perip_mask  = req_mask;

    // Constant switch levels; each bit is synchronized independently.
    assign virtual_sw = 64'h1122_3344_5566_7788;

    perip_bridge dut (
        .clk               (clk),
        .cnt_clk           (cnt_clk),
        .rst               (rst),
        .perip_valid       (perip_valid),
        .perip_ready       (perip_ready),
        .perip_rvalid      (perip_rvalid),
        .perip_idle        (perip_idle),
        .perip_addr        (perip_addr),
        .perip_wdata       (perip_wdata),
        .perip_wen         (perip_wen),
        .perip_mask        (perip_mask),
        .perip_rdata       (perip_rdata),
        .timer_irq         (timer_irq),
        .virtual_sw_input  (virtual_sw),
        .virtual_key_input (8'h00),
        .uart_rx_data      (8'h00),
        .uart_rx_ready     (1'b0),
        .uart_tx_busy      (uart_tx_busy),
        .uart_tx_data      (uart_tx_data),
        .uart_tx_start     (uart_tx_start),
        .virtual_seg_output(virtual_seg),
        .virtual_led_output(virtual_led),
        .shared_rdata      (32'd0),
        .shared_req_valid  (),
        .shared_req_write  (),
        .shared_req_addr   (),
        .shared_req_wdata  (),
        .shared_req_wstrb  ()
    );

    // Synthesizable IROM/DRAM initialization path (no DPI in this build).
    logic [12:0] irom_addr;
    wire  [31:0] irom_data;

    IROM_BMEM32 u_irom (
        .addra(irom_addr),
        .clka (clk),
        .douta(irom_data)
    );

    wire uart_tx_pin;

    uart #(
        .CLK_FREQ (50_000_000),
        .BAUD_RATE(115200)
    ) u_uart (
        .clk     (cnt_clk),
        .rst_n   (~rst),
        .rx      (1'b1),
        .rx_data (),
        .rx_ready(),
        .tx      (uart_tx_pin),
        .tx_data (uart_tx_data),
        .tx_start(uart_tx_start),
        .tx_busy (uart_tx_busy)
    );

    task mmio_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            req_valid = 1'b1;
            req_addr  = addr;
            req_wdata = data;
            req_wen   = 1'b1;
            req_mask  = 2'b10;
            @(posedge clk);
            while (!perip_ready) @(posedge clk);
            req_valid = 1'b0;
            req_wen   = 1'b0;
            @(posedge clk);
        end
    endtask

    task mmio_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            req_valid = 1'b1;
            req_addr  = addr;
            req_wen   = 1'b0;
            req_mask  = 2'b10;
            @(posedge clk);
            while (!perip_ready) @(posedge clk);
            req_valid = 1'b0;
            while (!perip_rvalid) @(posedge clk);
            data = perip_rdata;
            @(posedge clk);
        end
    endtask

    task uart_recv(output [7:0] data);
        integer i;
        begin
            @(negedge uart_tx_pin);
            repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge cnt_clk);
            for (i = 0; i < 8; i = i + 1) begin
                data[i] = uart_tx_pin;
                repeat (BIT_CYCLES) @(posedge cnt_clk);
            end
        end
    endtask

    logic [31:0] rdata;
    logic [7:0]  ch;
    logic [31:0] cyc0, cyc1;
    integer      i;

    initial begin
        cnt_clk   = 1'b0;
        req_valid = 1'b0;
        req_addr  = 32'd0;
        req_wdata = 32'd0;
        req_wen   = 1'b0;
        req_mask  = 2'b10;
        done      = 1'b0;
        errors    = 32'd0;

        // PLL lock/reset are handled by the TB clock source; wait for reset.
        repeat (20) @(posedge clk);
        wait (!rst);
        repeat (20) @(posedge clk);
        repeat (10) @(posedge cnt_clk);

        // 0) inferred IROM/DRAM were initialized by $readmemh
        irom_addr = 13'd0;
        @(posedge clk);
        @(negedge clk);
        if (irom_data !== IROM_WORD0) begin
            $display("ERROR irom[0]=%08x expected %08x", irom_data, IROM_WORD0);
            errors = errors + 1;
        end
        irom_addr = 13'd1;
        @(posedge clk);
        @(negedge clk);
        if (irom_data !== IROM_WORD1) begin
            $display("ERROR irom[1]=%08x expected %08x", irom_data, IROM_WORD1);
            errors = errors + 1;
        end
        mmio_read(32'h8010_0000, rdata);
        if (rdata !== DRAM_WORD0) begin
            $display("ERROR dram[0]=%08x expected %08x", rdata, DRAM_WORD0);
            errors = errors + 1;
        end

        // 1) switch levels cross into the CPU domain
        mmio_read(SW0_ADDR, rdata);
        if (rdata !== 32'h5566_7788) begin
            $display("ERROR sw0=%08x expected 55667788", rdata);
            errors = errors + 1;
        end

        // 2) LED snapshot crosses into the peripheral domain
        mmio_write(LED_ADDR, 32'h0000_00a5);
        repeat (20) @(posedge cnt_clk);
        if (virtual_led[7:0] !== 8'hA5) begin
            $display("ERROR led=%02x expected a5", virtual_led[7:0]);
            errors = errors + 1;
        end

        // 3) real UART transmit path (toggle handshake, 50 MHz / 115200)
        // Decode each byte before issuing the next write, otherwise the
        // receiver task can start after an earlier byte has already finished.
        mmio_write(BENCH_UART, 32'h0000_004f); // 'O'
        uart_recv(ch);
        if (ch !== 8'h4f) begin
            $display("ERROR uart[0]=%02x expected 4f", ch);
            errors = errors + 1;
        end

        mmio_write(BENCH_UART, 32'h0000_004b); // 'K'
        uart_recv(ch);
        if (ch !== 8'h4b) begin
            $display("ERROR uart[1]=%02x expected 4b", ch);
            errors = errors + 1;
        end

        mmio_write(BENCH_UART, 32'h0000_000a); // '\n'
        uart_recv(ch);
        if (ch !== 8'h0a) begin
            $display("ERROR uart[2]=%02x expected 0a", ch);
            errors = errors + 1;
        end

        // 4) free-running CPU cycle counter advances
        mmio_read(BENCH_CYCLE_LO, cyc0);
        repeat (100) @(posedge clk);
        mmio_read(BENCH_CYCLE_LO, cyc1);
        if (!(cyc1 > cyc0)) begin
            $display("ERROR cycle counter did not advance: %08x -> %08x",
                     cyc0, cyc1);
            errors = errors + 1;
        end

        if (errors == 0) $display("CONSOLE PASS");
        else             $display("CONSOLE FAIL errors=%0d", errors);
        done = 1'b1;
        repeat (5) @(posedge clk);
        $finish;
    end
endmodule
