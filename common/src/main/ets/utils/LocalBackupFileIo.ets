import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { BackupTextIo } from './StoragePorts';
import { LocalBackupError, LocalBackupFailure } from './LocalBackupFormat';

/** 只暴露文档 URI 所需原语；没有删除、目录或读回权限假设。 */
export interface LocalBackupFilePort {
  encode(text: string): Uint8Array;
  decode(bytes: Uint8Array): string;
  open(uri: string, writing: boolean): Promise<number>;
  read(fd: number, bytes: ArrayBuffer): Promise<number>;
  write(fd: number, bytes: ArrayBuffer): Promise<number>;
  close(fd: number): Promise<void>;
}

class NativeLocalBackupFilePort implements LocalBackupFilePort {
  encode(text: string): Uint8Array {
    const encoded = buffer.from(text, 'utf-8');
    const bytes = new Uint8Array(encoded.length);
    for (let i = 0; i < bytes.length; i++) { bytes[i] = encoded.readUInt8(i); }
    return bytes;
  }

  decode(bytes: Uint8Array): string {
    return buffer.from(bytes).toString('utf-8');
  }

  async open(uri: string, writing: boolean): Promise<number> {
    const file = await fs.open(uri, writing ? fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC :
      fs.OpenMode.READ_ONLY);
    return file.fd;
  }

  async read(fd: number, bytes: ArrayBuffer): Promise<number> {
    return fs.read(fd, bytes);
  }

  async write(fd: number, bytes: ArrayBuffer): Promise<number> {
    // SDK offset 表示文件偏移；源视图已由调用方裁剪，沿用描述符当前位置。
    return fs.write(fd, bytes);
  }

  async close(fd: number): Promise<void> {
    await fs.close(fd);
  }
}

export class LocalBackupFileIo implements BackupTextIo {
  private readonly port: LocalBackupFilePort;
  private readonly isCancelled: () => boolean;

  constructor(port: LocalBackupFilePort = new NativeLocalBackupFilePort(), isCancelled: () => boolean = () => false) {
    this.port = port;
    this.isCancelled = isCancelled;
  }

  private checkCancelled(): void {
    if (this.isCancelled()) { throw new LocalBackupError(LocalBackupFailure.CANCELLED); }
  }

  async readText(uri: string): Promise<string> {
    try {
      this.checkCancelled();
      const fd = await this.port.open(uri, false);
      const chunks: Uint8Array[] = [];
      let total = 0;
      try {
        while (true) {
          this.checkCancelled();
          const buffer = new ArrayBuffer(65536);
          const length = await this.port.read(fd, buffer);
          this.checkCancelled();
          if (!Number.isInteger(length) || length < 0 || length > buffer.byteLength) {
            throw new LocalBackupError(LocalBackupFailure.READ);
          }
          if (length === 0) { break; }
          chunks.push(new Uint8Array(buffer.slice(0, length)));
          total += length;
        }
      } finally {
        await this.port.close(fd);
      }
      this.checkCancelled();
      const bytes = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return this.port.decode(bytes);
    } catch (_) {
      throw new LocalBackupError(this.isCancelled() ? LocalBackupFailure.CANCELLED : LocalBackupFailure.READ);
    }
  }

  async writeText(uri: string, content: string): Promise<void> {
    let started = false;
    try {
      this.checkCancelled();
      const bytes = this.port.encode(content);
      this.checkCancelled();
      started = true;
      const fd = await this.port.open(uri, true);
      try {
        // 目标一旦打开就不再提供中途取消；安全写完/关闭后由宿主决定是否展示结果。
        let offset = 0;
        while (offset < bytes.byteLength) {
          const length = Math.min(65536, bytes.byteLength - offset);
          const chunk = bytes.buffer.slice(bytes.byteOffset + offset, bytes.byteOffset + offset + length);
          const written = await this.port.write(fd, chunk);
          if (!Number.isInteger(written) || written <= 0 || written > length) {
            throw new LocalBackupError(LocalBackupFailure.SAVE);
          }
          offset += written;
        }
      } finally {
        await this.port.close(fd);
      }
    } catch (_) {
      throw new LocalBackupError(!started && this.isCancelled() ? LocalBackupFailure.CANCELLED : LocalBackupFailure.SAVE);
    }
  }
}
