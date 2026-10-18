`include "ares_autoconf.vh"

// The generated configuration header selects the ICache backing bus through
// CONFIG_IO_USE_AXI, while the front-end RTL tests the shorter `IO_USE_AXI
// macro (originally defined by rtl/frontend/include/autoconf.vh).  Bridge the
// two here so the modules keep their historical macro name.
`ifdef CONFIG_IO_USE_AXI
    `define IO_USE_AXI 1
`endif

package fe_pkg;

// These parameters are sized for the front-end modules.  A core-only build
// (sim, backend/lsu lint) compiles this package without them, so the ones the
// front-end alone consumes legitimately look unused there.
/* verilator lint_off UNUSEDPARAM */

    // ------------------
    // Base parameters
    // ------------------
    localparam int unsigned ADDR_WIDTH = `CONFIG_FE_ADDR_WIDTH;
    localparam int unsigned DATA_WIDTH = `CONFIG_FE_DATA_WIDTH;
    localparam int unsigned INST_WIDTH = `CONFIG_FE_INST_WIDTH;
    localparam int unsigned FETCH_WIDTH = `CONFIG_FE_FETCH_WIDTH;
    localparam int unsigned INST_BYTES = INST_WIDTH / 8;
    localparam int unsigned RESET_VEC = 32'h8000_0000;

    // ------------------
    // IQ parameters
    // ------------------
    localparam int unsigned DECODE_WIDTH = `CONFIG_FE_DECODE_WIDTH;
    localparam int unsigned BODY_DEPTH = `CONFIG_FE_BODY_DEPTH;
    localparam int unsigned IQ_DEPTH = BODY_DEPTH + DECODE_WIDTH;


    // ------------------
    // FTQ parameters
    // ------------------
    localparam int unsigned FTQ_NUM_ENTRIES = `CONFIG_FE_FTQ_NUM_ENTRIES;

    // ------------------
    // I-cache parameters
    // ------------------
    localparam int unsigned ICACHE_LINE_BYTES = `CONFIG_FE_ICACHE_LINE_BYTES;
    localparam int unsigned ICACHE_NR_SETS = `CONFIG_FE_ICACHE_NR_SETS;
    localparam int unsigned ICACHE_NR_WAYS = `CONFIG_FE_ICACHE_NR_WAYS;

    // ------------------
    // BTB parameters
    // ------------------
    localparam int unsigned PHT_WIDTH = `CONFIG_FE_PHT_WIDTH;
    localparam int unsigned UBTB_WIDTH = `CONFIG_FE_UBTB_WIDTH;
    localparam int unsigned GHR_WIDTH = `CONFIG_FE_GHR_WIDTH;
    localparam int unsigned MBTB_WIDTH = `CONFIG_FE_MBTB_WIDTH;

    // ------------------
    // Tournament predictor parameters
    // ------------------
    localparam int unsigned CHOOSER_WIDTH = 10;
    localparam int unsigned BPU_UPDATE_FIFO_DEPTH = 8;

    // Return address stack.  RAS_ON enables it; returns otherwise fall back to
    // the uBTB target.
`ifdef CONFIG_FE_RAS
    `define RAS_ON
    // ------------------
    // RAS parameters
    // ------------------
    parameter int unsigned RAS_ENTRIES = `CONFIG_FE_RAS_ENTRIES;
`endif

    // Loop predictor.  It overrides the direction of whichever direction
    // predictor is selected (Bimodal or Tournament) and is independent of it.
`ifdef CONFIG_FE_LOOP_PRED
    `define LOOP_PRED_ON
    // ------------------
    // Loop predictor parameters
    // ------------------
    localparam int unsigned LOOP_ENTRIES = `CONFIG_FE_LOOP_ENTRIES;
    localparam int unsigned LOOP_ITER_WIDTH = `CONFIG_FE_LOOP_ITER_WIDTH;
`endif

    // Tournament predictor.  Disabled selects the plain Bimodal + uBTB
    // configuration (DIR_TYPE == 1).
`ifdef CONFIG_FE_TOURNAMENT
    `define TOURNAMENT_ON
    localparam int unsigned DIR_TYPE = 2;
`else
    localparam int unsigned DIR_TYPE = 1;
`endif

    // Instruction cache backing bus: `IO_USE_AXI selects the AXI4-Lite master,
    // otherwise the miniTensor uncached read handshake is used.  The macro is
    // derived from CONFIG_IO_USE_AXI by the bridge at the top of this file.

/* verilator lint_on UNUSEDPARAM */

    /*
     * CFI type
     */
    typedef enum logic [2:0] {
        CFI_NONE = '0,
        CFI_COND_BRANCH,
        CFI_DIRECT_JUMP,
        CFI_CALL,
        CFI_RETURN,
        CFI_INDIRECT_JUMP
    } cfi_type_t;

    // Redirect kind (frontend_backend_contract.md section 3)
    typedef enum logic {
        REDIRECT_BRANCH = 1'b0,
        REDIRECT_ARCH   = 1'b1
    } fe_redirect_kind_t;

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

    // Fixed cross-boundary layout, independent of predictor feature switches.
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] pred_target;  // original predictor target
        logic pred_taken;
        cfi_type_t pred_type;
        logic [GHR_WIDTH-1:0] ghr_before;    // full per-slot recovery snapshot
        chooser_meta_t chooser_meta;        // actual table lookup history
        logic loop_override;
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

        logic [ADDR_WIDTH-1:0] pred_npc; // effective next PC after predecode
        // Original prediction, never rewritten by predecode/backend.
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
     * BPU training event (frontend_backend_contract.md section 4)
     */

    typedef struct packed {
        logic [ADDR_WIDTH-1:0] update_pc;        // PC of the resolved CFI
        logic                  actual_taken;     // JAL/JALR are always taken
        logic [ADDR_WIDTH-1:0] actual_target;    // BRU computed target
        cfi_type_t             actual_cfi_type;  // Decode-confirmed true CFI class
        pred_meta_t            pred_meta;        // raw prediction + ghr snapshot
    } bpu_update_t;

endpackage
