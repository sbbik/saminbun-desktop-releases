// Public QA helper only. Uses the installed app's own renderer bridge over a
// loopback-only CDP connection. It never reads app sources, credentials or DBs.
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const args = process.argv.slice(2), values = {};
for (let i = 0; i < args.length; i += 2) {
  if (!["--endpoint", "--mode", "--from", "--to", "--sentinel", "--fixture-url", "--job-id"].includes(args[i]) || !args[i + 1] || values[args[i]]) throw new Error("QA_ARGUMENTS_INVALID");
  values[args[i]] = args[i + 1];
}
function hostedOnly() {
  assert.equal(process.platform, "win32");
  assert.equal(process.env.GITHUB_ACTIONS, "true"); assert.equal(process.env.RUNNER_OS, "Windows");
  assert.equal(process.env.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(process.env.GITHUB_REPOSITORY, "sbbik/saminbun-desktop-releases");
  assert(!process.env.SAMINBUN_DESKTOP_QA_USER_DATA, "Default profile is required for real NSIS relaunch semantics");
}
async function run() {
  hostedOnly();
  const endpoint = new URL(values["--endpoint"]);
  assert(endpoint.protocol === "http:" && endpoint.hostname === "127.0.0.1" && /^\d+$/.test(endpoint.port) && endpoint.pathname === "/" && !endpoint.search && !endpoint.hash && !endpoint.username);
  for (const key of ["--from", "--to"]) assert(/^\d+\.\d+\.\d+$/.test(values[key] || ""));
  assert(/^[a-f0-9-]{36}$/.test(values["--sentinel"] || ""));
  assert.equal(require("playwright-core/package.json").version, "1.63.0");
  const { chromium } = require("playwright-core");
  const browser = await chromium.connectOverCDP(endpoint.href, { timeout: 30000 });
  let pages = [];
  const deadline = Date.now() + 30000;
  do {
    pages = browser.contexts().flatMap(context => context.pages()).filter(page => page.url() === "saminbun://app/index.html");
    if (pages.length) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  } while (Date.now() < deadline);
  assert.equal(pages.length, 1, "QA_APP_PAGE_NOT_UNIQUE"); const page = pages[0];
  await page.waitForFunction(() => Boolean(window.saminbun?.getUpdateState), undefined, { timeout: 30000 });
  if (values["--mode"] === "native-state") {
    try {
      const state = await Promise.race([page.evaluate(() => window.saminbun.getUpdateState()),
        new Promise((_, reject) => setTimeout(() => reject(new Error("STATE_TIMEOUT")), 5000))]);
      const version = value => /^\d+\.\d+\.\d+$/.test(value || "") ? value : null;
      return { phase: "native-confirmation-public-state", available: true,
        status: /^[a-z-]{1,40}$/.test(state.status || "") ? state.status : "other",
        currentVersion: version(state.currentVersion), availableVersion: version(state.availableVersion),
        updateRequired: state.updateRequired === true,
        blockedByPendingWork: typeof state.message === "string" && state.message.includes("진행 중이거나 결과를 확인하지 못한 작업"),
        cancelled: typeof state.message === "string" && state.message.includes("설치를 취소"),
        progress: Number.isFinite(state.progress) ? Math.min(100, Math.max(0, state.progress)) : null };
    } catch { return { phase: "native-confirmation-public-state", available: false }; }
  }
  const config = await page.evaluate(() => window.saminbun.getConfig());
  assert.equal(config.platform, "win32"); if (!["server-start", "server-readback"].includes(values["--mode"])) assert(!config.lastAccount, "No real/saved account may be present");
  const mode = values["--mode"], token = values["--sentinel"], from = values["--from"], to = values["--to"];
  if (mode === "server-start" || mode === "server-readback") {
    assert.equal(config.version, to);
    const fixture = new URL(values["--fixture-url"]);
    assert.equal(fixture.protocol, "https:"); assert.equal(fixture.hostname, "127.0.0.1");
    assert(/^\d+$/.test(fixture.port)); assert.equal(fixture.pathname, "/api/desktop");
    if (mode === "server-start") {
      assert(!config.lastAccount, "Server fixture requires synthetic fresh session");
      const saved = await page.evaluate(url => window.saminbun.saveServerUrl(url), fixture.href);
      assert.equal(saved.serverUrl, fixture.href);
      const login = await page.evaluate(() => window.saminbun.request({ method: "POST", path: "/v1/session", body: {
        workspaceSlug: "qa-windows", loginId: "qa-user", password: "Synthetic-QA-only-2026!" } }));
      const safePublicError = (outcome, response) => ({ phase: "synthetic-server-start-requested-via-real-installed-app", outcome,
        status: Number.isInteger(response?.status) && response.status >= 100 && response.status <= 599 ? response.status : null,
        code: /^[A-Z][A-Z0-9_]{1,63}$/.test(response?.body?.error?.code || "") ? response.body.error.code : null });
      if (login.status !== 200) return safePublicError("login-error", login);
      const jobs = await page.evaluate(() => window.saminbun.getApiOrderJobs());
      if (jobs.status !== 200) return safePublicError("initial-jobs-error", jobs);
      assert.equal(jobs.body.capabilities.serverExecution, true); assert.equal(jobs.body.jobs.length, 0);
      // Observe the actual public promise and actual GET jobs concurrently. An
      // early main/preflight error must be reported rather than swallowed.
      const started = await page.evaluate(async () => {
        const safe = response => ({ status: Number.isInteger(response?.status) && response.status >= 100 && response.status <= 599 ? response.status : null,
          code: /^[A-Z][A-Z0-9_]{1,63}$/.test(response?.body?.error?.code || "") ? response.body.error.code : null });
        const importing = window.saminbun.importApiOrders({ platform: "self", period: { start: "2026-10-01", end: "2026-10-01" }, expectedRevision: 1, executionMode: "server" })
          .then(response => ({ outcome: "import-returned-early", ...safe(response) }))
          .catch(() => ({ outcome: "import-rejected", status: null, code: null }));
        const observing = (async () => {
          const deadline = Date.now() + 7000;
          while (Date.now() < deadline) {
            const response = await window.saminbun.getApiOrderJobs();
            if (response.status !== 200) return { outcome: "jobs-read-error", ...safe(response) };
            if (response.body?.jobs?.some(job => job.status === "collecting" && job.execution?.mode === "server"))
              return { outcome: "accepted", status: 200, code: null };
            await new Promise(resolve => setTimeout(resolve, 150));
          }
          return { outcome: "start-not-observed", status: null, code: null };
        })().catch(() => ({ outcome: "jobs-read-rejected", status: null, code: null }));
        return Promise.race([importing, observing, new Promise(resolve => setTimeout(() => resolve({ outcome: "start-observation-timeout", status: null, code: null }), 8000))]);
      });
      return { phase: "synthetic-server-start-requested-via-real-installed-app", ...started };
    }
    assert.equal(config.serverUrl, fixture.href); assert.equal(config.lastAccount.loginId, "qa-user");
    const jobs = await page.evaluate(() => window.saminbun.getApiOrderJobs());
    assert.equal(jobs.status, 200); assert.equal(jobs.body.jobs.length, 1);
    const job = jobs.body.jobs[0]; assert.equal(job.jobId, values["--job-id"]);
    assert.equal(job.status, "completed"); assert.equal(job.execution.mode, "server"); assert.equal(job.receipt.revision, 2);
    assert.equal(job.receipt.result.total, 1);
    const state = await page.evaluate(() => window.saminbun.request({ method: "GET", path: "/v1/state" }));
    assert.equal(state.status, 200); assert.equal(state.body.revision, 2);
    assert.equal(state.body.workspaceId, "7d90967e-0eb1-4ed5-b78c-2cc631ce22e5");
    assert.equal(state.body.data.records.length, 1);
    assert.equal(state.body.data.records[0].orderId, "QA-WINDOWS-SERVER-ORDER-001");
    assert.equal(state.body.data.records[0].revenue, 1000);
    assert.equal(await page.evaluate(() => localStorage.getItem("saminbun.synthetic-update-smoke")), token);
    return { phase: "synthetic-server-post-close-readback", currentVersion: config.version, sameJob: true, completed: true, revision: 2, syntheticOrderCount: 1, syntheticOrderReadbackVerified: true, localStorageSentinelPreserved: true };
  }
  if (mode === "prepare") {
    assert.equal(config.version, from);
    await page.evaluate(token => localStorage.setItem("saminbun.synthetic-update-smoke", token), token);
    const initial = await page.evaluate(() => window.saminbun.getUpdateState());
    assert(!["unsupported", "unconfigured"].includes(initial.status), "INSTALLED_UPDATER_NOT_READY");
    const checked = await page.evaluate(() => window.saminbun.checkForUpdates());
    assert.equal(checked.status, "available"); assert.equal(checked.availableVersion, to);
    const downloaded = await Promise.race([page.evaluate(() => window.saminbun.downloadUpdate()),
      new Promise((_, reject) => setTimeout(() => reject(new Error("QA_DOWNLOAD_TIMEOUT")), 12 * 60_000))]);
    assert.equal(downloaded.status, "ready"); assert.equal(downloaded.availableVersion, to);
    return { phase: "download-verified-by-app", currentVersion: config.version, availableVersion: to, status: downloaded.status };
  }
  if (mode === "request-install") {
    assert.equal(config.version, from);
    const state = await page.evaluate(() => window.saminbun.getUpdateState()); assert.equal(state.status, "ready");
    // Return without resolving the native dialog. PowerShell invokes its actual
    // UIAutomation button; no mocked confirmation/IPC bypass exists here.
    await page.evaluate(() => { void window.saminbun.installUpdate().catch(() => {}); });
    return { phase: "native-confirmation-requested" };
  }
  if (mode === "cancel-check") {
    assert.equal(config.version, from);
    let state;
    for (let i = 0; i < 50; i++) {
      state = await page.evaluate(() => window.saminbun.getUpdateState());
      if (state.status === "ready" && state.message?.includes("취소")) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(state.status, "ready"); assert(state.message?.includes("취소"));
    return { phase: "native-cancel-preserved-download", status: state.status };
  }
  if (mode === "verify") {
    assert.equal(config.version, to);
    assert.equal(await page.evaluate(() => localStorage.getItem("saminbun.synthetic-update-smoke")), token);
    return { phase: "independent-post-relaunch-readback", currentVersion: config.version, localStorageSentinelPreserved: true };
  }
  throw new Error("QA_MODE_INVALID");
}
try { console.log(JSON.stringify(await run())); process.exit(0); }
catch { console.error("WINDOWS_UPDATE_QA_BRIDGE_FAILED"); process.exit(1); }
// Do not call browser.close(): disconnecting QA must not close the application.
