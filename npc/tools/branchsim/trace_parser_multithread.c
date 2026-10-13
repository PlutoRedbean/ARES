#include "include/branchsim.h"

#define MAX_PREDICTORS 4
#define BIMODAL_BITS 20
#define BIMODAL_SIZE (1u << BIMODAL_BITS)
#define PIPELINE_MISPRED_PENALTY 2
#define ALWAYS_TAKEN_CORRECT_PENALTY 1

typedef enum {
    PRED_ALWAYS_TAKEN = 0,
    PRED_ALWAYS_NOT_TAKEN,
    PRED_BTFNT,
    PRED_BIMODAL
} PredictorKind;

typedef struct {
    PredictorKind kind;
    const char *name;
    uint8_t *bimodal_table;
    uint32_t bimodal_mask;
    uint8_t *btb_valid;
    uint32_t *btb_tag;
    uint32_t *btb_target;
} Predictor;

typedef struct {
    const char *name;
    int64_t total;
    int64_t correct;
    int64_t mispred;
    double accuracy;
    int64_t correct_full;
    double full_accuracy;
    double mpki;
    double est_cycles;
    double lag_vs_best;
    double lag_vs_oracle;
    double cpi_theoretical;
    double cpi_param;
    int64_t mispred_direction;
    int64_t mispred_target;
    double pred_sequential_rate;
    double penalty_sum_theoretical;
    double penalty_sum_param;
    double penalty_per_branch;
    int64_t bimodal_case1_miss_nt;
    int64_t bimodal_case2_miss_t;
    int64_t bimodal_case3_hit_nt_nt;
    int64_t bimodal_case4_hit_nt_t;
    int64_t bimodal_case5_hit_t_t_target_ok;
    int64_t bimodal_case6_hit_t_t_target_bad;
    int64_t bimodal_case7_hit_t_nt_target_bad;
    int64_t bimodal_case8_hit_t_nt_target_eq_seq;
} PredictorResult;


static const RegMap kRegMap[] = {
    {"zero", 0}, {"ra", 1},  {"sp", 2},  {"gp", 3},  {"tp", 4},  {"t0", 5},  {"t1", 6},  {"t2", 7},
    {"s0", 8},   {"fp", 8},  {"s1", 9},  {"a0", 10}, {"a1", 11}, {"a2", 12}, {"a3", 13}, {"a4", 14},
    {"a5", 15},  {"a6", 16}, {"a7", 17}, {"s2", 18}, {"s3", 19}, {"s4", 20}, {"s5", 21}, {"s6", 22},
    {"s7", 23},  {"s8", 24}, {"s9", 25}, {"s10", 26},{"s11", 27},{"t3", 28}, {"t4", 29}, {"t5", 30},
    {"t6", 31},
    {"x0", 0},   {"x1", 1},  {"x2", 2},  {"x3", 3},  {"x4", 4},  {"x5", 5},  {"x6", 6},  {"x7", 7},
    {"x8", 8},   {"x9", 9},  {"x10", 10},{"x11", 11},{"x12", 12},{"x13", 13},{"x14", 14},{"x15", 15},
    {"x16", 16}, {"x17", 17},{"x18", 18},{"x19", 19},{"x20", 20},{"x21", 21},{"x22", 22},{"x23", 23},
    {"x24", 24}, {"x25", 25},{"x26", 26},{"x27", 27},{"x28", 28},{"x29", 29},{"x30", 30},{"x31", 31},
};

static uint32_t hash_pc(uint32_t pc) {
    return (pc * 2654435761u) % HASH_TABLE_SIZE;
}

static int get_reg_number(const char *name) {
    size_t n = sizeof(kRegMap) / sizeof(kRegMap[0]);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(name, kRegMap[i].name) == 0) {
            return kRegMap[i].id;
        }
    }
    return -1;
}

static int read_binary_pc_sequence(const char *filename, uint32_t **out_pc_sequence) {
    FILE *file = fopen(filename, "rb");
    if (!file) {
        printf("ERROR: cannot open pc trace %s\n", filename);
        return 0;
    }

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return 0;
    }

    long file_size = ftell(file);
    if (file_size <= 0 || file_size % (long)sizeof(uint32_t) != 0) {
        fclose(file);
        return 0;
    }

    rewind(file);
    int count = (int)(file_size / (long)sizeof(uint32_t));
    *out_pc_sequence = (uint32_t *)malloc((size_t)count * sizeof(uint32_t));
    if (!*out_pc_sequence) {
        fclose(file);
        return 0;
    }

    size_t read_n = fread(*out_pc_sequence, sizeof(uint32_t), (size_t)count, file);
    fclose(file);
    if (read_n != (size_t)count) {
        free(*out_pc_sequence);
        *out_pc_sequence = NULL;
        return 0;
    }

    return count;
}

static InstrType get_instruction_type(const char *mnemonic) {
    if (strcmp(mnemonic, "mul") == 0 || strcmp(mnemonic, "mulh") == 0 || strcmp(mnemonic, "mulhsu") == 0 ||
        strcmp(mnemonic, "mulhu") == 0) {
        return TYPE_MUL;
    }
    if (strcmp(mnemonic, "div") == 0 || strcmp(mnemonic, "divu") == 0 || strcmp(mnemonic, "rem") == 0 ||
        strcmp(mnemonic, "remu") == 0) {
        return TYPE_DIV;
    }
    if (strcmp(mnemonic, "lw") == 0 || strcmp(mnemonic, "lh") == 0 || strcmp(mnemonic, "lb") == 0 ||
        strcmp(mnemonic, "lhu") == 0 || strcmp(mnemonic, "lbu") == 0 || strcmp(mnemonic, "sw") == 0 ||
        strcmp(mnemonic, "sh") == 0 || strcmp(mnemonic, "sb") == 0 || strcmp(mnemonic, "ld") == 0 ||
        strcmp(mnemonic, "sd") == 0) {
        return TYPE_LD_ST;
    }

    if (strcmp(mnemonic, "beq") == 0 || strcmp(mnemonic, "beqz") == 0 || strcmp(mnemonic, "bne") == 0 ||
        strcmp(mnemonic, "bnez") == 0 || strcmp(mnemonic, "blt") == 0 || strcmp(mnemonic, "bltz") == 0 ||
        strcmp(mnemonic, "bge") == 0 || strcmp(mnemonic, "bgez") == 0 || strcmp(mnemonic, "bltu") == 0 ||
        strcmp(mnemonic, "bgeu") == 0 || strcmp(mnemonic, "jal") == 0 || strcmp(mnemonic, "jalr") == 0 ||
        strcmp(mnemonic, "j") == 0 || strcmp(mnemonic, "jr") == 0 || strcmp(mnemonic, "ret") == 0 ||
        strcmp(mnemonic, "call") == 0 || strcmp(mnemonic, "tail") == 0) {
        return TYPE_BRANCH;
    }

    return TYPE_ALU;
}

static BranchType get_branch_type(const char *mnemonic) {
    if (strcmp(mnemonic, "beq") == 0 || strcmp(mnemonic, "beqz") == 0) return BR_BEQ;
    if (strcmp(mnemonic, "bne") == 0 || strcmp(mnemonic, "bnez") == 0) return BR_BNE;
    if (strcmp(mnemonic, "blt") == 0 || strcmp(mnemonic, "bltz") == 0) return BR_BLT;
    if (strcmp(mnemonic, "bge") == 0 || strcmp(mnemonic, "bgez") == 0) return BR_BGE;
    if (strcmp(mnemonic, "bltu") == 0) return BR_BLTU;
    if (strcmp(mnemonic, "bgeu") == 0) return BR_BGEU;
    if (strcmp(mnemonic, "jal") == 0 || strcmp(mnemonic, "call") == 0 || strcmp(mnemonic, "tail") == 0) return BR_JAL;
    if (strcmp(mnemonic, "jalr") == 0 || strcmp(mnemonic, "jr") == 0 || strcmp(mnemonic, "ret") == 0) return BR_JALR;
    if (strcmp(mnemonic, "j") == 0) return BR_J;
    return BR_OTHER;
}

static const char *branch_type_name(int idx) {
    static const char *kNames[BR_TYPE_COUNT] = {
        "beq", "bne", "blt", "bge", "bltu", "bgeu", "jal", "jalr", "j", "other"
    };
    if (idx < 0 || idx >= BR_TYPE_COUNT) {
        return "unknown";
    }
    return kNames[idx];
}

static void trim_left(char **p) {
    while (**p != '\0' && isspace((unsigned char)**p)) {
        (*p)++;
    }
}

static int parse_asm_line(const char *line, Instruction *ins) {
    const char *colon = strchr(line, ':');
    if (!colon) {
        return 0;
    }

    char pc_buf[32];
    size_t pc_len = (size_t)(colon - line);
    if (pc_len == 0 || pc_len >= sizeof(pc_buf)) {
        return 0;
    }
    memcpy(pc_buf, line, pc_len);
    pc_buf[pc_len] = '\0';

    char *pc_ptr = pc_buf;
    trim_left(&pc_ptr);
    if (*pc_ptr == '\0') {
        return 0;
    }

    char *endp = NULL;
    unsigned long pc_val = strtoul(pc_ptr, &endp, 16);
    if (endp == pc_ptr) {
        return 0;
    }

    const char *p = colon + 1;
    while (*p != '\0' && isspace((unsigned char)*p)) p++;
    if (*p == '\0') {
        return 0;
    }

    while (*p != '\0' && !isspace((unsigned char)*p)) p++;
    while (*p != '\0' && isspace((unsigned char)*p)) p++;
    if (*p == '\0') {
        return 0;
    }

    int mi = 0;
    while (*p != '\0' && !isspace((unsigned char)*p) && mi < (int)sizeof(ins->mnemonic) - 1) {
        ins->mnemonic[mi++] = *p++;
    }
    ins->mnemonic[mi] = '\0';

    while (*p != '\0' && isspace((unsigned char)*p)) p++;
    int oi = 0;
    while (*p != '\0' && *p != '\n' && oi < (int)sizeof(ins->operands) - 1) {
        ins->operands[oi++] = *p++;
    }
    while (oi > 0 && isspace((unsigned char)ins->operands[oi - 1])) {
        oi--;
    }
    ins->operands[oi] = '\0';

    ins->pc = (uint32_t)pc_val;
    ins->type = get_instruction_type(ins->mnemonic);
    ins->dst_reg = -1;
    ins->src_count = 0;
    memset(ins->src_regs, 0, sizeof(ins->src_regs));
    return 1;
}

static void extract_registers(Instruction *ins) {
    char buf[160];
    strncpy(buf, ins->operands, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    char *saveptr = NULL;
    char *tok = strtok_r(buf, " ,()\t", &saveptr);
    while (tok) {
        int reg = get_reg_number(tok);
        if (reg >= 0) {
            if (ins->type == TYPE_BRANCH) {
                if (ins->src_count < 3) {
                    ins->src_regs[ins->src_count++] = reg;
                }
            } else if (ins->type == TYPE_LD_ST && ins->mnemonic[0] == 's') {
                if (ins->src_count < 3) {
                    ins->src_regs[ins->src_count++] = reg;
                }
            } else {
                if (ins->dst_reg < 0) {
                    ins->dst_reg = reg;
                } else if (ins->src_count < 3) {
                    ins->src_regs[ins->src_count++] = reg;
                }
            }
        }
        tok = strtok_r(NULL, " ,()\t", &saveptr);
    }
}

static int read_asm_file(const char *filename, Instruction **out_ins) {
    FILE *f = fopen(filename, "r");
    if (!f) {
        printf("ERROR: cannot open asm file %s\n", filename);
        return 0;
    }

    int cap = 8192;
    int cnt = 0;
    Instruction *arr = (Instruction *)malloc((size_t)cap * sizeof(Instruction));
    if (!arr) {
        fclose(f);
        return 0;
    }

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        Instruction ins;
        memset(&ins, 0, sizeof(ins));
        if (!parse_asm_line(line, &ins)) {
            continue;
        }
        extract_registers(&ins);
        if (cnt == cap) {
            cap *= 2;
            Instruction *tmp = (Instruction *)realloc(arr, (size_t)cap * sizeof(Instruction));
            if (!tmp) {
                free(arr);
                fclose(f);
                return 0;
            }
            arr = tmp;
        }
        arr[cnt++] = ins;
    }

    fclose(f);
    *out_ins = arr;
    return cnt;
}

static HashEntry *build_hash_table(const Instruction *ins, int n) {
    HashEntry *table = (HashEntry *)calloc(HASH_TABLE_SIZE, sizeof(HashEntry));
    if (!table) {
        return NULL;
    }

    for (int i = 0; i < n; i++) {
        uint32_t idx = hash_pc(ins[i].pc);
        while (table[idx].used) {
            idx = (idx + 1) % HASH_TABLE_SIZE;
        }
        table[idx].used = 1;
        table[idx].pc = ins[i].pc;
        table[idx].index = i;
    }
    return table;
}

static const Instruction *find_instruction(uint32_t pc, const Instruction *ins, const HashEntry *table) {
    uint32_t idx = hash_pc(pc);
    for (int i = 0; i < HASH_TABLE_SIZE; i++) {
        if (!table[idx].used) {
            return NULL;
        }
        if (table[idx].pc == pc) {
            return &ins[table[idx].index];
        }
        idx = (idx + 1) % HASH_TABLE_SIZE;
    }
    return NULL;
}

static void *thread_analyze(void *arg) {
    ThreadWork *w = (ThreadWork *)arg;
    ThreadResult r;
    memset(&r, 0, sizeof(r));

    for (int i = w->start_idx; i < w->end_idx; i++) {
        uint32_t pc = w->pc_sequence[i];
        const Instruction *ins = find_instruction(pc, w->instructions, w->hash_table);
        if (!ins) {
            continue;
        }

        r.matched++;
        r.type_count[ins->type]++;

        if (ins->dst_reg >= 0 && ins->dst_reg < 32) {
            r.reg_used[ins->dst_reg]++;
        }
        for (int k = 0; k < ins->src_count; k++) {
            int reg = ins->src_regs[k];
            if (reg >= 0 && reg < 32) {
                r.reg_used[reg]++;
            }
        }

        if (ins->type == TYPE_BRANCH && i + 1 < w->total_count) {
            BranchType bt = get_branch_type(ins->mnemonic);
            int64_t delta = (int64_t)(int32_t)w->pc_sequence[i + 1] - (int64_t)(int32_t)pc;
            uint64_t adelta = (delta < 0) ? (uint64_t)(-delta) : (uint64_t)delta;
            int taken = (delta != 4);

            r.branch_type_count[bt]++;
            if (taken) {
                r.branch_taken_total++;
                r.branch_taken_per_type[bt]++;
            } else {
                r.branch_not_taken_per_type[bt]++;
            }

            if (delta > 0) {
                r.branch_forward++;
            } else if (delta < 0) {
                r.branch_backward++;
            }

            r.branch_distance_sum += adelta;
            if (adelta > r.max_jump_distance) {
                r.max_jump_distance = adelta;
            }
        }
    }

    w->result = r;
    return NULL;
}

static int init_predictors(Predictor preds[], int *pred_count) {
    preds[0].kind = PRED_ALWAYS_TAKEN;
    preds[0].name = "always_taken";
    preds[0].bimodal_table = NULL;
    preds[0].bimodal_mask = 0;
    preds[0].btb_valid = NULL;
    preds[0].btb_tag = NULL;
    preds[0].btb_target = NULL;

    preds[1].kind = PRED_ALWAYS_NOT_TAKEN;
    preds[1].name = "always_not_taken";
    preds[1].bimodal_table = NULL;
    preds[1].bimodal_mask = 0;
    preds[1].btb_valid = NULL;
    preds[1].btb_tag = NULL;
    preds[1].btb_target = NULL;

    preds[2].kind = PRED_BTFNT;
    preds[2].name = "btfnt";
    preds[2].bimodal_table = NULL;
    preds[2].bimodal_mask = 0;
    preds[2].btb_valid = NULL;
    preds[2].btb_tag = NULL;
    preds[2].btb_target = NULL;

    preds[3].kind = PRED_BIMODAL;
    preds[3].name = "bimodal_2bit_4k";
    preds[3].bimodal_mask = BIMODAL_SIZE - 1;
    preds[3].bimodal_table = (uint8_t *)malloc(BIMODAL_SIZE);
    preds[3].btb_valid = (uint8_t *)calloc(BIMODAL_SIZE, sizeof(uint8_t));
    preds[3].btb_tag = (uint32_t *)malloc(BIMODAL_SIZE * sizeof(uint32_t));
    preds[3].btb_target = (uint32_t *)malloc(BIMODAL_SIZE * sizeof(uint32_t));
    if (!preds[3].bimodal_table || !preds[3].btb_valid || !preds[3].btb_tag || !preds[3].btb_target) {
        free(preds[3].bimodal_table);
        free(preds[3].btb_valid);
        free(preds[3].btb_tag);
        free(preds[3].btb_target);
        preds[3].bimodal_table = NULL;
        preds[3].btb_valid = NULL;
        preds[3].btb_tag = NULL;
        preds[3].btb_target = NULL;
        return 0;
    }
    memset(preds[3].bimodal_table, 1, BIMODAL_SIZE);
    memset(preds[3].btb_tag, 0, BIMODAL_SIZE * sizeof(uint32_t));
    memset(preds[3].btb_target, 0, BIMODAL_SIZE * sizeof(uint32_t));

    *pred_count = MAX_PREDICTORS;
    return 1;
}

static void free_predictors(Predictor preds[], int pred_count) {
    for (int i = 0; i < pred_count; i++) {
        free(preds[i].bimodal_table);
        free(preds[i].btb_valid);
        free(preds[i].btb_tag);
        free(preds[i].btb_target);
        preds[i].bimodal_table = NULL;
        preds[i].btb_valid = NULL;
        preds[i].btb_tag = NULL;
        preds[i].btb_target = NULL;
    }
}

static int predictor_btb_lookup(const Predictor *p, uint32_t pc, uint32_t *out_idx, uint32_t *out_target) {
    if (p->kind != PRED_BIMODAL || !p->btb_valid || !p->btb_tag || !p->btb_target) {
        return 0;
    }

    uint32_t idx = (pc >> 2) & p->bimodal_mask;
    if (out_idx) {
        *out_idx = idx;
    }
    if (!p->btb_valid[idx] || p->btb_tag[idx] != pc) {
        return 0;
    }

    if (out_target) {
        *out_target = p->btb_target[idx];
    }
    return 1;
}

static int predictor_predict_taken(const Predictor *p, uint32_t pc, int is_backward) {
    switch (p->kind) {
    case PRED_ALWAYS_TAKEN:
        return 1;
    case PRED_ALWAYS_NOT_TAKEN:
        return 0;
    case PRED_BTFNT:
        return is_backward ? 1 : 0;
    case PRED_BIMODAL: {
        uint32_t idx = 0;
        int hit = predictor_btb_lookup(p, pc, &idx, NULL);
        return hit && p->bimodal_table[idx] >= 2;
    }
    default:
        return 0;
    }
}

static int predictor_predict_target(const Predictor *p, uint32_t pc, int pred_taken, uint32_t *pred_target) {
    if (!pred_taken) {
        *pred_target = pc + 4;
        return 1;
    }

    if (p->kind == PRED_BIMODAL) {
        uint32_t target = 0;
        if (predictor_btb_lookup(p, pc, NULL, &target)) {
            *pred_target = target;
            return 1;
        }
    }

    /* For always_taken/btfnt taken path, this model does not provide IF-stage BTB target. */
    return 0;
}

static void predictor_update(Predictor *p, uint32_t pc, int taken, uint32_t actual_target) {
    if (p->kind != PRED_BIMODAL) {
        return;
    }

    uint32_t idx = (pc >> 2) & p->bimodal_mask;
    uint8_t c = p->bimodal_table[idx];
    if (taken) {
        if (c < 3) c++;
    } else {
        if (c > 0) c--;
    }
    p->bimodal_table[idx] = c;

    if (p->btb_valid && p->btb_tag && p->btb_target) {
        p->btb_valid[idx] = 1;
        p->btb_tag[idx] = pc;
        if (taken) {
            p->btb_target[idx] = actual_target;
        }
    }
}

static int is_predictable_conditional_branch(BranchType bt) {
    return bt == BR_BEQ || bt == BR_BNE || bt == BR_BLT || bt == BR_BGE || bt == BR_BLTU || bt == BR_BGEU;
}

static void simulate_predictors(const uint32_t *pc_seq, int pc_count, const Instruction *ins, const HashEntry *table,
                                Predictor preds[], int pred_count, PredictorResult results[],
                                double base_cpi, int mispred_penalty) {
    int64_t bimodal_pred_not_taken_count = 0;

    for (int p = 0; p < pred_count; p++) {
        memset(&results[p], 0, sizeof(results[p]));
        results[p].name = preds[p].name;
    }

    int64_t branch_events = 0;
    for (int i = 0; i + 1 < pc_count; i++) {
        uint32_t pc = pc_seq[i];
        const Instruction *cur = find_instruction(pc, ins, table);
        if (!cur || cur->type != TYPE_BRANCH) {
            continue;
        }

        BranchType bt = get_branch_type(cur->mnemonic);
        if (!is_predictable_conditional_branch(bt)) {
            continue;
        }

        int64_t delta = (int64_t)(int32_t)pc_seq[i + 1] - (int64_t)(int32_t)pc;
        uint32_t actual_target = pc_seq[i + 1];
        int taken = (delta != 4);
        int is_backward = (delta < 0);

        branch_events++;
        for (int p = 0; p < pred_count; p++) {
            int btb_hit = 0;
            int pred_taken = predictor_predict_taken(&preds[p], pc, is_backward);
            uint32_t pred_target = 0;
            int has_pred_target = predictor_predict_target(&preds[p], pc, pred_taken, &pred_target);
            int direction_ok = (pred_taken == taken);
            int target_ok = has_pred_target && (pred_target == actual_target);
            int full_ok = direction_ok && target_ok;

            if (preds[p].kind == PRED_BIMODAL) {
                btb_hit = predictor_btb_lookup(&preds[p], pc, NULL, NULL);
            }

            if (preds[p].kind == PRED_ALWAYS_TAKEN && direction_ok) {
                /* User-requested model: always_taken is fully correct when direction is correct. */
                full_ok = 1;
            }

            results[p].total++;

            if (preds[p].kind == PRED_BIMODAL) {
                if (!pred_taken) {
                    bimodal_pred_not_taken_count++;
                }
            }

            if (direction_ok) {
                results[p].correct++;
                if (full_ok) {
                    results[p].correct_full++;
                }
            } else {
                results[p].mispred++;
                if (preds[p].kind == PRED_BIMODAL) {
                    if (!pred_taken && taken) {
                        results[p].mispred_direction++;
                    } else {
                        results[p].mispred_target++;
                    }
                }
            }

            if (preds[p].kind == PRED_BIMODAL) {
                if (!btb_hit && !pred_taken && !taken) {
                    results[p].bimodal_case1_miss_nt++;
                } else if (!btb_hit && !pred_taken && taken) {
                    results[p].bimodal_case2_miss_t++;
                } else if (btb_hit && !pred_taken && !taken) {
                    results[p].bimodal_case3_hit_nt_nt++;
                } else if (btb_hit && !pred_taken && taken) {
                    results[p].bimodal_case4_hit_nt_t++;
                } else if (btb_hit && pred_taken && taken && target_ok) {
                    results[p].bimodal_case5_hit_t_t_target_ok++;
                } else if (btb_hit && pred_taken && taken && !target_ok) {
                    results[p].bimodal_case6_hit_t_t_target_bad++;
                } else if (btb_hit && pred_taken && !taken && target_ok) {
                    results[p].bimodal_case8_hit_t_nt_target_eq_seq++;
                } else if (btb_hit && pred_taken && !taken && !target_ok) {
                    results[p].bimodal_case7_hit_t_nt_target_bad++;
                }
            }

            if (preds[p].kind == PRED_ALWAYS_TAKEN) {
                results[p].penalty_sum_theoretical += direction_ok ? ALWAYS_TAKEN_CORRECT_PENALTY : PIPELINE_MISPRED_PENALTY;
                results[p].penalty_sum_param += direction_ok ? ALWAYS_TAKEN_CORRECT_PENALTY : mispred_penalty;
            } else {
                results[p].penalty_sum_theoretical += full_ok ? 0.0 : (double)PIPELINE_MISPRED_PENALTY;
                results[p].penalty_sum_param += full_ok ? 0.0 : (double)mispred_penalty;
            }

            predictor_update(&preds[p], pc, taken, actual_target);
        }
    }

    double base_cycles = base_cpi * (double)pc_count;
    double best_cycles = -1.0;
    for (int p = 0; p < pred_count; p++) {
        PredictorResult *r = &results[p];
        r->accuracy = (r->total > 0) ? (100.0 * (double)r->correct / (double)r->total) : 0.0;
        r->full_accuracy = (r->total > 0) ? (100.0 * (double)r->correct_full / (double)r->total) : 0.0;
        r->mpki = (pc_count > 0) ? (1000.0 * (double)r->mispred / (double)pc_count) : 0.0;
        r->est_cycles = base_cycles + r->penalty_sum_param;
        r->cpi_theoretical = (pc_count > 0)
                                 ? (base_cpi + r->penalty_sum_theoretical / (double)pc_count)
                                 : base_cpi;
        r->cpi_param = (pc_count > 0)
                           ? (base_cpi + r->penalty_sum_param / (double)pc_count)
                           : base_cpi;
        if (preds[p].kind == PRED_BIMODAL) {
            r->pred_sequential_rate = (r->total > 0)
                                          ? (100.0 * (double)bimodal_pred_not_taken_count / (double)r->total)
                                          : 0.0;
        }
        r->penalty_per_branch = (r->total > 0) ? (r->penalty_sum_theoretical / (double)r->total) : 0.0;
        if (best_cycles < 0.0 || r->est_cycles < best_cycles) {
            best_cycles = r->est_cycles;
        }
    }

    for (int p = 0; p < pred_count; p++) {
        PredictorResult *r = &results[p];
        r->lag_vs_best = r->est_cycles - best_cycles;
        r->lag_vs_oracle = r->est_cycles - base_cycles;
    }

    (void)branch_events;
}

static void write_report(const char *out_file, int pc_count, int instr_count, int threads, const ThreadResult *total,
                         const PredictorResult *pred_results, int pred_count,
                         double base_cpi, int mispred_penalty) {
    FILE *out = fopen(out_file, "w");
    if (!out) {
        printf("ERROR: cannot write report %s\n", out_file);
        return;
    }

    int64_t total_branches = 0;
    for (int i = 0; i < BR_TYPE_COUNT; i++) {
        total_branches += total->branch_type_count[i];
    }

    fprintf(out, "【基本统计】\n");
    fprintf(out, "  总PC序列长度: %d\n", pc_count);
    fprintf(out, "  独特指令数: %d\n", instr_count);
    fprintf(out, "  指令定义匹配率: %.2f%% (%lld/%d)\n", (pc_count > 0) ? (100.0 * (double)total->matched / (double)pc_count) : 0.0,
            (long long)total->matched, pc_count);

    fprintf(out, "\n  指令类型分布:\n");
    fprintf(out, "    ALU:    %lld (%.2f%%)\n", (long long)total->type_count[TYPE_ALU],
            (pc_count > 0) ? (100.0 * (double)total->type_count[TYPE_ALU] / (double)pc_count) : 0.0);
    fprintf(out, "    Load:   %lld (%.2f%%)\n", (long long)total->type_count[TYPE_LD_ST],
            (pc_count > 0) ? (100.0 * (double)total->type_count[TYPE_LD_ST] / (double)pc_count) : 0.0);
    fprintf(out, "    Mul:    %lld (%.2f%%)\n", (long long)total->type_count[TYPE_MUL],
            (pc_count > 0) ? (100.0 * (double)total->type_count[TYPE_MUL] / (double)pc_count) : 0.0);
    fprintf(out, "    Div:    %lld (%.2f%%)\n", (long long)total->type_count[TYPE_DIV],
            (pc_count > 0) ? (100.0 * (double)total->type_count[TYPE_DIV] / (double)pc_count) : 0.0);
    fprintf(out, "    Branch: %lld (%.2f%%)\n", (long long)total->type_count[TYPE_BRANCH],
            (pc_count > 0) ? (100.0 * (double)total->type_count[TYPE_BRANCH] / (double)pc_count) : 0.0);

    fprintf(out, "\n【寄存器使用分析】\n");
    int active_regs = 0;
    int top_reg = -1;
    int64_t top_count = 0;
    for (int i = 0; i < 32; i++) {
        if (total->reg_used[i] > 0) {
            active_regs++;
        }
        if (total->reg_used[i] > top_count) {
            top_count = total->reg_used[i];
            top_reg = i;
        }
    }
    fprintf(out, "  活跃寄存器数: %d\n", active_regs);
    if (top_reg >= 0) {
        fprintf(out, "  最繁忙寄存器: x%d (使用 %lld 次)\n", top_reg, (long long)top_count);
    }

    fprintf(out, "\n【分支跳转统计】\n");
    fprintf(out, "  分支指令总数: %lld (%.2f%% of 指令)\n", (long long)total_branches,
            (pc_count > 0) ? (100.0 * (double)total_branches / (double)pc_count) : 0.0);

    if (total_branches > 0) {
        fprintf(out, "\n  分支类型分布与预测效果:\n");
        for (int i = 0; i < BR_TYPE_COUNT; i++) {
            int64_t c = total->branch_type_count[i];
            if (c == 0) {
                continue;
            }
            int64_t tk = total->branch_taken_per_type[i];
            int64_t ntk = total->branch_not_taken_per_type[i];
            int64_t denom = tk + ntk;
            fprintf(out, "    %-6s: %8lld (%.2f%% of all branches)\n", branch_type_name(i), (long long)c,
                    100.0 * (double)c / (double)total_branches);
            if (denom > 0) {
                fprintf(out, "      └─ Taken:     %8lld (%.2f%%)\n", (long long)tk, 100.0 * (double)tk / (double)denom);
                fprintf(out, "      └─ Not-taken: %8lld (%.2f%%)\n", (long long)ntk, 100.0 * (double)ntk / (double)denom);
            }
        }

        fprintf(out, "\n  跳转方向分析:\n");
        fprintf(out, "    前向跳转 (Forward):  %lld\n", (long long)total->branch_forward);
        fprintf(out, "    后向跳转 (Backward): %lld\n", (long long)total->branch_backward);
        if (total->branch_forward + total->branch_backward > 0) {
            fprintf(out, "    后向跳转率: %.2f%% (循环检测指标)\n",
                    100.0 * (double)total->branch_backward / (double)(total->branch_forward + total->branch_backward));
        }

        fprintf(out, "\n  全局跳转目标分析:\n");
        fprintf(out, "    推测Taken分支: %lld (%.2f%%)\n", (long long)total->branch_taken_total,
                100.0 * (double)total->branch_taken_total / (double)total_branches);
        fprintf(out, "    推测Not-taken: %lld (%.2f%%)\n", (long long)(total_branches - total->branch_taken_total),
                100.0 * (double)(total_branches - total->branch_taken_total) / (double)total_branches);

        fprintf(out, "\n  跳转距离统计:\n");
        fprintf(out, "    平均跳转距离: %llu 字节\n",
                (unsigned long long)(total->branch_distance_sum / (uint64_t)total_branches));
        fprintf(out, "    最大跳转距离: %llu 字节\n", (unsigned long long)total->max_jump_distance);
    }

        fprintf(out, "\n【分支预测器对比（第一版，仅条件分支）】\n");
    fprintf(out, "  周期模型: cycles = base_cpi * Ninst + SUM(per-branch penalty)\n");
    fprintf(out, "  注: jal/jalr/j/call/ret/tail 等必然跳转不参与预测器统计\n");
        fprintf(out, "  注: dir_acc=方向正确率，full_acc=方向+目标地址均正确率（流水线等效无额外冲刷）\n");
        fprintf(out, "  注: always_taken 采用修订模型：方向对 penalty=1，方向错 penalty=2\n");
        fprintf(out, "  参数: base_cpi=%.3f  mispred_penalty(cmd)=%d  pipeline_penalty=%d\n",
            base_cpi, mispred_penalty, PIPELINE_MISPRED_PENALTY);
            fprintf(out, "\n  %-20s %10s %10s %10s %10s %10s %10s %12s %10s %14s %14s %14s\n",
                "predictor", "branches", "mispred", "dir_acc", "full_acc", "CPI(p=2)", "CPI(cmd)", "penalty/br", "MPKI", "est_cycles", "lag_best", "lag_oracle");
    for (int i = 0; i < pred_count; i++) {
        const PredictorResult *r = &pred_results[i];
            fprintf(out, "  %-20s %10lld %10lld %10.2f %10.2f %10.3f %10.3f %12.3f %10.2f %14.2f %14.2f %14.2f\n",
                r->name,
                (long long)r->total,
                (long long)r->mispred,
                r->accuracy,
                r->full_accuracy,
            r->cpi_theoretical,
            r->cpi_param,
                r->penalty_per_branch,
                r->mpki,
                r->est_cycles,
                r->lag_vs_best,
                r->lag_vs_oracle);
    }

        for (int i = 0; i < pred_count; i++) {
        const PredictorResult *r = &pred_results[i];
        if (strcmp(r->name, "bimodal_2bit_4k") != 0) {
            continue;
        }

        fprintf(out, "\n【bimodal_2bit_4k 八类场景占比】\n");
        fprintf(out, "  case1 miss + predNT + actualNT : %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case1_miss_nt,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case1_miss_nt / (double)r->total) : 0.0);
        fprintf(out, "  case2 miss + predNT + actualT  : %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case2_miss_t,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case2_miss_t / (double)r->total) : 0.0);
        fprintf(out, "  case3 hit  + predNT + actualNT : %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case3_hit_nt_nt,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case3_hit_nt_nt / (double)r->total) : 0.0);
        fprintf(out, "  case4 hit  + predNT + actualT  : %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case4_hit_nt_t,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case4_hit_nt_t / (double)r->total) : 0.0);
        fprintf(out, "  case5 hit  + predT  + actualT  + targetOK : %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case5_hit_t_t_target_ok,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case5_hit_t_t_target_ok / (double)r->total) : 0.0);
        fprintf(out, "  case6 hit  + predT  + actualT  + targetBAD: %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case6_hit_t_t_target_bad,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case6_hit_t_t_target_bad / (double)r->total) : 0.0);
        fprintf(out, "  case7 hit  + predT  + actualNT + targetBAD: %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case7_hit_t_nt_target_bad,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case7_hit_t_nt_target_bad / (double)r->total) : 0.0);
        fprintf(out, "  case8 hit  + predT  + actualNT + targetEQ : %10lld  (%6.2f%%)\n",
            (long long)r->bimodal_case8_hit_t_nt_target_eq_seq,
            (r->total > 0) ? (100.0 * (double)r->bimodal_case8_hit_t_nt_target_eq_seq / (double)r->total) : 0.0);

        {
            int64_t case_sum = r->bimodal_case1_miss_nt + r->bimodal_case2_miss_t + r->bimodal_case3_hit_nt_nt +
                       r->bimodal_case4_hit_nt_t + r->bimodal_case5_hit_t_t_target_ok + r->bimodal_case6_hit_t_t_target_bad +
                       r->bimodal_case7_hit_t_nt_target_bad + r->bimodal_case8_hit_t_nt_target_eq_seq;
            fprintf(out, "  case总和校验: %10lld / total=%lld\n", (long long)case_sum, (long long)r->total);
        }
        }

    fprintf(out, "\n✓ 处理使用了 %d 个线程，哈希表加速查询\n", threads);
    fclose(out);
}

int main(int argc, char *argv[]) {
    const char *pc_file = (argc > 1) ? argv[1] : "./data/pc_trace.bin";
    const char *asm_file = (argc > 2) ? argv[2] : "./data/microbench-riscv32e-soc.asm";
    const char *out_file = (argc > 3) ? argv[3] : "./build/pc_trace_analysis.txt";
    int num_threads = (argc > 4) ? atoi(argv[4]) : MAX_THREADS;
    int mispred_penalty = (argc > 5) ? atoi(argv[5]) : 8;
    double base_cpi = (argc > 6) ? atof(argv[6]) : 1.0;

    if (num_threads < 1) num_threads = 1;
    if (num_threads > MAX_THREADS) num_threads = MAX_THREADS;
    if (mispred_penalty < 1) mispred_penalty = 1;
    if (base_cpi <= 0.0) base_cpi = 1.0;

    uint32_t *pc_seq = NULL;
    int pc_count = read_binary_pc_sequence(pc_file, &pc_seq);
    if (pc_count < 2) {
        printf("ERROR: invalid pc trace: %s\n", pc_file);
        free(pc_seq);
        return 1;
    }

    Instruction *ins = NULL;
    int ins_count = read_asm_file(asm_file, &ins);
    if (ins_count <= 0) {
        printf("ERROR: invalid asm file: %s\n", asm_file);
        free(pc_seq);
        return 1;
    }

    HashEntry *table = build_hash_table(ins, ins_count);
    if (!table) {
        free(pc_seq);
        free(ins);
        return 1;
    }

    int transitions = pc_count - 1;
    if (num_threads > transitions) {
        num_threads = transitions;
    }

    pthread_t threads[MAX_THREADS];
    ThreadWork works[MAX_THREADS];
    int chunk = (transitions + num_threads - 1) / num_threads;

    for (int i = 0; i < num_threads; i++) {
        int start = i * chunk;
        int end = (i + 1) * chunk;
        if (end > transitions) end = transitions;

        works[i].pc_sequence = pc_seq;
        works[i].total_count = pc_count;
        works[i].start_idx = start;
        works[i].end_idx = end;
        works[i].instructions = ins;
        works[i].hash_table = table;
        memset(&works[i].result, 0, sizeof(works[i].result));

        pthread_create(&threads[i], NULL, thread_analyze, &works[i]);
    }

    ThreadResult total;
    memset(&total, 0, sizeof(total));

    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
        ThreadResult *r = &works[i].result;
        total.matched += r->matched;
        total.branch_forward += r->branch_forward;
        total.branch_backward += r->branch_backward;
        total.branch_taken_total += r->branch_taken_total;
        total.branch_distance_sum += r->branch_distance_sum;
        if (r->max_jump_distance > total.max_jump_distance) {
            total.max_jump_distance = r->max_jump_distance;
        }

        for (int k = 0; k < TYPE_COUNT; k++) {
            total.type_count[k] += r->type_count[k];
        }
        for (int k = 0; k < 32; k++) {
            total.reg_used[k] += r->reg_used[k];
        }
        for (int k = 0; k < BR_TYPE_COUNT; k++) {
            total.branch_type_count[k] += r->branch_type_count[k];
            total.branch_taken_per_type[k] += r->branch_taken_per_type[k];
            total.branch_not_taken_per_type[k] += r->branch_not_taken_per_type[k];
        }
    }

    Predictor preds[MAX_PREDICTORS];
    PredictorResult pred_results[MAX_PREDICTORS];
    int pred_count = 0;
    if (!init_predictors(preds, &pred_count)) {
        printf("ERROR: failed to initialize predictors\n");
        free(table);
        free(ins);
        free(pc_seq);
        return 1;
    }

    simulate_predictors(pc_seq, pc_count, ins, table, preds, pred_count, pred_results, base_cpi, mispred_penalty);

    write_report(out_file, pc_count, ins_count, num_threads, &total,
                 pred_results, pred_count, base_cpi, mispred_penalty);

    free_predictors(preds, pred_count);

    printf("PC trace: %s\n", pc_file);
    printf("ASM map : %s\n", asm_file);
    printf("Report  : %s\n", out_file);
    printf("Model   : base_cpi=%.3f mispred_penalty=%d\n", base_cpi, mispred_penalty);

    free(table);
    free(ins);
    free(pc_seq);
    return 0;
}
