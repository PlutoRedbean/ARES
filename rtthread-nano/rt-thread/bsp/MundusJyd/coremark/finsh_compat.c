#include <stddef.h>

#include <rtthread.h>

/* The firmware links with -nostdlib, so it has to supply its own runtime.
 *
 * These carry __attribute__((used)) because the whole program is built with
 * -flto: the compiler can decide late (after the point where it would have
 * discarded an unreferenced definition) to lower a struct copy into a memcpy
 * call, which then has no definition to bind to.  Marking them used keeps them
 * in the LTO symbol table regardless. */
#define MT_RUNTIME __attribute__((used))

/* Nano 3.1.5's built-in "ps" command references this symbol even when the
 * optional FinSH command collection is not linked.  The accelerator image
 * intentionally keeps only help/quit plus the miniTensor commands. */
MT_RUNTIME long list_thread(void)
{
    return 0;
}

MT_RUNTIME void *memset(void *destination, int value, size_t count)
{
    return rt_memset(destination, value, (rt_ubase_t)count);
}

MT_RUNTIME void *memcpy(void *destination, const void *source, size_t count)
{
    return rt_memcpy(destination, source, (rt_ubase_t)count);
}

MT_RUNTIME void *memmove(void *destination, const void *source, size_t count)
{
    return rt_memmove(destination, source, (rt_ubase_t)count);
}

MT_RUNTIME int memcmp(const void *left, const void *right, size_t count)
{
    const unsigned char *a = (const unsigned char *)left;
    const unsigned char *b = (const unsigned char *)right;

    while (count-- > 0u)
    {
        if (*a != *b)
        {
            return (int)*a - (int)*b;
        }
        a++;
        b++;
    }
    return 0;
}

MT_RUNTIME size_t strlen(const char *str)
{
    return (size_t)rt_strlen(str);
}

MT_RUNTIME int strncmp(const char *left, const char *right, size_t count)
{
    return (int)rt_strncmp(left, right, (rt_size_t)count);
}

MT_RUNTIME int strcmp(const char *left, const char *right)
{
    while ((*left != '\0') && (*left == *right))
    {
        left++;
        right++;
    }
    return (int)(unsigned char)*left - (int)(unsigned char)*right;
}

MT_RUNTIME char *strcpy(char *destination, const char *source)
{
    char *result = destination;

    while ((*destination++ = *source++) != '\0')
    {
    }
    return result;
}

MT_RUNTIME char *strncpy(char *destination, const char *source, size_t count)
{
    char *result = destination;

    while ((count > 0u) && (*source != '\0'))
    {
        *destination++ = *source++;
        count--;
    }
    while (count-- > 0u)
    {
        *destination++ = '\0';
    }
    return result;
}

MT_RUNTIME char *strcat(char *destination, const char *source)
{
    char *tail = destination + rt_strlen(destination);

    strcpy(tail, source);
    return destination;
}
