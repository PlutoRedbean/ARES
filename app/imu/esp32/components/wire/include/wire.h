#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Wire format shared by both hops:
 *
 *   WT61C --UART--> IMU node --ESP-NOW--> bridge node --UART--> FPGA
 *
 * The same frame is produced by the IMU node and forwarded unchanged by the
 * bridge node, so there is exactly one frame definition to keep in sync with
 * the FPGA.
 *
 *   off  size  field
 *   0    1     0xA5  sync0
 *   1    1     0x5A  sync1
 *   2    1     version (1)
 *   3    1     type (1 = data, 2 = status)
 *   4    1     flags
 *   5    1     body length (28)
 *   6    28    body
 *   34   2     CRC-16/CCITT-FALSE of bytes [2, 34), little endian
 *
 * Everything is little endian. Raw WT61C values are forwarded as int16 LSB;
 * see docs/PROTOCOL.md for the scale factors.
 *
 * Pure C, no ESP-IDF dependency: unit-tested on the host.
 */

#define WIRE_SYNC0   0xA5u
#define WIRE_SYNC1   0x5Au
#define WIRE_VERSION 0x01u

#define WIRE_TYPE_DATA   0x01u
#define WIRE_TYPE_STATUS 0x02u

#define WIRE_HDR_LEN   6u
#define WIRE_BODY_LEN  28u
#define WIRE_CRC_LEN   2u
#define WIRE_FRAME_LEN (WIRE_HDR_LEN + WIRE_BODY_LEN + WIRE_CRC_LEN)   /* 36 */
#define WIRE_MAX_FRAME WIRE_FRAME_LEN

#define WIRE_FLAG_ACC_VALID   (1u << 0)
#define WIRE_FLAG_GYRO_VALID  (1u << 1)
#define WIRE_FLAG_ANGLE_VALID (1u << 2)
#define WIRE_FLAG_DEGRADED    (1u << 3)   /* IMU fell back to 9600 baud / 20 Hz */
#define WIRE_FLAG_IMU_STALE   (1u << 4)   /* no valid WT61C packet recently */
#define WIRE_FLAG_LINK_LOST   (1u << 5)   /* bridge node saw no frame recently */

/* Control frames are bridge -> IMU node over ESP-NOW, two bytes:
 *   { WIRE_CTRL_MAGIC, cmd }
 * They are not wire frames and are never sent to the FPGA.
 * cmd is a WT61C command byte (0x52 zero, 0x67 accel calibrate). */
#define WIRE_CTRL_MAGIC 0xC1u
#define WIRE_CTRL_LEN   2u

static inline size_t wire_encode_ctrl(uint8_t cmd, uint8_t out[WIRE_CTRL_LEN])
{
    out[0] = WIRE_CTRL_MAGIC;
    out[1] = cmd;
    return WIRE_CTRL_LEN;
}

typedef struct {
    uint8_t  flags;
    uint16_t seq;
    uint32_t t_ms;        /* IMU node uptime, milliseconds */
    int16_t  acc[3];      /* raw LSB, +-16 g full scale */
    int16_t  gyro[3];     /* raw LSB, +-2000 dps full scale */
    int16_t  angle[3];    /* raw LSB, roll/pitch/yaw, +-180 deg */
    int16_t  temp_raw;    /* raw LSB, see wt61c_temp_c() */
    uint8_t  rate_hz;     /* configured output rate */
} wire_data_t;

typedef struct {
    uint16_t seq;
    uint32_t t_ms;
    uint32_t uptime_s;
    uint32_t frames;        /* valid WT61C packets since boot */
    uint16_t crc_err;
    uint16_t resync;
    uint16_t uart_ovf;
    uint16_t partial;       /* samples emitted without all three packets */
    uint32_t baud;
    uint8_t  flags;
} wire_status_t;

uint16_t wire_crc16(const uint8_t *data, size_t len);

size_t wire_encode_data(const wire_data_t *d, uint8_t *out, size_t cap);
size_t wire_encode_status(const wire_status_t *s, uint8_t *out, size_t cap);

/* Decoders require `len` bytes starting at `buf`; they do not search. */
bool wire_decode_data(const uint8_t *buf, size_t len, wire_data_t *out);
bool wire_decode_status(const uint8_t *buf, size_t len, wire_status_t *out);

/* Returns the offset of the first byte sequence that decodes as a valid
 * frame of any type, or `len` if there is none. Used by the bridge node and
 * by the reference parser to resynchronise. */
size_t wire_scan(const uint8_t *buf, size_t len, uint8_t *type_out);
