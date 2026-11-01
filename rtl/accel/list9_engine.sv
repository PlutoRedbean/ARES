//=============================================================================
// ARES - CoreMark list find/reverse/move-to-front engine
//-----------------------------------------------------------------------------
// Executes the hot loop of core_bench_list() for up to 32 nodes:
//
//   for (i = 0; i < seed3; i++) {
//       f = core_list_find(list, &info);      // idx mode, or data16 low byte
//       list = core_list_reverse(list);       // direction bit, O(1)
//       if (!f) { missed++; retval += (list->next->info->data16 >> 8) & 1; }
//       else {
//           found++;
//           if (f->info->data16 & 1) retval += (f->info->data16 >> 9) & 1;
//           if (f->next) move f->next to position 1;   // array shift
//       }
//       if (info.idx >= 0) info.idx++;
//   }
//   retval += found * 4 - missed;
//
// The engine keeps the list in a 32-entry array shadow.  The host writes the
// nodes in logical order, starts the loop, polls DONE and reads the final
// order back; sort/remove/CRC stay in software (cmp_complex calls back into
// the matrix/state engines).
//
// MMIO window (4 KiB, default 0xA000_3000):
//   0x000..0x07C  NODE[0..31]  node address, logical order (read back = final)
//   0x100..0x17C  VAL[0..31]   {idx[31:16], data16[15:0]}
//   0x700         CTRL         bit0 = start
//   0x704         N            node count (3..32)
//   0x708         FINDER       s16 finder_idx (negative = data16 mode)
//   0x70C         SEED3        s16 find count
//   0x710         STATUS       bit0 busy, bit1 done, bit2 final direction
//   0x714         RETVAL       u16 loop partial (includes found*4-missed)
//   0x718         FOUND        u16
//   0x71C         MISSED       u16
//
// One array read port and one write port: the engine and the host never own
// the arrays in the same cycle.  The array read is asynchronous because the
// find compare and the shift both need the current entry in the same cycle;
// the arrays are 32x32 each and map to distributed RAM.
//=============================================================================
module list9_engine (
    input  logic        clk,
    input  logic        rst,

    input  logic        host_req_valid,
    output logic        host_req_ready,
    input  logic        host_write,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] host_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] host_wdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [ 3:0] host_wstrb,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        host_rsp_valid,
    output logic [31:0] host_rsp_data
);

    localparam logic [11:0] CTRL   = 12'h700;
    localparam logic [11:0] N_REG  = 12'h704;
    localparam logic [11:0] FINDER = 12'h708;
    localparam logic [11:0] SEED3  = 12'h70C;
    localparam logic [11:0] STATUS = 12'h710;
    localparam logic [11:0] RETVAL = 12'h714;
    localparam logic [11:0] FOUND  = 12'h718;
    localparam logic [11:0] MISSED = 12'h71C;

    localparam logic [2:0] ST_IDLE     = 3'd0;
    localparam logic [2:0] ST_FIND     = 3'd1;
    localparam logic [2:0] ST_UPD      = 3'd2;
    localparam logic [2:0] ST_MTF_SAVE = 3'd3;
    localparam logic [2:0] ST_MTF_SHIFT= 3'd4;
    localparam logic [2:0] ST_MTF_PUT  = 3'd5;
    localparam logic [2:0] ST_NEXT     = 3'd6;

    //-------------------------------------------------------------------------
    // Array shadow: logical order (the direction bit only changes the mapping
    // between logical position and physical entry, exactly like the software
    // array shadow).
    //-------------------------------------------------------------------------
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [31:0] node_mem [0:31];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [31:0] val_mem  [0:31];

    logic [2:0]  state_q;
    logic [5:0]  n_q;
    logic [15:0] finder_q, seed3_q;
    logic        busy_q, done_q, dir_q;
    logic [15:0] retval_q, found_q, missed_q;
    logic [15:0] i_q;
    logic [5:0]  k_q, fi_q;
    logic [4:0]  save_q, cnt_q;
    logic        found_flag_q;
    logic        match_b0_q, match_b9_q;
    logic [31:0] saved_node_q, saved_val_q;

    //-------------------------------------------------------------------------
    // Host decode
    //-------------------------------------------------------------------------
    wire [11:0] haddr     = host_addr[11:0];
    wire        host_wr   = host_req_valid && host_write;
    wire        data_sel  = haddr < 12'h200;
    wire        is_val    = haddr[8];
    wire        start_pulse = host_wr && (haddr == CTRL) && host_wdata[0] && !busy_q;

    //-------------------------------------------------------------------------
    // Array read port: engine while busy, host while idle
    //-------------------------------------------------------------------------
    logic [4:0] eng_raddr;

    wire [4:0] raddr = busy_q ? eng_raddr : host_addr[6:2];
    wire [31:0] rd_node = node_mem[raddr];
    wire [31:0] rd_val  = val_mem[raddr];

    wire [15:0] cur_idx = rd_val[31:16];

    //-------------------------------------------------------------------------
    // Find key: idx mode increments finder_idx, data mode uses i & 0xff
    //-------------------------------------------------------------------------
    wire        idx_mode = ~finder_q[15];
    wire [15:0] find_key = idx_mode ? (finder_q + i_q) : {8'b0, i_q[7:0]};
    wire        match    = idx_mode ? (cur_idx == find_key)
                                    : (rd_val[7:0] == find_key[7:0]);

    // Logical position -> physical entry under the current direction.
    wire [4:0] phys_now = dir_q ? (n_q[4:0] - 5'd1 - k_q[4:0]) : k_q[4:0];

    // Move-to-front source indices, kept at 6 bits so the intermediate
    // subtraction never wraps; only the low 5 bits index the array.
    wire [5:0] ri_w     = n_q - 6'd1 - fi_q;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [5:0] save_r_w = n_q - fi_q;      // ri + 1
    wire [5:0] lo_w     = n_q - 6'd2 - ri_w;
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        case (state_q)
            ST_FIND:     eng_raddr = phys_now;
            ST_UPD:      eng_raddr = dir_q ? (n_q[4:0] - 5'd2) : 5'd1;
            ST_MTF_SAVE: eng_raddr = save_q;
            ST_MTF_SHIFT: eng_raddr = dir_q ? (cnt_q + 5'd1) : (cnt_q - 5'd1);
            default:     eng_raddr = 5'd0;
        endcase
    end

    //-------------------------------------------------------------------------
    // Array write port: host when idle, engine shift when busy
    //-------------------------------------------------------------------------
    wire        host_wr_data = host_wr && !busy_q && data_sel;
    wire        mtf_shift    = (state_q == ST_MTF_SHIFT);
    wire        mtf_put      = (state_q == ST_MTF_PUT);
    wire        eng_wr       = mtf_shift || mtf_put;
    wire [4:0]  eng_waddr    = mtf_shift ? cnt_q[4:0] :
                               (dir_q ? (n_q[4:0] - 5'd2) : 5'd1);
    wire [31:0] eng_wdata_node = mtf_shift ? rd_node : saved_node_q;
    wire [31:0] eng_wdata_val  = mtf_shift ? rd_val  : saved_val_q;

    always_ff @(posedge clk) begin
        if (host_wr_data) begin
            if (is_val) val_mem[haddr[6:2]]  <= host_wdata;
            else        node_mem[haddr[6:2]] <= host_wdata;
        end else if (eng_wr) begin
            node_mem[eng_waddr] <= eng_wdata_node;
            val_mem[eng_waddr]  <= eng_wdata_val;
        end
    end

    //-------------------------------------------------------------------------
    // Host read mux
    //-------------------------------------------------------------------------
    logic [31:0] host_rdata;

    always_comb begin
        host_rdata = 32'h0;
        if (data_sel && !busy_q)
            host_rdata = is_val ? val_mem[host_addr[6:2]]
                                : node_mem[host_addr[6:2]];
        else begin
            case (haddr)
                CTRL:   host_rdata = {29'b0, dir_q, done_q, busy_q};
                N_REG:  host_rdata = {26'b0, n_q};
                FINDER: host_rdata = {{16{finder_q[15]}}, finder_q};
                SEED3:  host_rdata = {{16{seed3_q[15]}}, seed3_q};
                STATUS: host_rdata = {29'b0, dir_q, done_q, busy_q};
                RETVAL: host_rdata = {16'b0, retval_q};
                FOUND:  host_rdata = {16'b0, found_q};
                MISSED: host_rdata = {16'b0, missed_q};
                default: host_rdata = 32'h0;
            endcase
        end
    end

    assign host_req_ready = 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            host_rsp_valid <= 1'b0;
            host_rsp_data  <= 32'h0;
        end else begin
            host_rsp_valid <= host_req_valid;
            host_rsp_data  <= host_wr ? 32'h0 : host_rdata;
        end
    end

    //-------------------------------------------------------------------------
    // Control registers
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            n_q      <= 6'd0;
            finder_q <= 16'd0;
            seed3_q  <= 16'd0;
        end else if (host_wr && !busy_q) begin
            case (haddr)
                N_REG:  n_q      <= host_wdata[5:0];
                FINDER: finder_q <= host_wdata[15:0];
                SEED3:  seed3_q  <= host_wdata[15:0];
                default: ;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Main FSM
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q     <= ST_IDLE;
            busy_q      <= 1'b0;
            done_q      <= 1'b0;
            dir_q       <= 1'b0;
            retval_q    <= 16'd0;
            found_q     <= 16'd0;
            missed_q    <= 16'd0;
            i_q         <= 16'd0;
            k_q         <= 6'd0;
            fi_q        <= 6'd0;
            save_q      <= 5'd0;
            cnt_q       <= 5'd0;
            found_flag_q<= 1'b0;
            match_b0_q  <= 1'b0;
            match_b9_q  <= 1'b0;
            saved_node_q<= 32'd0;
            saved_val_q <= 32'd0;
        end else if (start_pulse) begin
            busy_q      <= 1'b1;
            done_q      <= 1'b0;
            dir_q       <= 1'b0;
            retval_q    <= 16'd0;
            found_q     <= 16'd0;
            missed_q    <= 16'd0;
            i_q         <= 16'd0;
            k_q         <= 6'd0;
            found_flag_q<= 1'b0;
            if ((n_q < 6'd3) || (seed3_q == 16'd0) || seed3_q[15]) begin
                busy_q <= 1'b0;
                done_q <= 1'b1;
                state_q <= ST_IDLE;
            end else begin
                state_q <= ST_FIND;
            end
        end else begin
            case (state_q)
                ST_FIND: begin
                    if (k_q >= n_q) begin
                        found_flag_q <= 1'b0;
                        dir_q <= ~dir_q;
                        state_q <= ST_UPD;
                    end else if (match) begin
                        found_flag_q <= 1'b1;
                        fi_q <= k_q;
                        match_b0_q <= rd_val[0];
                        match_b9_q <= rd_val[9];
                        dir_q <= ~dir_q;
                        state_q <= ST_UPD;
                    end else if ((k_q + 6'd1) >= n_q) begin
                        found_flag_q <= 1'b0;
                        dir_q <= ~dir_q;
                        state_q <= ST_UPD;
                    end else begin
                        k_q <= k_q + 6'd1;
                    end
                end

                ST_UPD: begin
                    if (!found_flag_q) begin
                        missed_q <= missed_q + 16'd1;
                        retval_q <= retval_q + {15'b0, rd_val[8]};
                        state_q  <= ST_NEXT;
                    end else begin
                        found_q <= found_q + 16'd1;
                        if (match_b0_q)
                            retval_q <= retval_q + {15'b0, match_b9_q};
                        if ((ri_w > 6'd0) && ((ri_w + 6'd1) < n_q)) begin
                            if (!dir_q) begin
                                save_q <= save_r_w[4:0];   // ri + 1
                                cnt_q  <= save_r_w[4:0];
                            end else begin
                                save_q <= lo_w[4:0];       // fi - 1
                                cnt_q  <= lo_w[4:0];
                            end
                            state_q <= ST_MTF_SAVE;
                        end else begin
                            state_q <= ST_NEXT;
                        end
                    end
                end

                ST_MTF_SAVE: begin
                    saved_node_q <= rd_node;
                    saved_val_q  <= rd_val;
                    state_q <= ST_MTF_SHIFT;
                end

                ST_MTF_SHIFT: begin
                    if (!dir_q) begin
                        if (cnt_q == 5'd2) state_q <= ST_MTF_PUT;
                        else               cnt_q <= cnt_q - 5'd1;
                    end else begin
                        if (cnt_q == (n_q[4:0] - 5'd3)) state_q <= ST_MTF_PUT;
                        else                           cnt_q <= cnt_q + 5'd1;
                    end
                end

                ST_MTF_PUT: begin
                    state_q <= ST_NEXT;
                end

                ST_NEXT: begin
                    i_q <= i_q + 16'd1;
                    if ((i_q + 16'd1) >= seed3_q) begin
                        retval_q <= retval_q + {found_q[13:0], 2'b00} - missed_q;
                        busy_q   <= 1'b0;
                        done_q   <= 1'b1;
                        state_q  <= ST_IDLE;
                    end else begin
                        k_q <= 6'd0;
                        state_q <= ST_FIND;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
