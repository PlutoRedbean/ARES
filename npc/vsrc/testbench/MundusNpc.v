module MundusNpc(
    input clock,
    input reset
);

localparam ADDR_WIDTH   = 32;
localparam DATA_WIDTH   = 32;
localparam RESP_WIDTH   =  2;
localparam STRB_WIDTH   =  4;

wire          io_interrupt      ;
wire          io_master_awready ;
wire          io_master_wready  ;
wire          io_master_bvalid  ;
wire [ 1:0]   io_master_bresp   ;
wire [ 3:0]   io_master_bid     ;
wire          io_master_arready ;
wire          io_master_rvalid  ;
wire [ 1:0]   io_master_rresp   ;
wire [31:0]   io_master_rdata   ;
wire          io_master_rlast   ;
wire [ 3:0]   io_master_rid     ;
wire          io_slave_awvalid  ;
wire [31:0]   io_slave_awaddr   ;
wire [ 3:0]   io_slave_awid     ;
wire [ 7:0]   io_slave_awlen    ;
wire [ 2:0]   io_slave_awsize   ;
wire [ 1:0]   io_slave_awburst  ;
wire          io_slave_arvalid  ;
wire [31:0]   io_slave_araddr   ;
wire [ 3:0]   io_slave_arid     ;
wire [ 7:0]   io_slave_arlen    ;
wire [ 2:0]   io_slave_arsize   ;
wire [ 1:0]   io_slave_arburst  ;
wire          io_slave_rready   ;

wire          io_master_awvalid ;
wire [31:0]   io_master_awaddr  ;
wire [ 3:0]   io_master_awid    ;
wire [ 7:0]   io_master_awlen   ;
wire [ 2:0]   io_master_awsize  ;
wire [ 1:0]   io_master_awburst ;
wire          io_master_wvalid  ;
wire [31:0]   io_master_wdata   ;
wire [ 3:0]   io_master_wstrb   ;
wire          io_master_wlast   ;
wire          io_master_bready  ;
wire          io_master_arvalid ;
wire [31:0]   io_master_araddr  ;
wire [ 3:0]   io_master_arid    ;
wire [ 7:0]   io_master_arlen   ;
wire [ 2:0]   io_master_arsize  ;
wire [ 1:0]   io_master_arburst ;
wire          io_master_rready  ;
wire          io_slave_awready  ;
wire          io_slave_wready   ;
wire          io_slave_bvalid   ;
wire [ 1:0]   io_slave_bresp    ;
wire [ 3:0]   io_slave_bid      ;
wire          io_slave_arready  ;
wire          io_slave_rvalid   ;
wire [ 1:0]   io_slave_rresp    ;
wire [31:0]   io_slave_rdata    ;
wire          io_slave_rlast    ;
wire [ 3:0]   io_slave_rid      ;
wire          io_slave_wvalid   ;
wire [31:0]   io_slave_wdata    ;
wire [ 3:0]   io_slave_wstrb    ;
wire          io_slave_wlast    ;
wire          io_slave_bready   ;

wire                    axi_awvalid ;
wire [ADDR_WIDTH - 1:0] axi_awaddr  ;
wire                    axi_wvalid  ;
wire [DATA_WIDTH - 1:0] axi_wdata   ;
wire [STRB_WIDTH - 1:0] axi_wstrb   ;
wire                    axi_bready  ;
wire                    axi_arvalid ;
wire [ADDR_WIDTH - 1:0] axi_araddr  ;
wire                    axi_rready  ;

wire                    axi_awready ;
wire                    axi_wready  ;
wire                    axi_bvalid  ;
wire [RESP_WIDTH-1:0]   axi_bresp   ;
wire                    axi_arready ;
wire                    axi_rvalid  ;
wire [DATA_WIDTH-1:0]   axi_rdata   ;
wire [RESP_WIDTH-1:0]   axi_rresp   ;

assign io_interrupt       = 'd0         ;
assign io_master_awready   = axi_awready ;
assign io_master_wready    = axi_wready  ;
assign io_master_bvalid   = axi_bvalid  ;
assign io_master_bresp    = axi_bresp   ;
assign io_master_bid      = 'd0         ;
assign io_master_arready  = axi_arready ;
assign io_master_rvalid   = axi_rvalid  ;
assign io_master_rresp    = axi_rresp   ;
assign io_master_rdata    = axi_rdata   ;
assign io_master_rlast    = 'd0         ;
assign io_master_rid      = 'd0         ;
assign io_slave_awvalid   = 'd0         ;
assign io_slave_awaddr    = 'd0         ;
assign io_slave_awid      = 'd0         ;
assign io_slave_awlen     = 'd0         ;
assign io_slave_awsize    = 'd0         ;
assign io_slave_awburst   = 'd0         ;
assign io_slave_arvalid   = 'd0         ;
assign io_slave_araddr    = 'd0         ;
assign io_slave_arid      = 'd0         ;
assign io_slave_arlen     = 'd0         ;
assign io_slave_arsize    = 'd0         ;
assign io_slave_arburst   = 'd0         ;
assign io_slave_rready    = 'd0         ;

assign axi_awvalid = io_master_awvalid;
assign axi_awaddr  = io_master_awaddr ;
assign axi_wvalid  = io_master_wvalid ;
assign axi_wdata   = io_master_wdata  ;
assign axi_wstrb   = io_master_wstrb  ;
assign axi_bready  = io_master_bready ;
assign axi_arvalid = io_master_arvalid;
assign axi_araddr  = io_master_araddr ;
assign axi_rready  = io_master_rready ;

Mundus u_Mundus(
  .clock               ( clock              ),
  .reset               ( reset              ),
  .io_interrupt        ( io_interrupt       ),
  .io_master_awready   ( io_master_awready  ),
  .io_master_awvalid   ( io_master_awvalid  ),
  .io_master_awaddr    ( io_master_awaddr   ),
  .io_master_awid      ( io_master_awid     ),
  .io_master_awlen     ( io_master_awlen    ),
  .io_master_awsize    ( io_master_awsize   ),
  .io_master_awburst   ( io_master_awburst  ),
  .io_master_wready    ( io_master_wready   ),
  .io_master_wvalid    ( io_master_wvalid   ),
  .io_master_wdata     ( io_master_wdata    ),
  .io_master_wstrb     ( io_master_wstrb    ),
  .io_master_wlast     ( io_master_wlast    ),
  .io_master_bready    ( io_master_bready   ),
  .io_master_bvalid    ( io_master_bvalid   ),
  .io_master_bresp     ( io_master_bresp    ),
  .io_master_bid       ( io_master_bid      ),
  .io_master_arready   ( io_master_arready  ),
  .io_master_arvalid   ( io_master_arvalid  ),
  .io_master_araddr    ( io_master_araddr   ),
  .io_master_arid      ( io_master_arid     ),
  .io_master_arlen     ( io_master_arlen    ),
  .io_master_arsize    ( io_master_arsize   ),
  .io_master_arburst   ( io_master_arburst  ),
  .io_master_rready    ( io_master_rready   ),
  .io_master_rvalid    ( io_master_rvalid   ),
  .io_master_rresp     ( io_master_rresp    ),
  .io_master_rdata     ( io_master_rdata    ),
  .io_master_rlast     ( io_master_rlast    ),
  .io_master_rid       ( io_master_rid      ),
  .io_slave_awready    ( io_slave_awready   ),
  .io_slave_awvalid    ( io_slave_awvalid   ),
  .io_slave_awaddr     ( io_slave_awaddr    ),
  .io_slave_awid       ( io_slave_awid      ),
  .io_slave_awlen      ( io_slave_awlen     ),
  .io_slave_awsize     ( io_slave_awsize    ),
  .io_slave_awburst    ( io_slave_awburst   ),
  .io_slave_wready     ( io_slave_wready    ),
  .io_slave_wvalid     ( io_slave_wvalid    ),
  .io_slave_wdata      ( io_slave_wdata     ),
  .io_slave_wstrb      ( io_slave_wstrb     ),
  .io_slave_wlast      ( io_slave_wlast     ),
  .io_slave_bready     ( io_slave_bready    ),
  .io_slave_bvalid     ( io_slave_bvalid    ),
  .io_slave_bresp      ( io_slave_bresp     ),
  .io_slave_bid        ( io_slave_bid       ),
  .io_slave_arready    ( io_slave_arready   ),
  .io_slave_arvalid    ( io_slave_arvalid   ),
  .io_slave_araddr     ( io_slave_araddr    ),
  .io_slave_arid       ( io_slave_arid      ),
  .io_slave_arlen      ( io_slave_arlen     ),
  .io_slave_arsize     ( io_slave_arsize    ),
  .io_slave_arburst    ( io_slave_arburst   ),
  .io_slave_rready     ( io_slave_rready    ),
  .io_slave_rvalid     ( io_slave_rvalid    ),
  .io_slave_rresp      ( io_slave_rresp     ),
  .io_slave_rdata      ( io_slave_rdata     ),
  .io_slave_rlast      ( io_slave_rlast     ),
  .io_slave_rid        ( io_slave_rid       )
);

memory u_memory(
  .axi_awvalid   ( axi_awvalid  ),
  .axi_awready   ( axi_awready  ),
  .axi_awaddr    ( axi_awaddr   ),
  .axi_wvalid    ( axi_wvalid   ),
  .axi_wready    ( axi_wready   ),
  .axi_wdata     ( axi_wdata    ),
  .axi_wstrb     ( axi_wstrb    ),
  .axi_bvalid    ( axi_bvalid   ),
  .axi_bready    ( axi_bready   ),
  .axi_bresp     ( axi_bresp    ),
  .axi_arvalid   ( axi_arvalid  ),
  .axi_arready   ( axi_arready  ),
  .axi_araddr    ( axi_araddr   ),
  .axi_rvalid    ( axi_rvalid   ),
  .axi_rready    ( axi_rready   ),
  .axi_rdata     ( axi_rdata    ),
  .axi_rresp     ( axi_rresp    ),
  .clk           ( clock        ),
  .rst           ( reset        )
);

endmodule

`include "common_para.vh"
`include "SRAM_para.vh"
`include "AXI_para.vh"
module memory #(
  STRB_WIDTH = 4 ,
  RESP_WIDTH = 2 ,
  DATA_WIDTH = 32,
  ADDR_WIDTH = 32
)
(
/*--------------databus--------------*/
  input                     axi_awvalid ,
  output                    axi_awready ,
  input  [ADDR_WIDTH - 1:0] axi_awaddr  ,

  input                     axi_wvalid  ,
  output                    axi_wready  ,
  input  [DATA_WIDTH - 1:0] axi_wdata   ,
  input  [STRB_WIDTH - 1:0] axi_wstrb   ,

  output                    axi_bvalid  ,
  input                     axi_bready  ,
  output [RESP_WIDTH - 1:0] axi_bresp   ,

  input                     axi_arvalid ,
  output                    axi_arready ,
  input  [ADDR_WIDTH - 1:0] axi_araddr  ,

  output                    axi_rvalid  ,
  input                     axi_rready  ,
  output [DATA_WIDTH - 1:0] axi_rdata   ,
  output [RESP_WIDTH - 1:0] axi_rresp   ,
/*-----------------------------------*/

/*----------system-interface---------*/
  input                     clk         ,
  input                     rst
/*-----------------------------------*/
);

/*---------------axi-lite--------------*/

wire                    work_done ;
wire [ADDR_WIDTH - 1:0] waddr     ;
wire [STRB_WIDTH - 1:0] wstrb     ;
wire [DATA_WIDTH - 1:0] wdata     ;
wire [ADDR_WIDTH - 1:0] raddr     ;
wire [DATA_WIDTH - 1:0] rdata     ;
wire                    working   ;
reg                     read      ;
reg                     write     ;

AXI_Lite_S #(STRB_WIDTH,RESP_WIDTH,DATA_WIDTH,ADDR_WIDTH) AXI_LITE_SRAM (
  .axi_awvalid(axi_awvalid) ,
  .axi_awready(axi_awready) ,
  .axi_awaddr(axi_awaddr)   ,
  .axi_wvalid(axi_wvalid)   ,
  .axi_wready(axi_wready)   ,
  .axi_wdata(axi_wdata)     ,
  .axi_wstrb(axi_wstrb)     ,
  .axi_bvalid(axi_bvalid)   ,
  .axi_bready(axi_bready)   ,
  .axi_bresp(axi_bresp)     ,
  .axi_arvalid(axi_arvalid) ,
  .axi_arready(axi_arready) ,
  .axi_araddr(axi_araddr)   ,
  .axi_rvalid(axi_rvalid)   ,
  .axi_rready(axi_rready)   ,
  .axi_rdata(axi_rdata)     ,
  .axi_rresp(axi_rresp)     ,
  .aclk(clk)                ,
  .aresetn(~rst)            ,
  .work_done(work_done)     ,
  .waddr(waddr)             ,
  .wdata(wdata)             ,
  .wstrb(wstrb)             ,
  .raddr(raddr)             ,
  .rdata(rdata)             ,
  .working(working)
);

assign work_done = work_cnt_done;
  
/*-------------------------------------*/

/*--------------work_cnt-------------*/

wire [4:0] work_cnt     ;
wire [4:0] work_max     ;
wire [4:0] work_cnt_next;
wire       work_cnt_done;

Reg #(5, 0) work_cnt_r(clk, rst, work_cnt_next, work_cnt, working);

assign work_max = 5'd1;   // at least delay by 1 cycle.
assign work_cnt_next = work_cnt_done ? 5'd0 : work_cnt + 1'd1;
assign work_cnt_done = work_cnt == (work_max - 1'd1);

/*-----------------------------------*/

always @(posedge clk) begin
  if (axi_wvalid && axi_wready && axi_awvalid && axi_awready) begin
    write <= 1'd1;
    read  <= 1'd0;
  end
  else if (axi_arvalid && axi_arready) begin
    write <= 1'd0;
    read  <= 1'd1;
  end
end

import "DPI-C" function int mem_read(input int raddr);
import "DPI-C" function void mem_write(input int waddr, input int wdata, input byte mask);

reg [DATA_WIDTH - 1:0] rdata_r;

always @(posedge clk) begin
  if (working && work_done) begin
    if (read) begin
      rdata_r <= mem_read(raddr);
    end

    if (write) begin
      mem_write(waddr, wdata, {4'h0, wstrb});
    end
  end
end

assign rdata = rdata_r;

endmodule

