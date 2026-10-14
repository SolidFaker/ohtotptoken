import { describe, it, expect } from '@ohos/hypium';
import {
  CloudBackupSyncClient, CloudBackupSyncFactory, CloudBackupSyncProgressListener,
  CloudBackupSyncService, CloudBackupSyncSnapshot, CloudBackupSyncState, CloudBackupSyncError, CloudBackupSyncTimer,
  CloudBackupSyncDiagnostics, DiagnosticContext, DiagnosticDetails, DiagnosticKind, DiagnosticStage, DiagnosticResult,
  CloudBackupDiagnosticRecorder, DiagnosticSink, DiagnosticClock, DiagnosticThread,
} from 'common';

class ManualSyncTimer implements CloudBackupSyncTimer {
  callbacks: Map<number, () => void> = new Map();
  private nextId: number = 0;

  schedule(callback: () => void, _milliseconds: number): number {
    const id = this.nextId++;
    this.callbacks.set(id, callback);
    return id;
  }

  cancel(id: number): void {
    this.callbacks.delete(id);
  }

  expire(): void {
    for (const callback of Array.from(this.callbacks.values())) {
      callback();
    }
  }
}

class FakeSyncClient implements CloudBackupSyncClient {
  callback: CloudBackupSyncProgressListener | undefined = undefined;
  callbacks: CloudBackupSyncProgressListener[] = [];
  removed: CloudBackupSyncProgressListener[] = [];
  onCalls: number = 0;
  offCalls: number = 0;
  startCalls: number = 0;
  failOn: boolean = false;
  failOff: boolean = false;
  failStart: boolean = false;
  throwStart: boolean = false;
  initialCompleted: boolean = false;
  holdStart: boolean = false;
  private accept: () => void = (): void => {};
  private reject: (error: Error) => void = (_error: Error): void => {};

  onProgress(callback: CloudBackupSyncProgressListener): void {
    this.onCalls++;
    this.callback = callback;
    this.callbacks.push(callback);
    if (this.failOn) {
      throw new Error('SYNTHETIC_PRIVATE_ON_FAILURE');
    }
    if (this.initialCompleted) {
      this.emit(4, 0);
    }
  }

  offProgress(callback: CloudBackupSyncProgressListener): void {
    this.offCalls++;
    this.removed.push(callback);
    if (this.failOff) {
      throw new Error('SYNTHETIC_PRIVATE_OFF_FAILURE');
    }
    if (this.callback === callback) {
      this.callback = undefined;
    }
  }

  start(): Promise<void> {
    this.startCalls++;
    if (this.throwStart) {
      throw new Error('SYNTHETIC_PRIVATE_START_FAILURE');
    }
    if (this.failStart) {
      return Promise.reject(new Error('SYNTHETIC_PRIVATE_START_FAILURE'));
    }
    if (this.holdStart) {
      return new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
        this.accept = resolve;
        this.reject = reject;
      });
    }
    return Promise.resolve();
  }

  acceptStart(): void { this.accept(); }
  rejectStart(): void { this.reject(new Error('SYNTHETIC_PRIVATE_LATE_FAILURE')); }

  emit(state: number, error: number): void {
    if (this.callback !== undefined) {
      this.callback({ state: state, error: error });
    }
  }
}

class FakeSyncFactory implements CloudBackupSyncFactory {
  client: FakeSyncClient = new FakeSyncClient();
  createCalls: number = 0;
  failCreate: boolean = false;

  create(): CloudBackupSyncClient {
    this.createCalls++;
    if (this.failCreate) {
      throw new Error('SYNTHETIC_PRIVATE_FACTORY_FAILURE');
    }
    return this.client;
  }
}

class SyncDiagnosticSink implements DiagnosticSink {
  lines: string[] = [];
  write(line: string): void { this.lines.push(line); }
}

class SyncDiagnosticClock implements DiagnosticClock {
  now(): number { return 100; }
}

class SyncDiagnosticThread implements DiagnosticThread {
  isMainThread(): boolean { return true; }
}

class SyncDiagnosticProbe implements CloudBackupSyncDiagnostics {
  sink: SyncDiagnosticSink = new SyncDiagnosticSink();
  recorder: CloudBackupDiagnosticRecorder = new CloudBackupDiagnosticRecorder(
    this.sink, new SyncDiagnosticClock(), new SyncDiagnosticThread());
  created: DiagnosticContext[] = [];
  ended: DiagnosticContext[] = [];
  marked: DiagnosticContext[] = [];

  begin(kind: DiagnosticKind): DiagnosticContext {
    const context = this.recorder.begin(kind);
    this.created.push(context);
    return context;
  }

  mark(context: DiagnosticContext, stage: DiagnosticStage, result: DiagnosticResult, details?: DiagnosticDetails): void {
    this.marked.push(context);
    this.recorder.mark(context, stage, result, details);
  }

  end(context: DiagnosticContext): void {
    this.ended.push(context);
    this.recorder.end(context);
  }
}

async function syncTestTurn(): Promise<void> {
  for (let turn = 0; turn < 12; turn++) {
    await Promise.resolve();
  }
}

export default function cloudBackupSyncServiceTest() {
  describe('cloudBackupSyncServiceTest', () => {
    it('sync_subscribe_start_off_share_one_native_instance_and_callback', 0, async () => {
      const factory = new FakeSyncFactory();
      const timer = new ManualSyncTimer();
      const service = new CloudBackupSyncService(factory, timer);
      expect(factory.createCalls).assertEqual(0);
      const states: CloudBackupSyncSnapshot[] = [];
      const unsubscribe = service.subscribe((snapshot: CloudBackupSyncSnapshot): void => { states.push(snapshot); });
      const unsubscribeSecond = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => {});
      expect(factory.client.onCalls).assertEqual(1);
      expect(await service.start()).assertTrue();
      expect(factory.createCalls).assertEqual(1);
      expect(factory.client.startCalls).assertEqual(1);
      factory.client.emit(0, 0);
      expect(states[states.length - 1].state).assertEqual(CloudBackupSyncState.UPLOADING);
      unsubscribe();
      expect(factory.client.offCalls).assertEqual(0);
      unsubscribeSecond();
      unsubscribeSecond();
      expect(factory.client.offCalls).assertEqual(1);
      expect(factory.client.removed[0] === factory.client.callbacks[0]).assertTrue();
      expect(timer.callbacks.size).assertEqual(0);
    });

    it('sync_initial_and_active_to_completed_events_do_not_resolve_start', 0, async () => {
      const factory = new FakeSyncFactory();
      factory.client.initialCompleted = true;
      factory.client.holdStart = true;
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      const unsubscribe = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => {});
      expect(service.getSnapshot().state).assertEqual(CloudBackupSyncState.COMPLETED);
      let accepted = false;
      const start = service.start().then((value: boolean): boolean => { accepted = value; return value; });
      factory.client.emit(0, 0);
      factory.client.emit(4, 0);
      await syncTestTurn();
      expect(accepted).assertFalse();
      factory.client.acceptStart();
      expect(await start).assertTrue();
      // 快照仍是全局状态；没有 operationCompleted 字段或完成 promise。
      expect(service.getSnapshot().state).assertEqual(CloudBackupSyncState.COMPLETED);
      unsubscribe();
    });

    it('sync_start_acceptance_does_not_require_global_completion', 0, async () => {
      const factory = new FakeSyncFactory();
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      expect(await service.start()).assertTrue();
      expect(service.getSnapshot().state).assertEqual(CloudBackupSyncState.UNKNOWN);
      expect(factory.client.offCalls).assertEqual(1);
    });

    it('sync_duplicate_start_is_rejected_not_queued_or_reported_accepted', 0, async () => {
      const factory = new FakeSyncFactory();
      factory.client.holdStart = true;
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      const first = service.start();
      expect(await service.start()).assertFalse();
      expect(factory.client.startCalls).assertEqual(1);
      factory.client.acceptStart();
      expect(await first).assertTrue();
      await syncTestTurn();
      expect(factory.client.startCalls).assertEqual(1);
    });

    it('sync_timeout_returns_false_but_keeps_unknown_start_barrier', 0, async () => {
      const factory = new FakeSyncFactory();
      factory.client.holdStart = true;
      const timer = new ManualSyncTimer();
      const service = new CloudBackupSyncService(factory, timer, 100);
      const pending = service.start();
      timer.expire();
      expect(await pending).assertFalse();
      expect(await service.start()).assertFalse();
      expect(factory.client.startCalls).assertEqual(1);
      factory.client.acceptStart();
      await syncTestTurn();
      factory.client.holdStart = false;
      expect(await service.start()).assertTrue();
      expect(factory.createCalls).assertEqual(1);
      expect(factory.client.startCalls).assertEqual(2);
    });

    it('sync_late_rejection_releases_only_original_start_barrier', 0, async () => {
      const factory = new FakeSyncFactory();
      factory.client.holdStart = true;
      const timer = new ManualSyncTimer();
      const service = new CloudBackupSyncService(factory, timer, 100);
      const pending = service.start();
      timer.expire();
      expect(await pending).assertFalse();
      factory.client.rejectStart();
      await syncTestTurn();
      factory.client.holdStart = false;
      expect(await service.start()).assertTrue();
      expect(factory.createCalls).assertEqual(1);
    });

    it('sync_normalizes_unknown_values_and_defensively_copies_snapshots', 0, () => {
      const factory = new FakeSyncFactory();
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      const received: CloudBackupSyncSnapshot[] = [];
      const unsubscribe = service.subscribe((snapshot: CloudBackupSyncSnapshot): void => {
        received.push(snapshot);
        snapshot.state = CloudBackupSyncState.STOPPED;
      });
      factory.client.emit(0, 1);
      expect(service.getSnapshot().state).assertEqual(CloudBackupSyncState.UPLOADING);
      expect(service.getSnapshot().error).assertEqual(CloudBackupSyncError.NETWORK_UNAVAILABLE);
      const copy = service.getSnapshot();
      copy.error = CloudBackupSyncError.NO_ERROR;
      expect(service.getSnapshot().error).assertEqual(CloudBackupSyncError.NETWORK_UNAVAILABLE);
      factory.client.emit(99999, 987654);
      expect(service.getSnapshot().state).assertEqual(CloudBackupSyncState.UNKNOWN);
      expect(service.getSnapshot().error).assertEqual(CloudBackupSyncError.UNKNOWN);
      factory.client.emit(Number.NaN, Number.POSITIVE_INFINITY);
      expect(service.getSnapshot().error).assertEqual(CloudBackupSyncError.UNKNOWN);
      unsubscribe();
    });

    it('sync_maps_all_sdk_states_and_error_types', 0, () => {
      const factory = new FakeSyncFactory();
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      const unsubscribe = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => {});
      for (let state = 0; state <= 5; state++) {
        factory.client.emit(state, 0);
        expect(service.getSnapshot().state).assertEqual(state);
      }
      for (let error = 0; error <= 8; error++) {
        factory.client.emit(1, error);
        expect(service.getSnapshot().error).assertEqual(error);
      }
      unsubscribe();
    });

    it('sync_throwing_ui_subscriber_cannot_change_acceptance_or_other_subscribers', 0, async () => {
      const factory = new FakeSyncFactory();
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      let notifications = 0;
      const broken = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => { throw new Error('UI failure'); });
      const healthy = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => { notifications++; });
      expect(await service.start()).assertTrue();
      factory.client.emit(2, 0);
      expect(notifications).assertEqual(2);
      broken();
      healthy();
    });

    it('sync_subscription_factory_and_start_failures_return_false_without_raw_errors', 0, async () => {
      for (let failure = 0; failure < 4; failure++) {
        const factory = new FakeSyncFactory();
        factory.failCreate = failure === 0;
        factory.client.failOn = failure === 1;
        factory.client.failStart = failure === 2;
        factory.client.throwStart = failure === 3;
        const timer = new ManualSyncTimer();
        const service = new CloudBackupSyncService(factory, timer);
        expect(await service.start()).assertFalse();
        expect(timer.callbacks.size).assertEqual(0);
        factory.failCreate = false;
        factory.client.failOn = false;
        factory.client.failStart = false;
        factory.client.throwStart = false;
        expect(await service.start()).assertTrue();
      }
    });

    it('sync_failed_off_retains_callback_for_retry_without_duplicate_subscription', 0, async () => {
      const factory = new FakeSyncFactory();
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      const unsubscribe = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => {});
      const old = factory.client.callbacks[0];
      factory.client.failOff = true;
      unsubscribe();
      expect(await service.start()).assertFalse();
      expect(factory.client.onCalls).assertEqual(1);
      factory.client.failOff = false;
      const fresh = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => {});
      factory.client.emit(2, 0);
      old({ state: 4, error: 0 });
      expect(service.getSnapshot().state).assertEqual(CloudBackupSyncState.DOWNLOADING);
      expect(factory.createCalls).assertEqual(1);
      expect(factory.client.onCalls).assertEqual(2);
      fresh();
    });

    it('sync_old_parent_context_cannot_re_root_progress_after_diagnostic_reenable', 0, async () => {
      const factory = new FakeSyncFactory();
      factory.client.holdStart = true;
      const diagnostics = new SyncDiagnosticProbe();
      expect(diagnostics.recorder.enable()).assertTrue();
      const parent = diagnostics.begin(DiagnosticKind.BACKUP);
      diagnostics.recorder.disable();
      expect(diagnostics.recorder.enable()).assertTrue();
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer(), 1000, diagnostics);
      const pending = service.start(parent);
      factory.client.emit(0, 0);
      factory.client.emit(4, 0);
      factory.client.acceptStart();
      expect(await pending).assertTrue();
      expect(diagnostics.created.length).assertEqual(1);
      expect(diagnostics.ended.length).assertEqual(0);
      expect(diagnostics.sink.lines.length).assertEqual(0);
      for (const context of diagnostics.marked) {
        expect(context === parent).assertTrue();
      }
    });

    it('sync_detach_ends_only_standalone_subscription_context_not_parent', 0, async () => {
      const factory = new FakeSyncFactory();
      const diagnostics = new SyncDiagnosticProbe();
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer(), 1000, diagnostics);
      const parent = diagnostics.begin(DiagnosticKind.BACKUP);
      expect(await service.start(parent)).assertTrue();
      expect(diagnostics.ended.indexOf(parent)).assertEqual(-1);
      const unsubscribe = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => {});
      const standalone = diagnostics.created[1];
      unsubscribe();
      expect(diagnostics.ended.indexOf(standalone) >= 0).assertTrue();
      expect(diagnostics.ended.indexOf(parent)).assertEqual(-1);
    });

    it('sync_pending_start_keeps_subscription_after_last_ui_unsubscribes', 0, async () => {
      const factory = new FakeSyncFactory();
      factory.client.holdStart = true;
      const service = new CloudBackupSyncService(factory, new ManualSyncTimer());
      const unsubscribe = service.subscribe((_snapshot: CloudBackupSyncSnapshot): void => {});
      const pending = service.start();
      unsubscribe();
      expect(factory.client.offCalls).assertEqual(0);
      factory.client.acceptStart();
      expect(await pending).assertTrue();
      expect(factory.client.offCalls).assertEqual(1);
    });
  });
}
