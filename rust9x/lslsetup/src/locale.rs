//! Minimal UI localization: detect the Windows display language and
//! translate the boot-choice UX (the highest-stakes surface - a user who
//! cannot read the boot dialog cannot boot). English fallback everywhere.
//!
//! Deliberately NOT translating harvest-sensitive control text (write-mode
//! radios, target radios, BIOS/UEFI labels parsed by write_mode_from_label,
//! checked_target_letter, iso_row_path, ...). Those stay English until the
//! logic is decoupled from display text; translating them would silently
//! break the install. Console/log lines also stay English (diagnostics).
//!
//! Convention: msgid-style keys - the English source IS the key, `{K}` /
//! `{E}` are format placeholders substituted by the caller AFTER
//! translation. Unknown keys and unknown languages pass through unchanged.

use crate::sys;

/// Serializes tests that mutate LSL_LANG (process-global) so parallel test
/// threads can't observe each other's language. Hold it in any test that
/// sets the variable (poison-tolerant: a panicking holder must not cascade).
#[cfg(test)]
pub(crate) static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// ISO-639 primary language of the Windows UI ("de", "th", "en", ...).
/// English default (also on Win9x / when the API is missing).
/// LSL_LANG=th|de|en overrides the detection (for trying translations
/// without reinstalling the Windows display language); anything else
/// falls through to the system language.
pub fn ui_lang() -> &'static str {
    if let Ok(ov) = std::env::var("LSL_LANG") {
        match ov.to_ascii_lowercase().as_str() {
            "th" => return "th",
            "de" => return "de",
            "en" => return "en",
            _ => {}
        }
    }
    if sys::is_9x() {
        return "en";
    }
    type FnT = unsafe extern "system" fn() -> u16;
    match sys::proc_from_module::<FnT>("kernel32.dll", "GetUserDefaultUILanguage") {
        Some(f) => {
            let id = unsafe { f() };
            match id & 0x3FF {
                0x07 => "de",
                0x1E => "th", // Thai
                _ => "en",
            }
        }
        None => "en",
    }
}

/// Translate `msgid` for `lang` ("de", "th" supported). Pure: unit-tested.
pub fn tr_for(lang: &str, msgid: &str) -> String {
    if lang == "th" {
        return tr_th(msgid);
    }
    if lang != "de" {
        return msgid.to_string();
    }
    match msgid {
        "lsl-usb - Boot from USB" => "lsl-usb - Von USB booten".into(),
        "Boot USB now (set one-time boot entry)" => {
            "Jetzt von USB booten (einmaliger Boot-Eintrag)".into()
        }
        "Advanced boot menu (shutdown /r /o)" => {
            "Erweitertes Startmenü (shutdown /r /o)".into()
        }
        "Firmware boot menu (shutdown /r /fw)" => {
            "Firmware-Bootmenü (shutdown /r /fw)".into()
        }
        "Don't reboot" => "Nicht neu starten".into(),
        "Manual boot menu: press {K} during POST." => {
            "Manuelles Bootmenü: {K} während des POST drücken.".into()
        }
        "Manual boot-menu key unknown - watch for the prompt during POST (often F12, F9, F8, or Esc)." => {
            "Taste für das Bootmenü unbekannt - auf die Meldung beim POST achten (oft F12, F9, F8 oder Esc).".into()
        }
        "Caution: many HP, Dell, and Lenovo firmwares ignore the Windows boot override.\nIf the PC boots back into Windows, use 'Firmware boot menu' instead." => {
            "Achtung: Viele HP-, Dell- und Lenovo-Firmwares ignorieren die Windows-Bootvorgabe.\nFalls der PC wieder in Windows startet, stattdessen „Firmware-Bootmenü“ wählen.".into()
        }
        "Reboot to USB now" => "Jetzt von USB neu starten".into(),
        "Advanced startup menu" => "Erweitertes Startmenü".into(),
        "Firmware boot menu" => "Firmware-Bootmenü".into(),
        "lslsetup - boot the USB" => "lslsetup - USB booten".into(),
        "Keys 1-4 choose directly (Enter = first button, Esc = Don't reboot)." => {
            "Tasten 1-4 wählen direkt (Enter = erste Schaltfläche, Esc = Nicht neu starten).".into()
        }
        "The USB stick is ready. Reboot into it now, or later by hand.\n" => {
            "Der USB-Stick ist bereit. Jetzt davon neu starten oder später manuell.\n".into()
        }
        "One-time USB boot is not available on this PC. The Firmware Boot Menu option is reliable." => {
            "Einmaliger USB-Boot ist auf diesem PC nicht verfügbar. Die Option „Firmware-Bootmenü“ ist zuverlässig.".into()
        }
        "USB Boot Failed" => "USB-Boot fehlgeschlagen".into(),
        "Could not set one-time USB boot:\n\n{E}\n\nPlease try the Firmware Boot Menu option instead." => {
            "Einmaliger USB-Boot konnte nicht eingerichtet werden:\n\n{E}\n\nBitte stattdessen die Option „Firmware-Bootmenü“ wählen.".into()
        }
        "This PC appears to use Legacy BIOS, not UEFI.\nOne-time USB boot will not work.\nPlease use the Firmware Boot Menu or press {K} during POST." => {
            "Dieser PC scheint Legacy-BIOS statt UEFI zu verwenden.\nEinmaliger USB-Boot funktioniert nicht.\nBitte das Firmware-Bootmenü verwenden oder {K} während des POST drücken.".into()
        }
        "One-time USB boot requires Windows Vista or later." => {
            "Einmaliger USB-Boot erfordert Windows Vista oder neuer.".into()
        }
        "bcdedit.exe not found ({P}).\nThis usually happens on 32-bit Windows running on 64-bit hardware." => {
            "bcdedit.exe nicht gefunden ({P}).\nDas passiert meist bei 32-Bit-Windows auf 64-Bit-Hardware.".into()
        }
        "bcdedit failed (exit code {C})." => {
            "bcdedit ist fehlgeschlagen (Exit-Code {C}).".into()
        }
        "A USB boot entry was found, but many HP, Dell, and Lenovo firmwares ignore the Windows override and boot back into Windows.\nIf that happens, use 'Firmware Boot Menu' instead — it works on every PC." => {
            "Ein USB-Boot-Eintrag wurde gefunden, aber viele HP-, Dell- und Lenovo-Firmwares ignorieren die Windows-Vorgabe und starten wieder Windows.\nFalls das passiert, „Firmware-Bootmenü“ verwenden — das funktioniert auf jedem PC.".into()
        }
        "No USB boot entry detected in firmware.\nThe stick may not be plugged in, or this firmware does not expose USB devices to Windows.\nMany HP, Dell, and Lenovo laptops behave this way.\nUse the 'Firmware Boot Menu' option instead — it works on every PC." => {
            "Kein USB-Boot-Eintrag in der Firmware gefunden.\nDer Stick ist möglicherweise nicht eingesteckt, oder diese Firmware zeigt Windows keine USB-Geräte.\nViele HP-, Dell- und Lenovo-Laptops verhalten sich so.\nStattdessen die Option „Firmware-Bootmenü“ verwenden — sie funktioniert auf jedem PC.".into()
        }
        "Firmware entries found, but none look like a USB device:\n" => {
            "Firmware-Einträge gefunden, aber keiner sieht nach einem USB-Gerät aus:\n".into()
        }
        "\nIf your USB stick is plugged in, the firmware may be hiding it from Windows.\nUse the 'Firmware Boot Menu' option instead — it is reliable on every PC." => {
            "\nFalls der USB-Stick eingesteckt ist, verbirgt die Firmware ihn möglicherweise vor Windows.\nDie Option „Firmware-Bootmenü“ verwenden — sie ist auf jedem PC zuverlässig.".into()
        }
        _ => msgid.to_string(),
    }
}

/// Thai translations for every boot-USB msgid (same keys as the German
/// table above; `{K}`/`{P}`/`{C}`/`{E}` placeholders are substituted by
/// the caller AFTER translation, and firmware-supplied names are never
/// translated). Unknown keys fall through to English.
fn tr_th(msgid: &str) -> String {
    match msgid {
        "lsl-usb - Boot from USB" => "lsl-usb - บูตจาก USB".into(),
        "Boot USB now (set one-time boot entry)" => {
            "บูต USB เดี๋ยวนี้ (ตั้งค่ารายการบูตครั้งเดียว)".into()
        }
        "Advanced boot menu (shutdown /r /o)" => {
            "เมนูบูตขั้นสูง (shutdown /r /o)".into()
        }
        "Firmware boot menu (shutdown /r /fw)" => {
            "เมนูบูตเฟิร์มแวร์ (shutdown /r /fw)".into()
        }
        "Don't reboot" => "ไม่ต้องรีบูต".into(),
        "Manual boot menu: press {K} during POST." => {
            "เมนูบูตแบบเลือกเอง: กด {K} ระหว่าง POST".into()
        }
        "Manual boot-menu key unknown - watch for the prompt during POST (often F12, F9, F8, or Esc)." => {
            "ไม่ทราบปุ่มเมนูบูต - โปรดสังเกตข้อความระหว่าง POST (มักเป็น F12, F9, F8 หรือ Esc)".into()
        }
        "Caution: many HP, Dell, and Lenovo firmwares ignore the Windows boot override.\nIf the PC boots back into Windows, use 'Firmware boot menu' instead." => {
            "ข้อควรระวัง: เฟิร์มแวร์ของ HP, Dell และ Lenovo หลายรุ่นไม่สนใจคำสั่งบูตของ Windows\nหากเครื่องบูตกลับเข้า Windows ให้ใช้ 'เมนูบูตเฟิร์มแวร์' แทน".into()
        }
        "Reboot to USB now" => "รีบูตเข้า USB เดี๋ยวนี้".into(),
        "Advanced startup menu" => "เมนูเริ่มต้นขั้นสูง".into(),
        "Firmware boot menu" => "เมนูบูตเฟิร์มแวร์".into(),
        "lslsetup - boot the USB" => "lslsetup - บูต USB".into(),
        "Keys 1-4 choose directly (Enter = first button, Esc = Don't reboot)." => {
            "กดปุ่ม 1-4 เพื่อเลือกโดยตรง (Enter = ปุ่มแรก, Esc = ไม่ต้องรีบูต)".into()
        }
        "The USB stick is ready. Reboot into it now, or later by hand.\n" => {
            "แฟลชไดรฟ์ USB พร้อมแล้ว รีบูตเข้าใช้งานเดี๋ยวนี้ หรือทำเองภายหลัง\n".into()
        }
        "One-time USB boot is not available on this PC. The Firmware Boot Menu option is reliable." => {
            "เครื่องนี้ไม่รองรับการบูต USB ครั้งเดียว ตัวเลือกเมนูบูตเฟิร์มแวร์เชื่อถือได้".into()
        }
        "USB Boot Failed" => "บูต USB ไม่สำเร็จ".into(),
        "Could not set one-time USB boot:\n\n{E}\n\nPlease try the Firmware Boot Menu option instead." => {
            "ตั้งค่าการบูต USB ครั้งเดียวไม่ได้:\n\n{E}\n\nโปรดลองใช้ตัวเลือกเมนูบูตเฟิร์มแวร์แทน".into()
        }
        "This PC appears to use Legacy BIOS, not UEFI.\nOne-time USB boot will not work.\nPlease use the Firmware Boot Menu or press {K} during POST." => {
            "เครื่องนี้ดูเหมือนใช้ Legacy BIOS ไม่ใช่ UEFI\nการบูต USB ครั้งเดียวจะใช้ไม่ได้\nโปรดใช้เมนูบูตเฟิร์มแวร์ หรือกด {K} ระหว่าง POST".into()
        }
        "One-time USB boot requires Windows Vista or later." => {
            "การบูต USB ครั้งเดียวต้องใช้ Windows Vista หรือใหม่กว่า".into()
        }
        "bcdedit.exe not found ({P}).\nThis usually happens on 32-bit Windows running on 64-bit hardware." => {
            "ไม่พบ bcdedit.exe ({P})\nมักเกิดกับ Windows 32 บิตบนฮาร์ดแวร์ 64 บิต".into()
        }
        "bcdedit failed (exit code {C})." => {
            "bcdedit ล้มเหลว (รหัสออก {C})".into()
        }
        "A USB boot entry was found, but many HP, Dell, and Lenovo firmwares ignore the Windows override and boot back into Windows.\nIf that happens, use 'Firmware Boot Menu' instead — it works on every PC." => {
            "พบรายการบูต USB แล้ว แต่เฟิร์มแวร์ของ HP, Dell และ Lenovo หลายรุ่นไม่สนใจคำสั่งของ Windows แล้วบูตกลับเข้า Windows\nหากเป็นเช่นนั้น ให้ใช้ 'เมนูบูตเฟิร์มแวร์' แทน — ใช้ได้กับทุกเครื่อง".into()
        }
        "No USB boot entry detected in firmware.\nThe stick may not be plugged in, or this firmware does not expose USB devices to Windows.\nMany HP, Dell, and Lenovo laptops behave this way.\nUse the 'Firmware Boot Menu' option instead — it works on every PC." => {
            "ไม่พบรายการบูต USB ในเฟิร์มแวร์\nแฟลชไดรฟ์อาจไม่ได้เสียบอยู่ หรือเฟิร์มแวร์นี้ไม่แสดงอุปกรณ์ USB ให้ Windows เห็น\nแล็ปท็อป HP, Dell และ Lenovo หลายรุ่นเป็นแบบนี้\nโปรดใช้ตัวเลือก 'เมนูบูตเฟิร์มแวร์' แทน — ใช้ได้กับทุกเครื่อง".into()
        }
        "Firmware entries found, but none look like a USB device:\n" => {
            "พบรายการเฟิร์มแวร์ แต่ไม่มีรายการใดที่ดูเหมือนอุปกรณ์ USB:\n".into()
        }
        "\nIf your USB stick is plugged in, the firmware may be hiding it from Windows.\nUse the 'Firmware Boot Menu' option instead — it is reliable on every PC." => {
            "\nหากเสียบแฟลชไดรฟ์อยู่ เฟิร์มแวร์อาจซ่อนไว้ไม่ให้ Windows เห็น\nโปรดใช้ตัวเลือก 'เมนูบูตเฟิร์มแวร์' แทน — เชื่อถือได้บนทุกเครื่อง".into()
        }
        "Next >" => "ถัดไป >".into(),
        "Install" => "ติดตั้ง".into(),
        "< Back" => "< ย้อนกลับ".into(),
        "< Back to install options" => "< กลับไปตัวเลือกการติดตั้ง".into(),
        "Cancel" => "ยกเลิก".into(),
        "Finish" => "เสร็จสิ้น".into(),
        "Copy" => "คัดลอก".into(),
        "Browse..." => "เรียกดู...".into(),
        "Reboot" => "รีบูต".into(),
        "INSTALL NOW" => "ติดตั้งเลย".into(),
        "Write method:" => "วิธีเขียน:".into(),
        "Open manual download" => "เปิดหน้าดาวน์โหลดคู่มือ".into(),
        "Preparing the USB install..." => "กำลังเตรียมการติดตั้ง USB...".into(),
        "Target USB (for the non-destructive copy):" => {
            "USB เป้าหมาย (สำหรับการคัดลอกแบบไม่ทำลายข้อมูล):".into()
        }
        "Choose the target USB first, then how to write the image." => {
            "เลือก USB เป้าหมายก่อน แล้วเลือกวิธีเขียนอิมเมจ".into()
        }
        "[No removable USB drives detected]" => "[ไม่พบไดรฟ์ USB แบบถอดได้]".into(),
        "Copy Wifi Settings to LSL" => "คัดลอกการตั้งค่า WiFi ไปยัง LSL".into(),
        "Networks to copy (checked = include in wifi.sh):" => {
            "เครือข่ายที่จะคัดลอก (ติ๊ก = ใส่ใน wifi.sh):".into()
        }
        "No saved wifi profiles found." => "ไม่พบโปรไฟล์ WiFi ที่บันทึกไว้".into(),
        "Extra flatpak IDs (comma-separated):" => {
            "ID flatpak เพิ่มเติม (คั่นด้วยจุลภาค):".into()
        }
        "Flatpak apps to preload (checked = installed from Windows):" => {
            "แอป flatpak ที่จะโหลดล่วงหน้า (ติ๊ก = ติดตั้งจาก Windows):".into()
        }
        "FSearch (Everything-style file search)" => {
            "FSearch (ค้นหาไฟล์แบบ Everything)".into()
        }
        "Install Everything (voidtools)" => "ติดตั้ง Everything (voidtools)".into(),
        "Everything already installed (search ready)" => {
            "ติดตั้ง Everything แล้ว (พร้อมค้นหา)".into()
        }
        "Everything installed - index building in background" => {
            "ติดตั้ง Everything แล้ว - กำลังสร้างดัชนีเบื้องหลัง".into()
        }
        "Everything install failed - see console" => {
            "ติดตั้ง Everything ไม่สำเร็จ - ดูที่คอนโซล".into()
        }
        "Linux hardware compatibility (linux-hardware.org LKDDb): rating devices..." => {
            "ความเข้ากันได้ของฮาร์ดแวร์ Linux (linux-hardware.org LKDDb): กำลังประเมินอุปกรณ์...".into()
        }
        "WSL VHDX paths (one per line):" => "พาธ WSL VHDX (บรรทัดละหนึ่งพาธ):".into(),
        "LSL_DATA_DIR (Linux path, e.g. /mnt/c/Users/you/lsl-usb):" => {
            "LSL_DATA_DIR (พาธ Linux เช่น /mnt/c/Users/you/lsl-usb):".into()
        }
        "Category" => "หมวดหมู่".into(),
        "Support" => "การรองรับ".into(),
        "Device" => "อุปกรณ์".into(),
        "grub4dos boots via BIOS/CSM firmware from the MBR boot code + sectors 1-15. Needs FAT/NTFS on an MBR-partitioned stick." => {
            "grub4dos บูตผ่านเฟิร์มแวร์ BIOS/CSM จากโค้ดบูต MBR + เซกเตอร์ 1-15 ต้องใช้แท่งที่เป็น FAT/NTFS แบ่งพาร์ติชันแบบ MBR".into()
        }
        "UEFI boot needs a FAT32 stick plus a BOOTX64.EFI loader (vendored assets/BOOTX64.EFI at build time, or --uefi-bootx64). NTFS/GPT+NTFS single-partition sticks cannot UEFI-boot without a separate FAT32 ESP - that is also how Windows does it." => {
            "การบูต UEFI ต้องใช้แท่ง FAT32 พร้อมตัวโหลด BOOTX64.EFI (ไฟล์ assets/BOOTX64.EFI ตอนบิลด์ หรือ --uefi-bootx64) แท่ง NTFS/GPT+NTFS พาร์ติชันเดียวบูต UEFI ไม่ได้หากไม่มี FAT32 ESP แยก — Windows เองก็ทำแบบนี้".into()
        }
        "Used by the built-in installer only - pick Built-in non-destructive above to configure BIOS/UEFI boot." => {
            "ใช้ได้กับตัวติดตั้งในตัวเท่านั้น - เลือกวิธีติดตั้งในตัวแบบไม่ทำลายข้อมูลด้านบนเพื่อตั้งค่าบูต BIOS/UEFI".into()
        }
        "Rufus requires Windows 7 or later - use the built-in non-destructive write instead." => {
            "Rufus ต้องใช้ Windows 7 ขึ้นไป - ให้ใช้วิธีติดตั้งในตัวแบบไม่ทำลายข้อมูลแทน".into()
        }
        "Adds a DeleteMe folder, fills free space with 4 GB pseudo-random chunks, reads every byte back with OS caching DISABLED (bad/fake sticks cannot hide), then deletes DeleteMe. Catches dying and fake-capacity flash." => {
            "สร้างโฟลเดอร์ DeleteMe เติมพื้นที่ว่างด้วยข้อมูลสุ่มเทียมขนาด 4 GB อ่านทุกไบต์กลับโดยปิด OS caching (แท่งเสีย/ปลอมความจุซ่อนไม่ได้) แล้วลบ DeleteMe ตรวจจับแฟลชไดรฟ์ที่กำลังเสียและความจุปลอม".into()
        }
        "Built-in non-destructive (recommended - no reformat, keeps existing files; BIOS + UEFI)" => {
            "ติดตั้งในตัวแบบไม่ทำลายข้อมูล (แนะนำ - ไม่ฟอร์แมต เก็บไฟล์เดิม; BIOS + UEFI)".into()
        }
        "Rufus (well tested, UEFI + BIOS; rewrites the stick)" => {
            "Rufus (ทดสอบมาดี, UEFI + BIOS; เขียนทับทั้งแท่ง)".into()
        }
        "Skip - I will write the USB myself (like --skip-rufus)" => {
            "ข้าม - จะเขียน USB เอง (เหมือน --skip-rufus)".into()
        }
        "BIOS/CSM boot (grub4dos MBR, no reformat)" => {
            "บูต BIOS/CSM (grub4dos MBR, ไม่ฟอร์แมต)".into()
        }
        "UEFI boot (BOOTX64.EFI, Secure Boot off)" => {
            "บูต UEFI (BOOTX64.EFI, ปิด Secure Boot)".into()
        }
        "BIOS/CSM boot (built-in installer only)" => {
            "บูต BIOS/CSM (เฉพาะตัวติดตั้งในตัว)".into()
        }
        "UEFI boot (built-in installer only)" => {
            "บูต UEFI (เฉพาะตัวติดตั้งในตัว)".into()
        }
        "BIOS boot (unavailable - {E})" => "บูต BIOS (ไม่พร้อมใช้งาน - {E})".into(),
        "UEFI boot (unavailable - {E})" => "บูต UEFI (ไม่พร้อมใช้งาน - {E})".into(),
        "This PC boots {B} (board: UEFI {U}, legacy/CSM {L})" => {
            "เครื่องนี้บูตแบบ {B} (บอร์ด: UEFI {U}, legacy/CSM {L})".into()
        }
        " - WARNING: this selection will NOT boot this PC" => {
            " - คำเตือน: ตัวเลือกนี้จะบูตเครื่องนี้ไม่ติด".into()
        }
        "lsl-usb installer {V}" => "lsl-usb ตัวติดตั้ง {V}".into(),
        "Enabled - Mint's signed shim usually boots fine; you may see a one-time 'MOK management' screen (choose Enroll MOK)." => {
            "เปิดอยู่ - shim ที่เซ็นชื่อของ Mint มักบูตได้ปกติ อาจเห็นหน้าจอ 'MOK management' ครั้งเดียว (เลือก Enroll MOK)".into()
        }
        "Disabled - no Secure Boot issues expected." => {
            "ปิดอยู่ - ไม่มีปัญหา Secure Boot".into()
        }
        "Unknown - could not query (BIOS firmware, or run as Administrator for a firmware-level query)." => {
            "ไม่ทราบ - สอบถามไม่ได้ (เฟิร์มแวร์ BIOS หรือรันในฐานะ Administrator เพื่อสอบถามระดับเฟิร์มแวร์)".into()
        }
        "An up-to-date Mint ISO is already on this machine - it will be reused (no download needed)." => {
            "มีไฟล์ ISO ของ Mint รุ่นล่าสุดอยู่ในเครื่องแล้ว - จะใช้ไฟล์เดิม (ไม่ต้องดาวน์โหลด)".into()
        }
        "<- 64-bit: will NOT boot this 32-bit machine" => {
            "<- 64 บิต: จะบูตเครื่อง 32 บิตนี้ไม่ติด".into()
        }
        "<- recommended (up-to-date, reuse instead of downloading)" => {
            "<- แนะนำ (เป็นรุ่นล่าสุด ใช้ไฟล์เดิมแทนการดาวน์โหลด)".into()
        }
        "Tiny CorePlus is the recommended option." => {
            "Tiny CorePlus คือตัวเลือกที่แนะนำ".into()
        }
        "antiX 26 is the recommended option." => "antiX 26 คือตัวเลือกที่แนะนำ".into(),
        "Linux Mint Cinnamon is the recommended option." => {
            "Linux Mint Cinnamon คือตัวเลือกที่แนะนำ".into()
        }
        "Lubuntu 24.04 is the recommended option (Xubuntu 24.04 also viable)." => {
            "Lubuntu 24.04 คือตัวเลือกที่แนะนำ (Xubuntu 24.04 ก็ใช้ได้)".into()
        }
        "Your machine has only {M} MB of RAM. We recommend Tiny CorePlus, which needs as little as 46 MB and runs in 128 MB -- lighter than the minimalist 0.25 GB antiX. It is 32-bit, so it runs whether or not your machine supports 64-bit." => {
            "เครื่องนี้มี RAM เพียง {M} MB ขอแนะนำ Tiny CorePlus ซึ่งต้องการขั้นต่ำ 46 MB และรันได้ใน 128 MB — เบากว่า antiX แบบมินิมอล 0.25 GB และเป็น 32 บิต จึงรันได้ไม่ว่าเครื่องจะรองรับ 64 บิตหรือไม่".into()
        }
        "Your machine does not support 64-bit and will not be able to run Cinnamon. We recommend antiX 26, which runs on old hardware that doesn't support 64-bit and has as little as 0.25 GB of RAM." => {
            "เครื่องนี้ไม่รองรับ 64 บิต จึงรัน Cinnamon ไม่ได้ ขอแนะนำ antiX 26 ซึ่งรันบนฮาร์ดแวร์เก่าที่ไม่รองรับ 64 บิตและมี RAM น้อยเพียง 0.25 GB ได้".into()
        }
        "Your machine supports 64-bit and has {G0} GB of RAM, meeting Cinnamon's recommended 4 GB spec. There is no need to use the minimalist 0.25 GB antiX.{W}" => {
            "เครื่องนี้รองรับ 64 บิตและมี RAM {G0} GB ตรงตามสเปกแนะนำ 4 GB ของ Cinnamon ไม่จำเป็นต้องใช้ antiX แบบมินิมอล 0.25 GB{W}".into()
        }
        "Your machine supports 64-bit and has {G0} GB of RAM, meeting Cinnamon's minimum requirements of 2 GB, but not the recommended 4 GB. Consider enabling the experimental pagefile.sys swap. Your machine may be slow, but we still recommend Cinnamon over the minimalist 0.25 GB antiX.{W}" => {
            "เครื่องนี้รองรับ 64 บิตและมี RAM {G0} GB ผ่านขั้นต่ำ 2 GB ของ Cinnamon แต่ไม่ถึง 4 GB ที่แนะนำ ลองเปิดใช้ pagefile.sys swap แบบทดลอง เครื่องอาจช้า แต่เรายังแนะนำ Cinnamon มากกว่า antiX แบบมินิมอล 0.25 GB{W}".into()
        }
        "Your machine supports 64-bit and has {G0} GB of RAM (1-2 GB). We recommend Lubuntu 24.04, which is light enough for 1 GB. Xubuntu 24.04 is also a viable option on 1 GB, but it is a bit heavier and should still run.{W}" => {
            "เครื่องนี้รองรับ 64 บิตและมี RAM {G0} GB (1-2 GB) ขอแนะนำ Lubuntu 24.04 ซึ่งเบาพอสำหรับ 1 GB ส่วน Xubuntu 24.04 ก็เป็นตัวเลือกได้บน 1 GB แต่หนักกว่าเล็กน้อย ก็น่าจะยังรันได้{W}".into()
        }
        "Your machine supports 64-bit, but only has {G1} GB of RAM. We recommend the minimalist 0.25 GB antiX distro.{W}" => {
            "เครื่องนี้รองรับ 64 บิต แต่มี RAM เพียง {G1} GB ขอแนะนำดิสโทร antiX แบบมินิมอล 0.25 GB{W}".into()
        }
        " Note: the Windows running here is 32-bit, but your CPU does support 64-bit, so 64-bit live USBs boot normally." => {
            " หมายเหตุ: Windows ที่รันอยู่นี้เป็น 32 บิต แต่ CPU รองรับ 64 บิต ดังนั้น USB live 64 บิตจึงบูตได้ปกติ".into()
        }
        _ => msgid.to_string(),
    }
}

/// Translate `msgid` for the current Windows UI language.
pub fn tr(msgid: &str) -> String {
    tr_for(ui_lang(), msgid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_language_passes_through() {
        assert_eq!(tr_for("en", "Don't reboot"), "Don't reboot");
        assert_eq!(tr_for("fr", "Don't reboot"), "Don't reboot");
        assert_eq!(tr_for("", "Don't reboot"), "Don't reboot");
    }

    #[test]
    fn unknown_key_passes_through() {
        assert_eq!(tr_for("de", "no such string"), "no such string");
    }

    #[test]
    fn german_readiness_strings() {
        // Placeholder substitution survives translation ({K}/{P}/{C}).
        assert_eq!(
            tr_for(
                "de",
                "This PC appears to use Legacy BIOS, not UEFI.\nOne-time USB boot will not work.\nPlease use the Firmware Boot Menu or press {K} during POST."
            )
            .replace("{K}", "F12"),
            "Dieser PC scheint Legacy-BIOS statt UEFI zu verwenden.\nEinmaliger USB-Boot funktioniert nicht.\nBitte das Firmware-Bootmenü verwenden oder F12 während des POST drücken."
        );
        assert_eq!(
            tr_for("de", "bcdedit failed (exit code {C}).").replace("{C}", "1"),
            "bcdedit ist fehlgeschlagen (Exit-Code 1)."
        );
        assert_eq!(
            tr_for("de", "One-time USB boot requires Windows Vista or later."),
            "Einmaliger USB-Boot erfordert Windows Vista oder neuer."
        );
        assert_eq!(
            tr_for("de", "Firmware entries found, but none look like a USB device:\n"),
            "Firmware-Einträge gefunden, aber keiner sieht nach einem USB-Gerät aus:\n"
        );
        // Firmware entry names themselves are never translated.
        assert_eq!(
            tr_for("de", "SanDisk Cruzer"),
            "SanDisk Cruzer"
        );
    }

    #[test]
    fn lsl_lang_override_selects_language() {
        // Serialized via ENV_LOCK: LSL_LANG is process-global and other
        // tests pin it too; the override path itself returns before any
        // Win32 call.
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        unsafe {
            std::env::set_var("LSL_LANG", "th");
        }
        assert_eq!(ui_lang(), "th");
        unsafe {
            std::env::set_var("LSL_LANG", "DE");
        }
        assert_eq!(ui_lang(), "de");
        unsafe {
            std::env::set_var("LSL_LANG", "en");
        }
        assert_eq!(ui_lang(), "en");
        unsafe {
            std::env::set_var("LSL_LANG", "xx");
        }
        assert_ne!(ui_lang(), "xx");
        unsafe {
            std::env::remove_var("LSL_LANG");
        }
        // Without the override the system language decides (English here
        // unless the test box runs a Thai/German display language).
        assert!(["th", "de", "en"].contains(&ui_lang()));
    }

    #[test]
    fn thai_boot_strings() {
        // Placeholder substitution survives translation ({K}/{P}/{C}).
        assert_eq!(
            tr_for("th", "Manual boot menu: press {K} during POST.").replace("{K}", "F12"),
            "เมนูบูตแบบเลือกเอง: กด F12 ระหว่าง POST"
        );
        assert_eq!(
            tr_for("th", "bcdedit failed (exit code {C}).").replace("{C}", "1"),
            "bcdedit ล้มเหลว (รหัสออก 1)"
        );
        assert_eq!(tr_for("th", "Don't reboot"), "ไม่ต้องรีบูต");
        assert_eq!(
            tr_for("th", "Firmware entries found, but none look like a USB device:\n"),
            "พบรายการเฟิร์มแวร์ แต่ไม่มีรายการใดที่ดูเหมือนอุปกรณ์ USB:\n"
        );
        // Unknown keys and firmware names pass through untranslated.
        assert_eq!(tr_for("th", "no such string"), "no such string");
        assert_eq!(tr_for("th", "SanDisk Cruzer"), "SanDisk Cruzer");
    }

    #[test]
    fn german_boot_strings() {
        assert_eq!(tr_for("de", "Don't reboot"), "Nicht neu starten");
        assert_eq!(
            tr_for("de", "Firmware boot menu (shutdown /r /fw)"),
            "Firmware-Bootmenü (shutdown /r /fw)"
        );
        assert_eq!(
            tr_for("de", "Manual boot menu: press {K} during POST.")
                .replace("{K}", "F12"),
            "Manuelles Bootmenü: F12 während des POST drücken."
        );
    }
}
