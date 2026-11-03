/**
 * Web Serial 的最小类型声明。
 * 不污染 DOM 全局类型，避免与不同 TS 版本的 lib.dom 冲突。
 */
export interface SerialPortInfoLike {
  usbVendorId?: number;
  usbProductId?: number;
}

export interface SerialOptionsLike {
  baudRate: number;
  dataBits?: number;
  stopBits?: number;
  parity?: 'none' | 'even' | 'odd';
  bufferSize?: number;
  flowControl?: 'none' | 'hardware';
}

export interface SerialPortLike {
  readonly readable: ReadableStream<Uint8Array> | null;
  readonly writable: WritableStream<Uint8Array> | null;
  open(options: SerialOptionsLike): Promise<void>;
  close(): Promise<void>;
  getInfo(): SerialPortInfoLike;
}

export interface SerialApiLike {
  getPorts(): Promise<SerialPortLike[]>;
  requestPort(options?: unknown): Promise<SerialPortLike>;
  addEventListener(type: 'connect' | 'disconnect', listener: (event: Event) => void): void;
  removeEventListener(type: 'connect' | 'disconnect', listener: (event: Event) => void): void;
}

export function getSerialApi(): SerialApiLike | null {
  if (typeof navigator === 'undefined') return null;
  const candidate = (navigator as unknown as { serial?: SerialApiLike }).serial;
  return candidate ?? null;
}

export function describePort(info: SerialPortInfoLike | null): string {
  if (!info) return 'USB 串口';
  const { usbVendorId, usbProductId } = info;
  if (usbVendorId === undefined && usbProductId === undefined) return 'USB 串口';
  const hex = (value: number | undefined): string =>
    value === undefined ? '----' : value.toString(16).toUpperCase().padStart(4, '0');
  return `USB ${hex(usbVendorId)}:${hex(usbProductId)}`;
}
