# lsl-usb Cloudflare Worker

Anonymous hardware-compatibility report collector. Receives POSTed JSON
from lslsetup and stores it in a Cloudflare D1 SQLite database.

## Setup

1. Install Wrangler and authenticate:
   ```bash
   npm install -g wrangler
   wrangler login
   ```

2. Create the D1 database:
   ```bash
   wrangler d1 create lsl-usb-reports
   ```
   Copy the printed `database_id` into `wrangler.toml`.

3. Push the schema:
   ```bash
   wrangler d1 execute lsl-usb-reports --local --file=./schema.sql
   wrangler d1 execute lsl-usb-reports --remote --file=./schema.sql
   ```

4. Create the partition-layout KV namespace (F2FS safety net):
   ```bash
   wrangler kv namespace create lsl-usb-layouts
   ```
   Copy the printed `id` into `wrangler.toml` under `[[kv_namespaces]]`
   (binding `PARTITION_KV`). Without it the `/kv` routes answer 500 and
   Past Layouts shows nothing - `/report` keeps working regardless.

5. Deploy:
   ```bash
   wrangler deploy
   ```
   Note the worker URL (e.g. `https://lsl-usb-reports.YOUR_SUBDOMAIN.workers.dev`).

6. Update `src/telemetry.rs` in the lslsetup repo:
   ```rust
   const WORKER_URL: &str = "https://lsl-usb-reports.YOUR_SUBDOMAIN.workers.dev/report";
   ```
   (`KV_URL` in the same file already points at `/kv` on that host.)

## Querying reports

```bash
# List latest 100 reports
curl "https://lsl-usb-reports.YOUR_SUBDOMAIN.workers.dev/reports"

# Pagination
curl "https://lsl-usb-reports.YOUR_SUBDOMAIN.workers.dev/reports?limit=50&offset=100"
```

## Architecture

- `POST /report` — accepts JSON from lslsetup, validates `X-Lsl-Token`, inserts into D1
- `GET /reports` — lists reports (no auth; this is public crowd-sourced data)
- `GET /health` — health check
- `PUT /kv` — partition-layout value write (needs `X-Lsl-Token` + `X-Key`
  headers, body = value bytes <=1 KB, keys expire after 180 days)
- `GET /kv?key=<key>` — partition-layout value read (public, raw bytes)

The token (`lsl-usb-v1`) is hard-coded in both the worker and the binary. It
is not secret-grade security, but it stops drive-by spam.
