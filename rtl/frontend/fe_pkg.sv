package fe_pkg;

    // ------------------
    // Base parameters
    // ------------------
    localparam int unsigned ADDR_WIDTH = 32;
    localparam int unsigned DATA_WIDTH = 32;
    localparam int unsigned INST_WIDTH = 32;
    localparam int unsigned FETCH_WIDTH = 4;
    localparam int unsigned INST_BYTES = INST_WIDTH / 8;

    // ------------------
    // IQ parameters
    // ------------------
    localparam int unsigned DECODE_WIDTH = 2;
    localparam int unsigned IQ_DEPTH = 128;

    // ------------------
    // FTQ parameters
    // ------------------
    localparam int unsigned FTQ_NUM_ENTRIES = 16;

    // ------------------
    // BTB parameters
    // ------------------
    localparam int unsigned PHT_WIDTH = 10;
    localparam int unsigned UBTB_WIDTH = 4;
    localparam int unsigned GHR_WIDTH = 12;
    /* verilator lint_off UNUSEDPARAM */
    localparam int unsigned MBTB_WIDTH = 11;
    /* verilator lint_on UNUSEDPARAM */

    // Comment out to disable the loop predictor (and its override of the
    // tournament direction predictor).
    `define LOOP_PRED_ON

    // Return address stack.  Comment out RAS_ON to disable it (returns then
    // fall back to the uBTB target), and change RAS_DEPTH to resize it.
    `define RAS_ON
    `define TOURNAMENT_ON

`ifdef LOOP_PRED_ON
    // ------------------
    // Loop predictor parameters
    // ------------------
    localparam int unsigned LOOP_ENTRIES = 256;
    localparam int unsigned LOOP_ITER_WIDTH = 8;
`endif

`ifdef RAS_ON
    // ------------------
    // RAS parameters
    // ------------------
    parameter int unsigned RAS_ENTRIES = 16;
`endif

`ifdef TOURNAMENT_ON
    localparam int unsigned DIR_TYPE = 2;
`else
    localparam int unsigned DIR_TYPE = 1;
`endif

    /*
     * CFI type
     */
    typedef enum logic [2:0] {
        CFI_NONE = '0,
        CFI_BRANCH,
        CFI_DIRECT_JUMP,
        CFI_CALL,
        CFI_RETURN,
        CFI_INDIRECT_JUMP
    } cfi_type_t;

    /*
     * Direction predictor metadata.
     */
    // Tournament chooser metadata captured at prediction time: the two
    // component predictions fed to the chooser and the GHR gshare indexed with.
    // These let the speculative RTL train the components with the exact state
    // they used.  The chooser itself is read-modify-written at update time.
    typedef struct packed {
        logic                 update_gshare_taken;
        logic                 update_bimodal_taken;
        logic [GHR_WIDTH-1:0] pred_ghr;
    } chooser_meta_t;

    typedef struct packed {
        logic [ADDR_WIDTH-1:0] pred_target;
        logic                  pred_taken;

`ifdef TOURNAMENT_ON
        chooser_meta_t chooser_meta;
        logic          loop_override;  // direction came from the loop predictor
`endif
    } pred_meta_t;

    /*
     * FTQ Entry packed data
     */

    typedef struct packed {
        // Fetch Block
        logic [ADDR_WIDTH-1:0] start_pc;

        // Per-slot prediction (one entry per instruction slot of the block)
        logic [FETCH_WIDTH-1:0]       pred_cfi_valid;  // BTB knows a CFI here
        cfi_type_t [FETCH_WIDTH-1:0]  pred_cfi_type;
        pred_meta_t [FETCH_WIDTH-1:0] pred_meta;

    } ftq_entry_t;

    /*
     * IQ Entry packed data
     */

    typedef struct packed {

        // Instruction PC (needed by the multi-cycle NPC back-end)
        logic [ADDR_WIDTH - 1:0] pc;

        // BPU metadata
        pred_meta_t pred_meta;

        // Instruction
        logic [31:0] inst;
        logic        valid;  // 指令是否有效

        cfi_type_t cfi_type;  // is_jal is_jalr is_branch is_call is_ret
        logic is_cfi;  // control flow instruction
    } iq_entry_t;

    /*
     * BTB Entry packed data
     */

    typedef struct packed {
        logic [ADDR_WIDTH-1:0]    start_pc;
        logic [ADDR_WIDTH-1:0]    target_pc;
        // CFI Information
        cfi_type_t                cfi_type;
        logic [FETCH_WIDTH - 1:0] cfi_offset;  // CFI 在 fetch block 中的 slot 位置
    } btb_target_info_t;

    // One CFI slot of a Fetch Block (multi-target BTB record)
    typedef struct packed {
        logic [FETCH_WIDTH - 1:0] cfi_offset;  // CFI 在 block 内的 slot 位置
        cfi_type_t                cfi_type;
        logic [ADDR_WIDTH-1:0]    target_pc;
    } btb_cfi_t;

    typedef struct packed {
        logic [1:0] useful_cnt;  // 借鉴XiangShan kunminghu-v3 中的useful counter
        logic [ADDR_WIDTH - 1:$clog2(FETCH_WIDTH * INST_BYTES)] tag;

        // Information for fetch block (up to FETCH_WIDTH CFIs, block-relative)
        logic [$clog2(FETCH_WIDTH + 1) - 1:0] cfi_count;
        btb_cfi_t [FETCH_WIDTH - 1:0]         cfi;
    } btb_entry_t;

    /*
     * BPU Update metadata packed data
     */

    typedef struct packed {
        // resolution of the CFI
        logic [ADDR_WIDTH - 1:0] update_pc;
        logic                    actual_taken;
        logic                    is_branch;     // conditional branch (opcode 0x63)
        btb_target_info_t        actual_info;

        // the prediction that was made for this instruction; needed by the
        // direction predictor to train the state it used at predict time
        pred_meta_t pred_meta;
    } update_meta_t;

endpackage
