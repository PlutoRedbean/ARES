#include "wire.h"

#include <string.h>

uint16_t wire_crc16(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x8000u) ? (uint16_t)((crc << 1) ^ 0x1021u)
                                  : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

static void put_u16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v & 0xFFu);
    p[1] = (uint8_t)(v >> 8);
}

static void put_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFFu);
    p[1] = (uint8_t)((v >> 8) & 0xFFu);
    p[2] = (uint8_t)((v >> 16) & 0xFFu);
    p[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static uint16_t get_u16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t get_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static size_t encode(uint8_t type, uint8_t flags, const uint8_t *body,
                     uint8_t *out, size_t cap)
{
    if (out == NULL || cap < WIRE_FRAME_LEN) {
        return 0;
    }
    out[0] = WIRE_SYNC0;
    out[1] = WIRE_SYNC1;
    out[2] = WIRE_VERSION;
    out[3] = type;
    out[4] = flags;
    out[5] = (uint8_t)WIRE_BODY_LEN;
    memcpy(out + WIRE_HDR_LEN, body, WIRE_BODY_LEN);

    const uint16_t crc = wire_crc16(out + 2, 4u + WIRE_BODY_LEN);
    put_u16(out + WIRE_HDR_LEN + WIRE_BODY_LEN, crc);
    return WIRE_FRAME_LEN;
}

size_t wire_encode_data(const wire_data_t *d, uint8_t *out, size_t cap)
{
    uint8_t body[WIRE_BODY_LEN] = {0};

    put_u16(body + 0, d->seq);
    put_u32(body + 2, d->t_ms);
    for (int i = 0; i < 3; i++) {
        put_u16(body + 6 + i * 2, (uint16_t)d->acc[i]);
    }
    for (int i = 0; i < 3; i++) {
        put_u16(body + 12 + i * 2, (uint16_t)d->gyro[i]);
    }
    for (int i = 0; i < 3; i++) {
        put_u16(body + 18 + i * 2, (uint16_t)d->angle[i]);
    }
    put_u16(body + 24, (uint16_t)d->temp_raw);
    body[26] = d->rate_hz;
    body[27] = 0;

    return encode(WIRE_TYPE_DATA, d->flags, body, out, cap);
}

size_t wire_encode_status(const wire_status_t *s, uint8_t *out, size_t cap)
{
    uint8_t body[WIRE_BODY_LEN] = {0};

    put_u16(body + 0, s->seq);
    put_u32(body + 2, s->t_ms);
    put_u32(body + 6, s->uptime_s);
    put_u32(body + 10, s->frames);
    put_u16(body + 14, s->crc_err);
    put_u16(body + 16, s->resync);
    put_u16(body + 18, s->uart_ovf);
    put_u16(body + 20, s->partial);
    put_u32(body + 22, s->baud);
    body[26] = s->flags;
    body[27] = 0;

    return encode(WIRE_TYPE_STATUS, s->flags, body, out, cap);
}

static bool header_ok(const uint8_t *buf, size_t len)
{
    return len >= WIRE_FRAME_LEN &&
           buf[0] == WIRE_SYNC0 &&
           buf[1] == WIRE_SYNC1 &&
           buf[2] == WIRE_VERSION &&
           buf[5] == WIRE_BODY_LEN;
}

static bool crc_ok(const uint8_t *buf)
{
    const uint16_t want = get_u16(buf + WIRE_HDR_LEN + WIRE_BODY_LEN);
    const uint16_t got = wire_crc16(buf + 2, 4u + WIRE_BODY_LEN);
    return want == got;
}

bool wire_decode_data(const uint8_t *buf, size_t len, wire_data_t *out)
{
    if (out == NULL || !header_ok(buf, len) || buf[3] != WIRE_TYPE_DATA ||
        !crc_ok(buf)) {
        return false;
    }
    const uint8_t *b = buf + WIRE_HDR_LEN;

    out->flags = buf[4];
    out->seq = get_u16(b + 0);
    out->t_ms = get_u32(b + 2);
    for (int i = 0; i < 3; i++) {
        out->acc[i] = (int16_t)get_u16(b + 6 + i * 2);
    }
    for (int i = 0; i < 3; i++) {
        out->gyro[i] = (int16_t)get_u16(b + 12 + i * 2);
    }
    for (int i = 0; i < 3; i++) {
        out->angle[i] = (int16_t)get_u16(b + 18 + i * 2);
    }
    out->temp_raw = (int16_t)get_u16(b + 24);
    out->rate_hz = b[26];
    return true;
}

bool wire_decode_status(const uint8_t *buf, size_t len, wire_status_t *out)
{
    if (out == NULL || !header_ok(buf, len) || buf[3] != WIRE_TYPE_STATUS ||
        !crc_ok(buf)) {
        return false;
    }
    const uint8_t *b = buf + WIRE_HDR_LEN;

    out->flags = buf[4];
    out->seq = get_u16(b + 0);
    out->t_ms = get_u32(b + 2);
    out->uptime_s = get_u32(b + 6);
    out->frames = get_u32(b + 10);
    out->crc_err = get_u16(b + 14);
    out->resync = get_u16(b + 16);
    out->uart_ovf = get_u16(b + 18);
    out->partial = get_u16(b + 20);
    out->baud = get_u32(b + 22);
    return true;
}

size_t wire_scan(const uint8_t *buf, size_t len, uint8_t *type_out)
{
    for (size_t i = 0; i + WIRE_FRAME_LEN <= len; i++) {
        if (!header_ok(buf + i, len - i) || !crc_ok(buf + i)) {
            continue;
        }
        const uint8_t type = buf[i + 3];
        if (type != WIRE_TYPE_DATA && type != WIRE_TYPE_STATUS) {
            continue;
        }
        if (type_out != NULL) {
            *type_out = type;
        }
        return i;
    }
    return len;
}
