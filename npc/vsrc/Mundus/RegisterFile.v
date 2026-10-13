`ifdef __VERILATOR__
`include "common_para.vh"
`endif

`ifdef DPIC
import "DPI-C" function void init_reg(input int data, input int index);
`endif
module RegisterFile #(ADDR_WIDTH = 4, DATA_WIDTH = 32) (
  input                   clk     ,
  input                   wen0    ,
  input  [ADDR_WIDTH-1:0] waddr0  ,
  input  [DATA_WIDTH-1:0] wdata0  ,
  input                   wen1    ,
  input  [ADDR_WIDTH-1:0] waddr1  ,
  input  [DATA_WIDTH-1:0] wdata1  ,
  input                   ren     ,
  input  [ADDR_WIDTH-1:0] raddr1_0,
  output [DATA_WIDTH-1:0] rdata1_0,
  input  [ADDR_WIDTH-1:0] raddr2_0,
  output [DATA_WIDTH-1:0] rdata2_0,
  input  [ADDR_WIDTH-1:0] raddr1_1,
  output [DATA_WIDTH-1:0] rdata1_1,
  input  [ADDR_WIDTH-1:0] raddr2_1,
  output [DATA_WIDTH-1:0] rdata2_1
);
  localparam integer REG_COUNT = 1 << ADDR_WIDTH;

  wire write0_en = wen0 && (waddr0 != {ADDR_WIDTH{1'b0}});
  wire write1_en = wen1 && (waddr1 != {ADDR_WIDTH{1'b0}});

  // A live-value table converts the two architectural write ports into two
  // single-write banks.  Replicating each bank supplies four independent
  // asynchronous LUTRAM read ports without a wide flip-flop register mux.
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank0_read0 [0:REG_COUNT-1];
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank0_read1 [0:REG_COUNT-1];
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank0_read2 [0:REG_COUNT-1];
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank0_read3 [0:REG_COUNT-1];
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank1_read0 [0:REG_COUNT-1];
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank1_read1 [0:REG_COUNT-1];
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank1_read2 [0:REG_COUNT-1];
  (* ram_style = "distributed" *)
  reg [DATA_WIDTH-1:0] bank1_read3 [0:REG_COUNT-1];

  // Packed storage forces a small register implementation for the LVT.  If a
  // defensive same-address dual write reaches this module, lane 1 is younger
  // and its later assignment deliberately wins.
  reg [REG_COUNT-1:0] latest_bank;

  always @(posedge clk) begin
    if (write0_en) begin
      bank0_read0[waddr0] <= wdata0;
      bank0_read1[waddr0] <= wdata0;
      bank0_read2[waddr0] <= wdata0;
      bank0_read3[waddr0] <= wdata0;
      latest_bank[waddr0] <= 1'b0;
    end
    if (write1_en) begin
      bank1_read0[waddr1] <= wdata1;
      bank1_read1[waddr1] <= wdata1;
      bank1_read2[waddr1] <= wdata1;
      bank1_read3[waddr1] <= wdata1;
      latest_bank[waddr1] <= 1'b1;
    end
  end

`ifdef DPIC
  integer i;
  initial begin
    latest_bank = {REG_COUNT{1'b0}};
    for (i = 0; i < REG_COUNT; i = i + 1) begin
      bank0_read1[i] = bank0_read0[i];
      bank0_read2[i] = bank0_read0[i];
      bank0_read3[i] = bank0_read0[i];
      bank1_read0[i] = bank0_read0[i];
      bank1_read1[i] = bank0_read0[i];
      bank1_read2[i] = bank0_read0[i];
      bank1_read3[i] = bank0_read0[i];
      if (i != 0)
        init_reg(bank0_read0[i], i);
    end
  end
`endif

  reg [ADDR_WIDTH-1:0] raddr1_0_r;
  reg [ADDR_WIDTH-1:0] raddr2_0_r;
  reg [ADDR_WIDTH-1:0] raddr1_1_r;
  reg [ADDR_WIDTH-1:0] raddr2_1_r;

  always @(posedge clk) begin
    if (ren) begin
      raddr1_0_r <= raddr1_0;
      raddr2_0_r <= raddr2_0;
      raddr1_1_r <= raddr1_1;
      raddr2_1_r <= raddr2_1;
    end
  end

  wire [DATA_WIDTH-1:0] rdata1_0_bank0 = bank0_read0[raddr1_0_r];
  wire [DATA_WIDTH-1:0] rdata1_0_bank1 = bank1_read0[raddr1_0_r];
  wire [DATA_WIDTH-1:0] rdata2_0_bank0 = bank0_read1[raddr2_0_r];
  wire [DATA_WIDTH-1:0] rdata2_0_bank1 = bank1_read1[raddr2_0_r];
  wire [DATA_WIDTH-1:0] rdata1_1_bank0 = bank0_read2[raddr1_1_r];
  wire [DATA_WIDTH-1:0] rdata1_1_bank1 = bank1_read2[raddr1_1_r];
  wire [DATA_WIDTH-1:0] rdata2_1_bank0 = bank0_read3[raddr2_1_r];
  wire [DATA_WIDTH-1:0] rdata2_1_bank1 = bank1_read3[raddr2_1_r];

  assign rdata1_0 = (raddr1_0_r == {ADDR_WIDTH{1'b0}}) ?
                    {DATA_WIDTH{1'b0}} :
                    latest_bank[raddr1_0_r] ?
                      rdata1_0_bank1 : rdata1_0_bank0;
  assign rdata2_0 = (raddr2_0_r == {ADDR_WIDTH{1'b0}}) ?
                    {DATA_WIDTH{1'b0}} :
                    latest_bank[raddr2_0_r] ?
                      rdata2_0_bank1 : rdata2_0_bank0;
  assign rdata1_1 = (raddr1_1_r == {ADDR_WIDTH{1'b0}}) ?
                    {DATA_WIDTH{1'b0}} :
                    latest_bank[raddr1_1_r] ?
                      rdata1_1_bank1 : rdata1_1_bank0;
  assign rdata2_1 = (raddr2_1_r == {ADDR_WIDTH{1'b0}}) ?
                    {DATA_WIDTH{1'b0}} :
                    latest_bank[raddr2_1_r] ?
                      rdata2_1_bank1 : rdata2_1_bank0;

endmodule
