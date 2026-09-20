CREATE TABLE IF NOT EXISTS reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  probe_id TEXT NOT NULL UNIQUE,
  boot_success INTEGER NOT NULL DEFAULT 0,
  boot_outcome TEXT,
  linux_distro TEXT,
  kernel TEXT,
  motherboard TEXT,
  cpu TEXT,
  is_uefi INTEGER NOT NULL DEFAULT 0,
  secure_boot TEXT,
  boot_method TEXT,
  wifi_adapter TEXT,
  wifi_worked INTEGER NOT NULL DEFAULT 0,
  ethernet_adapter TEXT,
  ethernet_worked INTEGER NOT NULL DEFAULT 0,
  gpu TEXT,
  gpu_worked INTEGER NOT NULL DEFAULT 0,
  audio_worked INTEGER NOT NULL DEFAULT 0,
  firstboot_ok INTEGER NOT NULL DEFAULT 0,
  network_ok INTEGER NOT NULL DEFAULT 0,
  shutdown_clean INTEGER NOT NULL DEFAULT 0,
  lslsetup_version TEXT,
  windows_version TEXT,
  raw_json TEXT,
  upload_count INTEGER NOT NULL DEFAULT 1,
  first_uploaded_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_uploaded_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_reports_probe ON reports(probe_id);
CREATE INDEX IF NOT EXISTS idx_reports_created ON reports(first_uploaded_at);
