// Cloudflare Worker for lsl-usb hardware compatibility reports
// Stores POSTed JSON reports in D1 SQLite.
//
// Setup:
//   1. wrangler d1 create lsl-usb-reports
//   2. Copy the database_id into wrangler.toml
//   3. wrangler d1 execute lsl-usb-reports --local --file=./schema.sql
//   4. wrangler deploy

const TOKEN = "lsl-usb-v1";  // Hard-coded simple token; not secret-grade,
                               // but enough to stop drive-by spam.

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, X-Lsl-Token",
        },
      });
    }

    if (path === "/report" && request.method === "POST") {
      return handleReport(request, env);
    }

    if (path === "/reports" && request.method === "GET") {
      return handleList(request, env);
    }

    if (path === "/health") {
      return jsonResponse({ ok: true });
    }

    return jsonResponse({ error: "Not found" }, 404);
  },
};

async function handleReport(request, env) {
  // Simple token check
  const token = request.headers.get("X-Lsl-Token") || "";
  if (token !== TOKEN) {
    return jsonResponse({ error: "Invalid token" }, 403);
  }

  let body;
  try {
    body = await request.json();
  } catch (e) {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const db = env.DB;
  if (!db) {
    return jsonResponse({ error: "Database not configured" }, 500);
  }

  // Extract fields with safe defaults
  const probeId = String(body.probe_id || "").slice(0, 64);
  const bootSuccess = body.boot_success ? 1 : 0;
  const bootOutcome = String(body.boot_outcome || "").slice(0, 256);
  const linuxDistro = String(body.linux_distro || "").slice(0, 128);
  const kernel = String(body.kernel || "").slice(0, 64);
  const motherboard = String(body.motherboard || "").slice(0, 256);
  const cpu = String(body.cpu || "").slice(0, 256);
  const isUefi = body.is_uefi ? 1 : 0;
  const secureBoot = String(body.secure_boot || "").slice(0, 32);
  const bootMethod = String(body.boot_method || "").slice(0, 32);
  const wifiAdapter = String(body.wifi_adapter || "").slice(0, 256);
  const wifiWorked = body.wifi_worked ? 1 : 0;
  const ethernetAdapter = String(body.ethernet_adapter || "").slice(0, 256);
  const ethernetWorked = body.ethernet_worked ? 1 : 0;
  const gpu = String(body.gpu || "").slice(0, 256);
  const gpuWorked = body.gpu_worked ? 1 : 0;
  const audioWorked = body.audio_worked ? 1 : 0;
  const firstbootOk = body.firstboot_ok ? 1 : 0;
  const networkOk = body.network_ok ? 1 : 0;
  const shutdownClean = body.shutdown_clean ? 1 : 0;
  const lslsetupVersion = String(body.lslsetup_version || "").slice(0, 32);
  const windowsVersion = String(body.windows_version || "").slice(0, 64);
  const raw = JSON.stringify(body).slice(0, 65535);

  try {
    await db.prepare(
      `INSERT INTO reports (
        probe_id, boot_success, boot_outcome, linux_distro, kernel,
        motherboard, cpu, is_uefi, secure_boot, boot_method,
        wifi_adapter, wifi_worked, ethernet_adapter, ethernet_worked,
        gpu, gpu_worked, audio_worked, firstboot_ok, network_ok, shutdown_clean,
        lslsetup_version, windows_version, raw_json,
        first_uploaded_at, last_uploaded_at, upload_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'), 1)
      ON CONFLICT(probe_id) DO UPDATE SET
        boot_success = excluded.boot_success,
        boot_outcome = excluded.boot_outcome,
        linux_distro = excluded.linux_distro,
        kernel = excluded.kernel,
        motherboard = excluded.motherboard,
        cpu = excluded.cpu,
        is_uefi = excluded.is_uefi,
        secure_boot = excluded.secure_boot,
        boot_method = excluded.boot_method,
        wifi_adapter = excluded.wifi_adapter,
        wifi_worked = excluded.wifi_worked,
        ethernet_adapter = excluded.ethernet_adapter,
        ethernet_worked = excluded.ethernet_worked,
        gpu = excluded.gpu,
        gpu_worked = excluded.gpu_worked,
        audio_worked = excluded.audio_worked,
        firstboot_ok = excluded.firstboot_ok,
        network_ok = excluded.network_ok,
        shutdown_clean = excluded.shutdown_clean,
        lslsetup_version = excluded.lslsetup_version,
        windows_version = excluded.windows_version,
        raw_json = excluded.raw_json,
        last_uploaded_at = datetime('now'),
        upload_count = upload_count + 1`
    ).bind(
      probeId, bootSuccess, bootOutcome, linuxDistro, kernel,
      motherboard, cpu, isUefi, secureBoot, bootMethod,
      wifiAdapter, wifiWorked, ethernetAdapter, ethernetWorked,
      gpu, gpuWorked, audioWorked, firstbootOk, networkOk, shutdownClean,
      lslsetupVersion, windowsVersion, raw
    ).run();

    return jsonResponse({ ok: true, id: probeId });
  } catch (e) {
    return jsonResponse({ error: "Database error: " + e.message }, 500);
  }
}

async function handleList(request, env) {
  const db = env.DB;
  if (!db) {
    return jsonResponse({ error: "Database not configured" }, 500);
  }

  const url = new URL(request.url);
  const limit = Math.min(parseInt(url.searchParams.get("limit") || "100", 10), 1000);
  const offset = Math.max(parseInt(url.searchParams.get("offset") || "0", 10), 0);

  try {
    const { results } = await db.prepare(
      `SELECT * FROM reports ORDER BY last_uploaded_at DESC LIMIT ? OFFSET ?`
    ).bind(limit, offset).all();

    const { count } = await db.prepare(
      `SELECT COUNT(*) as count FROM reports`
    ).first();

    return jsonResponse({
      total: count,
      limit,
      offset,
      results,
    });
  } catch (e) {
    return jsonResponse({ error: "Database error: " + e.message }, 500);
  }
}

function jsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
