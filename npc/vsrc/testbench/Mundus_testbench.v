`timescale 1ns / 1ps

module Mundus_testbench();

  reg clock;
  reg reset;

  wire        io_master_awready;
  wire        io_master_awvalid;
  wire [31:0] io_master_awaddr ;
  wire        io_master_arready;
  wire        io_master_arvalid;
  wire [31:0] io_master_araddr ;
  wire        io_master_bready ;
  reg         io_master_bvalid ;
  reg  [ 1:0] io_master_bresp  ;
  wire        io_master_wready ;
  wire        io_master_wvalid ;
  wire [31:0] io_master_wdata  ;
  wire [ 3:0] io_master_wstrb  ;
  wire        io_master_rready ;
  reg         io_master_rvalid ;
  reg  [31:0] io_master_rdata  ;
  reg  [ 1:0] io_master_rresp  ;

  reg [7:0] psram [(32 * 1024 * 1024) - 1:0];

  reg  [31:0] addr;
  reg  [31:0] wdata;

  reg aw_shake, w_shake;

  assign io_master_awready = 1'd1;
  assign io_master_arready = 1'd1;
  assign io_master_wready  = 1'd1;

Mundus cpu(
  .clock              (clock),
  .reset              (reset),
  .io_interrupt       (),
  .io_master_awready  (io_master_awready),
  .io_master_awvalid  (io_master_awvalid),
  .io_master_awaddr   (io_master_awaddr ),
  .io_master_awid     (),
  .io_master_awlen    (),
  .io_master_awsize   (),
  .io_master_awburst  (),
  .io_master_wready   (io_master_wready),
  .io_master_wvalid   (io_master_wvalid),
  .io_master_wdata    (io_master_wdata ),
  .io_master_wstrb    (io_master_wstrb ),
  .io_master_wlast    (),
  .io_master_bready   (io_master_bready),
  .io_master_bvalid   (io_master_bvalid),
  .io_master_bresp    (io_master_bresp ),
  .io_master_bid      (),
  .io_master_arready  (io_master_arready),
  .io_master_arvalid  (io_master_arvalid),
  .io_master_araddr   (io_master_araddr),
  .io_master_arid     (),
  .io_master_arlen    (),
  .io_master_arsize   (),
  .io_master_arburst  (),
  .io_master_rready   (io_master_rready),
  .io_master_rvalid   (io_master_rvalid),
  .io_master_rresp    (io_master_rresp ),
  .io_master_rdata    (io_master_rdata ),
  .io_master_rlast    (),
  .io_master_rid      (),
  .io_slave_awready   (),
  .io_slave_awvalid   (),
  .io_slave_awaddr    (),
  .io_slave_awid      (),
  .io_slave_awlen     (),
  .io_slave_awsize    (),
  .io_slave_awburst   (),
  .io_slave_wready    (),
  .io_slave_wvalid    (),
  .io_slave_wdata     (),
  .io_slave_wstrb     (),
  .io_slave_wlast     (),
  .io_slave_bready    (),
  .io_slave_bvalid    (),
  .io_slave_bresp     (),
  .io_slave_bid       (),
  .io_slave_arready   (),
  .io_slave_arvalid   (),
  .io_slave_araddr    (),
  .io_slave_arid      (),
  .io_slave_arlen     (),
  .io_slave_arsize    (),
  .io_slave_arburst   (),
  .io_slave_rready    (),
  .io_slave_rvalid    (),
  .io_slave_rresp     (),
  .io_slave_rdata     (),
  .io_slave_rlast     (),
  .io_slave_rid       ()
);

  initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0, Mundus_testbench);
    clock = 1'd0;
    reset = 1'd1;
    io_master_rvalid = 1'd0;
    #10
    reset = 1'd0;
  end

  initial begin
    // $readmemh("/home/redbean/ysyx-workbench/am-kernels/tests/cpu-tests/build/iverilog.hex", psram);
    $readmemh("/home/redbean/ysyx-workbench/am-kernels/benchmarks/microbench/build/iverilog.hex", psram);
    // $readmemh("/home/redbean/ysyx-workbench/rt-thread-am/bsp/abstract-machine/build/iverilog.hex", psram);
  end

  always #5 clock = ~clock;

  always @(posedge clock) begin
    if (io_master_arvalid && io_master_arready) begin
      io_master_rvalid <= 1'd1;
    end
    if (io_master_rready && io_master_rvalid) begin
      io_master_rvalid <= 1'd0;
    end
  end

  always @(posedge clock) begin
    if (w_shake && aw_shake) begin
      if (addr[31:28] == 4'h8) begin
        if (io_master_wstrb[3]) psram[{8'h00, addr[23:2], 2'b00} + 3] <= wdata[31:24];
        if (io_master_wstrb[2]) psram[{8'h00, addr[23:2], 2'b00} + 2] <= wdata[23:16];
        if (io_master_wstrb[1]) psram[{8'h00, addr[23:2], 2'b00} + 1] <= wdata[15: 8];
        if (io_master_wstrb[0]) psram[{8'h00, addr[23:2], 2'b00} + 0] <= wdata[ 7: 0];
      end
      else if (addr == 32'ha00003f8) begin
        $write("%c", wdata[7:0]);
        $fflush;
      end
      else begin
        $display("Unknown address space 0x%x", addr);
        $stop;
      end
    end
  end

  always @(posedge clock) begin
    aw_shake <= io_master_awvalid && io_master_awready;
    w_shake  <= io_master_wvalid  && io_master_wready ;
  end

  always @(posedge clock) begin
    if (io_master_arvalid && io_master_arready) begin
      addr <= io_master_araddr;
    end
    if (io_master_awvalid && io_master_awready) begin
      addr <= io_master_awaddr;
    end
  end

  always @(posedge clock) begin
    if (io_master_wready && io_master_wvalid) begin
      io_master_bvalid <= 1'd1;
    end
    else if (io_master_bready && io_master_bvalid) begin
      io_master_bvalid <= 1'd0;
    end
  end

  always @(io_master_wready && io_master_wvalid) begin
    if (io_master_wready && io_master_wvalid) begin
      wdata = io_master_wdata;
    end
  end

  always @(io_master_rready && io_master_rvalid) begin
    if (io_master_rready && io_master_rvalid) begin
      io_master_rresp = 2'b00;
      if (addr[31:28] == 4'h8) begin
        io_master_rdata = {
          psram[{8'h00, addr[23:2], 2'b00} + 3],
          psram[{8'h00, addr[23:2], 2'b00} + 2],
          psram[{8'h00, addr[23:2], 2'b00} + 1],
          psram[{8'h00, addr[23:2], 2'b00}    ]
        };
      end
      else if (addr == 32'ha0000048 || addr == 32'ha000004c) begin
        io_master_rdata = 32'd0;
      end
      else begin
        io_master_rdata = 32'hx;
        $display("Unknown address space 0x%x", addr);
        $stop;
      end
    end
    else begin
      io_master_rresp = 2'bxx;
      io_master_rdata = 32'hx;
    end
  end

  always @(io_master_bready && io_master_bvalid) begin
    if (io_master_bready && io_master_bvalid) begin
      io_master_bresp = 2'b00;
    end
    else begin
      io_master_bresp = 2'bxx;
    end
  end

  always @(*) begin
    if (io_master_rdata == 32'b00000000000100000000000001110011) begin
      $display("ebreak");
      $finish(0);
    end
  end

endmodule
