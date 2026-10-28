`timescale 1ns/1ps
// Framebuffer data-path test: write a known colour, read it back and compare.
// Small frame (64x8) so the AXI memory is modest; LINE_ADDR_WIDTH=16 keeps the
// two frame buffers at word 0 and 0x10000.
module tb_fram_buf_pat;
    localparam integer H      = 1280;
    localparam integer V      = 720;
    localparam integer LINES  = 16;   // enough frames to fill both buffers

    reg vin_clk = 0, vout_clk = 0, ddr_clk = 0;
    always #12 vin_clk  = ~vin_clk;   // ~42 MHz
    always #13 vout_clk = ~vout_clk;  // ~38 MHz
    always #4  ddr_clk  = ~ddr_clk;   // 125 MHz

    reg rst = 1;
    reg ddr_rstn = 0;

    reg        wr_fsync = 0;
    reg        wr_en = 0;
    reg [15:0] wr_data = 0;
    reg        rd_fsync = 0;
    reg        rd_en = 0;
    wire       vout_de;
    wire [15:0] vout_data;
    wire       init_done;

    wire [27:0] awaddr, araddr;
    wire [3:0]  awid, awlen, arid, arlen;
    wire [2:0]  awsize, arsize;
    wire [1:0]  awburst, arburst;
    wire        awvalid, awready, arvalid, arready;
    wire [255:0] wdata, rdata;
    wire [31:0] wstrb;
    wire        wlast, wvalid, wready, rvalid, rlast, rready;
    wire [3:0]  rid;
    wire [3:0]  bid = 4'd0;

    // The framebuf input axi_wlast is driven by the slave's write-last.
    wire        slave_wlast;

    fram_buf #(
        .MEM_ROW_WIDTH    (15),
        .MEM_COLUMN_WIDTH (10),
        .MEM_BANK_WIDTH   (3),
        .CTRL_ADDR_WIDTH  (28),
        .MEM_DQ_WIDTH     (32),
        .H_NUM            (H),
        .V_NUM            (V),
        .PIX_WIDTH        (16)
    ) dut (
        .vin_clk     (vin_clk),
        .wr_fsync    (wr_fsync),
        .wr_en       (wr_en),
        .wr_data     (wr_data),
        .init_done   (init_done),
        .ddr_clk     (ddr_clk),
        .ddr_rstn    (ddr_rstn),
        .vout_clk    (vout_clk),
        .rd_fsync    (rd_fsync),
        .rd_en       (rd_en),
        .vout_de     (vout_de),
        .vout_data   (vout_data),
        .axi_awaddr  (awaddr), .axi_awid(awid), .axi_awlen(awlen),
        .axi_awsize  (awsize), .axi_awburst(awburst),
        .axi_awready (awready), .axi_awvalid(awvalid),
        .axi_wdata   (wdata), .axi_wstrb(wstrb), .axi_wlast(slave_wlast),
        .axi_wvalid  (wvalid), .axi_wready(wready), .axi_bid(bid),
        .axi_araddr  (araddr), .axi_arid(arid), .axi_arlen(arlen),
        .axi_arsize  (arsize), .axi_arburst(arburst),
        .axi_arvalid (arvalid), .axi_arready(arready),
        .axi_rready  (rready), .axi_rdata(rdata), .axi_rvalid(rvalid),
        .axi_rlast   (rlast),  .axi_rid(rid)
    );

    // Note: LINE_ADDR_WIDTH is a parameter of fram_buf but not exposed in its
    // port list; the default 22 puts the second buffer at word 0x400000.
    // The memory below is therefore 1M words only if the test's addresses stay
    // below it; for the 800-style framebuf we use a sparse model below.

    axis_slave #(.AW(28), .WORDS(1<<23)) slave (
        .clk(ddr_clk), .rst(rst),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rvalid(rvalid), .rlast(rlast),
        .wlast_out(slave_wlast)
    );

    // Write side: one frame is V lines of H active pixels with gaps.
    initial begin
        wr_fsync = 0; wr_en = 0; wr_data = 0;
        repeat (5) @(posedge vin_clk);
        ddr_rstn = 1;
        repeat (10) @(posedge vin_clk);
        forever begin
            @(posedge vin_clk);
            wr_fsync <= 1;
            @(posedge vin_clk);
            wr_fsync <= 0;
            repeat (8) @(posedge vin_clk);
            for (integer y = 0; y < V; y = y + 1) begin
                for (integer x = 0; x < H; x = x + 1) begin
                    wr_en   <= 1;
                    wr_data <= {4'hA, x[7:0], 4'h5};
                    @(posedge vin_clk);
                end
                wr_en <= 0;
                repeat (8) @(posedge vin_clk);
            end
            repeat (32) @(posedge vin_clk);
        end
    end

    // Read side: same cadence, independent clock.
    initial begin
        rd_fsync = 0; rd_en = 0;
        wait (init_done);
        repeat (100) @(posedge vout_clk);
        forever begin
            @(posedge vout_clk);
            rd_fsync <= 1;
            @(posedge vout_clk);
            rd_fsync <= 0;
            repeat (8) @(posedge vout_clk);
            for (integer y = 0; y < V; y = y + 1) begin
                for (integer x = 0; x < H; x = x + 1) begin
                    rd_en <= 1;
                    @(posedge vout_clk);
                end
                rd_en <= 0;
                repeat (8) @(posedge vout_clk);
            end
            repeat (32) @(posedge vout_clk);
        end
    end

    // Check readback on vout_de.
    integer rd_pixels = 0, bad = 0;
    reg [15:0] first_bad = 0;
    reg check_en = 0;
    integer rd_x = 0;
    initial begin
        wait (init_done);
        repeat (2500000) @(posedge vout_clk);
        check_en = 1;
        forever begin
            @(posedge vout_clk);
            if (!rd_en) rd_x = 0;
            if (check_en && vout_de) begin
                rd_pixels = rd_pixels + 1;
                if (vout_data !== {4'hA, rd_x[7:0], 4'h5}) begin
                    bad = bad + 1;
                    if (bad == 1) first_bad = vout_data;
                end
                rd_x = rd_x + 1;
            end
        end
    end

    initial begin
        repeat (5) @(posedge vin_clk);
        rst = 0;
        // Wait for a few complete read frames after init.
        wait (init_done);
        repeat (3000000) @(posedge vout_clk);
        $display("init_done=%b rd_pixels=%0d bad=%0d first_bad=%h",
                 init_done, rd_pixels, bad, first_bad);
        $display("AXI aw=%0d w=%0d ar=%0d r=%0d", slave.aw_cnt, slave.w_cnt, slave.ar_cnt, slave.r_cnt);
        $display("mem[0]=%h mem[0x400000]=%h mem[0x400020]=%h",
                 slave.mem[0], slave.mem[28'h400000], slave.mem[28'h400020]);
        if (rd_pixels == 0) begin $display("FAIL: no vout_de"); $fatal(1); end
        if (bad == 0) $display("PASS: framebuf readback matches");
        else          $display("FAIL: readback mismatch");
        $finish;
    end
endmodule

module axis_slave #(parameter AW = 28, parameter WORDS = 1<<23) (
    input  wire          clk,
    input  wire          rst,
    input  wire [AW-1:0] awaddr,
    input  wire [3:0]    awlen,
    input  wire          awvalid,
    output wire          awready,
    input  wire [255:0]  wdata,
    input  wire [31:0]   wstrb,
    input  wire          wvalid,
    output wire          wready,
    input  wire [AW-1:0] araddr,
    input  wire [3:0]    arlen,
    input  wire          arvalid,
    output wire          arready,
    output wire [255:0]  rdata,
    output wire          rvalid,
    output wire          rlast,
    output wire          wlast_out
);
    reg [31:0] mem [0:WORDS-1];
    reg [AW-1:0] waddr, raddr;
    reg [3:0]    wbeat, rbeat;
    reg          wactive, ractive;
    integer aw_cnt=0, w_cnt=0, ar_cnt=0, r_cnt=0;

    assign awready   = ~wactive;
    assign wready    =  wactive;
    assign arready   = ~ractive;
    assign rvalid    =  ractive;
    assign rlast     =  ractive && (rbeat == arlen);
    assign wlast_out =  wactive && (wbeat == awlen);
    assign rdata     = {mem[raddr + rbeat*8 + 7], mem[raddr + rbeat*8 + 6],
                        mem[raddr + rbeat*8 + 5], mem[raddr + rbeat*8 + 4],
                        mem[raddr + rbeat*8 + 3], mem[raddr + rbeat*8 + 2],
                        mem[raddr + rbeat*8 + 1], mem[raddr + rbeat*8 + 0]};

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            wactive <= 0; ractive <= 0;
            waddr <= 0; raddr <= 0;
            wbeat <= 0; rbeat <= 0;
        end else begin
            if (awvalid && awready) begin
                if (aw_cnt < 10)
                    $display("AW%0d addr=%h len=%0d", aw_cnt, awaddr, awlen);
                aw_cnt <= aw_cnt + 1;
                waddr <= awaddr; wbeat <= 0; wactive <= 1;
            end else if (wactive && wvalid && wready) begin
                if (w_cnt < 4)
                    $display("W%0d addr=%h beat=%0d data=%h", w_cnt, waddr, wbeat, wdata[31:0]);
                w_cnt <= w_cnt + 1;
                for (k = 0; k < 8; k = k + 1)
                    mem[waddr + wbeat*8 + k] <= wdata[32*k +: 32];
                if (wbeat == awlen) wactive <= 0;
                else                wbeat   <= wbeat + 1;
            end
            if (arvalid && arready) begin
                ar_cnt <= ar_cnt + 1;
                raddr <= araddr; rbeat <= 0; ractive <= 1;
            end else if (ractive) begin
                r_cnt <= r_cnt + 1;
                if (rbeat == arlen) ractive <= 0;
                else                rbeat   <= rbeat + 1;
            end
        end
    end
endmodule
