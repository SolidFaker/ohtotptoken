import { CloudFileCacher, FsStatInfo } from 'common';
import { MemoryFs } from './BackupFakes';

export class MissingCloudFileError extends Error {
  code: number = 13900002;
}

export class DownloadAwareFs extends MemoryFs {
  failList: boolean = false;
  failStatFor: Set<string> = new Set();
  failDeleteFor: Set<string> = new Set();
  /** 模拟 stat 后文件被其他参与者删掉；unlink 返回明确 ENOENT。 */
  absentOnDeleteFor: Set<string> = new Set();
  listCalls: number = 0;
  statPaths: string[] = [];
  readPaths: string[] = [];
  deleteAttempts: string[] = [];
  /** 默认保留云端读取失败场景；显式标记的路径模拟普通 read 可取回内容，但不改变 stat.location。 */
  readableCloudPaths: Set<string> = new Set();

  async listFiles(dir: string): Promise<string[]> {
    this.listCalls++;
    if (this.failList) {
      throw new Error('list unavailable');
    }
    return super.listFiles(dir);
  }

  async stat(path: string): Promise<FsStatInfo> {
    this.statPaths.push(path);
    if (this.failStatFor.has(path)) {
      throw new Error('stat unavailable');
    }
    if (!this.files.has(path) && !this.dirs.has(path)) {
      throw new MissingCloudFileError('missing cloud file');
    }
    return super.stat(path);
  }

  async readTextFile(path: string): Promise<string> {
    this.readPaths.push(path);
    // location 只是驻留信息，不强制规定原生 read 的结果；显式 IO 故障始终优先。
    if ((this.locationOverride.get(path) === 2 && !this.readableCloudPaths.has(path)) || this.failReadFor.has(path)) {
      throw new Error('read unavailable');
    }
    return super.readTextFile(path);
  }

  async deleteFile(path: string): Promise<void> {
    this.deleteAttempts.push(path);
    if (this.failDeleteFor.has(path)) {
      throw new Error('delete unavailable');
    }
    if (this.absentOnDeleteFor.has(path)) {
      this.files.delete(path);
      throw new MissingCloudFileError('already absent');
    }
    await super.deleteFile(path);
  }
}

class CacheRead {
  cancelled: boolean = false;
  release: (() => void) | null = null;
}

export class FakeFileCacher implements CloudFileCacher {
  calls: string[] = [];
  fail: boolean = false;
  /** 模拟结果已失败但 native 工作尚未确认终止，与普通安全终态失败区分。 */
  failKeepsInFlight: boolean = false;
  hang: boolean = false;
  prepareCalls: string[] = [];
  cancelCalls: string[] = [];
  retryCleanupCalls: number = 0;
  /** 只有真正调用 cache 或测试显式注入的任务才触发删除保护。 */
  inFlightPaths: Set<string> = new Set();
  failCancel: boolean = false;
  private fs: MemoryFs;
  private reads: Map<string, CacheRead> = new Map();
  private cleanupPendingPaths: Set<string> = new Set();

  constructor(fs: MemoryFs) {
    this.fs = fs;
  }

  async cache(path: string): Promise<void> {
    this.calls.push(path);
    if (this.fail) {
      if (this.failKeepsInFlight) {
        this.inFlightPaths.add(path);
        this.cleanupPendingPaths.add(path);
      }
      throw new Error('cache failed');
    }
    const read = new CacheRead();
    this.reads.set(path, read);
    this.inFlightPaths.add(path);
    try {
      if (this.hang) {
        await new Promise<void>((resolve: () => void) => {
          read.release = resolve;
        });
      }
      if (read.cancelled) {
        throw new Error('cache cancelled');
      }
      this.fs.locationOverride.set(path, 3);
    } finally {
      if (this.reads.get(path) === read) {
        this.reads.delete(path);
        if (!this.cleanupPendingPaths.has(path)) this.inFlightPaths.delete(path);
      }
    }
  }

  async prepareForDelete(path: string): Promise<boolean> {
    this.prepareCalls.push(path);
    if (!this.inFlightPaths.has(path) && !this.cleanupPendingPaths.has(path)) return true;
    this.cancelCalls.push(path);
    if (this.failCancel) {
      this.cleanupPendingPaths.add(path);
      return false;
    }
    this.confirmStopped(path);
    return true;
  }

  async retryCleanup(): Promise<boolean> {
    this.retryCleanupCalls++;
    if (this.failCancel && this.cleanupPendingPaths.size > 0) return false;
    this.cleanupPendingPaths.forEach((path: string) => this.confirmStopped(path));
    return true;
  }

  isCleanupPending(): boolean {
    return this.cleanupPendingPaths.size > 0;
  }

  private confirmStopped(path: string): void {
    const read = this.reads.get(path);
    if (read !== undefined) {
      read.cancelled = true;
      if (read.release !== null) read.release();
      this.reads.delete(path);
    }
    this.inFlightPaths.delete(path);
    this.cleanupPendingPaths.delete(path);
  }

  complete(): void {
    this.reads.forEach((read: CacheRead) => {
      if (read.release !== null) {
        read.release();
        read.release = null;
      }
    });
  }
}

export function cloudTestTurn(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 1);
  });
}
