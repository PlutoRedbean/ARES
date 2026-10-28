`include "ares_autoconf.vh"

`ifdef CONFIG_IO_USE_AXI
    `define IO_USE_AXI 1
`endif
package fe_pkg;

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
    // uBTB (small, fast target BTB)
    // ------------------
    // 32B region, 8 bank x 8 way (bank = tag low bits), two CFI slots per entry.
    localparam int unsigned UBTB_ENTRIES = 1 << UBTB_WIDTH;  // 256
    localparam int unsigned UBTB_BANKS = 16;
    localparam int unsigned UBTB_WAYS = UBTB_ENTRIES / UBTB_BANKS;
    localparam int unsigned UBTB_BANK_SEL_WIDTH = (UBTB_BANKS > 1) ? $clog2(UBTB_BANKS) : 1;
    localparam int unsigned UBTB_REGION_WIDTH = 5;  // 32B region
    localparam int unsigned UBTB_REGION_BYTES = 1 << UBTB_REGION_WIDTH;
    localparam int unsigned UBTB_TAG_WIDTH = ADDR_WIDTH - UBTB_REGION_WIDTH;
    localparam int unsigned UBTB_WAY_TAG_WIDTH = UBTB_TAG_WIDTH - UBTB_BANK_SEL_WIDTH;
    localparam int unsigned UBTB_POS_WIDTH = 3;  // 8 instr per 32B
    localparam int unsigned UBTB_SLOT_NUM = 2;
    localparam int unsigned UBTB_USEFUL_CNT_WIDTH = 2;
    localparam int unsigned UBTB_PRED_LATENCY = 1;

    // ------------------
    // mBTB (Region-BTB, one CFI per way, SRAM)
    // ------------------
    // 16B region (= fetch block); MBTB_WIDTH=7 -> 128 sets x 4 ways.
    localparam int unsigned MBTB_SET_NUM = 1 << MBTB_WIDTH;
    localparam int unsigned MBTB_WAYS = 4;
    localparam int unsigned MBTB_ENTRIES = MBTB_SET_NUM * MBTB_WAYS;  // 2048
    localparam int unsigned MBTB_REGION_WIDTH = 4;  // 16B
    localparam int unsigned MBTB_REGION_BYTES = 1 << MBTB_REGION_WIDTH;
    localparam int unsigned MBTB_IDX_WIDTH = $clog2(MBTB_SET_NUM);
    localparam int unsigned MBTB_TAG_WIDTH = ADDR_WIDTH - MBTB_REGION_WIDTH - MBTB_IDX_WIDTH;
    localparam int unsigned MBTB_POS_WIDTH = 2;  // 4 instr per 16B
    localparam int unsigned MBTB_TARGET_WIDTH = 22;
    localparam int unsigned MBTB_PRED_LATENCY = 2;
    localparam int unsigned MBTB_LRU_BITS = MBTB_WAYS * (MBTB_WAYS - 1) / 2;

    // ------------------
    // Tournament predictor parameters
    // ------------------
    localparam int unsigned CHOOSER_WIDTH = PHT_WIDTH;
    localparam int unsigned BPU_UPDATE_FIFO_DEPTH = 8;
    localparam int unsigned PRED_CKPT_DEPTH = `CONFIG_FE_TAGE_CKPT_DEPTH;
    localparam int unsigned PRED_CKPT_W = $clog2(PRED_CKPT_DEPTH);

    // Return address stack (target predictor override).  CONFIG_FE_RAS enables
    // it; returns otherwise fall back to the BTB target.
`ifdef CONFIG_FE_RAS
    // ------------------
    // RAS parameters
    // ------------------
    localparam int unsigned RAS_ENTRIES = `CONFIG_FE_RAS_ENTRIES;
`endif

    // Loop predictor (direction override).  It overrides the direction of
    // whichever direction predictor is selected (Bimodal or Tournament) and is
    // independent of it.
`ifdef CONFIG_FE_LOOP_PRED
    // ------------------
    // Loop predictor parameters
    // ------------------
    localparam int unsigned LOOP_ENTRIES = `CONFIG_FE_LOOP_ENTRIES;
    localparam int unsigned LOOP_ITER_WIDTH = `CONFIG_FE_LOOP_ITER_WIDTH;
`endif

    // Direction predictor selection is done directly with the CONFIG_FE_*
    // macros in bpu (CONFIG_FE_BIMODAL / CONFIG_FE_TOURNAMENT, mutually
    // exclusive) and with CONFIG_FE_TAGE for the S2 precise direction.

`ifdef CONFIG_FE_TAGE

`ifndef CONFIG_FE_TAGE_NUM_TABLES
    `define CONFIG_FE_TAGE_NUM_TABLES 8
`endif
`ifndef CONFIG_FE_TAGE_GHV_WIDTH
    `define CONFIG_FE_TAGE_GHV_WIDTH 256
`endif
`ifndef CONFIG_FE_TAGE_INDEX_WIDTH
    `define CONFIG_FE_TAGE_INDEX_WIDTH 10
`endif
`ifndef CONFIG_FE_TAGE_TAG_WIDTH
    `define CONFIG_FE_TAGE_TAG_WIDTH 13
`endif
`ifndef CONFIG_FE_TAGE_CTR_WIDTH
    `define CONFIG_FE_TAGE_CTR_WIDTH 5
`endif
`ifndef CONFIG_FE_TAGE_USEFUL_WIDTH
    `define CONFIG_FE_TAGE_USEFUL_WIDTH 2
`endif
`ifndef CONFIG_FE_TAGE_CKPT_DEPTH
    `define CONFIG_FE_TAGE_CKPT_DEPTH 64
`endif
`ifndef CONFIG_FE_TAGE_USE_ALT_ON_NA
    `define CONFIG_FE_TAGE_USE_ALT_ON_NA 1
`endif

    localparam int unsigned TAGE_NUM_TABLES = `CONFIG_FE_TAGE_NUM_TABLES;
    localparam int unsigned TAGE_HIST_MAX = 256;
    // Keep the full length table independent of the enabled table count so the
    // table count can be tuned from Kconfig without editing this file.
    localparam int unsigned TAGE_NUM_HIST = 9;
    // XiangShan-style geometric history lengths.
    localparam int unsigned TAGE_HIST_LENGTH[TAGE_NUM_HIST] = '{4, 8, 13, 21, 34, 55, 89, 144, 233};
    localparam int unsigned TAGE_GHV_WIDTH = `CONFIG_FE_TAGE_GHV_WIDTH;
    localparam int unsigned TAGE_INDEX_WIDTH = `CONFIG_FE_TAGE_INDEX_WIDTH;
    localparam int unsigned TAGE_TAG_WIDTH = `CONFIG_FE_TAGE_TAG_WIDTH;
    localparam int unsigned TAGE_CTR_WIDTH = `CONFIG_FE_TAGE_CTR_WIDTH;
    localparam int unsigned TAGE_USEFUL_WIDTH = `CONFIG_FE_TAGE_USEFUL_WIDTH;
    localparam int unsigned TAGE_CKPT_DEPTH = `CONFIG_FE_TAGE_CKPT_DEPTH;
    localparam int unsigned TAGE_HASH_WIDTH = 64;
    // Four ways per set, selected by the instruction slot.  This keeps a
    // branch's TAGE entry stable across uBTB/mBTB CFI-coverage changes.  Each
    // table is 4 banks x 64 sets x 4 ways = 1024 entries; 8 tables with
    // tag10/counter4/useful1 are 16 KiB.
    localparam int unsigned TAGE_NUM_SLOTS = FETCH_WIDTH;
    localparam int unsigned TAGE_NUM_BANKS = 4;
    localparam int unsigned TAGE_TAGGED_ENTRIES = (1 << `CONFIG_FE_TAGE_INDEX_WIDTH) * TAGE_NUM_SLOTS;
    localparam int unsigned TAGE_SETS = TAGE_TAGGED_ENTRIES / (TAGE_NUM_BANKS * TAGE_NUM_SLOTS);
    localparam int unsigned TAGE_SET_WIDTH = $clog2(TAGE_SETS);
    localparam int unsigned TAGE_BASE_NUM_BANKS = 4;
    localparam int unsigned TAGE_BASE_ENTRIES_PER_BANK = 1024;
    localparam int unsigned TAGE_BASE_INDEX_WIDTH = 10;
    localparam int unsigned USE_ALT_ON_NA_ENTRIES = 128;
    localparam bit TAGE_USE_ALT_ON_NA = (`CONFIG_FE_TAGE_USE_ALT_ON_NA != 0);
    localparam bit TAGE_ALLOC_RANDOM_EN = 1'b0;
    localparam int unsigned TAGE_SLOT_WIDTH = (TAGE_NUM_SLOTS > 1) ? $clog2(TAGE_NUM_SLOTS) : 1;
    localparam int unsigned TAGE_PROVIDER_WIDTH = $clog2(TAGE_NUM_TABLES + 1);
    localparam int unsigned TAGE_SLOT_ID_WIDTH = (FETCH_WIDTH > 1) ? $clog2(FETCH_WIDTH) : 1;
    localparam int unsigned TAGE_CKPT_PTR_WIDTH = $clog2(TAGE_CKPT_DEPTH);
    // Per-block TAGE hash side table: idx/tag are identical for every slot of a
    // fetch block, so they are stored once per block and the per-slot metadata
    // only keeps a pointer + generation.  The ring write pointer is monotonic
    // (never rolled back on redirects), so an entry stays valid until it wraps.
    localparam int unsigned TAGE_BLOCK_META_DEPTH = 128;
    localparam int unsigned TAGE_BLOCK_META_PTR_WIDTH = $clog2(TAGE_BLOCK_META_DEPTH);
    localparam int unsigned TAGE_BLOCK_META_SEQ_WIDTH = 8;
    localparam int unsigned TAGE_COND_PREFIX_WIDTH = $clog2(FETCH_WIDTH + 1);

    // ------------------------------------------------------------------
    // Micro-TAGE (uTAGE): fast S1 direction predictor, modeled after the
    // XiangShan frontend MicroTage.  Two 512-set, 1-way tables with short
    // folded histories (5/9) and an instruction-position tag; the T0 base
    // table is the fallback.  The full TAGE above remains the S2 predictor.
    // ------------------------------------------------------------------
    localparam int unsigned UTAGE_NUM_TABLES = 2;
    localparam int unsigned UTAGE_NUM_HIST = 2;
    localparam int unsigned UTAGE_HIST_LENGTH[UTAGE_NUM_HIST] = '{9, 21};
    localparam int unsigned UTAGE_PROVIDER_WIDTH = (UTAGE_NUM_TABLES > 1) ? $clog2(
        UTAGE_NUM_TABLES
    ) : 1;
    localparam int unsigned UTAGE_INDEX_WIDTH = 8;  // 256 sets
    localparam int unsigned UTAGE_TAG_WIDTH = 12;
    localparam int unsigned UTAGE_CTR_WIDTH = 3;
    // One entry per instruction slot (like the full TAGE), so several
    // conditional branches in the same block do not fight for one entry.
    localparam int unsigned UTAGE_SLOT_NUM = FETCH_WIDTH;
    localparam int unsigned UTAGE_POS_WIDTH = (FETCH_WIDTH > 1) ? $clog2(FETCH_WIDTH) : 1;

    typedef struct packed {
        logic                       valid;
        logic [UTAGE_TAG_WIDTH-1:0] tag;
        logic [UTAGE_CTR_WIDTH-1:0] ctr;
    } utage_entry_t;

    // Prediction-time snapshot carried in the FTQ for training.
    typedef struct packed {
        logic valid;  // conditional branch in this slot
        logic hit;
        logic [UTAGE_PROVIDER_WIDTH-1:0] provider;  // tagged table id
        logic [UTAGE_POS_WIDTH-1:0] pos;
        logic [UTAGE_NUM_TABLES-1:0][UTAGE_INDEX_WIDTH-1:0] idx;
        logic [UTAGE_NUM_TABLES-1:0][UTAGE_TAG_WIDTH-1:0] tag;
        logic pred;
    } utage_meta_t;
`endif

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

`ifdef CONFIG_FE_TAGE
    /*
     * TAGE per-slot metadata (docs/tage-design.md §5).
     *
     * One entry is stored per fetch-block slot in the FTQ.  `valid=1` marks a
     * slot TAGE manages (one of the first two conditional branches of the
     * block); `valid=0` marks a non-conditional CFI or a 3rd+ branch, which only
     * fall back to the base (T0) table.  `ckpt_ptr` / `cond_prefix` are valid
     * for every slot because a redirect may be triggered by any CFI.
     */
    typedef struct packed {
        logic valid;  // TAGE-managed conditional branch
        logic meta_valid;  // the S2 backfill wrote this meta (ckpt_ptr/cond_prefix usable)
        logic provided;  // a tagged provider exists
        logic [TAGE_PROVIDER_WIDTH-1:0] provider;  // longest-history hit (0 = T0)
        logic [TAGE_CTR_WIDTH-1:0] provider_ctr;  // tagged provider ctr snapshot
        logic [1:0] base_ctr;  // T0 snapshot (RMW)
        logic provider_pred;
        logic alt_pred;
        logic tage_pred;  // TAGE own direction (pre loop override)
        logic [TAGE_BLOCK_META_PTR_WIDTH-1:0] block_ptr;  // per-block idx/tag ring
        logic [TAGE_BLOCK_META_SEQ_WIDTH-1:0] block_seq;  // ring generation
        logic [TAGE_SLOT_ID_WIDTH-1:0] slot_id;  // instruction slot (T0 bank)
        logic [TAGE_CKPT_PTR_WIDTH-1:0] ckpt_ptr;  // block-before history checkpoint
        logic [TAGE_COND_PREFIX_WIDTH-1:0] cond_prefix;  // on-path cond branches before slot
`ifdef CONFIG_FE_UTAGE
        utage_meta_t utage;  // S1 fast-predictor state (trained at commit)
`endif
    } tage_meta_t;
`endif

    // Base FE/BE recovery fields remain present in every predictor mode.
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] pred_target;
        logic pred_taken;
        cfi_type_t pred_type;
        logic [GHR_WIDTH-1:0] ghr_before;
        chooser_meta_t chooser_meta;
        logic loop_override;
        logic loop_taken;
        logic [PRED_CKPT_W-1:0] ras_ckpt_ptr;
`ifdef CONFIG_FE_TAGE
        tage_meta_t tage_meta;
`endif
        logic [$clog2(FETCH_WIDTH+1)-1:0] cfi_prefix;
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

        logic [ADDR_WIDTH-1:0] pred_npc; // effective NPC after predecode
        // Original prediction remains intact for training and recovery.
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

    // CFI slot position within a fetch block (2 bits for FETCH_WIDTH=4).
    localparam int unsigned CFI_OFFSET_WIDTH = (FETCH_WIDTH > 1) ? $clog2(FETCH_WIDTH) : 1;

    typedef struct packed {
        logic [ADDR_WIDTH-1:0]       start_pc;
        logic [ADDR_WIDTH-1:0]       target_pc;
        // CFI Information
        cfi_type_t                   cfi_type;
        logic [CFI_OFFSET_WIDTH-1:0] cfi_offset;  // CFI 在 fetch block 中的 slot 位置
    } btb_target_info_t;

    // One CFI slot of a Fetch Block (multi-target BTB record)
    typedef struct packed {
        logic [CFI_OFFSET_WIDTH-1:0] cfi_offset;  // CFI 在 block 内的 slot 位置
        cfi_type_t                   cfi_type;
        logic [ADDR_WIDTH-1:0]       target_pc;
    } btb_cfi_t;

    typedef struct packed {
        logic [1:0] useful_cnt;  // 借鉴XiangShan kunminghu-v3 中的useful counter
        logic [ADDR_WIDTH - 1:$clog2(FETCH_WIDTH * INST_BYTES)] tag;

        // Information for fetch block (up to FETCH_WIDTH CFIs, block-relative)
        logic [$clog2(FETCH_WIDTH + 1) - 1:0] cfi_count;
        btb_cfi_t [FETCH_WIDTH - 1:0]         cfi;
    } btb_entry_t;

    /*
     * uBTB entry (R1: two CFI slots, no `taken`; per-slot useful counter)
     */

    typedef struct packed {
        logic [UBTB_POS_WIDTH-1:0]        position;          // CFI position in the 32B region
        cfi_type_t                        cfi_type;          // branch attribute
        logic                             is_static_target;  // target only depends on PC
        logic [ADDR_WIDTH-1:0]            target;            // full target (no target_carry)
        logic [UBTB_USEFUL_CNT_WIDTH-1:0] useful_cnt;        // per-slot: valid = (useful_cnt > 0)
    } ubtb_slot_t;

    typedef struct packed {
        logic [UBTB_TAG_WIDTH-1:0] tag;  // 32B region tag
        ubtb_slot_t [UBTB_SLOT_NUM-1:0] slot;
    } ubtb_entry_t;

    /*
     * mBTB entry (Region-BTB: one CFI per way, multiple ways share a region tag)
     */

    typedef struct packed {
        logic                         valid;
        logic [MBTB_TAG_WIDTH-1:0]    tag;
        cfi_type_t                    cfi_type;
        logic [MBTB_POS_WIDTH-1:0]    position;          // position in the 16B region
        logic                         target_carry;
        logic [MBTB_TARGET_WIDTH-1:0] target_lower;
        logic                         is_static_target;
    } mbtb_entry_t;

    /*
     * Prediction source (profiling only under R2)
     */

    typedef enum logic [1:0] {
        PRED_SRC_NONE = 2'd0,
        PRED_SRC_UBTB,
        PRED_SRC_MBTB,
        PRED_SRC_LOOP
    } pred_src_t;

    /*
     * S1 loop register: the merged prediction of the block requested in S0
     */

    typedef struct packed {
        logic                                   valid;
        logic [ADDR_WIDTH-1:0]                  start_pc;
        logic [FETCH_WIDTH-1:0]                 pred_cfi_valid;
        cfi_type_t [FETCH_WIDTH-1:0]            pred_cfi_type;
        logic [FETCH_WIDTH-1:0]                 pred_taken;
        logic [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target;
        pred_meta_t [FETCH_WIDTH-1:0]           pred_meta;
        pred_src_t [FETCH_WIDTH-1:0]            pred_src;
        logic                                   first_taken_valid;
        logic [$clog2(FETCH_WIDTH)-1:0]         first_taken;
        logic [ADDR_WIDTH-1:0]                  next_pc;
    } pred_s1_t;

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

/* verilator lint_on UNUSEDPARAM */
endpackage
