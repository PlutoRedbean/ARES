#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>

#define EOF (-1)

#define INT_WIDTH 10

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

#define __FMT_QUIT__() state = __FMT_END__

typedef enum {
  __FMT_RUN__,
  __FMT_NUM__,
  __FMT_OUT__,
  __FMT_END__
} __fmt_state__;

typedef void (*__put_func__)(void *out, char c, int i);

void __sputc__(void *out, char c, int i);
void __putc__(void *out, char c, int i);
char *__fmt_itoa__(int num, char *str);
char *__fmt_itoh__(int num, char *str);
void fmt_analyze(__put_func__ put_func, void *out, const char *fmt, va_list *ap, int *bytes, int *index);
int __printf__(__put_func__ put_func, void *out, const char *fmt, va_list *ap);
int printf(const char *fmt, ...);
int vsprintf(char *out, const char *fmt, va_list ap);
int sprintf(char *out, const char *fmt, ...);
int snprintf(char *out, size_t n, const char *fmt, ...);
int vsnprintf(char *out, size_t n, const char *fmt, va_list ap);

void __sputc__(void *out, char c, int i) {
  *((char *)out + i) = c;
}

void __putc__(void *out, char c, int i) {
  putch(c);
}

char *__fmt_itoh__(int num, char *str) {
  int bytes = 0;
  for (int i = 0; i < 8; i++) {
    unsigned int one_hex = ((unsigned int)num & ((unsigned int)0xf0000000 >> (i << 2))) >> ((8 - 1 - i) << 2);
    if (bytes == 0 && one_hex == 0 && i < 7) continue;

    str[bytes++] = one_hex < 10 ? one_hex + 48 : one_hex + 87;
  }
  str[bytes] = '\0';
  return str;
}

char *__fmt_itoa__(int num, char *str) {
  int bytes = 0;
  if (num < 0) str[bytes++] = '-';
  int start = bytes;
  do {
    str[bytes++] = ((num % 10) > 0 ? (num % 10) : -(num % 10)) + 48;
  } while (num /= 10);
  str[bytes] = '\0';
  int end = bytes - 1;
  for(int i = 0; i < (end - start + 1) / 2; i++) {
    char tmp       = str[start + i];
    str[start + i] = str[end   - i];
    str[end   - i] = tmp           ;
  }
  return str;
}

void fmt_analyze(__put_func__ put_func, void *out, const char *fmt, va_list *ap, int *bytes, int *index) {
  __fmt_state__ state = __FMT_RUN__;
  char ph = ' ';
  int ph_num = 0;
  int total_out = 0;
  int num;
  int origin_index = *index;

  while (state != __FMT_END__) {
    switch (*(fmt + (*index) + 1)) {
      case '0':
        if (state == __FMT_NUM__) {
          total_out = total_out * 10;
          (*index)++;
        } else {
          state = __FMT_NUM__;
          ph = '0';
          (*index)++;
        }
        break;
      
      case '1':
      case '2':
      case '3':
      case '4':
      case '5':
      case '6':
      case '7':
      case '8':
      case '9':
        state = __FMT_NUM__;
        num = *(fmt + (*index) + 1) - 48;
        total_out = total_out * 10 + num;
        (*index)++;
        break;
      
      case 'd':
        state = __FMT_OUT__;
        num = va_arg(*ap, int);
        int i = 0;
        if (num < 0 && ph == '0') {
          put_func(out, '-', (*bytes)++);
          total_out--;
          i = 1;
        }
        char num_str[16];
        __fmt_itoa__(num, num_str);

        int dlen = strlen(num_str);
        if (total_out < dlen) total_out = dlen;
        ph_num = total_out - dlen;

        for (; i < total_out; i++) {
          if (i < ph_num) put_func(out, ph, (*bytes)++);
          else put_func(out, num_str[i - ph_num], (*bytes)++);
        }
        
        (*index) += 2;
        __FMT_QUIT__();
        break;

      case 'x':
        state = __FMT_OUT__;
        num = va_arg(*ap, int);
        char hex_str[9];
        __fmt_itoh__(num, hex_str);
        
        int hlen = strlen(hex_str);
        if (total_out < hlen) total_out = hlen;
        ph_num = total_out - hlen;

        for (int i = 0; i < total_out; i++) {
          if (i < ph_num) put_func(out, ph, (*bytes)++);
          else put_func(out, hex_str[i - ph_num], (*bytes)++);
        }
        
        (*index) += 2;
        __FMT_QUIT__();
        break;

      case 's':
        state = __FMT_OUT__;
        char *buf = va_arg(*ap, char *);
        for (int i = 0; i < strlen(buf); i++) put_func(out, buf[i], (*bytes)++);
        
        (*index) += 2;
        __FMT_QUIT__();
        break;

      case 'c':
        state = __FMT_OUT__;
        /* char is promoted to int when passed through '...' */
        char ch = va_arg(*ap, int);
        put_func(out, ch, (*bytes)++);
        
        (*index) += 2;
        __FMT_QUIT__();
        break;
      default :
        put_func(out, '%', (*bytes)++);
        (*index) = origin_index + 1;
        __FMT_QUIT__();
        break;
    }
  }
}

int __printf__(__put_func__ put_func, void *out, const char *fmt, va_list *ap) {
  int bytes = 0, index = 0;

  while (*(fmt + index)) {
    if (*(fmt + index) == '%') {
      fmt_analyze(put_func, out, fmt, ap, &bytes, &index);
    } else {
      put_func(out, *(fmt + index), bytes++);
      index++;
    }
  }

  // String formatting needs a terminator; console output must not transmit it.
  if (put_func == __sputc__) put_func(out, '\0', bytes);

  return bytes;
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  
  int ret = __printf__(&__putc__, NULL, fmt, &ap);
  
  va_end(ap);

  return ret;
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  panic("Not implemented");
}

int sprintf(char *out, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  
  int ret = __printf__(&__sputc__, out, fmt, &ap);
  
  va_end(ap);

  return ret;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

#endif
