/**
 * 手势桥接（SSE）客户端。
 *
 * 板子只输出 hand: rock / paper / scissors，网页只认 START / FIST / MODE 这类指令，
 * 中间的翻译在 tools/gesture-bridge/gesture_bridge.py 里做（独占 COM 口）。
 * 它在本机起一个 SSE 服务，这里把指令行当成串口的一行喂进同一条解析链路。
 *
 * 选 SSE 而不是 WebSocket：浏览器原生 EventSource 自带断线重连，
 * 服务端用标准库就能实现，不需要额外依赖。
 */
export type BridgeState = 'off' | 'connecting' | 'online' | 'error';

export interface BridgeLinkOptions {
  /** 例如 http://127.0.0.1:8765/events */
  url: string;
  onLine: (text: string) => void;
  onState: (state: BridgeState, detail: string) => void;
}

export class BridgeLink {
  private readonly options: BridgeLinkOptions;
  private source: EventSource | null = null;
  private state: BridgeState = 'off';
  private closed = false;

  constructor(options: BridgeLinkOptions) {
    this.options = options;
  }

  get currentState(): BridgeState {
    return this.state;
  }

  connect(): void {
    if (this.closed) return;
    if (typeof EventSource === 'undefined') {
      this.setState('error', '当前浏览器不支持 EventSource');
      return;
    }
    if (this.source) return;

    this.setState('connecting', this.options.url);
    const source = new EventSource(this.options.url);
    this.source = source;

    source.onopen = () => {
      this.setState('online', this.options.url);
    };

    source.onmessage = (event: MessageEvent<string>) => {
      const text = String(event.data ?? '').trim();
      if (!text) return;
      // 服务端只用 data: 帧推一行指令；多行防御性拆开
      for (const line of text.split(/\r?\n/)) {
        const value = line.trim();
        if (value) this.options.onLine(value);
      }
    };

    source.onerror = () => {
      // EventSource 会自己重连，这里只更新状态，不主动关闭
      if (this.closed) return;
      this.setState('error', this.options.url);
    };
  }

  close(): void {
    this.closed = true;
    this.source?.close();
    this.source = null;
    this.setState('off', '');
  }

  private setState(state: BridgeState, detail: string): void {
    if (this.state === state) return;
    this.state = state;
    this.options.onState(state, detail);
  }
}
