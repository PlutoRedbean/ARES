// miniTensor external memory interface (miniTensor.md section 4.2.1).
//
// A 128-bit uncached read/write handshake with no burst and a single
// outstanding read.  The icache uses it as an alternative backing bus when
// `IO_USE_AXI is not defined.
//
//   read  : request  (mem_rd_valid / mem_rd_ready / mem_rd_addr)
//           response (mem_rsp_valid / mem_rsp_ready / mem_rsp_data)
//   write : single phase, whole-line overwrite (mem_wr_be is always all ones)
//
// `mem_rd_addr` / `mem_wr_addr` must be 16-byte aligned.
interface miniTensor_if #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 128
);

    // read request
    logic                    mem_rd_valid;
    logic                    mem_rd_ready;
    logic [  ADDR_WIDTH-1:0] mem_rd_addr;  // 16-byte aligned

    // read response
    logic                    mem_rsp_valid;
    logic                    mem_rsp_ready;
    logic [  DATA_WIDTH-1:0] mem_rsp_data;  // little-endian

    // write (single phase)
    logic                    mem_wr_valid;
    logic                    mem_wr_ready;
    logic [  ADDR_WIDTH-1:0] mem_wr_addr;  // 16-byte aligned
    logic [  DATA_WIDTH-1:0] mem_wr_data;  // little-endian
    logic [DATA_WIDTH/8-1:0] mem_wr_be;  // byte enables, all ones

    modport master(
        output mem_rd_valid,
        input mem_rd_ready,
        output mem_rd_addr,

        input mem_rsp_valid,
        output mem_rsp_ready,
        input mem_rsp_data,

        output mem_wr_valid,
        input mem_wr_ready,
        output mem_wr_addr,
        output mem_wr_data,
        output mem_wr_be
    );

    modport slave(
        input mem_rd_valid,
        output mem_rd_ready,
        input mem_rd_addr,

        output mem_rsp_valid,
        input mem_rsp_ready,
        output mem_rsp_data,

        input mem_wr_valid,
        output mem_wr_ready,
        input mem_wr_addr,
        input mem_wr_data,
        input mem_wr_be
    );

endinterface
