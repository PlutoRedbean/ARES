import { describe, expect, it } from 'vitest';
import { LineParser } from '../src/serial/lineParser';
import { parseCommandLine } from '../src/app/commands';

function parser(): LineParser {
  return new LineParser(64);
}

describe('lineParser', () => {
  it('P01 一次输入 START\\n 解析出 START', () => {
    const lines = parser().feed('START\n');
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ status: 'ok', text: 'START' });
  });

  it('P02 分片 STA + RT\\n 拼成 START', () => {
    const p = parser();
    expect(p.feed('STA')).toEqual([]);
    const lines = p.feed('RT\n');
    expect(lines[0]).toMatchObject({ status: 'ok', text: 'START' });
  });

  it('P03 FIST\\r\\n 去掉 \\r', () => {
    const lines = parser().feed('FIST\r\n');
    expect(lines[0]).toMatchObject({ status: 'ok', text: 'FIST', raw: 'FIST' });
  });

  it('P04 "  mode  \\n" 归一化为 MODE', () => {
    const lines = parser().feed('  mode  \n');
    expect(lines[0]).toMatchObject({ status: 'ok', text: 'MODE' });
    expect(parseCommandLine(lines[0].text)?.command).toBe('MODE');
  });

  it('P05 空行 / 未知指令 -> 忽略', () => {
    const p = parser();
    const lines = p.feed('\n \nBOGUS\n');
    expect(lines.map((l) => l.status)).toEqual(['empty', 'empty', 'ok']);
    expect(parseCommandLine(lines[2].text)).toBeNull();
  });

  it('P06 超长行丢弃到下一个换行，后续行不受影响', () => {
    const p = parser();
    const long = p.feed(`${'A'.repeat(80)}\n`);
    expect(long[0].status).toBe('too-long');
    const next = p.feed('FIST\n');
    expect(next[0]).toMatchObject({ status: 'ok', text: 'FIST' });
  });

  it('P07 非 ASCII 整行忽略', () => {
    const lines = parser().feed('握拳\nFIST\n');
    expect(lines[0].status).toBe('non-ascii');
    expect(lines[1]).toMatchObject({ status: 'ok', text: 'FIST' });
  });

  it('一次分片里包含多条指令', () => {
    const lines = parser().feed('START\nFIST\nPOINT\n');
    expect(lines.map((l) => l.text)).toEqual(['START', 'FIST', 'POINT']);
  });

  it('reset 丢弃未完成的行', () => {
    const p = parser();
    p.feed('STA');
    p.reset();
    expect(p.feed('RT\n')).toEqual([{ raw: 'RT', text: 'RT', status: 'ok' }]);
  });
});
