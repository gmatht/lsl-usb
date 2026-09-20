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

4. Deploy:
   ```bash
   wrangler deploy
   ```
   Note the worker URL (e.g. `https://lsl-usb-reports.YOUR_SUBDOMAIN.workers.dev`).

5. Update `src/telemetry.rs` in the lslsetup repo:
   ```rust
   const WORKER_URL: &str = "https://lsl-usb-reports.YOUR_SUBDOMAIN.workers.dev/report";
   ```

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

The token (`lsl-usb-v1`) is hard-coded in both the worker and the binary. It
is not secret-grade security, but it stops drive-by spam.
