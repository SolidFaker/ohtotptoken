import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';

function load(file) {
  return readFileSync(new URL(`../${file}`, import.meta.url), 'utf8').replace(/^import\s[\s\S]*?;\r?\n/gm, '').replace(/export /g, '');
}
const paramsSource = load('entry/src/main/ets/dialogs/TokenProgressDialog.ets').split('@ComponentV2')[0]
  .replace(/@ObservedV2\s*/g, '').replace(/@Trace /g, '');
const runnerSource = load('entry/src/main/ets/utils/TokenBatchOperation.ets');

function fixture({ failOpen = false, failClose = false } = {}) {
  const events = [];
  const systemMaterial = { kind: 'test-dialog-material' };
  let options;
  let clock = 0;
  let current;
  const context = { getPromptAction: () => ({
    async openCustomDialog(value) {
      events.push('open'); options = value;
      assert.equal(typeof value.builder, 'function');
      assert.equal(value.customStyle, undefined);
      assert.equal(value.backgroundColor, undefined);
      assert.equal(value.systemMaterial, systemMaterial);
      if (failOpen) throw new Error('open failed');
      value.builder();
      return 42;
    },
    closeCustomDialog(id) {
      assert.equal(id, 42);
      events.push('close');
      if (failClose) throw new Error('context already gone');
    }
  }) };
  const host = {
    getUIContext: () => context,
    buildTokenProgressDialog(params) {
      assert.equal(this, host, 'builder must retain its UI component receiver');
      current = { params, updates: [] };
      let progress = params.progress;
      Object.defineProperty(params, 'progress', {
        get: () => progress,
        set: value => {
          progress = value;
          current.updates.push({ progress: value });
          events.push('update');
        }
      });
    }
  };
  const { TokenBatchOperation } = runInNewContext(stripTypeScriptTypes(paramsSource + runnerSource) + '\n({ TokenBatchOperation });', {
    TokenProgressDialogBuilder() { throw new Error('Builder cannot be called without a View context'); },
    dialogSystemMaterial: () => systemMaterial,
    TokenBatchStage: { PREPARING: 0 },
    DialogAlignment: { Center: 0 }, Date: { now: () => clock }, hilog: { info() {}, warn() {} }
  });
  return { runner: TokenBatchOperation, context: host, events, current: () => current, options: () => options,
    tick: ms => { clock += ms; } };
}

test('UI component builder preserves its receiver and updates progress with system dialog styling', async () => {
  const f = fixture();
  await f.runner.run(f.context, 'Importing', async report => {
    assert.equal(f.runner.isBusy(), true);
    assert.deepEqual(f.events, ['open']);
    report({ stage: 7, completed: 0, total: 100 });
    assert.equal(f.current().params.title, 'Importing');
    assert.equal(f.current().params.progress.total, 100);
    report({ stage: 7, completed: 100, total: 100 });
    f.events.push('work finished');
  });
  assert.deepEqual(f.events.slice(-2), ['work finished', 'close']);
  assert.equal(f.runner.isBusy(), false);
});

test('stage boundaries and final counts always update; intermediate ticks are throttled', async () => {
  const f = fixture();
  await f.runner.run(f.context, 'Importing', async report => {
    report({ stage: 7, completed: 0, total: 100 });
    for (let i = 1; i < 100; i++) {
      f.tick(1);
      report({ stage: 7, completed: i, total: 100 });
    }
    report({ stage: 7, completed: 100, total: 100 });
    report({ stage: 10, completed: 100, total: 100 });
    assert.deepEqual(f.current().updates.map(p => p.progress.completed), [0, 80, 100, 100]);
  });
});

test('open failure never starts persistence and still releases busy guard', async () => {
  const f = fixture({ failOpen: true });
  let worked = false;
  await assert.rejects(f.runner.run(f.context, 'Importing', async () => { worked = true; }), /open failed/);
  assert.equal(worked, false);
  assert.deepEqual(f.events, ['open']);
  assert.equal(f.runner.isBusy(), false);
});

test('work failure closes dialog and preserves the original error for retry UI', async () => {
  const f = fixture();
  await assert.rejects(f.runner.run(f.context, 'Deleting', async () => { throw new Error('KV rollback'); }), /KV rollback/);
  assert.deepEqual(f.events, ['open', 'close']);
  assert.equal(f.runner.isBusy(), false);
  await f.runner.run(f.context, 'Retry', async () => {});
});

for (const failure of ['failClose']) {
  test(`${failure} does not report committed data as failed or leave busy guard stuck`, async () => {
    const f = fixture({ [failure]: true });
    await f.runner.run(f.context, 'Importing', async () => {});
    assert.equal(f.runner.isBusy(), false);
    assert.equal(f.events.includes('close'), true);
  });
}

test('second operation is rejected without starting work or closing the first dialog', async () => {
  const f = fixture();
  await f.runner.run(f.context, 'First', async () => {
    let secondRan = false;
    await assert.rejects(f.runner.run(f.context, 'Second', async () => { secondRan = true; }), /already running/);
    assert.equal(secondRan, false);
    assert.deepEqual(f.events, ['open']);
    assert.equal(f.runner.isBusy(), true);
  });
});

test('back/outside dismissal is blocked during work and enabled after completion', async () => {
  const f = fixture();
  let dismissed = 0;
  const action = { dismiss: () => { dismissed++; } };
  await f.runner.run(f.context, 'Deleting', async () => {
    assert.equal(f.options().autoCancel, false);
    f.options().onWillDismiss(action);
    assert.equal(dismissed, 0);
  });
  f.options().onWillDismiss(action);
  assert.equal(dismissed, 1);
});

test('late progress after completion never updates closed content', async () => {
  const f = fixture();
  let reportLate;
  await f.runner.run(f.context, 'Importing', async report => { reportLate = report; });
  reportLate({ stage: 7, completed: 1, total: 2 });
  assert.deepEqual(f.events, ['open', 'close']);
});

test('URI submit awaits persistence, forwards progress, and only then pops the page', async () => {
  const text = load('entry/src/main/ets/pages/setting/UriImportSheet.ets');
  const start = text.indexOf('  private async submit(');
  const end = text.indexOf('\n  @Builder', start);
  const code = text.slice(start, end).replace('  private async submit(', 'async function submit(');
  const events = [];
  const tokens = [{ TokenUUID: 'generated' }];
  const report = () => {};
  let fail = false;
  const submit = runInNewContext(stripTypeScriptTypes(code) + '\nsubmit;', {
    parseOtpAuthUris: () => tokens,
    TokenBatchOperation: {
      isBusy: () => false,
      run: async (_context, _title, work) => { events.push('open'); try { await work(report); } finally { events.push('close'); } }
    },
    $r: key => key, showSnackBar: (_text, type) => events.push(type),
    SnackBarNotifyType: { SUCCESS: 'success', ERROR: 'error' }
  });
  const host = { isReading: false, uriText: 'generated URI', getUIContext: () => ({}),
    pageInfos: { pop: () => events.push('pop') },
    backupReload: async (values, observer) => {
      assert.equal(host.isReading, true);
      assert.equal(values, tokens);
      assert.equal(observer, report);
      events.push('persist');
      if (fail) throw new Error('KV failure');
    }
  };
  await submit.call(host);
  assert.deepEqual(events, ['open', 'persist', 'close', 'success', 'pop']);
  assert.equal(host.isReading, false);
  fail = true; events.length = 0;
  await submit.call(host);
  assert.deepEqual(events, ['open', 'persist', 'close', 'error']);
  assert.equal(host.uriText, 'generated URI');
  assert.equal(host.isReading, false);
});

test('backup decoding and persistence share one dialog; decode failure never calls import', async () => {
  const events = [];
  const report = () => {};
  let decodeFails = false;
  let busy = false;
  const { importBackupWithProgress } = runInNewContext(stripTypeScriptTypes(load('entry/src/main/ets/utils/BackupImportOperation.ets')) + '\n({ importBackupWithProgress });', {
    TokenBatchOperation: {
      isBusy: () => busy,
      run: async (_context, _title, work) => { events.push('open'); try { await work(report); } finally { events.push('close'); } }
    },
    restoreFromBackup: async (_uri, _encrypted, _password, observer) => {
      assert.equal(observer, report);
      events.push('decode');
      if (decodeFails) throw new Error('Wrong password');
      return { configs: [{ TokenUUID: 'generated' }] };
    },
    $r: key => key, showSnackBar: (_text, type) => events.push(type), hilog: { error() {} },
    SnackBarNotifyType: { SUCCESS: 'success', ERROR: 'error' }
  });
  const persist = async (_tokens, observer) => { assert.equal(observer, report); events.push('persist'); };
  assert.equal(await importBackupWithProgress({}, 'fixture', true, 'test password', persist), true);
  assert.deepEqual(events, ['open', 'decode', 'persist', 'close', 'success']);
  events.length = 0; decodeFails = true;
  assert.equal(await importBackupWithProgress({}, 'fixture', true, 'wrong', persist), false);
  assert.deepEqual(events, ['open', 'decode', 'close', 'error']);
  events.length = 0; busy = true;
  assert.equal(await importBackupWithProgress({}, 'fixture', false, '', persist), false);
  assert.equal(events.length, 0);
});

test('batch dialog only shows system loading animation and localized loading text', () => {
  const text = load('entry/src/main/ets/dialogs/TokenProgressDialog.ets');
  assert.match(text, /LoadingDialogV2\(\{ content: \$r\('app.string.token_batch_loading'\) \}\)/);
  assert.doesNotMatch(text, /CustomContentDialogV2|LoadingProgress\(|Text\(/);
  assert.doesNotMatch(text, /\.backgroundColor\(|\.borderRadius\(/);
  assert.doesNotMatch(text, /this.params\.|stageLabel|contentText|token_batch_keep_open/);
});

test('batch deletion confirmation uses system AlertDialogV2 with a destructive action', () => {
  const text = load('entry/src/main/ets/pages/Index.ets');
  const block = text.slice(text.indexOf('  private confirmMultiDelete()'), text.indexOf('  MultiGroupDialog('));
  assert.match(block, /openCustomDialog\(/);
  assert.match(block, /AlertDialogV2\(/);
  assert.match(block, /role: ButtonRole.ERROR/);
  assert.match(block, /this.applyMultiAction\('delete'\)/);
  assert.doesNotMatch(block, /showAlertDialog\(/);
});

test('progress resources exist with matching placeholders in all shipped languages', () => {
  const locales = ['base', 'en_US', 'zh_CN', 'zh_TW'];
  let keys;
  for (const locale of locales) {
    const strings = JSON.parse(readFileSync(new URL(`../common/src/main/resources/${locale}/element/string.json`, import.meta.url), 'utf8')).string;
    const progress = strings.filter(item => item.name.startsWith('token_batch_'));
    const names = progress.map(item => item.name).sort();
    if (keys) assert.deepEqual(names, keys); else keys = names;
    assert.equal(new Set(names).size, names.length);
    assert.equal(progress.find(item => item.name === 'token_batch_count').value.match(/%d/g).length, 2);
    assert.equal(progress.every(item => item.value.length > 0), true);
  }
});
