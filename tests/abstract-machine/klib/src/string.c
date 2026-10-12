#include <klib.h>
#include <klib-macros.h>
#include <stdint.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

static inline int byte_cmp(const void *s1, const void *s2, size_t offset) {
  return *((unsigned char *)s1 + offset) - *((unsigned char *)s2 + offset);
}

static void _byte_memcpy(void *out, const void *in, size_t n) {
  for (volatile size_t i = 0; i < n; i++) {
    *((char *)out + i) = *((char *)in + i);
  }
}

size_t strlen(const char *s) {
  size_t i = 0;
  for (i = 0; s[i] != '\0'; i++);
  return i;
}

char *strcpy(char *dst, const char *src) {
  size_t i;
  for (i = 0; src[i] != '\0'; i++) *(dst + i) = src[i];

  *(dst + i) = '\0';

  return dst;
}

char *strncpy(char *dst, const char *src, size_t n) {
  panic("Not implemented");
}

char *strcat(char *dst, const char *src) {
  strcpy(dst + strlen(dst), src);
  return dst;
}

int strcmp(const char *s1, const char *s2) {
  if (s1 == s2) return 0;
  
  int result;
  
  for (size_t i = 0; s1[i] != '\0' || s2[i] != '\0'; i++) {
    result = byte_cmp(s1, s2, i);
    if (result != 0) return result;
  }
  
  return 0;
}

int strncmp(const char *s1, const char *s2, size_t n) {
  if (s1 == s2) return 0;

  int result;
  
  for (size_t i = 0; (s1[i] != '\0' || s2[i] != '\0') && i < n; i++) {
    result = byte_cmp(s1, s2, i);
    if (result != 0) return result;
  }
  
  return 0;
}

void *memset(void *s, int c, size_t n) {
  for (size_t i = 0; i < n; i++) {
    *((unsigned char *)s + i) = (unsigned char)c;
  }
  return s;
}

void *memmove(void *dst, const void *src, size_t n) {
  void* ret = dst;
  if (dst == src) {
    return ret;
  } else if (dst < src) {
    _byte_memcpy(dst, src, n);
  } else {
    while (n--) {
      *((char*)dst + n) = *((char*)src + n);
    }
  }
  return ret;
}

void *memcpy(void *out, const void *in, size_t n) {
  void *result = out;
  size_t align_cnt = 0;
  if (n <= 0) {
    return result;
  } else if (n < 32) {
    _byte_memcpy(out, in, n);
    return result;
  } else if (((uintptr_t)out & 0x3u) != ((uintptr_t)in & 0x3u)) {
    _byte_memcpy(out, in, n);
    return result;
  } else if (((uintptr_t)out & 0x3u) != 0) {
    align_cnt = 4 - ((uintptr_t)out & 0x3u);
    _byte_memcpy(out, in, align_cnt);
  }

  uint32_t *dest = out + align_cnt;
  const uint32_t *src = in + align_cnt;
  size_t cnt = n - align_cnt;

  align_cnt = cnt & 0x3u;
  cnt >>= 2;
  for (size_t i = 0; i < cnt; i++) {
    *(dest++) = *(src++);
  }
  if (align_cnt != 0) {
    _byte_memcpy(dest, src, align_cnt);
  }
  return result;
}

int memcmp(const void *s1, const void *s2, size_t n) {
  if (n == 0) return 0;

  int result;

  for (size_t i = 0; i < n; i++) {
    result = byte_cmp(s1, s2, i);
    if (result != 0) return result;
  }

  return 0;
}

#endif
