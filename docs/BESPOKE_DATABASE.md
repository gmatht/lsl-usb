# Boot Result Telemetry & Bespoke Database

## Problem

`lslsetup.exe` offers three ways to reboot into a USB stick:

1. **One-time USB boot** (`bcdedit /set {fwbootmgr} bootsequence`) — sets a BCD entry
2. **Advanced startup menu** (`shutdown /r /o`) — Windows recovery environment
3. **Firmware boot menu** (`shutdown /r /fw`) — native UEFI boot picker

Not all PCs honor the BCD `bootsequence` override. Some firmwares (notably HP, Dell, and Lenovo laptops) silently ignore it and boot Windows anyway. There is **no canonical public compatibility list** because vendors do not document this behavior.

We need to **crowdsource** a firmware-compatibility database by:
- Recording which boot method the user chose
- Detecting whether Linux actually booted
- Collecting motherboard, CPU, and firmware metadata
- Letting users upload results with one click

## Recommended Architecture

```
┌─────────────┐      POST JSON (anon)      ┌─────────────┐
│ lslsetup.exe │ ─────────────────────────► │  Supabase   │  ← live database
│  (Win9x→11)  │   (no API key in binary)   │  (Postgres) │
└─────────────┘                            └──────┬──────┘
       │                                          │
       │ fallback on failure                      │ Table Editor
       ▼                                   ┌──────▼──────┐
┌─────────────┐                            │ Public link │  ← human-readable
│ GitHub Issue│                            │ (read-only) │
│  (pre-fill) │                            └─────────────┘
└─────────────┘
```

1. **Primary**: `POST` JSON to **Supabase** (Postgres) automatically — queryable, durable, no quota anxiety
2. **If POST fails**: Open pre-filled **GitHub issue URL** — no data loss, no auth needed
3. **View**: Share the Supabase **Table Editor** as a public read-only link — looks like a spreadsheet, always current

---

## Why Supabase?

| Dimension | GitHub Issues | keyval.org | Google Sheets | **Supabase** | DynamoDB |
|-----------|--------------|------------|---------------|--------------|----------|
| **Setup effort** | Zero | Zero | 10 min | **10 min** | ~1 hour |
| **Running cost** | Free | Free | Free | **Free** | ~$0 |
| **Quota anxiety** | None | None | **100 req/100s** | **None** | None |
| **Query / dashboard** | Painful (grep) | GET by key only | Spreadsheet | **Full SQL** | Full query |
| **Spreadsheet UI** | No | No | Native | **Table Editor** | No |
| **Real-time** | N/A | Yes | No | **Yes** | Yes |
| **Backup / export** | N/A | Manual | Manual | **pg_dump, CLI, UI** | Point-in-time |
| **Auth for binary** | None | None | OAuth | **None** (RLS) | API key |
| **Credential leak risk** | None | None | High | **None** | Low |
| **Reliability** | High | Hobby | High | **High** | High |
| **Vendor lock-in** | GitHub | Simple HTTP | Google | **Postgres (open)** | AWS |

Supabase is the sweet spot: **no API key in the binary** (RLS allows anonymous inserts), **no quota limits**, **full SQL querying**, and a **built-in spreadsheet-like Table Editor** that you can share publicly.

---

## Supabase Setup

### 1. Create Project

1. [supabase.com](https://supabase.com) → Sign up (GitHub auth)
2. **New project** → Name: `lsl-usb`
3. Choose region closest to your users (e.g. `us-east-1`)
4. Wait ~2 minutes for provisioning
5. Note your **Project URL** and **anon public key**:
   ```
   https://<PROJECT_REF>.supabase.co
   eyJhbGciOiJIUzI1NiIs...  ← anon key, safe to embed
   ```

### 2. Create Table

SQL Editor → New query → Run:

```sql
CREATE TABLE boot_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    boot_success BOOLEAN NOT NULL,
    boot_method TEXT NOT NULL CHECK (boot_method IN ('usb-one-time','advanced-menu','firmware-menu')),
    lslsetup_version TEXT,
    windows_version TEXT,
    is_uefi BOOLEAN,
    secure_boot TEXT,
    motherboard_manufacturer TEXT,
    motherboard_product TEXT,
    cpu TEXT,
    linux_distro TEXT,
    kernel TEXT,
    firstboot_ok BOOLEAN,
    network_ok BOOLEAN
);

-- Index for fast filtering
CREATE INDEX idx_boot_reports_board ON boot_reports(motherboard_manufacturer, boot_success);
CREATE INDEX idx_boot_reports_method ON boot_reports(boot_method, boot_success);
CREATE INDEX idx_boot_reports_time ON boot_reports(created_at);
```

### 3. Enable Anonymous Writes (RLS)

Supabase uses **Row Level Security** (RLS). By default, no one can write. Allow anonymous inserts:

```sql
ALTER TABLE boot_reports ENABLE ROW LEVEL SECURITY;

-- Allow anyone to insert (no auth needed)
CREATE POLICY "Allow anonymous inserts" ON boot_reports
    FOR INSERT TO anon WITH CHECK (true);

-- Allow anyone to read (public dashboard)
CREATE POLICY "Allow anonymous reads" ON boot_reports
    FOR SELECT TO anon USING (true);

-- Deny updates/deletes (append-only telemetry)
```

**Security note:** The `anon` key is safe to embed because RLS prevents reading sensitive data (there is none) and the policy only allows `INSERT`/`SELECT`. Even if someone scrapes the key from the binary, they cannot `UPDATE`, `DELETE`, or access other tables.

### 4. Test with curl

```bash
curl -X POST 'https://<PROJECT_REF>.supabase.co/rest/v1/boot_reports' \
  -H "apikey: <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d '{
    "boot_success": true,
    "boot_method": "usb-one-time",
    "motherboard_manufacturer": "Dell Inc.",
    "motherboard_product": "XPS 13 9310",
    "linux_distro": "Linux Mint 22.1"
  }'
```

### 5. Share the Table Editor

1. Supabase Dashboard → **Table Editor** → `boot_reports`
2. Copy the URL (it includes your project ref)
3. Send to stakeholders — they see a live, sortable, filterable table

---

## What `lslsetup.exe` Needs

### 1. Add HTTP POST to `net.rs`

WinHTTP already supports POST via `send_request` with a body buffer. Add a `post_json(url, body, headers)` function (~40 lines) next to the existing `get()`.

### 2. Add `telemetry_post()` in `telemetry.rs`

```rust
const SUPABASE_URL: &str = option_env!("SUPABASE_URL").unwrap_or("");
const SUPABASE_ANON_KEY: &str = option_env!("SUPABASE_ANON_KEY").unwrap_or("");

pub fn post_report(report: &BootReport) -> Result<(), String> {
    if SUPABASE_URL.is_empty() || SUPABASE_ANON_KEY.is_empty() {
        return Err("Supabase not configured".into());
    }
    let url = format!("{}/rest/v1/boot_reports", SUPABASE_URL);
    let json = format!(
        r#"{{
            "boot_success":{},
            "boot_method":"{}",
            "lslsetup_version":"{}",
            "windows_version":"{}",
            "is_uefi":{},
            "secure_boot":"{}",
            "motherboard_manufacturer":"{}",
            "motherboard_product":"{}",
            "cpu":"{}",
            "linux_distro":"{}",
            "kernel":"{}",
            "firstboot_ok":{},
            "network_ok":{}
        }}"#,
        report.boot_success,
        report.probe.boot_method,
        report.probe.lslsetup_version,
        report.probe.windows_version,
        report.probe.is_uefi,
        report.probe.secure_boot,
        report.probe.motherboard_manufacturer,
        report.probe.motherboard_product,
        report.probe.cpu,
        report.linux_distro,
        report.kernel,
        report.firstboot_ok,
        report.network_ok,
    );
    let mut headers: Vec<(&str, &str)> = Vec::new();
    headers.push(("apikey", SUPABASE_ANON_KEY));
    headers.push(("Content-Type", "application/json"));
    headers.push(("Prefer", "return=minimal"));
    let res = crate::net::post_json_with_headers(&url, &json, &headers, crate::net::user_agent())?;
    if res.status == 201 {
        Ok(())
    } else {
        Err(format!("Supabase rejected: HTTP {}", res.status))
    }
}
```

### 3. Configuration

Compile with environment variables:

```bash
set SUPABASE_URL=https://<PROJECT_REF>.supabase.co
set SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIs...
cargo build --release
```

Or read from Windows Registry at runtime for per-fork configuration without recompiling.

### 4. Fallback on failure

```rust
match telemetry::post_report(&report) {
    Ok(()) => out::info("Report uploaded to Supabase."),
    Err(e) => {
        out::warn(&format!("Supabase upload failed ({}). Falling back to GitHub issue.", e));
        let url = telemetry::upload_url(&report);
        let _ = sys::spawn("explorer", &[url]);
    }
}
```

---

## Backing Up Supabase

Supabase runs on Postgres. You have multiple backup options, from one-click to fully automated.

### Option 1: Supabase Dashboard Export (easiest)

1. Dashboard → **Database** → **Backups**
2. **Trigger backup now** (free tier: daily automated backups retained for 7 days)
3. To export as SQL: **Database** → **Extensions** → Enable `pg_dump` via SQL Editor

### Option 2: pg_dump CLI (recommended for automation)

Install the Supabase CLI or any `pg_dump` client:

```bash
# Install Supabase CLI
npm install -g supabase

# Link to your project
supabase link --project-ref <PROJECT_REF>

# Dump to file
supabase db dump -f boot_reports_backup.sql

# Or use pg_dump directly (get the connection string from Dashboard → Settings → Database)
pg_dump \
  -h db.<PROJECT_REF>.supabase.co \
  -p 5432 \
  -d postgres \
  -U postgres \
  --data-only \
  --table=boot_reports \
  -f boot_reports_$(date +%F).sql
```

### Option 3: Scheduled GitHub Actions Backup (fully automated)

Create `.github/workflows/backup-supabase.yml`:

```yaml
name: Backup Supabase Boot Reports

on:
  schedule:
    - cron: '0 3 * * *'  # nightly at 3 AM UTC
  workflow_dispatch:       # manual trigger

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Dump boot_reports table
        env:
          SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL }}
        run: |
          sudo apt-get update && sudo apt-get install -y postgresql-client
          pg_dump "$SUPABASE_DB_URL" \
            --data-only \
            --table=boot_reports \
            --inserts \
            > backups/boot_reports_$(date +%F).sql

      - name: Commit backup
        run: |
          git config user.name "github-actions"
          git config user.email "github-actions@github.com"
          git add backups/
          git diff --cached --quiet || git commit -m "backup: boot_reports $(date +%F)"
          git push
```

Add `SUPABASE_DB_URL` as a GitHub secret (from Dashboard → Settings → Database → Connection string).

**Result:** Your repo gets a `backups/` directory with dated SQL dumps, giving you:
- **Git history** of every report
- **Offline access** to raw data
- **Zero vendor lock-in** (plain `INSERT` statements)

### Option 4: Export to CSV (for stakeholders)

```sql
-- In Supabase SQL Editor
COPY (SELECT * FROM boot_reports ORDER BY created_at DESC)
TO '/tmp/boot_reports.csv' WITH CSV HEADER;
```

Or query via the REST API and pipe to a CSV tool:

```bash
curl -s "https://<PROJECT_REF>.supabase.co/rest/v1/boot_reports?select=*&order=created_at.desc" \
  -H "apikey: <ANON_KEY>" \
  | jq -r '.[] | [\(.created_at),\(.boot_success),\(.motherboard_manufacturer),\(.motherboard_product),\(.boot_method)] | @csv'
```

---

## Alternative: DynamoDB + API Gateway (for scale)

If you outgrow Supabase free tier (500 MB, 2 GB egress/month) or prefer AWS, use the DynamoDB architecture documented below. It requires more setup but has no hard data-size limits.

### Why not direct DynamoDB?

DynamoDB's REST API requires **AWS Signature Version 4** — HMAC-SHA256 signing over the request, timestamp, region, and your **secret access key**. Embedding a secret key in a distributed Windows binary is a credential-leak risk.

### Architecture

```
lslsetup.exe ──POST JSON──► API Gateway ──► Lambda ──► DynamoDB
```

### Schema

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | String (PK) | UUID v4 |
| `timestamp` | String | ISO-8601 |
| `boot_success` | Boolean | |
| `boot_method` | String | `usb-one-time`, `advanced-menu`, `firmware-menu` |
| `lslsetup_version` | String | |
| `windows_version` | String | |
| `is_uefi` | Boolean | |
| `secure_boot` | String | |
| `motherboard_manufacturer` | String | |
| `motherboard_product` | String | |
| `cpu` | String | |
| `linux_distro` | String | |
| `kernel` | String | |
| `firstboot_ok` | Boolean | |
| `network_ok` | Boolean | |

### Lambda Handler

See earlier sections in this document for the full Python handler and Terraform setup.

---

## Recommended Migration Path

| Phase | Action |
|-------|--------|
| **Now** | Ship GitHub Issues telemetry (already implemented). |
| **Want live data** | Create Supabase project (10 min), add `SUPABASE_URL` + `SUPABASE_ANON_KEY` at compile time. |
| **Supabase full** | Export to CSV, import into self-hosted Postgres, or upgrade to Supabase Pro ($25/mo). |
| **AWS shop / huge scale** | Migrate to DynamoDB + API Gateway. Schema is identical. |
| **Long-term** | Auto-generate `COMPATIBILITY.md` from nightly SQL dumps: "Dell XPS 13 9310 — BCD USB works on firmware 2.8.0, fails on 2.9.0." |

---

## Security Notes

- **Never embed AWS secret keys** in the binary. Supabase `anon` key is safe because RLS restricts what it can do.
- **No PII**: The schema intentionally avoids serial numbers, MAC addresses, Windows usernames, or IP addresses.
- **CORS**: Supabase REST API has CORS enabled by default. No extra configuration needed.
- **Rate limiting**: Supabase free tier has soft limits. If you exceed 2 GB egress, upgrade or cache aggressively.
- **Append-only**: The RLS policy denies `UPDATE` and `DELETE`. Even a leaked key cannot tamper with historical data.

---

## Related Files in This Repo

- `rust9x/lslsetup/src/telemetry.rs` — Windows-side probe writing, result scanning, upload URL generation
- `rust9x/lslsetup/src/net.rs` — WinHTTP GET support (POST/PUT extension needed)
- `rust9x/lslsetup/src/boot.rs` — Boot-method selection and pre-flight checks
- `onboot.sh` — Linux-side result writing back to the USB stick
