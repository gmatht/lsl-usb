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
