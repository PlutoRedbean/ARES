#ifndef __IRINGBUF_H__
#define __IRINGBUF_H__

typedef struct ringbuf {
    int index;
    int head;
    int len;
    int size;
} ringbuf;

#endif
