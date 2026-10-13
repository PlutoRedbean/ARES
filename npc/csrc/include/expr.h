#ifndef __EXPR_H__
#define __EXPR_H__

#include <common.h>

#define REG_ERR_BUF 32
#define MAX_TOKENS 128
#define MAX_TOK_STR 32

void init_regex();

word_t expr(char *e, bool *success);
word_t paddr_read(paddr_t addr, int len);

#endif
