import { CONFIG } from '../config';
import { LineParser, type ParsedLine } from './lineParser';
import {
  describePort,
  getSerialApi,
  type SerialApiLike,
  type SerialPortInfoLike,
  type SerialPortLike,
} from './serialTypes';

export type SerialState = 'unsupported' | 'disconnected' | 'connecting' | 'connected' | 'error';

export interface SerialLinkEvents {
  onLine(line: ParsedLine): void;
  onState(state: SerialState, detail: string): void;
  onPort(info: SerialPortInfoLike | null): void;
  onLog(message: string): void;
}

/**
 * Web Serial 连接、读循环、断线检测、重连。
 * 只负责链路，不解析指令（行解析交给 LineParser）。
 */
export class WebSerialLink {
  private readonly api: SerialApiLike | null;
  private readonly parser = new LineParser(CONFIG.serial.maxLineBytes);
  private decoder = new TextDecoder('utf-8', { fatal: false });
  private readonly events: SerialLinkEvents;

  private port: SerialPortLike | null = null;
  private reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  private state: SerialState = 'disconnected';
  private detail = '';
  private closing = false;
  private portInfo: SerialPortInfoLike | null = null;
  private disposed = false;

  constructor(events: SerialLinkEvents) {
    this.events = events;
    this.api = getSerialApi();
    if (!this.api) {
      this.state = 'unsupported';
      this.detail = '当前浏览器不支持 Web Serial（需要 Chrome / Edge，且通过 localhost 或 https 访问）';
    }
    this.api?.addEventListener('disconnect', this.handleHardwareDisconnect);
    this.api?.addEventListener('connect', this.handleHardwareConnect);
  }

  get isSupported(): boolean {
    return this.api !== null;
  }

  get currentState(): SerialState {
    return this.state;
  }

  get portLabel(): string {
    return this.portInfo ? describePort(this.portInfo) : '—';
  }

  /** 连接：优先使用已授权端口，没有则弹出端口选择框。 */
  async connect(): Promise<void> {
    if (!this.api) {
      this.setState('unsupported', '浏览器不支持 Web Serial');
      return;
    }
    if (this.state === 'connected' || this.state === 'connecting') return;

    this.setState('connecting', '正在连接串口…');
    await this.closePort();

    let lastError: unknown = null;

    // 1) 已授权端口：支持关闭标签页后直接重连
    try {
      const ports = await this.api.getPorts();
      for (const port of ports) {
        try {
          await this.openPort(port);
          return;
        } catch (error) {
          lastError = error;
        }
      }
    } catch (error) {
      lastError = error;
    }

    // 2) 让用户选择新端口（必须在用户手势中调用）
    try {
      const port = await this.api.requestPort();
      await this.openPort(port);
    } catch (error) {
      lastError = error;
      const message = this.describeError(error, lastError);
      this.setState('error', message);
      this.events.onLog(`[serial] 连接失败：${message}`);
      throw error instanceof Error ? error : new Error(message);
    }
  }

  async disconnect(): Promise<void> {
    this.closing = true;
    await this.closePort();
    this.closing = false;
    this.parser.reset();
    this.setState('disconnected', '串口已断开');
  }

  dispose(): void {
    this.disposed = true;
    void this.disconnect();
    this.api?.removeEventListener('disconnect', this.handleHardwareDisconnect);
    this.api?.removeEventListener('connect', this.handleHardwareConnect);
  }

  private async openPort(port: SerialPortLike): Promise<void> {
    this.closing = false;
    await port.open({
      baudRate: CONFIG.serial.baudRate,
      dataBits: 8,
      stopBits: 1,
      parity: 'none',
      flowControl: 'none',
    });

    this.port = port;
    this.portInfo = port.getInfo();
    this.events.onPort(this.portInfo);
    this.parser.reset();
    this.decoder = new TextDecoder('utf-8', { fatal: false });

    const readable = port.readable;
    if (!readable) {
      await this.closePort();
      throw new Error('串口没有可读流');
    }
    this.reader = readable.getReader();
    this.setState('connected', `已连接 ${describePort(this.portInfo)} · 115200 8N1`);
    this.events.onLog(`[serial] 已连接 ${describePort(this.portInfo)}`);
    void this.readLoop(this.reader);
  }

  private async readLoop(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        if (!value || value.length === 0) continue;
        const text = this.decoder.decode(value, { stream: true });
        for (const line of this.parser.feed(text)) {
          this.events.onLine(line);
        }
      }
      if (!this.closing && !this.disposed) {
        await this.fail('串口读取结束，可能已拔出');
      }
    } catch (error) {
      if (!this.closing && !this.disposed) {
        await this.fail(`串口读取中断：${this.describeError(error)}`);
      }
    } finally {
      try {
        reader.releaseLock();
      } catch {
        /* 已释放 */
      }
    }
  }

  private async fail(message: string): Promise<void> {
    if (this.state === 'error' && this.detail === message) return;
    await this.closePort();
    this.parser.reset();
    this.setState('error', message);
    this.events.onLog(`[serial] ${message}`);
  }

  private async closePort(): Promise<void> {
    const reader = this.reader;
    this.reader = null;
    if (reader) {
      try {
        await reader.cancel();
      } catch {
        /* 忽略取消异常 */
      }
      try {
        reader.releaseLock();
      } catch {
        /* 忽略重复释放 */
      }
    }

    const port = this.port;
    this.port = null;
    this.portInfo = null;
    if (port) {
      try {
        await port.close();
      } catch {
        /* 端口可能已经被系统关闭 */
      }
    }
    this.events.onPort(null);
  }

  private setState(state: SerialState, detail: string): void {
    this.state = state;
    this.detail = detail;
    this.events.onState(state, detail);
  }

  private describeError(error: unknown, fallback: unknown = null): string {
    const source = error instanceof Error ? error : fallback;
    if (source instanceof Error) {
      const name = source.name;
      if (name === 'NotFoundError') return '未选择串口';
      if (name === 'InvalidStateError') return '串口已被占用，请关闭串口助手或其他标签页';
      if (name === 'NetworkError' || name === 'AbortError') return '串口已断开';
      if (name === 'SecurityError') return '串口权限被拒绝（请使用 localhost / https）';
      return source.message || name;
    }
    return '未知错误';
  }

  private readonly handleHardwareDisconnect = (event: Event): void => {
    if (!this.port) return;
    const target = event.target as SerialPortLike | null;
    if (target && target !== this.port) return;
    void this.fail('USB 串口已断开，插回后点击“重新连接”');
  };

  private readonly handleHardwareConnect = (): void => {
    this.events.onLog('[serial] 检测到串口设备插入');
  };
}
