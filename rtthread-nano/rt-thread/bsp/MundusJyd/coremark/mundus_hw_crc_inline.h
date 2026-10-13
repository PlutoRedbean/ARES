#ifndef MUNDUS_HW_CRC_INLINE_H
#define MUNDUS_HW_CRC_INLINE_H

/*
 * Mundus custom-0 funct7=0 CRC instruction.
 *
 * The instruction is a pure ALU operation:
 *
 *   rd = crcu16(rs1[15:0], rs2[15:0])
 *
 * Keep the asm non-volatile and free of memory clobbers so GCC can schedule it
 * with surrounding independent work.  A 32-bit temporary also makes the
 * zero-extended hardware result explicit before converting it to ee_u16.
 */
static inline __attribute__((always_inline)) ee_u16
mundus_hw_crc16_inline(ee_u16 newval, ee_u16 crc)
{
    ee_u32 result;

    __asm__(".insn r 0x0b, 0, 0, %0, %1, %2"
            : "=r"(result)
            : "r"((ee_u32)newval), "r"((ee_u32)crc));
    return (ee_u16)result;
}

static inline __attribute__((always_inline)) ee_u16
mundus_hw_crcu32_inline(ee_u32 newval, ee_u16 crc)
{
    crc = mundus_hw_crc16_inline((ee_u16)newval, crc);
    return mundus_hw_crc16_inline((ee_u16)(newval >> 16), crc);
}

/* coremark.h has already declared these names when this overlay is included. */
#define crc16  mundus_hw_crc16_inline
#define crcu16 mundus_hw_crc16_inline
#define crcu32 mundus_hw_crcu32_inline

#endif
