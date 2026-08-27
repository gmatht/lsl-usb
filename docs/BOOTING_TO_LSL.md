# Summary: Booting Linux USB from Windows

Fast Startup (hybrid shutdown) saves kernel state to `hiberfil.sys` on **shutdown only**, not restart. This matters because:

| Method | Typical command | Fast Startup involved? | Effect |
|--------|-----------------|----------------------|--------|
| **bcdedit bootsequence** | `shutdown /r /t 0` | No — `/r` = restart | Works normally |
| **bcdedit bootsequence** | `shutdown /s /t 0` then power on | **Yes** — hibernation resume | May fail — bootsequence is "next boot only" and resume-from-hibernate might consume/skip it |
| **shutdown /r /o** | `shutdown /r /o /t 0` | No — `/r` = restart | Works normally |
| **F12** | `shutdown /s /t 0` then power on | **Yes** — hibernation resume | Usually works — firmware shows boot menu *before* handing off to Windows resume, but some firmware implementations are finicky |
| **F12** | `shutdown /r /t 0` | No | Works normally |

---

## The Problem Case

If someone does:
```
bcdedit /set {bootmgr} bootsequence {linux-usb-guid} /addfirst
shutdown /s /t 0
<power on>
```

The firmware may see the hibernation marker, hand off to Windows to resume, and the bootsequence setting either:
- Gets consumed but Windows just resumes anyway
- Gets skipped entirely
- Works on some firmware but not others

---

## How to Disable Fast Startup

**Permanently:**
```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
```

**Or via PowerShell (requires admin):**
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0
```

**Or GUI:** Control Panel → Power Options → Choose what the power buttons do → uncheck "Turn on fast startup"

---

## Practical Advice

- Always use **`/r`** (restart) when using `bcdedit bootsequence` — avoids the issue entirely
- If you must use `/s` (shutdown), disable Fast Startup first or use F12 instead
- `shutdown /r /o` is inherently safe since it forces a restart


### Three Methods Compared

| | bcdedit bootsequence | shutdown /r /o | F12 |
|---|---|---|---|
| **How it works** | Creates BCD entry → sets one-time boot | Restarts to Windows "Use a device" menu | Firmware boot menu at startup |
| **Automated?** | Yes | No (needs human) | No (needs human) |
| **Secure Boot** | Same check as all methods | Same check as all methods | Same check as all methods |
| **EFI path needed?** | Yes, must know exact `.efi` location | No | No |
| **Persistent state?** | Yes, needs cleanup | No | No |
| **Fast Startup risk** | Only if using `/s` (shutdown) | None (uses `/r`) | Possible if using `/s` |


### NOTES

1. **Secure Boot** — Not bypassed by any method. It's a firmware-level check that applies regardless of how you select the boot device.

2. **Drive letters** — The BCD entry GUID is stable; the risk is the `device` field *inside* the entry if set by drive letter. Fix: use volume GUIDs (`partition=\??\Volume{...}`) instead.

3. **Fast Startup** — Only applies to `shutdown /s`, not `shutdown /r`. Using restart (`/r`) avoids all Fast Startup issues.

### Practical Recommendations

- **Need it scripted** → `bcdedit` with `/r` (restart), use volume GUIDs for device
- **Need it reliable** → `shutdown /r /o /t 0` → click "Use a device"
- **Most reliable overall** → F12 at boot, bypasses Windows entirely
- **Must use `/s` (shutdown)** → Disable Fast Startup first, or avoid bcdedit
