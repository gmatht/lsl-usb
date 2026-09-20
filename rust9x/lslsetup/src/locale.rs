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

/// ISO-639 primary language of the Windows UI ("de", "th", "en", ...).
/// English default (also on Win9x / when the API is missing).
pub fn ui_lang() -> &'static str {
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
