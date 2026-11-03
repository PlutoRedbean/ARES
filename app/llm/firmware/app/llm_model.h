#ifndef LLM_MODEL_H
#define LLM_MODEL_H

#include <stdint.h>

void llm_load_weights(void);
void llm_reset(void);
void llm_feed(int token_id);
int llm_argmax(void);
int llm_argmax_penalized(const int *recent, int n, int32_t penalty);
int llm_vocab_size(void);
int llm_char_to_id(char c);
char llm_id_to_char(int id);
const char *llm_vocab_ptr(void);

#endif
