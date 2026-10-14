export enum CloudBackupOperationKind {
  BACKUP = 'BACKUP',
  RESTORE = 'RESTORE',
  CLEAR = 'CLEAR',
  HISTORY = 'HISTORY',
  ICONS = 'ICONS',
}

/** 许可仅属于发起操作；未知 I/O 必须由原所有者确认结束后再释放。 */
export class CloudBackupOperationLease {
  readonly kind: CloudBackupOperationKind;
  private released: boolean = false;
  private unknownIo: boolean = false;
  private releaseOwner: (lease: CloudBackupOperationLease) => boolean;

  constructor(kind: CloudBackupOperationKind, releaseOwner: (lease: CloudBackupOperationLease) => boolean) {
    this.kind = kind;
    this.releaseOwner = releaseOwner;
  }

  retainUnknownIo(): void {
    if (!this.released) {
      this.unknownIo = true;
    }
  }

  /** 只撤销屏障，不隐式释放；调用者须先确认该操作的所有底层工作均已结束。 */
  resolveUnknownIo(): void {
    if (!this.released) {
      this.unknownIo = false;
    }
  }

  isCleanupPending(): boolean {
    return this.unknownIo && !this.released;
  }

  release(): boolean {
    if (this.released || this.unknownIo) {
      return false;
    }
    if (!this.releaseOwner(this)) {
      return false;
    }
    this.released = true;
    return true;
  }
}

/** 进程内非重入闸门：冲突立即返回，不保存自动备份等候队列。 */
export class CloudBackupOperationGate {
  private static instance: CloudBackupOperationGate | undefined = undefined;
  private owner: CloudBackupOperationLease | undefined = undefined;

  static getInstance(): CloudBackupOperationGate {
    if (CloudBackupOperationGate.instance === undefined) {
      CloudBackupOperationGate.instance = new CloudBackupOperationGate();
    }
    return CloudBackupOperationGate.instance;
  }

  tryEnter(kind: CloudBackupOperationKind): CloudBackupOperationLease | undefined {
    if (this.owner !== undefined) {
      return undefined;
    }
    const lease = new CloudBackupOperationLease(kind, (candidate: CloudBackupOperationLease): boolean => {
      if (this.owner !== candidate) {
        return false;
      }
      this.owner = undefined;
      return true;
    });
    this.owner = lease;
    return lease;
  }

  owns(lease: CloudBackupOperationLease): boolean {
    return this.owner === lease;
  }

  canUse(lease: CloudBackupOperationLease): boolean {
    return this.owns(lease) && !lease.isCleanupPending();
  }

  isBusy(): boolean {
    return this.owner !== undefined;
  }
}
