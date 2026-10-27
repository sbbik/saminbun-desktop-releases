// Synthetic loopback HTTPS service only. No provider calls, production code or business data.
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID, randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

export function createFixture({ key, cert, report, closedMarker, delayMs = 20000 }) {
  const token = randomBytes(32).toString('hex');
  const session = { workspace: { id: '7d90967e-0eb1-4ed5-b78c-2cc631ce22e5', slug: 'qa-windows', name: 'Synthetic QA' },
    user: { id: '11b854d4-8674-4bf0-9c90-62469145f9b5', loginId: 'qa-user', displayName: 'Synthetic QA', role: 'master' },
    permissions: ['orders.read', 'orders.collect'] };
  const createdAt = new Date().toISOString();
  const syntheticOrder = { resource: 'orders', platform: 'self', source: 'synthetic-windows-qa', date: '2026-10-01',
    orderId: 'QA-WINDOWS-SERVER-ORDER-001', sourceOrderLineId: 'QA-WINDOWS-SERVER-LINE-001', productName: 'Synthetic Windows QA', quantity: 1, revenue: 1000, grossRevenue: 1000, status: 'completed' };
  let job = null, revision = 1, timer;
  const state = { ready: false, revision, startPosts: 0, observerJobGets: 0, forbiddenJobWrites: 0, protocol2Observed: false,
    acceptedAt: null, appClosedAt: null, completedAt: null, completedAfterAppClosed: false, job: null, failure: null };
  function persist() {
    state.revision = revision; state.job = job;
    fs.writeFileSync(`${report}.tmp`, JSON.stringify(state)); fs.renameSync(`${report}.tmp`, report);
  }
  const reply = (res, status, value) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(value)); };
  const server = https.createServer({ key, cert }, async (req, res) => {
    try {
      assert.equal(req.socket.remoteAddress, '127.0.0.1');
      const route = new URL(req.url, 'https://127.0.0.1').pathname;
      const root = '/api/desktop/v1';
      let body = '';
      for await (const chunk of req) { body += chunk; if (Buffer.byteLength(body) > 8192) throw Error('BODY_LIMIT'); }
      const input = body ? JSON.parse(body) : null;
      if (route === `${root}/session` && req.method === 'POST') {
        assert.deepEqual(input, { workspaceSlug: 'qa-windows', loginId: 'qa-user', password: 'Synthetic-QA-only-2026!' });
        return reply(res, 200, { ...session, token, expiresAt: new Date(Date.now() + 3600000).toISOString() });
      }
      if (req.headers.authorization !== `Bearer ${token}`) return reply(res, 401, { error: { code: 'UNAUTHORIZED', mayHaveSaved: false } });
      if (route === `${root}/session` && req.method === 'GET') return reply(res, 200, session);
      if (route === `${root}/state` && req.method === 'GET') return reply(res, 200, { workspaceId: session.workspace.id, revision, updatedAt: state.completedAt || createdAt, data: { records: revision === 2 ? [syntheticOrder] : [] }, hiddenSections: [] });
      const jobs = `${root}/api-order-jobs`;
      if (route.startsWith(jobs)) {
        assert.equal(req.headers['x-saminbun-order-protocol'], '2'); state.protocol2Observed = true;
        if (req.method === 'GET' && route === jobs) return reply(res, 200, { jobs: job ? [job] : [], capabilities: { serverExecution: true } });
        if (req.method === 'GET' && job && route === `${jobs}/${job.jobId}`) { state.observerJobGets++; persist(); return reply(res, 200, job); }
        if (req.method === 'POST' && route === jobs) {
          state.startPosts++; persist();
          assert.equal(state.startPosts, 1, 'DUPLICATE_START');
          assert.deepEqual(Object.keys(input).sort(), ['executionMode', 'expectedRevision', 'period', 'platform', 'requestId']);
          assert.equal(input.executionMode, 'server'); assert.equal(input.expectedRevision, 1);
          assert.equal(input.platform, 'self'); assert.deepEqual(input.period, { start: '2026-10-01', end: '2026-10-01' });
          assert(/^[a-f0-9-]{36}$/.test(input.requestId));
          const now = new Date().toISOString();
          job = { jobId: randomUUID(), requestId: input.requestId, platform: input.platform, period: input.period,
            status: 'collecting', progress: { completedDays: 0, totalDays: 1, records: 0 }, inputRevision: 1, connectionRevision: 1,
            expiresAt: new Date(Date.now() + 3600000).toISOString(), asOf: now, dateBasis: 'synthetic', warnings: [], errorCode: null, receipt: null,
            execution: { mode: 'server', state: 'running', attempt: 1, nextAttemptAt: null, lastErrorCode: null } };
          state.acceptedAt = now; persist();
          timer = setTimeout(() => {
            try {
              assert(fs.existsSync(closedMarker), 'APP_NOT_CLOSED_BEFORE_SERVER_COMPLETION');
              const marker = JSON.parse(fs.readFileSync(closedMarker, 'utf8'));
              assert.equal(marker.mainPidGone, true); assert(Date.parse(marker.closedAt) >= Date.parse(state.acceptedAt));
              const completedAt = new Date().toISOString();
              assert(Date.parse(marker.closedAt) < Date.parse(completedAt));
              job.status = 'completed'; job.progress = { completedDays: 1, totalDays: 1, records: 1 }; job.execution.state = 'completed';
              job.receipt = { revision: 2, result: { jobId: job.jobId, imported: 1, updated: 0, unchanged: 0, total: 1 }, updatedAt: completedAt };
              revision = 2; state.appClosedAt = marker.closedAt; state.completedAt = completedAt; state.completedAfterAppClosed = true;
            } catch { state.failure = 'SYNTHETIC_COMPLETION_PRECONDITION_FAILED'; }
            persist();
          }, delayMs);
          return reply(res, 202, job);
        }
        if (req.method !== 'GET') { state.forbiddenJobWrites++; persist(); throw Error('CLIENT_JOB_WRITE_FORBIDDEN'); }
      }
      // UI status probes outside this fixture's narrow contract get a real 404.
      return reply(res, 404, { error: { code: 'NOT_FOUND', mayHaveSaved: false } });
    } catch { state.failure = 'SYNTHETIC_CONTRACT_VIOLATION'; persist(); return reply(res, 400, { error: { code: 'ORDER_INVALID_INPUT', mayHaveSaved: false } }); }
  });
  return { server, state, ready() { state.ready = true; persist(); }, dispose() { clearTimeout(timer); server.closeAllConnections(); return new Promise(resolve => server.close(resolve)); } };
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  assert.equal(process.platform, 'win32'); assert.equal(process.env.GITHUB_ACTIONS, 'true');
  assert.equal(process.env.RUNNER_ENVIRONMENT, 'github-hosted'); assert.equal(process.env.GITHUB_REPOSITORY, 'sbbik/saminbun-desktop-releases');
  const [keyFile, certFile, report, closedMarker, port] = process.argv.slice(2);
  assert(/^\d+$/.test(port) && Number(port) > 1024 && Number(port) < 65536);
  const fixture = createFixture({ key: fs.readFileSync(keyFile), cert: fs.readFileSync(certFile), report, closedMarker });
  fixture.server.listen(Number(port), '127.0.0.1', () => fixture.ready());
  setTimeout(() => { void fixture.dispose().then(() => process.exit(1)); }, 120000).unref();
}
