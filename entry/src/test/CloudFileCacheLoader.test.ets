import { describe, it, expect } from '@ohos/hypium';
import {
  CloudCacheClient, CloudCacheFactory, CloudCacheListener, CloudCacheState, CloudCacheTimer,
  CloudFileCacher, CloudFileCacheLoader, prepareCloudFileRead, waitForCloudFileCache,
} from 'common';

async function cloudTestTurn(): Promise<void> {
  // 只排空微任务，不依赖 LocalUnit 原生库或真实时钟。
  for (let turn = 0; turn < 12; turn++) {
    await Promise.resolve();
  }
}

class ManualCacheTimer implements CloudCacheTimer {
  callbacks: Map<number, () => void> = new Map();
  nextId: number = 0;

  schedule(callback: () => void, _milliseconds: number): number {
    const id = this.nextId++;
    this.callbacks.set(id, callback);
    return id;
  }

  cancel(id: number): void {
    this.callbacks.delete(id);
  }

  expire(): void {
    const callbacks = Array.from(this.callbacks.values());
    for (const callback of callbacks) {
      callback();
    }
  }
}

class FakeCacheClient implements CloudCacheClient {
  listener: CloudCacheListener | null = null;
  savedListener: CloudCacheListener | null = null;
  offCalls: number = 0;
  stopCalls: number = 0;
  startCalls: number = 0;
  failOn: boolean = false;
  failStart: boolean = false;
  failOff: boolean = false;
  failStop: boolean = false;
  holdStart: boolean = false;
  holdStop: boolean = false;
  private releaseStop: (() => void) | null = null;
  completeDuringStart: boolean = false;
  completeDuringSubscription: boolean = false;
  errorMessage: string = 'SYNTHETIC_PRIVATE_PATH_SECRET';
  private release: (() => void) | null = null;

  onProgress(listener: CloudCacheListener): void {
    if (this.failOn) {
      throw new Error(this.errorMessage);
    }
    this.listener = listener;
    this.savedListener = listener;
    if (this.completeDuringSubscription) {
      this.emit(CloudCacheState.COMPLETED);
    }
  }

  offProgress(): void {
    this.offCalls++;
    this.listener = null;
    if (this.failOff) {
      throw new Error('off failed');
    }
  }

  async start(uri: string): Promise<void> {
    this.startCalls++;
    if (this.completeDuringStart) {
      this.emit(CloudCacheState.COMPLETED, uri);
    }
    if (this.failStart) {
      throw new Error(this.errorMessage);
    }
    if (this.holdStart) {
      await new Promise<void>((resolve: () => void) => {
        this.release = resolve;
      });
    }
  }

  async stop(_uri: string): Promise<void> {
    this.stopCalls++;
    if (this.failStop) {
      throw new Error(this.errorMessage);
    }
    if (this.holdStop) {
      await new Promise<void>((resolve: () => void) => { this.releaseStop = resolve; });
    }
  }

  acceptStop(): void {
    if (this.releaseStop !== null) {
      this.releaseStop();
      this.releaseStop = null;
    }
  }

  acceptStart(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }

  emit(state: CloudCacheState, uri: string = 'file:///backup', error: number = 0): void {
    if (this.listener !== null) {
      this.listener({ uri: uri, state: state, error: error });
    }
  }
}

class FakeCacheFactory implements CloudCacheFactory {
  clients: FakeCacheClient[] = [];
  holdFirstStart: boolean = false;
  holdFirstStop: boolean = false;
  failFirstStop: boolean = false;

  create(): CloudCacheClient {
    const client = new FakeCacheClient();
    if (this.clients.length === 0) {
      client.holdStart = this.holdFirstStart;
      client.holdStop = this.holdFirstStop;
      client.failStop = this.failFirstStop;
    }
    this.clients.push(client);
    return client;
  }

  toUri(path: string): string {
    return `file://${path}`;
  }
}

/** 兼容旧端口：拒绝后无法证明是否仍有在途 native 工作，不能回退读取。 */
class UninspectableFileCacher implements CloudFileCacher {
  calls: number = 0;

  cache(_path: string): Promise<void> {
    this.calls++;
    return Promise.reject(new Error('cache state unavailable'));
  }
}

class ThrowingStateFileCacher extends UninspectableFileCacher {
  isCleanupPending(): boolean {
    if (this.calls === 0) return false;
    throw new Error('cleanup state unavailable');
  }
}

async function rejected(promise: Promise<void>): Promise<boolean> {
  try {
    await promise;
    return false;
  } catch (_) {
    return true;
  }
}

export default function cloudFileCacheLoaderTest() {
  describe('cloudFileCacheLoaderTest', () => {
    it('prepare_read_without_cacher_allows_direct_io_without_initiated_cache_work', 0, async () => {
      for (const location of [0, 1, 2, 3]) {
        expect(await prepareCloudFileRead(undefined, '/backup', location)).assertTrue();
      }
    });

    it('prepare_read_non_cloud_residency_does_not_start_optional_cache', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      for (const location of [0, 1, 3]) {
        expect(await prepareCloudFileRead(loader, '/backup', location)).assertTrue();
      }
      expect(factory.clients.length).assertEqual(0);
    });

    it('prepare_read_allows_real_loader_terminal_failed_after_settled_start', 0, async () => {
      const factory = new FakeCacheFactory();
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000);
      const readable = prepareCloudFileRead(loader, '/backup', 2);
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(1);
      expect(factory.clients[0].startCalls).assertEqual(1);
      // start 已确认；FAILED 终态排空真实 loader，但不伪装成缓存成功。
      factory.clients[0].emit(CloudCacheState.FAILED);
      expect(await readable).assertTrue();
      expect(loader.isCleanupPending()).assertFalse();
      expect(factory.clients[0].stopCalls).assertEqual(0);
      expect(factory.clients[0].offCalls).assertEqual(1);
      expect(timer.callbacks.size).assertEqual(0);
    });

    it('prepare_read_allows_completed_cache_after_real_loader_drain', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const readable = prepareCloudFileRead(loader, '/backup', 2);
      await cloudTestTurn();
      factory.clients[0].emit(CloudCacheState.COMPLETED);
      expect(await readable).assertTrue();
      expect(loader.isCleanupPending()).assertFalse();
      expect(factory.clients.length).assertEqual(1);
    });

    it('prepare_read_timeout_blocks_unresolved_native_start_or_stop_even_for_local_files', 0, async () => {
      for (const holdStart of [true, false]) {
        const factory = new FakeCacheFactory();
        factory.holdFirstStart = holdStart;
        factory.holdFirstStop = !holdStart;
        const timer = new ManualCacheTimer();
        const loader = new CloudFileCacheLoader(factory, timer, 1000);
        const readable = prepareCloudFileRead(loader, '/backup', 2);
        await cloudTestTurn();
        timer.expire();
        try {
          expect(await readable).assertFalse();
          expect(loader.isCleanupPending()).assertTrue();
          expect(await prepareCloudFileRead(loader, '/other', 2)).assertFalse();
          expect(await prepareCloudFileRead(loader, '/local', 3)).assertFalse();
          expect(factory.clients.length).assertEqual(1);
          expect(factory.clients[0].stopCalls).assertEqual(holdStart ? 0 : 1);
        } finally {
          factory.clients[0].acceptStart();
          factory.clients[0].acceptStop();
          await cloudTestTurn();
        }
        expect(loader.isCleanupPending()).assertFalse();
      }
    });

    it('prepare_read_checks_existing_pending_work_before_starting_optional_cache', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const pending = loader.cache('/backup');
      await cloudTestTurn();
      try {
        expect(await prepareCloudFileRead(loader, '/other', 2)).assertFalse();
        expect(await prepareCloudFileRead(loader, '/local', 1)).assertFalse();
        expect(factory.clients.length).assertEqual(1);
        expect(factory.clients[0].stopCalls).assertEqual(0);
      } finally {
        factory.clients[0].emit(CloudCacheState.COMPLETED);
        await pending;
      }
    });

    it('prepare_read_rejected_cache_without_cleanup_introspection_stays_fail_closed', 0, async () => {
      const cacher = new UninspectableFileCacher();
      expect(await prepareCloudFileRead(cacher, '/backup', 2)).assertFalse();
      expect(cacher.calls).assertEqual(1);
    });

    it('prepare_read_rejected_cache_with_unreadable_cleanup_state_stays_fail_closed', 0, async () => {
      const cacher = new ThrowingStateFileCacher();
      expect(await prepareCloudFileRead(cacher, '/backup', 2)).assertFalse();
      expect(cacher.calls).assertEqual(1);
    });

    it('cache_waits_for_matching_completed_not_start_or_running', 0, async () => {
      const client = new FakeCacheClient();
      const timer = new ManualCacheTimer();
      let done = false;
      const pending = waitForCloudFileCache(client, 'file:///backup', timer, 1000).then(() => { done = true; });
      await cloudTestTurn();
      expect(done).assertFalse();
      client.emit(CloudCacheState.COMPLETED, 'file:///other');
      client.emit(CloudCacheState.RUNNING);
      await cloudTestTurn();
      expect(done).assertFalse();
      client.emit(CloudCacheState.COMPLETED);
      await pending;
      expect(done).assertTrue();
      expect(client.offCalls).assertEqual(1);
      expect(timer.callbacks.size).assertEqual(0);
    });

    it('cache_handles_completion_before_start_acknowledgment', 0, async () => {
      const client = new FakeCacheClient();
      client.holdStart = true;
      client.completeDuringStart = true;
      const timer = new ManualCacheTimer();
      let done = false;
      const pending = waitForCloudFileCache(client, 'file:///backup', timer, 1000).then(() => { done = true; });
      await cloudTestTurn();
      expect(done).assertFalse();
      client.acceptStart();
      await pending;
      expect(done).assertTrue();
    });

    it('cache_rejects_failed_stopped_and_error_progress', 0, async () => {
      for (const state of [CloudCacheState.FAILED, CloudCacheState.STOPPED, CloudCacheState.COMPLETED]) {
        const client = new FakeCacheClient();
        const timer = new ManualCacheTimer();
        const pending = rejected(waitForCloudFileCache(client, 'file:///backup', timer, 1000));
        client.emit(state, 'file:///backup', state === CloudCacheState.COMPLETED ? 1 : 0);
        expect(await pending).assertTrue();
        expect(client.offCalls).assertEqual(1);
        expect(timer.callbacks.size).assertEqual(0);
      }
    });

    it('cache_rejects_subscription_and_start_errors', 0, async () => {
      for (const subscriptionFailure of [true, false]) {
        const client = new FakeCacheClient();
        client.failOn = subscriptionFailure;
        client.failStart = !subscriptionFailure;
        const timer = new ManualCacheTimer();
        expect(await rejected(waitForCloudFileCache(client, 'file:///backup', timer, 1000))).assertTrue();
        await cloudTestTurn();
        expect(timer.callbacks.size).assertEqual(0);
        expect(client.offCalls).assertEqual(1);
      }
    });

    it('cache_timeout_cancels_and_handles_late_start_ack', 0, async () => {
      const client = new FakeCacheClient();
      client.holdStart = true;
      client.failStop = true;
      client.failOff = true;
      const timer = new ManualCacheTimer();
      const pending = rejected(waitForCloudFileCache(client, 'file:///backup', timer, 1000));
      timer.expire();
      expect(await pending).assertTrue();
      expect(client.stopCalls).assertEqual(0);
      client.acceptStart();
      await cloudTestTurn();
      expect(client.stopCalls).assertEqual(1);
      expect(timer.callbacks.size).assertEqual(0);
    });


    it('cache_timeout_blocks_queued_and_new_requests_until_native_cleanup', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.holdFirstStart = true;
      factory.holdFirstStop = true;
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000);
      const first = rejected(loader.cache('/backup'));
      const queued = rejected(loader.cache('/other'));
      await cloudTestTurn();
      timer.expire();
      expect(await first).assertTrue();
      expect(await queued).assertTrue();
      expect(await rejected(loader.cache('/backup'))).assertTrue();
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].acceptStart();
      await cloudTestTurn();
      expect(factory.clients[0].stopCalls).assertEqual(1);
      expect(await rejected(loader.cache('/backup'))).assertTrue();
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].acceptStop();
      await cloudTestTurn();
      const retry = loader.cache('/backup');
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(2);
      factory.clients[1].emit(CloudCacheState.COMPLETED);
      await retry;
    });

    it('cache_stop_failure_keeps_loader_closed_without_new_downloads', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.failFirstStop = true;
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000);
      const first = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      timer.expire();
      expect(await first).assertTrue();
      await cloudTestTurn();
      expect(await rejected(loader.cache('/backup'))).assertTrue();
      expect(await rejected(loader.cache('/different'))).assertTrue();
      expect(factory.clients.length).assertEqual(1);
    });

    it('cache_queues_and_deduplicates_and_recovers_after_failure', 0, async () => {
      const factory = new FakeCacheFactory();
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000);
      const first = loader.cache('/backup');
      expect(loader.cache('/backup') === first).assertTrue();
      const firstResult = rejected(first);
      const second = loader.cache('/second');
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].emit(CloudCacheState.FAILED);
      expect(await firstResult).assertTrue();
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(2);
      factory.clients[1].emit(CloudCacheState.COMPLETED, 'file:///second');
      await second;
      const retry = loader.cache('/backup');
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(3);
      factory.clients[2].emit(CloudCacheState.COMPLETED);
      await retry;
      expect(timer.callbacks.size).assertEqual(0);
    });

    it('cache_delete_without_existing_task_does_not_create_or_download', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      expect(await loader.prepareForDelete('/cloud-only')).assertTrue();
      expect(await loader.retryCleanup()).assertTrue();
      expect(loader.isCleanupPending()).assertFalse();
      expect(factory.clients.length).assertEqual(0);
    });

    it('cache_delete_cancels_queued_target_without_downloading_it', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const pending = rejected(loader.cache('/backup'));
      expect(await loader.prepareForDelete('/backup')).assertTrue();
      expect(await pending).assertTrue();
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(0);
      expect(loader.isCleanupPending()).assertFalse();
    });

    it('cache_delete_refuses_unrelated_pending_task_before_native_start', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const pending = rejected(loader.cache('/backup'));
      const cleanup = loader.prepareForDelete('/other');
      const retry = loader.retryCleanup();
      expect(await cleanup).assertFalse();
      expect(await retry).assertTrue();
      expect(await pending).assertTrue();
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(0);
    });

    it('cache_cleanup_retry_before_start_discards_pending_requests_without_io', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const first = rejected(loader.cache('/backup'));
      const second = rejected(loader.cache('/other'));
      expect(loader.isCleanupPending()).assertTrue();
      expect(await loader.retryCleanup()).assertTrue();
      expect(await first).assertTrue();
      expect(await second).assertTrue();
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(0);
      expect(loader.isCleanupPending()).assertFalse();
    });

    it('cache_delete_stops_existing_task_and_discards_queued_content_work', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const pending = rejected(loader.cache('/backup'));
      const queued = rejected(loader.cache('/other'));
      await cloudTestTurn();
      expect(loader.isCleanupPending()).assertTrue();
      expect(await loader.prepareForDelete('/backup')).assertTrue();
      expect(await pending).assertTrue();
      expect(await queued).assertTrue();
      await cloudTestTurn();
      expect(factory.clients.length).assertEqual(1);
      expect(factory.clients[0].stopCalls).assertEqual(1);
      expect(loader.isCleanupPending()).assertFalse();
    });

    it('cache_different_active_target_is_not_reported_safe_for_delete', 0, async () => {
      const factory = new FakeCacheFactory();
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const pending = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      expect(await loader.prepareForDelete('/other')).assertFalse();
      expect(factory.clients[0].stopCalls).assertEqual(0);
      expect(loader.isCleanupPending()).assertTrue();
      expect(await loader.retryCleanup()).assertTrue();
      expect(await pending).assertTrue();
    });

    it('cache_explicit_retry_reuses_cancellation_handle_and_clears_barrier', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.failFirstStop = true;
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const pending = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      expect(await loader.prepareForDelete('/backup')).assertFalse();
      expect(await pending).assertTrue();
      expect(loader.isCleanupPending()).assertTrue();
      expect(factory.clients[0].listener === null).assertFalse();
      expect(await loader.retryCleanup()).assertFalse();
      expect(factory.clients[0].stopCalls).assertEqual(2);
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].failStop = false;
      expect(await loader.retryCleanup()).assertTrue();
      expect(factory.clients[0].stopCalls).assertEqual(3);
      expect(loader.isCleanupPending()).assertFalse();
      const retry = loader.cache('/backup');
      await cloudTestTurn();
      factory.clients[1].emit(CloudCacheState.COMPLETED);
      await retry;
    });

    it('cache_cleanup_wait_is_bounded_and_does_not_repeat_unresolved_stop', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.holdFirstStop = true;
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000, 100);
      const pending = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      const cleanup = loader.prepareForDelete('/backup');
      const concurrentRetry = loader.retryCleanup();
      timer.expire();
      expect(await cleanup).assertFalse();
      expect(await concurrentRetry).assertFalse();
      expect(await pending).assertTrue();
      expect(factory.clients[0].stopCalls).assertEqual(1);
      expect(loader.isCleanupPending()).assertTrue();
      const retry = loader.retryCleanup();
      factory.clients[0].acceptStop();
      expect(await retry).assertTrue();
      expect(factory.clients[0].stopCalls).assertEqual(1);
      expect(factory.clients.length).assertEqual(1);
    });

    it('cache_late_terminal_after_failed_stop_drains_same_task_only', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.failFirstStop = true;
      const loader = new CloudFileCacheLoader(factory, new ManualCacheTimer());
      const pending = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      expect(await loader.prepareForDelete('/backup')).assertFalse();
      expect(await pending).assertTrue();
      const oldCallback = factory.clients[0].savedListener;
      factory.clients[0].emit(CloudCacheState.STOPPED);
      await cloudTestTurn();
      expect(loader.isCleanupPending()).assertFalse();
      const next = loader.cache('/backup');
      await cloudTestTurn();
      if (oldCallback !== null) {
        oldCallback({ uri: 'file:///backup', state: CloudCacheState.COMPLETED, error: 0 });
      }
      expect(loader.isCleanupPending()).assertTrue();
      factory.clients[1].emit(CloudCacheState.COMPLETED);
      await next;
    });

    it('cache_terminal_cannot_release_unresolved_stop_that_could_hit_next_task', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.holdFirstStop = true;
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000, 100);
      const pending = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      const cleanup = loader.prepareForDelete('/backup');
      factory.clients[0].emit(CloudCacheState.STOPPED);
      timer.expire();
      expect(await cleanup).assertFalse();
      expect(await pending).assertTrue();
      expect(await rejected(loader.cache('/backup'))).assertTrue();
      expect(factory.clients.length).assertEqual(1);
      factory.clients[0].acceptStop();
      await cloudTestTurn();
      expect(loader.isCleanupPending()).assertFalse();
    });

    it('cache_late_start_during_cleanup_never_creates_second_download', 0, async () => {
      const factory = new FakeCacheFactory();
      factory.holdFirstStart = true;
      const timer = new ManualCacheTimer();
      const loader = new CloudFileCacheLoader(factory, timer, 1000, 100);
      const pending = rejected(loader.cache('/backup'));
      await cloudTestTurn();
      const cleanup = loader.prepareForDelete('/backup');
      timer.expire();
      expect(await cleanup).assertFalse();
      expect(await pending).assertTrue();
      expect(factory.clients[0].stopCalls).assertEqual(0);
      expect(loader.isCleanupPending()).assertTrue();
      factory.clients[0].acceptStart();
      await cloudTestTurn();
      expect(factory.clients[0].stopCalls).assertEqual(1);
      expect(factory.clients.length).assertEqual(1);
      expect(await loader.retryCleanup()).assertTrue();
    });

    it('cache_initial_subscription_completion_does_not_complete_new_request', 0, async () => {
      const client = new FakeCacheClient();
      client.completeDuringSubscription = true;
      let done = false;
      const pending = waitForCloudFileCache(client, 'file:///backup', new ManualCacheTimer(), 1000)
        .then(() => { done = true; });
      await cloudTestTurn();
      expect(done).assertFalse();
      client.emit(CloudCacheState.COMPLETED);
      await pending;
    });

    it('cache_start_errors_are_fixed_and_not_raw_native_messages', 0, async () => {
      const client = new FakeCacheClient();
      client.failStart = true;
      let message = '';
      try {
        await waitForCloudFileCache(client, 'file:///backup', new ManualCacheTimer(), 1000);
      } catch (error) {
        message = (error as Error).message;
      }
      expect(message).assertEqual('CLOUD_CACHE_START_FAILED');
      expect(message.indexOf(client.errorMessage)).assertEqual(-1);
      await cloudTestTurn();
      expect(client.stopCalls).assertEqual(1);
    });
  });
}
