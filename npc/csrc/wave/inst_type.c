#include <inst_type.h>

#include <dbg.h>

Type decode_inst_type(uint32_t inst) {
  uint32_t opcode = BITS(inst, 6, 0);
  uint32_t func3 = BITS(inst, 14, 12);
  uint32_t func7 = BITS(inst, 31, 25);
  if (opcode == 0b1110011)
    return CSR;         // CSR, ecall, ebreak, mret
  else if (opcode == 0b0000011 || opcode == 0b0100011)
    return LOAD_STORE;  // lb, lbu, lh, lhu, lw, sb, sh, sw
  else if (opcode == 0b1100011 || opcode == 0b1100111 || opcode == 0b1101111)
    return BRANCH;      // jal, jalr and B-type
  else if (opcode == 0b0010111 || opcode == 0b0110111)
    return U_IMM;       // auipc and lui
  else if (opcode == 0b0110011 && func7 == 0b0000001 && func3 <= 0b011)
    return MUL_OP;      // mul, mulh, mulhsu, mulhu
  else if (opcode == 0b0110011 && func7 == 0b0000001 && func3 >= 0b100)
    return DIV_OP;      // div, divu, rem, remu
  else if (opcode == 0b0001011 && func7 == 0b0000000 && func3 == 0b000)
    return LOGIC_OP;    // Mundus custom CRC16
  else if (opcode == 0b0001011 && func7 == 0b0000001 && func3 == 0b000)
    return MUL_OP;      // Mundus custom CoreMark matrix bit-extract multiply
  else if ((opcode == 0b0110011 || opcode == 0b0010011) && (func3 == 0b010 || func3 == 0b011))
    return CMP_OP;      // slt sltu slti sltiu
  else if ((opcode == 0b0110011 || opcode == 0b0010011) && (func3 == 0b001 || func3 == 0b101))
    return SHIFT_OP;    // sll slli srl srli sra srai
  else if ((opcode == 0b0110011 || opcode == 0b0010011) && (func3 == 0b111 || func3 == 0b110 || func3 == 0b100))
    return LOGIC_OP;    // and andi or ori xor xori
  else if ((opcode == 0b0110011 || opcode == 0b0010011) && (func3 == 0b000))
    return ARITH_OP;    // add addi sub
  else if (inst == 0x0000100f)
    return ENVIRONMENT; // fence.i
  else
    panic("Undefined inst-type. Inst: " FMT_WORD, inst);
}
