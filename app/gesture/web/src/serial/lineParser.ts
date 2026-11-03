import { CONFIG } from '../config';

export type LineStatus = 'ok' | 'empty' | 'non-ascii' | 'too-long';

export interface ParsedLine {
  /** 原始内容，已去掉行尾 \r，保留大小写与空白 */
  raw: string;
  /** 归一化后的内容：trim + 大写；非 ok 状态时为空或原文 */
  text: string;
  status: LineStatus;
}

const NON_ASCII = /[^\t\n\r\x20-\x7e]/;
const HARD_BUFFER_LIMIT = 4096;

/**
 * 把任意分片的串口文本拆成行。
 * - 一行一条指令，\n 结尾，兼容 \r\n
 * - 首尾空白忽略、转大写
 * - 单行超过 maxLineBytes 时整行丢弃到下一个换行
 * - 含非 ASCII 字符的整行忽略
 */
export class LineParser {
  private buffer = '';
  private overflow = false;

  constructor(private readonly maxLineBytes: number = CONFIG.serial.maxLineBytes) {}

  feed(chunk: string): ParsedLine[] {
    const out: ParsedLine[] = [];

    for (let i = 0; i < chunk.length; i += 1) {
      const ch = chunk[i];

      if (ch === '\n') {
        const raw = this.buffer;
        this.buffer = '';
        const overflow = this.overflow;
        this.overflow = false;
        out.push(this.finishLine(raw, overflow));
        continue;
      }

      this.buffer += ch;

      if (this.buffer.length > this.maxLineBytes) {
        this.overflow = true;
      }
      // 防御异常长数据：保留“已溢出”标记，清空缓冲，继续等换行
      if (this.buffer.length > HARD_BUFFER_LIMIT) {
        this.buffer = '';
        this.overflow = true;
      }
    }

    return out;
  }

  /** 丢弃未完成的行（断线/重连时调用） */
  reset(): void {
    this.buffer = '';
    this.overflow = false;
  }

  private finishLine(buffer: string, overflow: boolean): ParsedLine {
    const withoutCr = buffer.endsWith('\r') ? buffer.slice(0, -1) : buffer;
    if (overflow) {
      return { raw: withoutCr.slice(0, 160), text: '', status: 'too-long' };
    }
    if (NON_ASCII.test(withoutCr)) {
      return { raw: withoutCr, text: '', status: 'non-ascii' };
    }
    const text = withoutCr.trim();
    if (!text) {
      return { raw: withoutCr, text: '', status: 'empty' };
    }
    return { raw: withoutCr, text: text.toUpperCase(), status: 'ok' };
  }
}
