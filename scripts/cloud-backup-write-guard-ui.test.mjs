import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';

// 直接提取并执行当前生产方法，只替换平台边界；不复制清理、路由或结果判断实现。
// ArkUI 渲染用组件桩验证真实 builder 分支，不能替代主代理的构建/设备验收。
const load = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const common = 'common/src/main/ets/utils/';
const pages = 'entry/src/main/ets/pages/';
const history = load(pages + 'ShowCloudBackupHistoryPage.ets');
const details = load(pages + 'ShowCloudSyncDetailsPage.ets');
const sheet = load(pages + 'setting/CloudBackupDetailsSheet.ets');
const historyPanel = load(pages + 'setting/CloudBackupHistorySheet.ets');
const feedback = load(pages + 'setting/FeedbackSheet.ets');
const web = load(pages + 'WebPage.ets');
const SENTINEL = 'SYNTHETIC_PRIVATE_DATA';
const r = (key, ...args) => ({ key, args });
const plain = value => JSON.parse(JSON.stringify(value));

function blockEnd(source, open) {
  let depth = 0;
  // 忽略注释和字面量中的括号，保留原方法正文，不根据待测逻辑改写代码。
  const tokens = /\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`|[{}]/g;
  tokens.lastIndex = open;
  for (let match; (match = tokens.exec(source));) {
    if (match[0] === '{') depth++;
    if (match[0] === '}' && --depth === 0) return match.index + 1;
  }
  throw new Error('PRODUCTION_BLOCK_UNAVAILABLE');
}
function method(source, name) {
  const match = new RegExp(`^  (?:private\\s+)?(?:async\\s+)?${name}\\(`, 'm').exec(source);
  assert.ok(match, `Production method ${name} must exist`);
  const open = source.indexOf('{', match.index);
  return source.slice(match.index, blockEnd(source, open));
}
function declaration(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `Production declaration ${marker} must exist`);
  const open = source.indexOf('{', start);
  return source.slice(start, blockEnd(source, open));
}
function executable(source) {
  return stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, '').replace(/\bexport\s+/g, ''),
    { mode: 'transform' });
}
function builderContainers(source) {
  // 仅适配 ArkUI 容器语法为回调；条件、组件调用、参数与事件均执行原正文。
  const pattern = /\b(?:HdsNavDestination|Column)\(\)\s*\{/g;
  let match;
  let output = '';
  let position = 0;
  while ((match = pattern.exec(source))) {
    const open = source.indexOf('{', match.index);
    const end = blockEnd(source, open);
    output += source.slice(position, open) + '(() => {' + builderContainers(source.slice(open + 1, end - 1)) + '})';
    position = end;
    pattern.lastIndex = end;
  }
  return output + source.slice(position);
}
function fixtureClass(name, source, names, builder = false) {
  const body = names.map(name => method(source, name)).join('\n');
  return executable(`class ${name} {\n${builder ? builderContainers(body) : body}\n}`);
}
const production = [
  executable(load(common + 'CloudBackupDiagnostics.ets')),
  executable(load(common + 'CloudBackupResult.ets')),
  ...['CloudBackupMetadataStatus', 'CloudBackupIdentityStatus'].map(name =>
    executable(declaration(load(common + 'CloudBackupCrypto.ets'), `export enum ${name}`))),
  ...['ROUTE_NAMES', 'EXTERNAL_URLS'].map(name =>
    executable(declaration(load(common + 'AppPreference.ets'), `export enum ${name}`))),
  executable(declaration(web, 'export class WebPageParams')),
  fixtureClass('HistoryFixture', history, ['refreshOperationState', 'interactionBlocked', 'canStartAction',
    'loadBackupHistory', 'triggerUnknownSourceCleanup', 'retrySync', 'isEnumerated', 'canRestore',
    'selectionStillValid', 'actionFailureText', 'failureText', 'triggerDelete']),
  fixtureClass('DetailsFixture', details, ['interactionBlocked', 'openFeedback', 'failureText', 'lastFailureReasonText']),
  fixtureClass('SheetFixture', sheet, ['aboutToAppear', 'aboutToDisappear', 'Destination'], true),
  fixtureClass('HistoryPanelFixture', historyPanel, ['aboutToAppear', 'aboutToDisappear', 'Destination'], true),
  fixtureClass('FeedbackFixture', feedback, ['navDestinationBuilder']),
].join('\n');

function environment(detailed = true) {
  const lines = [], snacks = [], components = [];
  const attributes = event => new Proxy({}, { get: (_target, key) => (...args) => {
    event.attributes[key] = args;
    return attributes(event);
  } });
  const component = name => props => {
    const event = { name, props, attributes: {} };
    components.push(event);
    return attributes(event);
  };
  const container = name => () => children => {
    const event = { name, attributes: {} };
    components.push(event);
    children();
    return attributes(event);
  };
  const api = runInNewContext(production + `\n({ HistoryFixture, DetailsFixture, SheetFixture, HistoryPanelFixture, FeedbackFixture,
    WebPageParams, ROUTE_NAMES, EXTERNAL_URLS, CloudBackupActionResult, CloudBackupFailureReason,
    CloudBackupMetadataStatus, CloudBackupIdentityStatus, CloudBackupDiagnostics,
    activeContexts: () => CloudBackupDiagnostics.recorder.operations.length });`, {
    process: { pid: 1, tid: 1 }, systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 1 },
    hilog: { info: (_domain, _tag, _format, line) => lines.push(line) },
    $r: r, SnackBarNotifyType: { SUCCESS: 'SUCCESS', WARNING: 'WARNING' },
    showSnackBar: (message, type) => snacks.push({ message, type }),
    DeviceInfoHelper: { getInstance: () => ({ getDeviceId: () => 'synthetic-current' }) },
    MaterialTheme: { surfaceBackground: value => value },
    HdsNavDestination: container('HdsNavDestination'), Column: container('Column'),
    Button: component('Button'), FeedbackSheet: component('FeedbackSheet'), WebPage: component('WebPage'),
    ShowCloudSyncDetailsPage: component('ShowCloudSyncDetailsPage'),
    ShowCloudBackupHistoryPage: component('ShowCloudBackupHistoryPage'),
  });
  if (detailed) assert.equal(api.CloudBackupDiagnostics.enable(), true);
  return { api, lines, snacks, components };
}
function record(api, suffix) {
  return { id: `${SENTINEL}_${suffix}`, date: SENTINEL, deviceName: SENTINEL, deviceId: '',
    metadataStatus: api.CloudBackupMetadataStatus.VALID, identityStatus: api.CloudBackupIdentityStatus.ID_MISSING };
}
function historyFixture(outcomes, options = {}) {
  const env = environment(options.detailed ?? true);
  const { api } = env;
  const records = ['a', 'b', 'c', 'untargeted'].map(suffix => record(api, suffix));
  const calls = { deletes: [], lists: 0, sync: 0 };
  const behavior = { retry: true };
  const page = Object.assign(new api.HistoryFixture(), {
    isMounted: true, isLoading: false, isActionRunning: false, isRetryingCleanup: false,
    confirmationOpen: false, serviceBusy: false, cleanupPending: false, needsSyncRetry: false,
    historyLoaded: true, historyError: '', actionMessage: '', backupRecords: records.slice(),
    selectedRecord: records[0], isDetailVisible: true,
    backupManager: {
      isBusy: () => false, isCleanupPending: () => false,
      async deleteBackupRecordResult(id) {
        const index = calls.deletes.length;
        calls.deletes.push(id);
        options.beforeDelete?.(index, page);
        const value = outcomes[index];
        if (typeof value === 'function') return value(page, api);
        if (value instanceof Error) throw value;
        return Object.assign(new api.CloudBackupActionResult(), value);
      },
      async listBackupHistoryResult() {
        calls.lists++;
        if (options.refreshThrows) throw new Error(SENTINEL);
        return { success: false, reason: api.CloudBackupFailureReason.READ_FAILED, records: [] };
      },
      async retrySync() {
        calls.sync++;
        if (behavior.retry instanceof Error) throw behavior.retry;
        return behavior.retry;
      },
    },
  });
  return { ...env, page, records, calls, behavior };
}
const accepted = { success: true, localComplete: true, syncStartAccepted: true };
const rejected = { localComplete: true, reason: 'SYNC_FAILED' };
const notDeleted = { reason: 'DELETE_FAILED' };
function summary(fixture, key, args, type = 'WARNING') {
  assert.deepEqual(plain(fixture.page.actionMessage), r('app.string.' + key, ...args));
  assert.equal(fixture.snacks.at(-1).type, type);
  assert.equal(fixture.page.isActionRunning, false);
  assert.equal(fixture.api.activeContexts(), 0);
}
function resultLine(fixture) {
  return fixture.lines.find(line => line.includes('stage=UI_RESULT'));
}

test('production aggregate rejects sync with warning and removes completed IDs before failed refresh', async () => {
  const f = historyFixture([rejected]);
  await f.page.triggerUnknownSourceCleanup([f.records[0]]);
  summary(f, 'cloud_backup_unknown_cleanup_sync_failed', [1, 0]);
  assert.equal(f.page.needsSyncRetry, true);
  assert.deepEqual(f.page.backupRecords.map(item => item.id), f.records.slice(1).map(item => item.id));
  assert.equal(f.page.canRestore(f.records[0]), false);
  assert.equal(f.page.selectedRecord, null);
  assert.equal(f.page.isDetailVisible, false);
  assert.equal(f.calls.lists, 1);
  assert.equal(f.page.historyError.key, 'app.string.cloud_backup_read_failed');
  assert.match(resultLine(f), /result=FAIL reason=SYNC_REJECTED/);
  assert.match(resultLine(f), /syncStartAccepted=false partialFailure=false/);
  assert.ok(f.lines.some(line => /stage=UI_REFRESH result=FAIL/.test(line)));
});

test('mixed aggregate retains failed IDs and does not hide earlier sync rejection after later acceptance', async () => {
  const f = historyFixture([rejected, notDeleted, accepted], { beforeDelete(index, page) {
    if (index > 0) assert.equal(page.backupRecords.some(item => item.id.endsWith('_a')), false);
  } });
  await f.page.triggerUnknownSourceCleanup(f.records.slice(0, 3));
  summary(f, 'cloud_backup_unknown_cleanup_sync_failed', [2, 1]);
  assert.deepEqual(f.page.backupRecords.map(item => item.id), [f.records[1].id, f.records[3].id]);
  assert.equal(f.page.needsSyncRetry, true);
  assert.equal(f.page.canRestore(f.records[0]), false);
  assert.equal(f.page.canRestore(f.records[2]), false);
  assert.match(resultLine(f), /syncStartAccepted=false partialFailure=true/);
});

test('accepted aggregate deletion still warns that cloud deletion is pending, not complete', async () => {
  const f = historyFixture([accepted, accepted]);
  f.page.needsSyncRetry = true;
  await f.page.triggerUnknownSourceCleanup(f.records.slice(0, 2));
  summary(f, 'cloud_backup_unknown_cleanup_sync_pending', [2, 0]);
  assert.equal(f.page.needsSyncRetry, false);
  assert.match(resultLine(f), /result=PENDING reason=NONE/);
  assert.match(resultLine(f), /syncStartAccepted=true partialFailure=false/);
});

test('aggregate delete exception retains failed and unattempted IDs with accurate local summary', async () => {
  const f = historyFixture([accepted, notDeleted, new Error(SENTINEL)]);
  await f.page.triggerUnknownSourceCleanup(f.records);
  summary(f, 'cloud_backup_unknown_cleanup_sync_pending', [1, 3]);
  assert.deepEqual(f.page.backupRecords.map(item => item.id), f.records.slice(1).map(item => item.id));
  assert.equal(f.calls.deletes.length, 3);
  assert.match(resultLine(f), /result=FAIL reason=PARTIAL_FAILURE/);
});

test('aggregate with no completed deletion keeps all records and does not reload history', async () => {
  const f = historyFixture([notDeleted, notDeleted]);
  await f.page.triggerUnknownSourceCleanup(f.records.slice(0, 2));
  summary(f, 'cloud_backup_unknown_cleanup_done', [0, 2]);
  assert.equal(f.calls.lists, 0);
  assert.deepEqual(f.page.backupRecords, f.records);
});

test('history refresh rejection cannot reintroduce completed aggregate records', async () => {
  const f = historyFixture([rejected], { refreshThrows: true });
  await f.page.triggerUnknownSourceCleanup([f.records[0]]);
  summary(f, 'cloud_backup_unknown_cleanup_sync_failed', [1, 0]);
  assert.equal(f.page.backupRecords.some(item => item.id === f.records[0].id), false);
  assert.equal(f.page.historyError.key, 'app.string.cloud_backup_history_load_failed');
});

test('blocked or empty aggregates end diagnostics without deletion or changing action state', async () => {
  for (const flag of ['isLoading', 'isActionRunning', 'confirmationOpen', 'isRetryingCleanup', 'isMounted', 'empty']) {
    const f = historyFixture([]);
    if (flag !== 'empty') f.page[flag] = flag !== 'isMounted';
    await f.page.triggerUnknownSourceCleanup(flag === 'empty' ? [] : [f.records[0]]);
    assert.equal(f.calls.deletes.length, 0);
    assert.equal(f.snacks.length, 0);
    assert.equal(f.api.activeContexts(), 0);
    assert.match(resultLine(f), /result=BLOCKED/);
    if (flag === 'isActionRunning') assert.equal(f.page.isActionRunning, true);
  }
});

test('unmounted aggregate resets loading and ends context without updating disposed UI', async () => {
  const f = historyFixture([page => { page.isMounted = false; return accepted; }]);
  await f.page.triggerUnknownSourceCleanup([f.records[0]]);
  assert.equal(f.page.isActionRunning, false);
  assert.equal(f.api.activeContexts(), 0);
  assert.equal(f.snacks.length, 0);
  assert.deepEqual(f.page.backupRecords, f.records);
  assert.match(resultLine(f), /result=CANCELLED/);
});

test('production sync retry only submits sync and never repeats deletion or reloads records', async () => {
  const f = historyFixture([rejected]);
  await f.page.triggerUnknownSourceCleanup([f.records[0]]);
  const kept = f.page.backupRecords.slice();
  for (const outcome of [false, new Error(SENTINEL), true]) {
    f.behavior.retry = outcome;
    await f.page.retrySync();
    assert.equal(f.page.needsSyncRetry, outcome !== true);
    assert.equal(f.page.isActionRunning, false);
    assert.deepEqual(f.page.backupRecords, kept);
  }
  assert.equal(f.calls.sync, 3);
  assert.equal(f.calls.deletes.length, 1);
  assert.equal(f.calls.lists, 1);
  assert.equal(f.page.actionMessage.key, 'app.string.cloud_backup_sync_pending');
});

test('single production delete also removes locally complete records despite rejected sync and failed refresh', async () => {
  const f = historyFixture([rejected]);
  await f.page.triggerDelete(f.records[0]);
  assert.equal(f.page.needsSyncRetry, true);
  assert.equal(f.page.canRestore(f.records[0]), false);
  assert.equal(f.page.selectedRecord, null);
  assert.equal(f.page.isDetailVisible, false);
  assert.equal(f.snacks.at(-1).type, 'WARNING');
  assert.equal(f.page.actionMessage.key, 'app.string.cloud_backup_local_done_sync_failed');
});

function feedbackFixture(detailed = true) {
  const f = environment(detailed);
  const page = Object.assign(new f.api.DetailsFixture(), {
    isMounted: true, isLoading: false, isRetryingCleanup: false, confirmationOpen: false,
    serviceBusy: false, cleanupPending: false, lastFailure: { knownReason: true, reason: 'POST_VERIFY_FAILED' },
    isFeedbackSheetVisible: false,
  });
  return { ...f, page };
}

test('production feedback action opens the in-sheet feedback panel with no business payload', () => {
  const f = feedbackFixture();
  f.page.openFeedback();
  assert.equal(f.page.isFeedbackSheetVisible, true);
  assert.equal(f.api.ROUTE_NAMES.SettingFeedback, 'setting/feedback');
  assert.match(resultLine(f), /result=OK reason=NONE.*uiAction=FEEDBACK/);
  assert.equal(f.api.activeContexts(), 0);
  assert.match(details, /\.onClick\(\(\) => this\.openFeedback\(\)\)/);
});

test('feedback blockers cannot open the panel and never leave a live diagnostic context', () => {
  for (const flag of ['isMounted', 'isLoading', 'isRetryingCleanup', 'confirmationOpen', 'serviceBusy', 'cleanupPending',
    'lastFailure']) {
    const f = feedbackFixture();
    if (flag === 'lastFailure') f.page[flag] = null;
    else f.page[flag] = flag !== 'isMounted';
    f.page.openFeedback();
    assert.equal(f.page.isFeedbackSheetVisible, false);
    assert.equal(f.api.activeContexts(), 0);
    assert.match(resultLine(f), /result=BLOCKED/);
    assert.equal(f.lines.join('\n').includes(SENTINEL), false);
  }
});

test('actual sheet builder auto-pushes only the sync details root without animation and clears on hide', () => {
  const f = environment();
  const paths = [];
  const stack = { pushPathByName: (...args) => paths.push(args), pop: () => paths.pop(), clear: () => { paths.length = 0; } };
  const page = Object.assign(new f.api.SheetFixture(), { pageInfos: stack, scrollEffectType: 'synthetic-effect', onClose() {} });
  page.aboutToAppear();
  assert.deepEqual(paths, [[f.api.ROUTE_NAMES.ShowCloudSyncDetailsPage, null, false]]);
  page.Destination(f.api.ROUTE_NAMES.ShowCloudSyncDetailsPage, null);
  const content = f.components.find(item => item.name === 'ShowCloudSyncDetailsPage');
  assert.ok(content);
  assert.equal(content.props.scrollEffectType, 'synthetic-effect');
  assert.equal(content.props.inMaterialSheet, true);
  assert.equal(content.props.sheetRoot, true);
  assert.equal(typeof content.props.onCloseSheet, 'function');
  page.aboutToDisappear();
  assert.deepEqual(paths, []);
  assert.doesNotMatch(sheet, /backFromFeedback|SettingFeedback|ShowCloudBackupHistoryPage/);
  assert.match(sheet, /HdsNavigation\(this\.pageInfos\)[\s\S]*\.navDestination\(this\.Destination\)/);
});

test('history panel wrapper keeps an isolated animation-free stack and closes its own panel', () => {
  const f = environment();
  const paths = [];
  let closed = 0;
  const stack = { pushPathByName: (...args) => paths.push(args), pop: () => paths.pop(), clear: () => { paths.length = 0; } };
  const page = Object.assign(new f.api.HistoryPanelFixture(), {
    pageInfos: stack, scrollEffectType: 'synthetic-effect', onClose() { closed++; },
  });
  page.aboutToAppear();
  assert.deepEqual(paths, [[f.api.ROUTE_NAMES.ShowCloudBackupHistoryPage, null, false]]);
  page.Destination(f.api.ROUTE_NAMES.ShowCloudBackupHistoryPage, null);
  const content = f.components.find(item => item.name === 'ShowCloudBackupHistoryPage');
  assert.ok(content);
  assert.equal(content.props.scrollEffectType, 'synthetic-effect');
  assert.equal(content.props.inMaterialSheet, true);
  assert.equal(content.props.sheetRoot, true);
  assert.equal(typeof content.props.onCloseSheet, 'function');
  content.props.onCloseSheet();
  assert.equal(closed, 1);
  page.aboutToDisappear();
  assert.deepEqual(paths, []);
});

test('history and feedback open as bottom sheets on the sync details page without side-slide pushes', () => {
  assert.match(details, /import lazy \{ CloudBackupHistorySheet, cloudBackupHistorySheetOptions \} from '\.\/setting\/CloudBackupHistorySheet'/);
  assert.match(details, /import lazy \{ FeedbackSheet \} from '\.\/setting\/FeedbackSheet'/);
  assert.match(details, /bindSheet\(\$\$this\.isHistorySheetVisible, this\.HistorySheetContent\(\), this\.historySheetOptions\(\)\)/);
  assert.match(details, /bindSheet\(\$\$this\.isFeedbackSheetVisible, this\.FeedbackSheetContent\(\), this\.feedbackSheetOptions\(\)\)/);
  assert.match(details, /FeedbackSheet\(\{ scrollEffectType: this\.scrollEffectType, embedded: false \}\)/);
  // 侧滑 push 是沉浸光感残留的触发条件（透明背板页被侧滑推入）；详情页内禁止回归。
  assert.doesNotMatch(details, /pushPathByName/);
});

test('reused FeedbackSheet independently registers its real WebPage target and preserves survey parameters', () => {
  const f = environment();
  const page = Object.assign(new f.api.FeedbackFixture(), { scrollEffectType: 'synthetic-effect' });
  const param = new f.api.WebPageParams(f.api.EXTERNAL_URLS.FEEDBACK_SURVEY, r('app.string.feedback_survey'));
  page.navDestinationBuilder(f.api.ROUTE_NAMES.WebPage, param);
  const content = f.components.find(item => item.name === 'WebPage');
  assert.ok(content);
  assert.equal(content.props.pageParams, param);
  assert.equal(content.props.scrollEffectType, 'synthetic-effect');
  assert.equal(content.props.pageParams.url, f.api.EXTERNAL_URLS.FEEDBACK_SURVEY);
  assert.match(feedback, /pageInfos: NavPathStack = new NavPathStack\(\)/);
  assert.match(feedback, /HdsNavigation\(this\.pageInfos\)[\s\S]*\.navDestination\(this\.navDestinationBuilder\)/);
  assert.match(feedback, /this\.pageInfos\.pushPathByName\(ROUTE_NAMES\.WebPage,\s*new WebPageParams\(EXTERNAL_URLS\.FEEDBACK_SURVEY,/);
  assert.match(web, /EmbeddedLayout\(\)[\s\S]*HdsNavDestination\(\)/);
  assert.match(web, /this\.pageInfos = context\.pathStack/);
});

test('production post-verify reason mapping uses neutral unavailable text without unconditional cleanup claims', () => {
  const f = feedbackFixture();
  assert.equal(f.page.lastFailureReasonText(f.page.lastFailure).key, 'app.string.cloud_backup_failure_reason_post_verify');
  assert.match(details, /Text\(this\.lastFailureReasonText\(this\.lastFailure\)\)/);
  for (const locale of ['base', 'en_US', 'zh_CN', 'zh_TW']) {
    const rows = JSON.parse(load(`common/src/main/resources/${locale}/element/string.json`)).string;
    const value = rows.find(item => item.name === 'cloud_backup_failure_reason_post_verify').value;
    assert.doesNotMatch(value, /removed|cleaned|已清理|已刪除|已删除/i);
    assert.match(value, /unavailable|不可用/);
  }
});

test('all cloud UI resources and four-language placeholders agree, including aggregate variants and back label', () => {
  const used = [...new Set([...history.matchAll(/\$r\('app\.string\.([^']+)'/g),
    ...details.matchAll(/\$r\('app\.string\.([^']+)'/g), ...sheet.matchAll(/\$r\('app\.string\.([^']+)'/g)]
    .map(match => match[1]))];
  let signatures;
  for (const locale of ['base', 'en_US', 'zh_CN', 'zh_TW']) {
    const rows = JSON.parse(load(`common/src/main/resources/${locale}/element/string.json`)).string;
    const cloud = rows.filter(item => item.name.startsWith('cloud_backup_'));
    assert.equal(new Set(cloud.map(item => item.name)).size, cloud.length);
    const current = cloud.map(item => [item.name, item.value.match(/%(?:\d+\$)?[ds]/g) ?? []]).sort();
    if (signatures) assert.deepEqual(current, signatures); else signatures = current;
    for (const key of used) assert.equal(rows.filter(item => item.name === key && item.value.trim() !== '').length, 1);
    for (const key of ['done', 'sync_failed', 'sync_pending']) {
      const value = cloud.find(item => item.name === 'cloud_backup_unknown_cleanup_' + key).value;
      assert.deepEqual(value.match(/%[ds]/g), ['%d', '%d']);
    }
    assert.deepEqual(rows.find(item => item.name === 'cloud_backup_feedback_back').value.match(/%[ds]/g) ?? [], []);
  }
});

test('actual recorder keeps detailed UI events closed and default summaries free of private data or counts', async () => {
  for (const detailed of [true, false]) {
    const f = historyFixture([rejected], { detailed });
    await f.page.triggerUnknownSourceCleanup([f.records[0]]);
    const g = feedbackFixture(detailed);
    g.page.openFeedback();
    const lines = [...f.lines, ...g.lines];
    assert.ok(lines.length > 0);
    assert.doesNotMatch(lines.join('\n'), /SYNTHETIC_PRIVATE_DATA|setting\/feedback|records|deleted|failedCount|deviceName|tokenCount/);
    const allowed = detailed ? ['v', 'op', 'kind', 'stage', 'result', 'reason', 'elapsed', 'uiAction',
      'syncStartAccepted', 'partialFailure'] : ['v', 'kind', 'stage', 'result', 'reason'];
    for (const line of lines) for (const field of line.split(' ')) assert.ok(allowed.includes(field.split('=')[0]));
    if (detailed) assert.ok(lines.some(line => line.includes('uiAction=UNKNOWN_SOURCE_CLEANUP')));
    else assert.equal(lines.some(line => line.includes('uiAction=')), false);
  }
  for (const source of [history, details, sheet]) assert.doesNotMatch(source, /\b(?:hilog|console)\s*[.[]|\.message\b|\.stack\b/);
});
