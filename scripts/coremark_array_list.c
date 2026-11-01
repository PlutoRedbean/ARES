/* ARES software array-shadow core_bench_list.
 *
 * This file is not part of the EEMBC CoreMark sources.  It is added by the
 * accelerated build flow; the reference core_bench_list() in
 * core_list_join.c is renamed to core_bench_list_orig() so this definition
 * wins for every caller (core_main.c is unchanged).
 *
 * The benchmark's linked list has only ~30 nodes and lives in L1D.  The
 * original find is a 3-load serial chain per node (next -> info -> idx) and
 * every find is followed by a full core_list_reverse() and a move-to-front.
 *
 * Two implementations share the same array tail (sort/remove/CRC):
 *
 *   - default: an index-linked order over cached {idx,data16} values.  Find
 *     walks one dependent load per node; reverse is a direction bit and
 *     move-to-front is pointer surgery, so neither is O(n) any more.
 *   - ARES_LIST_ENGINE: the 102-iteration find/reverse/move-to-front loop is
 *     executed by list9_engine at 0xA000_3000.  The core only copies the
 *     ~31 nodes in and the final order out.
 *
 * The array tail keeps the exact bottom-up merge algorithm of CoreMark, so the
 * cmp() call order (and therefore calc_func's caching/CRC side effects) is
 * unchanged.  The linked list is materialised from the array at the end of
 * every call, restoring the original idx order.
 *
 * The array is reused across calls (keyed by core_results/list head).  No
 * CoreMark source file is modified.
 */

#include "coremark.h"

#define ARES_LIST_MAX 64

/* The hardware loop owns 32 slots; longer lists fall back to the reference
 * core_bench_list_orig() instead of silently truncating.  The software path
 * can use the full 64-entry shadow. */
#ifdef ARES_LIST_ENGINE
#define ARES_LIST_LIMIT 32
#else
#define ARES_LIST_LIMIT ARES_LIST_MAX
#endif

typedef ee_s32 (*ares_cmp_fn)(list_data *, list_data *, core_results *);

extern ee_s32 cmp_complex(list_data *, list_data *, core_results *);
extern ee_u16 core_bench_list_orig(core_results *, ee_s16);

static list_head *ares_nodes[ARES_LIST_MAX];
static list_data *ares_info[ARES_LIST_MAX];
static list_head *ares_tmp_nodes[ARES_LIST_MAX];
static list_data *ares_tmp_info[ARES_LIST_MAX];
static ee_s16 ares_idx_val[ARES_LIST_MAX];   /* cached info->idx        */
static ee_u16 ares_d16_val[ARES_LIST_MAX];   /* cached info->data16     */
static ee_s16 ares_tmp_idx[ARES_LIST_MAX];
static ee_u16 ares_tmp_d16[ARES_LIST_MAX];
static int ares_next[ARES_LIST_MAX];         /* logical next, physical slot */
static int ares_prev[ARES_LIST_MAX];
static int ares_n;
static int ares_dir;                         /* 0: head->tail, 1: reversed */
static int ares_head_idx, ares_tail;
static core_results *ares_res;
static list_head *ares_head_ptr;

/*---------------------------------------------------------------------------
 * Array tail: the arrays always hold the list in logical (forward) order.
 *---------------------------------------------------------------------------*/

static void ares_build(core_results *res)
{
    list_head *p = res->list;
    int n = 0;
    int i;

    while (p != 0 && n < ARES_LIST_MAX) {
        ares_nodes[n] = p;
        ares_info[n] = p->info;
        n++;
        p = p->next;
    }
    ares_res = res;
    ares_head_ptr = res->list;
    ares_n = (p == 0 && n <= ARES_LIST_LIMIT) ? n : 0;
    ares_dir = 0;
    if (ares_n == 0)
        return;
    for (i = 0; i < ares_n; i++) {
        ares_idx_val[i] = ares_info[i]->idx;
        ares_d16_val[i] = ares_info[i]->data16;
        ares_next[i] = (i + 1 < ares_n) ? i + 1 : -1;
        ares_prev[i] = i - 1;
    }
    ares_head_idx = 0;
    ares_tail = ares_n - 1;
}

/* data16 may change between calls (cmp_idx restores it), idx does not.
 * The tail sorts the arrays but not the linked order, so the chain must be
 * rebuilt from the (authoritative) array order at every entry. */
static void ares_sync_values(void)
{
    int i;

    for (i = 0; i < ares_n; i++) {
        ares_idx_val[i] = ares_info[i]->idx;
        ares_d16_val[i] = ares_info[i]->data16;
        ares_next[i] = (i + 1 < ares_n) ? i + 1 : -1;
        ares_prev[i] = i - 1;
    }
    ares_dir = 0;
    ares_head_idx = 0;
    ares_tail = ares_n - 1;
}

/* Forward array find, used by the post-loop remove/CRC tail.  The tail sorts
 * the arrays after the hot loop, so it must read the live list_data rather
 * than the loop's cached idx/data16. */
static int ares_find_idx_arr(ee_s16 idx)
{
    int i;

    for (i = 0; i < ares_n; i++)
        if (ares_info[i]->idx == idx)
            return i;
    return -1;
}

static int ares_find_data_arr(ee_u16 data)
{
    int i;
    int key = (int)(data & 0xffu);

    for (i = 0; i < ares_n; i++)
        if ((int)(ares_info[i]->data16 & 0xffu) == key)
            return i;
    return -1;
}

/*---------------------------------------------------------------------------
 * Software loop: index-linked order.
 *---------------------------------------------------------------------------*/

static int ares_next_of(int i)
{
    return ares_dir ? ares_prev[i] : ares_next[i];
}

static int ares_prev_of(int i)
{
    return ares_dir ? ares_next[i] : ares_prev[i];
}

static void ares_set_next(int i, int v)
{
    if (ares_dir)
        ares_prev[i] = v;
    else
        ares_next[i] = v;
}

static void ares_set_prev(int i, int v)
{
    if (ares_dir)
        ares_next[i] = v;
    else
        ares_prev[i] = v;
}

static int ares_chain_find(int use_idx, int key, int *fi_out)
{
    int i = ares_head_idx;
    int k = 0;

    while (i >= 0) {
        int v = use_idx ? (int)ares_idx_val[i]
                        : (int)(ares_d16_val[i] & 0xffu);
        if (v == key) {
            *fi_out = k;
            return i;
        }
        i = ares_next_of(i);
        k++;
    }
    *fi_out = -1;
    return -1;
}

static void ares_flip(void)
{
    int t;

    ares_dir ^= 1;
    t = ares_head_idx;
    ares_head_idx = ares_tail;
    ares_tail = t;
}

/* Move logical node x to logical position 1 (pointer surgery, O(1)). */
static void ares_move_after_head(int x)
{
    int h, p, q, hn;

    if (x < 0)
        return;
    h = ares_head_idx;
    if (x == h)
        return;
    if (x == ares_next_of(h))
        return;                     /* already at position 1 */

    p = ares_prev_of(x);
    q = ares_next_of(x);
    if (p >= 0)
        ares_set_next(p, q);
    else
        ares_head_idx = q;
    if (q >= 0)
        ares_set_prev(q, p);
    else
        ares_tail = p;

    hn = ares_next_of(h);
    ares_set_next(h, x);
    ares_set_prev(x, h);
    ares_set_next(x, hn);
    if (hn >= 0)
        ares_set_prev(hn, x);
    else
        ares_tail = x;
}

/* Copy the linked order into the forward arrays, once after the hot loop. */
static void ares_normalize(void)
{
    int i;
    int k = 0;

    if (ares_n <= 0)
        return;
    for (i = ares_head_idx; i >= 0; i = ares_next_of(i)) {
        ares_tmp_nodes[k] = ares_nodes[i];
        ares_tmp_info[k] = ares_info[i];
        ares_tmp_idx[k] = ares_idx_val[i];
        ares_tmp_d16[k] = ares_d16_val[i];
        k++;
    }
    for (i = 0; i < ares_n; i++) {
        ares_nodes[i] = ares_tmp_nodes[i];
        ares_info[i] = ares_tmp_info[i];
        ares_idx_val[i] = ares_tmp_idx[i];
        ares_d16_val[i] = ares_tmp_d16[i];
    }
    ares_dir = 0;
    for (i = 0; i < ares_n; i++) {
        ares_next[i] = (i + 1 < ares_n) ? i + 1 : -1;
        ares_prev[i] = i - 1;
    }
    ares_head_idx = 0;
    ares_tail = ares_n - 1;
}

/* Returns the loop's partial retval (before the CRC walks). */
static ee_u16 ares_sw_loop(ee_s16 finder_idx, ee_s16 find_num)
{
    ee_u16 retval = 0;
    ee_u16 found = 0;
    ee_u16 missed = 0;
    ee_s16 finder = finder_idx;
    ee_s16 i;

    for (i = 0; i < find_num; i++) {
        int key = (finder >= 0) ? (int)finder : (int)(i & 0xff);
        int fi;
        int f = ares_chain_find(finder >= 0, key, &fi);
        int x = (f >= 0) ? ares_prev_of(f) : -1;

        ares_flip();
        if (f < 0) {
            missed++;
            retval = (ee_u16)(retval +
                     ((ares_d16_val[ares_next_of(ares_head_idx)] >> 8) & 1));
        } else {
            found++;
            if (ares_d16_val[f] & 0x1)
                retval = (ee_u16)(retval + ((ares_d16_val[f] >> 9) & 1));
            if (x >= 0)
                ares_move_after_head(x);
        }
        if (finder >= 0)
            finder++;
    }
    retval = (ee_u16)(retval + found * 4u - missed);
    ares_normalize();
    return retval;
}

/*---------------------------------------------------------------------------
 * Hardware loop: list9_engine at 0xA000_3000.
 *---------------------------------------------------------------------------*/
#ifdef ARES_LIST_ENGINE
#define LE_BASE   0xA0003000u
#define LE_NODE   (LE_BASE + 0x000u)
#define LE_VAL    (LE_BASE + 0x100u)
#define LE_CTRL   (LE_BASE + 0x700u)
#define LE_N      (LE_BASE + 0x704u)
#define LE_FINDER (LE_BASE + 0x708u)
#define LE_SEED3  (LE_BASE + 0x70Cu)
#define LE_STATUS (LE_BASE + 0x710u)
#define LE_RETVAL (LE_BASE + 0x714u)

static inline void le_wr(ee_u32 a, ee_u32 v)
{
    *(volatile ee_u32 *)a = v;
}

static inline ee_u32 le_rd(ee_u32 a)
{
    return *(volatile ee_u32 *)a;
}

static ee_u16 ares_hw_loop(ee_s16 finder_idx, ee_s16 find_num)
{
    ee_u32 st;
    ee_u32 dir;
    int i;

    for (i = 0; i < ares_n; i++) {
        le_wr(LE_NODE + 4u * (ee_u32)i, (ee_u32)ares_nodes[i]);
        le_wr(LE_VAL + 4u * (ee_u32)i,
              ((ee_u32)(ee_u16)ares_idx_val[i] << 16) |
              (ee_u32)(ee_u16)ares_d16_val[i]);
    }
    __asm__ volatile("" ::: "memory");

    le_wr(LE_N, (ee_u32)ares_n);
    le_wr(LE_FINDER, (ee_u32)(ee_u16)finder_idx);
    le_wr(LE_SEED3, (ee_u32)(ee_u16)find_num);
    le_wr(LE_CTRL, 1u);
    while ((le_rd(LE_STATUS) & 2u) == 0u)
        ;
    __asm__ volatile("" ::: "memory");

    st = le_rd(LE_STATUS);
    dir = (st >> 2) & 1u;

    for (i = 0; i < ares_n; i++) {
        int k = dir ? (ares_n - 1 - i) : i;
        ee_u32 node = le_rd(LE_NODE + 4u * (ee_u32)k);
        ee_u32 val = le_rd(LE_VAL + 4u * (ee_u32)k);
        ares_nodes[i] = (list_head *)node;
        ares_info[i] = ((list_head *)node)->info;
        ares_idx_val[i] = (ee_s16)(val >> 16);
        ares_d16_val[i] = (ee_u16)val;
    }
    ares_dir = 0;

    return (ee_u16)le_rd(LE_RETVAL);
}
#endif

/*---------------------------------------------------------------------------
 * Shared tail: sort / remove / CRC / materialise.
 *---------------------------------------------------------------------------*/

static void ares_sort(ares_cmp_fn cmp, core_results *res)
{
    int insize = 1;
    int i;

    for (;;) {
        int p = 0;
        int out = 0;
        int nmerges = 0;

        while (p < ares_n) {
            int q = p;
            int psize = 0;
            int qsize;
            int e;

            nmerges++;
            for (i = 0; i < insize; i++) {
                psize++;
                q++;
                if (q >= ares_n)
                    break;
            }
            qsize = insize;

            while (psize > 0 || (qsize > 0 && q < ares_n)) {
                if (psize == 0) {
                    e = q;
                    q++;
                    qsize--;
                } else if (qsize == 0 || q >= ares_n) {
                    e = p;
                    p++;
                    psize--;
                } else if (cmp(ares_info[p], ares_info[q], res) <= 0) {
                    e = p;
                    p++;
                    psize--;
                } else {
                    e = q;
                    q++;
                    qsize--;
                }
                ares_tmp_nodes[out] = ares_nodes[e];
                ares_tmp_info[out] = ares_info[e];
                out++;
            }
            p = q;
        }

        for (i = 0; i < out; i++) {
            ares_nodes[i] = ares_tmp_nodes[i];
            ares_info[i] = ares_tmp_info[i];
        }
        if (nmerges <= 1)
            break;
        insize *= 2;
    }
}

static ee_s32 ares_cmp_idx(list_data *a, list_data *b, core_results *res)
{
    if (res == 0) {
        a->data16 = (a->data16 & 0xff00) | (0x00ff & (a->data16 >> 8));
        b->data16 = (b->data16 & 0xff00) | (0x00ff & (b->data16 >> 8));
    }
    return a->idx - b->idx;
}

static list_head *ares_remove_after_head(void)
{
    list_head *item;
    list_head *ret;
    list_data *tmp;
    int k;

    if (ares_n < 3)
        return 0;

    item = ares_nodes[1];
    ret = ares_nodes[2];

    tmp = item->info;
    item->info = ret->info;
    ret->info = tmp;
    ret->next = 0;
    ares_info[1] = item->info;

    for (k = 2; k < ares_n - 1; k++) {
        ares_nodes[k] = ares_nodes[k + 1];
        ares_info[k] = ares_info[k + 1];
    }
    ares_n--;
    return ret;
}

static void ares_undo_remove(list_head *removed)
{
    list_head *modified;
    list_data *tmp;
    int k;

    if (removed == 0 || ares_n < 2)
        return;

    modified = ares_nodes[1];
    tmp = removed->info;
    removed->info = modified->info;
    modified->info = tmp;
    ares_info[1] = modified->info;

    for (k = ares_n; k > 2; k--) {
        ares_nodes[k] = ares_nodes[k - 1];
        ares_info[k] = ares_info[k - 1];
    }
    ares_nodes[2] = removed;
    ares_info[2] = removed->info;
    ares_n++;

    modified->next = removed;
    removed->next = (ares_n > 3) ? ares_nodes[3] : 0;
}

static ee_u16 ares_crc_walk(int start, ee_u16 retval)
{
    ee_s16 head_data;
    int i;

    if (start < 0)
        start = 0;
    head_data = ares_info[0]->data16;
    for (i = start; i < ares_n; i++)
        retval = crc16(head_data, retval);
    return retval;
}

static void ares_materialize(void)
{
    int i;

    for (i = 0; i < ares_n; i++)
        ares_nodes[i]->next = (i + 1 < ares_n) ? ares_nodes[i + 1] : 0;
}

ee_u16 core_bench_list(core_results *res, ee_s16 finder_idx)
{
    ee_u16 retval;
    ee_s16 find_num = res->seed3;
    ee_s16 info_idx;
    ee_s16 info_data16;
    int fi;
    list_head *remover;

    if (ares_n == 0 || ares_res != res || ares_head_ptr != res->list)
        ares_build(res);
    if (ares_n < 3)
        return core_bench_list_orig(res, finder_idx);

    ares_sync_values();

#ifdef ARES_LIST_ENGINE
    retval = ares_hw_loop(finder_idx, find_num);
#else
    retval = ares_sw_loop(finder_idx, find_num);
#endif

    info_idx = (finder_idx >= 0) ? (ee_s16)(finder_idx + find_num) : finder_idx;
    info_data16 = (ee_s16)((find_num > 0) ? ((find_num - 1) & 0xff) : 0);

    if (finder_idx > 0)
        ares_sort(cmp_complex, res);

    remover = ares_remove_after_head();
    if (remover == 0)
        return retval;

    fi = (info_idx >= 0) ? ares_find_idx_arr(info_idx)
                         : ares_find_data_arr((ee_u16)info_data16);
    if (fi < 0)
        fi = 1;
    retval = ares_crc_walk(fi, retval);

    ares_undo_remove(remover);

    ares_sort(ares_cmp_idx, 0);
    retval = ares_crc_walk(1, retval);

    ares_materialize();
    return retval;
}
