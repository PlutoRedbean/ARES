#ifndef __BRANCH_DIFFTEST_H__
#define __BRANCH_DIFFTEST_H__

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void branch_difftest_set_report_path(const char *path);
void branch_difftest_set_test_file(const char *path);
void branch_difftest_reset_statistics(void);
void branch_difftest_freeze_statistics(void);
void branch_difftest_queue_update(int update_en, int update_pc, int predicted_pc,
    int predicted_taken, int actual_taken, int actual_target);
void branch_difftest_frp_update(int valid, int candidate, int active,
    int boundary, int pc, int predicted_taken, int actual_taken);
void branch_difftest_frp_activity(int token_created, int token_consumed,
    int blocked_by_issued);
void branch_difftest_loop_update(int valid, int pc, int loop_candidate,
    int loop_prediction, int reference_valid, int reference_prediction,
    int final_prediction, int actual_taken);
void branch_difftest_on_bpu_response(int resp_valid, int resp_pc,
    int predicted_pc, int predicted_taken, int predicted_slot,
    int predicted_hit);
void branch_difftest_on_frontend_cycle(int external_redirect, int queue_count,
    int downstream_ready, int dequeue_count, int request_candidate,
    int reservation_available, int request_fire, int inflight_count,
    int response_usable, int enqueue_count, int iq_reservation_available,
    int ftq_reservation_available, int ftq_count, int ftq_alloc_count,
    int ftq_pop_count, int ftq_rollback_count);
void branch_difftest_on_ares_iqftq(int iq_occ, int iq_enq, int iq_deq,
    int ftq_occ, int ftq_alloc, int ftq_pop, int redirect, int icache_refill,
    int icache_req_fire);
void branch_difftest_on_ares_stagep(int cls, int f_start, int resp_accept,
    int resp_lat, int diag, int iq_occ, int ftq_occ);
void branch_difftest_on_ares_icache(int state);
void branch_difftest_on_ares_bpu(int issue, int w_fire, int ftq_stall,
    int corr_fire, int corr_hold);
void branch_difftest_on_ares_tage(int valid, int provided, int correct);
void branch_difftest_on_tage_response(int resp_valid, int resp_pc,
    int provisional_pc, int final_pc, int final_taken);
void branch_difftest_on_tage_frontend(int override_valid, int restarted,
    int blocked, int fast_loop_provisional, int override_replaced_loop);
void branch_difftest_dump_report(void);

#ifdef __cplusplus
}
#endif

#endif
