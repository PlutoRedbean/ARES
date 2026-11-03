#ifndef LLM_MT_MODEL_H
#define LLM_MT_MODEL_H

#include <stdint.h>

void llm_mt_reset(void);
int llm_mt_feed(int token_id);
int llm_mt_argmax(void);
int llm_mt_test_gemv(void);
int llm_mt_test_full(void);
int llm_mt_debug_state(void);
int llm_mt_debug_i2(void);
int llm_mt_test_hh(void);
int llm_mt_test_simple(void);
int llm_mt_last_error(void);
int llm_mt_vocab_size(void);
int llm_mt_char_to_id(char c);
char llm_mt_id_to_char(int id);

#endif
