//=============================================================================
// ARES pipeline SoC - per-hart memory port adapter
//-----------------------------------------------------------------------------
// Converts the pipeline core's 32-bit perip interface into:
//   * one 16 B-beat port on the coherent shared L2 (cacheable DRAM window)
//   * one MMIO request port (all other addresses)
//
// At most one core request is outstanding.  That restriction makes the
// response selection (L2 word lane vs. MMIO register) a registered mux and
// prevents a younger MMIO read from overtaking an older cacheable read.  The
// core is in-order, so this costs little and keeps the adapter's control path
// small.  The L2 itself remains the only shared/coherent block.
//=============================================================================
module pipeline_core_port (
    input  wire        clk,
    input  wire        rst,

    //---- pipeline core perip interface ------------------------------------
    input  wire        perip_valid,
    output wire        perip_ready,
    output wire        perip_rvalid,
    input  wire [31:0] perip_addr,
    input  wire        perip_wen,
    input  wire [ 1:0] perip_mask,
    input  wire [31:0] perip_wdata,
    output wire [31:0] perip_rdata,
    output wire        perip_idle,

    //---- shared L2 port ----------------------------------------------------
    output wire         l2_rd_valid,
    input  wire         l2_rd_ready,
    output wire [ 31:0] l2_rd_addr,
    input  wire         l2_rsp_valid,
    output wire         l2_rsp_ready,
    input  wire [127:0] l2_rsp_data,
    output wire         l2_wr_valid,
    input  wire         l2_wr_ready,
    output wire [ 31:0] l2_wr_addr,
    output wire [127:0] l2_wr_data,
    output wire [ 15:0] l2_wr_be,

    //---- shared MMIO port --------------------------------------------------
    output wire        mmio_req_valid,
    input  wire        mmio_req_ready,
    output wire        mmio_write,
    output wire [31:0] mmio_addr,
    output wire [31:0] mmio_wdata,
    output wire [ 3:0] mmio_wstrb,
    input  wire        mmio_rsp_valid,
    output wire        mmio_rsp_ready,
    input  wire [31:0] mmio_rsp_data,

    //---- activity ----------------------------------------------------------
    input  wire        l2_idle,
    input  wire        mmio_idle
);
    // Cacheable DRAM window: 0x8010_0000..0x8013_FFFF.  This is the same
    // window the pipeline L1 D-cache tags, so the L1 and L2 agree on what is
    // cacheable.
    wire is_dram = (perip_addr[31:18] == 14'b1000_0000_0001_00);

    function automatic [3:0] strobe4(input [1:0] mask, input [1:0] low);
        begin
            case (mask)
                2'b10:   strobe4 = 4'b1111;
                2'b01:   strobe4 = low[1] ? 4'b1100 : 4'b0011;
                2'b00:   strobe4 = 4'b0001 << low;
                default: strobe4 = 4'b0000;
            endcase
        end
    endfunction

    function automatic [31:0] align_word(input [31:0] wdata, input [1:0] mask);
        begin
            case (mask)
                2'b10:   align_word = wdata;
                2'b01:   align_word = {2{wdata[15:0]}};
                2'b00:   align_word = {4{wdata[7:0]}};
                default: align_word = 32'd0;
            endcase
        end
    endfunction

    wire [3:0]  wstrb     = strobe4(perip_mask, perip_addr[1:0]);
    wire [31:0] wword     = align_word(perip_wdata, perip_mask);
    wire [3:0]  word_off  = {perip_addr[3:2], 2'b00};

    // One outstanding core request.  A response is always consumed from the
    // adapter, so the core sees one rvalid per accepted read.
    reg         rsp_pending_q;
    reg         rsp_from_l2_q;
    reg  [1:0]  rsp_word_q;
    // Do not accept the same core request twice.  The pipeline can keep
    // perip_valid asserted while its downstream stage is stalled; once the
    // adapter has performed a request it waits for valid to drop before
    // accepting another one.  Without this a stalled store could be committed
    // repeatedly and a read could receive duplicate responses.
    reg         hold_q;

    wire can_issue = ~rsp_pending_q && ~hold_q;

    assign l2_rd_valid  = perip_valid && ~perip_wen &&  is_dram && can_issue;
    assign l2_rd_addr   = {perip_addr[31:4], 4'b0000};
    assign l2_wr_valid  = perip_valid &&  perip_wen &&  is_dram && can_issue;
    assign l2_wr_addr   = {perip_addr[31:4], 4'b0000};
    assign l2_wr_data   = {4{wword}};
    assign l2_wr_be     = {12'b0, wstrb} << word_off;

    assign mmio_req_valid = perip_valid && ~is_dram && can_issue;
    assign mmio_write     = perip_wen;
    assign mmio_addr      = perip_addr;
    assign mmio_wdata     = perip_wdata;
    assign mmio_wstrb     = wstrb;

    assign perip_ready = can_issue &&
        (is_dram ? (perip_wen ? l2_wr_ready : l2_rd_ready)
                 : mmio_req_ready);

    // Response mux is selected by a registered source/word index, not by the
    // live perip address.
    assign l2_rsp_ready   = rsp_pending_q && rsp_from_l2_q;
    assign mmio_rsp_ready = rsp_pending_q && ~rsp_from_l2_q;

    wire [6:0] rsp_bit = {rsp_word_q, 5'b00000};
    assign perip_rvalid = rsp_pending_q &&
                          (rsp_from_l2_q ? l2_rsp_valid : mmio_rsp_valid);
    assign perip_rdata  = rsp_from_l2_q
                          ? l2_rsp_data[rsp_bit +: 32]
                          : mmio_rsp_data;

    assign perip_idle = l2_idle && mmio_idle && ~rsp_pending_q &&
                        ~perip_valid;

    always @(posedge clk) begin
        if (rst) begin
            rsp_pending_q <= 1'b0;
            rsp_from_l2_q <= 1'b0;
            rsp_word_q    <= 2'd0;
            hold_q        <= 1'b0;
        end else begin
            if (perip_valid && perip_ready) begin
                hold_q <= 1'b1;
            end else if (!perip_valid) begin
                hold_q <= 1'b0;
            end

            if (perip_valid && perip_ready && !perip_wen) begin
                rsp_pending_q <= 1'b1;
                rsp_from_l2_q <= is_dram;
                rsp_word_q    <= perip_addr[3:2];
            end else if (rsp_pending_q &&
                         (rsp_from_l2_q ? l2_rsp_valid : mmio_rsp_valid)) begin
                rsp_pending_q <= 1'b0;
            end
        end
    end

endmodule
