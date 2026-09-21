// =====================================================================
// Pushes the manually-maintained dashboard JSONs (the big v10 investigation
// dashboard + the 8 standalone quick-view ones) straight into Grafana via
// its HTTP API, into the correct folders, creating those folders first if
// they don't exist yet.
//
// Node.js fallback for apply-dashboards.sh, for machines without `jq`
// (Node 18+ only — uses the built-in fetch()).
//
// Usage:
//   set GRAFANA_URL=http://<node-ip>:30300
//   set GRAFANA_PASSWORD=<the grafana-admin secret's password>
//   node push-dashboards.js
//
// (On bash: export GRAFANA_URL=... && export GRAFANA_PASSWORD=... && node push-dashboards.js)
// =====================================================================

const fs = require("fs");

const GRAFANA_URL = process.env.GRAFANA_URL;
if (!GRAFANA_URL) {
  console.error("Set GRAFANA_URL first, e.g. http://<node-ip>:30300");
  process.exit(1);
}
if (!process.env.GRAFANA_PASSWORD) {
  console.error("Set GRAFANA_PASSWORD first (the grafana-admin secret's password)");
  process.exit(1);
}
const AUTH = "Basic " + Buffer.from(`admin:${process.env.GRAFANA_PASSWORD}`).toString("base64");

const FILES = [
  ["Exora_G360_SRE_API_Dashboard_v10.json", "APM"],
  ["standalone-dashboards/DevopsLabs_APM_API-Performance.json", "APM"],
  ["standalone-dashboards/DevopsLabs_APM_JVM-Memory.json", "APM"],
  ["standalone-dashboards/DevopsLabs_APM_Request-Investigation.json", "APM"],
  ["standalone-dashboards/DevopsLabs_APM_Service-Dependencies.json", "APM"],
  ["standalone-dashboards/DevopsLabs_Database_Connection-Pool.json", "Database"],
  ["standalone-dashboards/DevopsLabs_Infrastructure_Kubernetes-Workload.json", "Infrastructure"],
  ["standalone-dashboards/DevopsLabs_Infrastructure_Node-Health.json", "Infrastructure"],
  ["standalone-dashboards/DevopsLabs_Platform_Telemetry-Pipeline-Health.json", "Platform"],
];

async function api(path, opts = {}) {
  const res = await fetch(GRAFANA_URL + path, {
    ...opts,
    headers: { Authorization: AUTH, "Content-Type": "application/json", ...(opts.headers || {}) },
  });
  const text = await res.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { ok: res.ok, status: res.status, body };
}

const folderCache = new Map();
async function getOrCreateFolderUid(title) {
  if (folderCache.has(title)) return folderCache.get(title);
  const list = await api("/api/folders");
  if (!list.ok) throw new Error(`GET /api/folders failed: ${list.status} ${JSON.stringify(list.body)}`);
  let f = list.body.find((x) => x.title === title);
  if (!f) {
    const created = await api("/api/folders", { method: "POST", body: JSON.stringify({ title }) });
    if (!created.ok) throw new Error(`create folder '${title}' failed: ${created.status} ${JSON.stringify(created.body)}`);
    f = created.body;
    console.log(`  (created folder '${title}')`);
  }
  folderCache.set(title, f.uid);
  return f.uid;
}

(async () => {
  for (const [file, folderTitle] of FILES) {
    if (!fs.existsSync(file)) {
      console.log(`SKIP ${file} (not found)`);
      continue;
    }
    console.log(`-> ${file}  (folder: ${folderTitle})`);
    const dashboard = JSON.parse(fs.readFileSync(file, "utf8"));
    const folderUid = await getOrCreateFolderUid(folderTitle);
    const res = await api("/api/dashboards/db", {
      method: "POST",
      body: JSON.stringify({ dashboard, folderUid, overwrite: true }),
    });
    if (res.ok && res.body.status === "success") {
      console.log(`   OK: ${GRAFANA_URL}${res.body.url}`);
    } else {
      console.log(`   FAILED (${res.status}): ${JSON.stringify(res.body)}`);
    }
  }
})();
