#include "core_portme.h"
#include "coremark.h"

#include "board.h"

#include <stdarg.h>

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = COREMARK_ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static rt_uint32_t start_ms;
static rt_uint32_t stop_ms;

#define COREMARK_PRINTF_BUFFER_SIZE 256u

static void coremark_append_char(char      *buffer,
                                 rt_size_t  capacity,
                                 rt_size_t *length,
                                 char       value)
{
    if (*length + 1u < capacity)
        buffer[*length] = value;
    (*length)++;
}

static void coremark_append_text(char       *buffer,
                                 rt_size_t   capacity,
                                 rt_size_t  *length,
                                 const char *text,
                                 rt_size_t   text_length)
{
    rt_size_t index;

    for (index = 0; index < text_length; index++)
        coremark_append_char(buffer, capacity, length, text[index]);
}

/* Format the finite, small positive/negative values emitted by CoreMark. */
static void coremark_append_fixed(char      *buffer,
                                  rt_size_t  capacity,
                                  rt_size_t *length,
                                  double     value,
                                  int        precision)
{
    char          integral_text[16];
    char          fractional_text[10];
    unsigned long integral;
    unsigned long fraction;
    unsigned long scale = 1u;
    int           count;
    int           index;

    if (precision < 0)
        precision = 6;
    if (precision > 9)
        precision = 9;

    if (value < 0.0)
    {
        coremark_append_char(buffer, capacity, length, '-');
        value = -value;
    }

    integral = (unsigned long)value;
    for (index = 0; index < precision; index++)
        scale *= 10u;

    fraction = (unsigned long)(((value - (double)integral) *
                                (double)scale) + 0.5);
    if (fraction >= scale)
    {
        integral++;
        fraction -= scale;
    }

    count = rt_snprintf(integral_text, sizeof(integral_text), "%lu", integral);
    if (count > 0)
        coremark_append_text(buffer, capacity, length, integral_text,
                             (rt_size_t)count);

    if (precision == 0)
        return;

    coremark_append_char(buffer, capacity, length, '.');
    for (index = precision - 1; index >= 0; index--)
    {
        fractional_text[index] = (char)('0' + fraction % 10u);
        fraction /= 10u;
    }
    coremark_append_text(buffer, capacity, length, fractional_text,
                         (rt_size_t)precision);
}

int coremark_printf(const char *format, ...)
{
    char       output[COREMARK_PRINTF_BUFFER_SIZE];
    char       conversion[16];
    char       converted[COREMARK_PRINTF_BUFFER_SIZE];
    rt_size_t  output_length = 0;
    va_list    arguments;

    va_start(arguments, format);
    while (*format != '\0')
    {
        rt_size_t conversion_length;
        int       precision = -1;
        int       is_long = 0;
        char      type;
        int       converted_length = 0;

        if (*format != '%')
        {
            coremark_append_char(output, sizeof(output), &output_length,
                                 *format++);
            continue;
        }

        conversion_length = 0;
        conversion[conversion_length++] = *format++;
        if (*format == '%')
        {
            coremark_append_char(output, sizeof(output), &output_length,
                                 *format++);
            continue;
        }

        while (*format == '-' || *format == '+' || *format == ' ' ||
               *format == '#' || *format == '0')
        {
            if (conversion_length + 1u < sizeof(conversion))
                conversion[conversion_length++] = *format;
            format++;
        }
        while (*format >= '0' && *format <= '9')
        {
            if (conversion_length + 1u < sizeof(conversion))
                conversion[conversion_length++] = *format;
            format++;
        }
        if (*format == '.')
        {
            precision = 0;
            if (conversion_length + 1u < sizeof(conversion))
                conversion[conversion_length++] = *format;
            format++;
            while (*format >= '0' && *format <= '9')
            {
                precision = precision * 10 + (*format - '0');
                if (conversion_length + 1u < sizeof(conversion))
                    conversion[conversion_length++] = *format;
                format++;
            }
        }
        if (*format == 'l')
        {
            is_long = 1;
            if (conversion_length + 1u < sizeof(conversion))
                conversion[conversion_length++] = *format;
            format++;
        }

        type = *format;
        if (type == '\0')
            break;
        format++;
        if (conversion_length + 1u < sizeof(conversion))
            conversion[conversion_length++] = type;
        conversion[conversion_length] = '\0';

        if (type == 'f')
        {
            coremark_append_fixed(output, sizeof(output), &output_length,
                                  va_arg(arguments, double), precision);
            continue;
        }

        switch (type)
        {
        case 'd':
        case 'i':
            if (is_long)
                converted_length = rt_snprintf(converted, sizeof(converted),
                                               conversion,
                                               va_arg(arguments, long));
            else
                converted_length = rt_snprintf(converted, sizeof(converted),
                                               conversion,
                                               va_arg(arguments, int));
            break;
        case 'u':
        case 'x':
        case 'X':
            if (is_long)
                converted_length = rt_snprintf(
                    converted, sizeof(converted), conversion,
                    va_arg(arguments, unsigned long));
            else
                converted_length = rt_snprintf(
                    converted, sizeof(converted), conversion,
                    va_arg(arguments, unsigned int));
            break;
        case 's':
            converted_length = rt_snprintf(converted, sizeof(converted),
                                           conversion,
                                           va_arg(arguments, const char *));
            break;
        case 'c':
            converted_length = rt_snprintf(converted, sizeof(converted),
                                           conversion,
                                           va_arg(arguments, int));
            break;
        case 'p':
            converted_length = rt_snprintf(converted, sizeof(converted),
                                           conversion,
                                           va_arg(arguments, void *));
            break;
        default:
            coremark_append_text(output, sizeof(output), &output_length,
                                 conversion, conversion_length);
            break;
        }

        if (converted_length > 0)
            coremark_append_text(output, sizeof(output), &output_length,
                                 converted, (rt_size_t)converted_length);
    }
    va_end(arguments);

    if (output_length >= sizeof(output))
        output[sizeof(output) - 1u] = '\0';
    else
        output[output_length] = '\0';
    rt_kprintf("%s", output);
    return (int)output_length;
}

void start_time(void)
{
    start_ms = rt_hw_timer_get_ms();
}

void stop_time(void)
{
    stop_ms = rt_hw_timer_get_ms();
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(rt_uint32_t)(stop_ms - start_ms);
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)1000;
}

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    portable->portable_id = 1;
}

void portable_fini(core_portable *portable)
{
    portable->portable_id = 0;
}

void ioe_init(void)
{
}
