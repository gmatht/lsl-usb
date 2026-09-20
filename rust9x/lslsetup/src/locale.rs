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

/// ISO-639 primary language of the Windows UI ("de", "en", ...).
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
                _ => "en",
            }
        }
        None => "en",
    }
}

/// Translate `msgid` for `lang` ("de" supported). Pure: unit-tested.
pub fn tr_for(lang: &str, msgid: &str) -> String {
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
