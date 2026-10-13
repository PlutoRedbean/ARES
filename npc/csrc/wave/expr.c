/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

// #include <isa.h>

/* We use the POSIX regex functions to process regular expressions.
 * Type 'man regex' for more information about POSIX regex functions.
 */
#include <expr.h>

#include <regex.h>
#include <reg.h>
#include <mem.h>
#include <stack.h>
#include <dbg.h>

#define faild_to_eval(format, ...) Log_warn(format, ##__VA_ARGS__); *success = false; return EOF

static bool make_token(char *e);
static void tokens_handle();
static int get_op(int start, int end);
static bool check_parentheses(bool *success, int start, int end);
static uint32_t hex2uint(bool *success, char *hex);
static bool is_expr(const int position);
static bool is_operator(const int position);
static bool is_single_eye(const int position);
static bool single_eye_trans(const int position);
static uint32_t get_priority(const int position);
static uint32_t negative(bool *success, const uint32_t val);
static uint32_t dereference(bool *success, const uint32_t val);
static uint32_t reg_val(bool *success, int start, int end);
static uint32_t eval(bool *success, int start, int end);

enum {
  TK_NOTYPE = 256, TK_EQ,
  TK_DIGITS, TK_NEQ,
  TK_AND, TK_NEG,
  TK_DER, TK_HEX,
  TK_NAME
};

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {
  {" +", TK_NOTYPE},             // spaces
  {"\\+", '+'},                  // plus
  {"\\-", '-'},                  // minus
  {"\\*", '*'},                  // multiply
  {"\\/", '/'},                  // divide
  {"\\(", '('},                  // left parentheses
  {"\\)", ')'},                  // right parentheses
  {"0x[0-9a-f]+", TK_HEX},       // hex
  {"[a-z]+[0-9]*", TK_NAME},     // name
  {"[0-9]+", TK_DIGITS},         // digits
  {"==", TK_EQ},                 // equal
  {"!=", TK_NEQ},                // not-equal
  {"&&", TK_AND},                // and
  {"\\$", '$'},                  // register
};

#define NR_REGEX ARRLEN(rules)

static regex_t re[NR_REGEX] = {};

/* Rules are used for many times.
 * Therefore we compile them only once before any usage.
 */
void init_regex() {
  int i;
  char error_msg[REG_ERR_BUF];
  int ret;

  for (i = 0; i < NR_REGEX; i ++) {
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, REG_ERR_BUF);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[MAX_TOK_STR];
} Token;

static Token tokens[MAX_TOKENS] __attribute__((used)) = {};
static int nr_token __attribute__((used))  = 0;

static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t pmatch;

  nr_token = 0;

  while (e[position] != '\0') {
    /* Try all rules one by one. */
    for (i = 0; i < NR_REGEX; i ++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 && pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;

        // Log("match rules[%d] = \"%s\" at position %d with len %d: %.*s",
        //     i, rules[i].regex, position, substr_len, substr_len, substr_start);

        position += substr_len;

        switch (rules[i].token_type) {
          case TK_NOTYPE:
            break;

          case '+':
          case '-':
          case '*':
          case '/':
          case '(':
          case ')':
          case TK_EQ:
          case TK_NEQ:
          case TK_AND:
          case '$':
            tokens[nr_token].type = rules[i].token_type;
            nr_token++;
            break;

          case TK_DIGITS:
          case TK_HEX:
          case TK_NAME:
            tokens[nr_token].type = rules[i].token_type;
            strncpy(tokens[nr_token].str, substr_start, substr_len);
            tokens[nr_token].str[substr_len] = '\0';
            nr_token++;
            break;

          default: panic("Incorrect token");
        }
        Log_Check(nr_token < MAX_TOKENS, "tokens overflow.");

        break;
      }
    }

    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
  }

  tokens_handle();
  
  return true;
}

static bool check_parentheses(bool *success, int start, int end) {
  Log_Check(start < end, "Invalid start/end range");
  
  Stack *parentheses = Stack_create();
  int left_cnt = 0, right_cnt = 0;
  uintptr_t left[MAX_TOKENS] = {2};
  uintptr_t right[MAX_TOKENS] = {1};

  for (uintptr_t i = start; i <= end; i++) {
    if (tokens[i].type == '(') {
      Log_Check(left_cnt < MAX_TOKENS, "Buffer overflow.");
      Stack_push(parentheses, (uintptr_t *)i);
      left[left_cnt] = i;
      left_cnt++;
    } else if (tokens[i].type == ')') {
      Log_Check(right_cnt < MAX_TOKENS, "Buffer overflow.");
      if (Stack_empty(parentheses)) {
        Log_warn("Invalid EXPR.");
        Stack_destroy(parentheses);
        *success = false;
        return false;
      }
      right[right_cnt] = (uintptr_t)Stack_pop(parentheses);
      right_cnt++;
    }
  }

  if (right_cnt != left_cnt) {
    Stack_destroy(parentheses);
    Log_warn("Invalid EXPR.");
    *success = false;
	  return false;
  }
  if (tokens[start].type != '(' || tokens[end].type != ')') {
    Stack_destroy(parentheses);
    *success = true;
    return false;
  }
  if (left[0] != right[right_cnt - 1]) {
    Stack_destroy(parentheses);
    *success = true;
	  return false;
  }

  Stack_destroy(parentheses);
  *success = true;
  return true;
}

static uint32_t eval(bool *success, int start, int end) {
  if (start > end) {
    /* Bad expression */
    faild_to_eval("Invalid start/end range");
  }
  else if (start == end) {
    if (!is_expr(start)) { faild_to_eval("Non-number token left."); }

    uint32_t result = 0;
    if (tokens[start].type == TK_DIGITS) {
      result = atoi(tokens[start].str);
      if (result == 0 && tokens[start].str[0] != '0') { faild_to_eval("Fail to analyze a single token."); }
    } else if (tokens[start].type == TK_HEX) {
      result = hex2uint(success, tokens[start].str);
      if (*success == false) { faild_to_eval("Fail to analyze a single token."); }
    }
    *success = true;
    return result;
  }
  else if (check_parentheses(success, start, end) == true) {
    return eval(success, start + 1, end - 1);
  }
  else {
    if (*success == false) {
      faild_to_eval("Unmatched parentheses.");
    }
    
    int op = get_op(start, end);
    if (op == EOF) {
      faild_to_eval("Fail to get op.");
    }
    // Log("op = %d", op);

    uint32_t val1 = 0, val2 = 0;
    if (!is_single_eye(op)) {
      val1 = eval(success, start, op - 1);
      if(*success == false) return EOF;
    }
    val2 = eval(success, op + 1, end);
    if(*success == false) return EOF;

    switch (tokens[op].type) {
      case '+': *success = true;return val1 + val2;break;
      case '-': *success = true;return val1 - val2;break;
      case '*': *success = true;return val1 * val2;break;
      case '/': 
        // Log("%u / %u", val1, val2);
        if (val2 == 0) {
          faild_to_eval("Arithmetic exception. Floating point exception.");
        }
        *success = true;
        return val1 / val2;
        break;

      case TK_EQ: *success = true;return val1 == val2;break;
      case TK_NEQ: *success = true;return val1 != val2;break;
      case TK_AND: *success = true;return val1 && val2;break;
      case TK_NEG: return negative(success, val2);break;

      case TK_DER: return dereference(success, val2);break;

      case '$': return reg_val(success, op, op + 1);break;
      default: assert(0);break;
    }
  }
}

word_t expr(char *e, bool *success) {
  if (!make_token(e)) {
    *success = false;
    return 0;
  }

  uint32_t result = eval(success, 0, nr_token - 1);
  if (*success == false) {
    return 0;
  }

  return result;
}

static void tokens_handle() {
  for (int i = 0; i < nr_token; i++) {
    if (single_eye_trans(i) && tokens[i].type == '-') {
      tokens[i].type = TK_NEG;
    } else if (single_eye_trans(i) && tokens[i].type == '*') {
      tokens[i].type = TK_DER;
    }
  }
}

static uint32_t negative(bool *success, const uint32_t val) {
  return -val;
}

static uint32_t dereference(bool *success, const uint32_t val) {
  if (!in_pmem(val)) {
    faild_to_eval("EXPR result: %d\n" FMT_WORD " is out of bound.", val, val);
  }
  
  return paddr_read(val);
}

static uint32_t reg_val(bool *success, int start, int end) {
  func_check(tokens[end].type == TK_NAME, EOF, "Non-name type following $");
  return isa_reg_str2val(tokens[end].str, success);
}

static uint32_t get_priority(const int position) {
  switch (tokens[position].type) {
    case '$':
    case TK_NEG:
    case TK_DER:
      return 2;
      break;
    
    case '*':
    case '/':
      return 3;
      break;
    
    case '+':
    case '-':
      return 4;
      break;

    case TK_EQ:
    case TK_NEQ:
      return 7;
      break;

    case TK_AND:
      return 11;
      break;

    default:
      return -1;
      break;
      
  }
}

static bool is_expr(const int position) {
  return (tokens[position].type == TK_DIGITS ||
          tokens[position].type == TK_HEX ||
          tokens[position].type == TK_NAME)
          ? true : false;
}

static bool is_single_eye(const int position) {
  switch (tokens[position].type) {
    case TK_NEG:
    case TK_DER:
    case '$':
      return true;
      break;
    default :
      return false;
      break;
  }
}

static bool is_operator(const int position) {
  return (tokens[position].type == TK_NAME ||
      tokens[position].type == TK_DIGITS ||
      tokens[position].type == TK_HEX) 
      ? false : true;
}

static uint32_t hex2uint(bool *success, char *hex) {
  uint32_t result = 0;

  int i = 0;
  char *c = hex + i + 2;
  if (*c >= 48 && *c <= 57) {result += (uint32_t)(*c - 48);}
  else if (*c >= 97 && *c <= 102) {result += (uint32_t)(*c - 87);}
  else { faild_to_eval("Invalid hexadecimal digits."); }
  i++;

  for (; i < 8; i++) {
    c = hex + i + 2;
    if (*c == '\0') {break;}
    
    if (*c >= 48 && *c <= 57) {
      result <<= 4;
      result += (uint32_t)(*c - 48);
    } else if (*c >= 97 && *c <= 102) {
      result <<= 4;
      result += (uint32_t)(*c - 87);
    } else { faild_to_eval("Invalid hexadecimal digits."); }
  }

  *success = true;
  return result;
}

static int get_op(int start, int end) {
  int in_parentheses = 0;
  int depth = 0;
  int result = EOF;
  int priority = 0;
  for (int i = start; i <= end; i++) {
    if (tokens[i].type == '(') {
      depth++;
    } else if (tokens[i].type == ')') {
      depth--;
    }
    in_parentheses = (depth > 0);
    if (in_parentheses || !is_operator(i)) continue;

    int new_priority = get_priority(i);
    if (new_priority > priority) {
      result = i;
      priority = new_priority;
    } else if (new_priority == priority && new_priority != 2) {
      result = i;
      priority = new_priority;
    }
  }

  return result;
}

static bool single_eye_trans(const int position) {
  if (tokens[position].type != '-' && tokens[position].type != '*') {
    return false;
  }
  else if (position == 0 || tokens[position - 1].type == '(') {
    return true;
  }
  else if (!is_expr(position + 1)) {
    return false;
  }
  else if (is_expr(position - 1) || tokens[position - 1].type == ')') {
    return false;
  } else {
    return true;
  }
}
