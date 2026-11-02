#include <stddef.h>
#include <rtthread.h>
#include <string.h>

void *memset(void *destination, int value, size_t count)
{
    return rt_memset(destination, value, (rt_ubase_t)count);
}

void *memcpy(void *destination, const void *source, size_t count)
{
    return rt_memcpy(destination, source, (rt_ubase_t)count);
}

void *memmove(void *destination, const void *source, size_t count)
{
    return rt_memmove(destination, source, (rt_ubase_t)count);
}

int memcmp(const void *left, const void *right, size_t count)
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

size_t strlen(const char *str)
{
    return (size_t)rt_strlen(str);
}

int strncmp(const char *left, const char *right, size_t count)
{
    return (int)rt_strncmp(left, right, (rt_size_t)count);
}

int strcmp(const char *left, const char *right)
{
    while ((*left != '\0') && (*left == *right))
    {
        left++;
        right++;
    }
    return (int)(unsigned char)*left - (int)(unsigned char)*right;
}

char *strcpy(char *destination, const char *source)
{
    char *result = destination;

    while ((*destination++ = *source++) != '\0')
    {
    }
    return result;
}

char *strncpy(char *destination, const char *source, size_t count)
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

char *strcat(char *destination, const char *source)
{
    char *tail = destination + rt_strlen(destination);

    strcpy(tail, source);
    return destination;
}
