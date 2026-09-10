//! HTTPS/HTTP downloads via winhttp, loaded dynamically.
//!
//! winhttp.dll exists on Win2000+ SP3 and later (not on Win9x). TLS 1.2 is
//! only negotiated on Win8.1+/patched Win7 — we request it explicitly and
//! treat failure as a graceful "manual download needed" result, which the
//! callers surface with the exact URL and destination path.

use crate::sys::{c_void, DynLib};
use std::sync::OnceLock;

const WINHTTP_FLAG_SECURE: u32 = 0x0080_0000;
const WINHTTP_OPTION_SECURE_PROTOCOLS: u32 = 84;
const SP_PROT_TLS1_2_CLIENT: u32 = 0x0000_0800;
const WINHTTP_QUERY_STATUS_CODE: u32 = 19;
const WINHTTP_QUERY_FLAG_NUMBER: u32 = 0x2000_0000;
const WINHTTP_QUERY_CONTENT_LENGTH: u32 = 5;
const WINHTTP_OPTION_REDIRECT_POLICY: u32 = 88;
const WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS: u32 = 2;

type HInternet = *mut c_void;

struct WinHttp {
    _lib: DynLib,
    open: unsafe extern "system" fn(*const u16, u32, *const u16, *const u16, u32) -> HInternet,
    connect: unsafe extern "system" fn(HInternet, *const u16, u16, u32) -> HInternet,
    open_request: unsafe extern "system" fn(
        HInternet, *const u16, *const u16, *const u16, *const u16, *const u16, u32,
    ) -> HInternet,
    set_option: unsafe extern "system" fn(HInternet, u32, *mut c_void, u32) -> i32,
    add_headers: unsafe extern "system" fn(HInternet, *const u16, u32, u32) -> i32,
    send_request: unsafe extern "system" fn(
        HInternet, *const u16, u32, *mut c_void, u32, *mut c_void, usize,
    ) -> i32,
    receive_response: unsafe extern "system" fn(HInternet, *mut c_void) -> i32,
    query_headers: unsafe extern "system" fn(
        HInternet, u32, *mut c_void, *mut c_void, *mut u32, *mut u32,
    ) -> i32,
    query_data_available: unsafe extern "system" fn(HInternet, *mut u32) -> i32,
    read_data: unsafe extern "system" fn(HInternet, *mut c_void, u32, *mut u32) -> i32,
    close_handle: unsafe extern "system" fn(HInternet) -> i32,
}

impl WinHttp {
    fn load() -> Option<WinHttp> {
        let lib = DynLib::load("winhttp.dll")?;
        macro_rules! get {
            ($name:literal) => {
                lib.proc($name)?
            };
        }
        unsafe {
            Some(WinHttp {
                open: std::mem::transmute(get!("WinHttpOpen")),
                connect: std::mem::transmute(get!("WinHttpConnect")),
                open_request: std::mem::transmute(get!("WinHttpOpenRequest")),
                set_option: std::mem::transmute(get!("WinHttpSetOption")),
                add_headers: std::mem::transmute(get!("WinHttpAddRequestHeaders")),
                send_request: std::mem::transmute(get!("WinHttpSendRequest")),
                receive_response: std::mem::transmute(get!("WinHttpReceiveResponse")),
                query_headers: std::mem::transmute(get!("WinHttpQueryHeaders")),
                query_data_available: std::mem::transmute(get!("WinHttpQueryDataAvailable")),
                read_data: std::mem::transmute(get!("WinHttpReadData")),
                close_handle: std::mem::transmute(get!("WinHttpCloseHandle")),
                _lib: lib,
            })
        }
    }
}

// FFI handles are not thread-associated (winhttp is free-threaded), and the
// function pointers are immutable after load.
unsafe impl Send for WinHttp {}
unsafe impl Sync for WinHttp {}

static WINHTTP: OnceLock<Option<WinHttp>> = OnceLock::new();
fn winhttp() -> Option<&'static WinHttp> {
    WINHTTP.get_or_init(WinHttp::load).as_ref()
}

pub enum HttpErr {
    /// winhttp.dll is absent (Win9x) — manual download is the only way.
    NoTransport,
    /// Transport present but the request failed (old TLS, offline, ...).
    Failed(String),
    /// Transport present; TLS is too old for modern hosts.
    OldTls,
}
impl std::fmt::Display for HttpErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HttpErr::NoTransport => write!(f, "no HTTP transport on this Windows version (winhttp.dll absent)"),
            HttpErr::Failed(m) => write!(f, "{}", m),
            HttpErr::OldTls => write!(f, "TLS 1.2 not supported by this Windows version"),
        }
    }
}

pub struct HttpResult {
    pub status: u32,
    pub body: Vec<u8>,
}

fn split_url(url: &str) -> (bool, String, u16, String) {
    let (secure, rest) = if let Some(r) = url.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = url.strip_prefix("http://") {
        (false, r)
    } else {
        (false, url)
    };
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => {
            (h.to_string(), p.parse().unwrap_or(if secure { 443 } else { 80 }))
        }
        _ => (hostport.to_string(), if secure { 443 } else { 80 }),
    };
    (secure, host, port, path.to_string())
}

/// GET a URL fully into memory. Small payloads only (API JSON, checksums).
pub fn get(url: &str, user_agent: &str) -> Result<HttpResult, HttpErr> {
    let wh = winhttp().ok_or(HttpErr::NoTransport)?;
    get_with(wh, url, user_agent, &mut |_, _| {})
}

fn get_with(
    wh: &WinHttp,
    url: &str,
    user_agent: &str,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<HttpResult, HttpErr> {
    let (secure, host, port, path) = split_url(url);
    unsafe {
        let ua = crate::sys::wide(user_agent);
        let session = (wh.open)(ua.as_ptr(), 0, std::ptr::null(), std::ptr::null(), 0);
        if session.is_null() {
            return Err(HttpErr::Failed("WinHttpOpen failed".into()));
        }
        let whost = crate::sys::wide(&host);
        let conn = (wh.connect)(session, whost.as_ptr(), port as u16, 0);
        if conn.is_null() {
            (wh.close_handle)(session);
            return Err(HttpErr::Failed("WinHttpConnect failed (DNS/offline?)".into()));
        }
        let wpath = crate::sys::wide(&path);
        let req = (wh.open_request)(
            conn,
            cstr16("GET").as_ptr(),
            wpath.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            if secure { WINHTTP_FLAG_SECURE } else { 0 },
        );
        if req.is_null() {
            (wh.close_handle)(conn);
            (wh.close_handle)(session);
            return Err(HttpErr::Failed("WinHttpOpenRequest failed".into()));
        }
        // Best-effort: ask for modern TLS; ignored on versions that don't
        // support the option (they will fail the handshake and we surface
        // that as OldTls-ish failure below).
        let protos: u32 = SP_PROT_TLS1_2_CLIENT;
        (wh.set_option)(
            req,
            WINHTTP_OPTION_SECURE_PROTOCOLS,
            &protos as *const u32 as *mut c_void,
            4,
        );
        let policy: u32 = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
        (wh.set_option)(req, WINHTTP_OPTION_REDIRECT_POLICY, &policy as *const u32 as *mut c_void, 4);

        let mut uah = crate::sys::wide(&format!("User-Agent: {}\r\n", user_agent));
        let _ = (wh.add_headers)(req, uah.as_mut_ptr(), (uah.len() as u32) - 1, 0x20000000); // WINHTTP_ADDREQ_FLAG_ADD

        let mut ok = (wh.send_request)(req, std::ptr::null(), 0, std::ptr::null_mut(), 0, std::ptr::null_mut(), 0) != 0;
        if ok {
            ok = (wh.receive_response)(req, std::ptr::null_mut()) != 0;
        }
        if !ok {
            (wh.close_handle)(req);
            (wh.close_handle)(conn);
            (wh.close_handle)(session);
            let e = winapi::um::errhandlingapi::GetLastError();
            // 12029 = cannot connect, 12175 = security failure (old TLS)
            if e == 12175 {
                return Err(HttpErr::OldTls);
            }
            return Err(HttpErr::Failed(format!("request failed (error {})", e)));
        }
        let mut status: u32 = 0;
        let mut sz: u32 = 4;
        (wh.query_headers)(
            req,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            std::ptr::null_mut(),
            &mut status as *mut u32 as *mut c_void,
            &mut sz,
            std::ptr::null_mut(),
        );
        let mut body: Vec<u8> = Vec::new();
        let total: u64 = 0;
        loop {
            let mut avail: u32 = 0;
            if (wh.query_data_available)(req, &mut avail) == 0 || avail == 0 {
                break;
            }
            let mut buf = vec![0u8; avail as usize];
            let mut got: u32 = 0;
            if (wh.read_data)(req, buf.as_mut_ptr() as *mut c_void, avail, &mut got) == 0 || got == 0 {
                break;
            }
            body.extend_from_slice(&buf[..got as usize]);
            progress(total, body.len() as u64);
        }
        (wh.close_handle)(req);
        (wh.close_handle)(conn);
        (wh.close_handle)(session);
        Ok(HttpResult { status, body })
    }
}

fn cstr16(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Download a URL to a file with progress callback (downloaded, total-known?).
/// `total_known` is false until Content-Length becomes available (winhttp
/// doesn't expose it without an extra query; we report bytes downloaded).
pub fn download_to_file(
    url: &str,
    dest: &str,
    user_agent: &str,
    progress: &mut dyn FnMut(u64),
) -> Result<u64, HttpErr> {
    let wh = winhttp().ok_or(HttpErr::NoTransport)?;
    // Reuse the in-memory path but stream: implement separately for files to
    // keep memory flat for the ~3 GB ISO.
    unsafe {
        let (secure, host, port, path) = split_url(url);
        let ua = crate::sys::wide(user_agent);
        let session = (wh.open)(ua.as_ptr(), 0, std::ptr::null(), std::ptr::null(), 0);
        if session.is_null() {
            return Err(HttpErr::Failed("WinHttpOpen failed".into()));
        }
        let whost = crate::sys::wide(&host);
        let conn = (wh.connect)(session, whost.as_ptr(), port as u16, 0);
        if conn.is_null() {
            (wh.close_handle)(session);
            return Err(HttpErr::Failed("WinHttpConnect failed (DNS/offline?)".into()));
        }
        let wpath = crate::sys::wide(&path);
        let req = (wh.open_request)(
            conn,
            cstr16("GET").as_ptr(),
            wpath.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            if secure { WINHTTP_FLAG_SECURE } else { 0 },
        );
        if req.is_null() {
            (wh.close_handle)(conn);
            (wh.close_handle)(session);
            return Err(HttpErr::Failed("WinHttpOpenRequest failed".into()));
        }
        let protos: u32 = SP_PROT_TLS1_2_CLIENT;
        (wh.set_option)(req, WINHTTP_OPTION_SECURE_PROTOCOLS, &protos as *const u32 as *mut c_void, 4);
        let policy: u32 = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
        (wh.set_option)(req, WINHTTP_OPTION_REDIRECT_POLICY, &policy as *const u32 as *mut c_void, 4);
        let mut uah = crate::sys::wide(&format!("User-Agent: {}\r\n", user_agent));
        let _ = (wh.add_headers)(req, uah.as_mut_ptr(), (uah.len() as u32) - 1, 0x20000000);

        let mut ok = (wh.send_request)(req, std::ptr::null(), 0, std::ptr::null_mut(), 0, std::ptr::null_mut(), 0) != 0;
        if ok {
            ok = (wh.receive_response)(req, std::ptr::null_mut()) != 0;
        }
        if !ok {
            (wh.close_handle)(req);
            (wh.close_handle)(conn);
            (wh.close_handle)(session);
            let e = winapi::um::errhandlingapi::GetLastError();
            if e == 12175 {
                return Err(HttpErr::OldTls);
            }
            return Err(HttpErr::Failed(format!("request failed (error {})", e)));
        }
        let mut status: u32 = 0;
        let mut sz: u32 = 4;
        (wh.query_headers)(
            req,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            std::ptr::null_mut(),
            &mut status as *mut u32 as *mut c_void,
            &mut sz,
            std::ptr::null_mut(),
        );
        if status != 200 {
            (wh.close_handle)(req);
            (wh.close_handle)(conn);
            (wh.close_handle)(session);
            return Err(HttpErr::Failed(format!("HTTP {}", status)));
        }

        // Length enforcement: without it a stalled/broken stream returns
        // Ok(short) and callers verify a truncated file (Rufus died in
        // Authenticode with exactly this shape). Unknown length (chunked /
        // header absent) skips the check, as before.
        let mut content_len: Option<u64> = None;
        {
            let mut n: u32 = 0;
            let mut sz: u32 = 4;
            if (wh.query_headers)(
                req,
                WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
                std::ptr::null_mut(),
                &mut n as *mut u32 as *mut c_void,
                &mut sz,
                std::ptr::null_mut(),
            ) != 0 && n > 0
            {
                content_len = Some(n as u64);
            }
        }

        let file = std::fs::File::create(dest).map_err(|e| HttpErr::Failed(e.to_string()))?;
        let mut out = std::io::BufWriter::with_capacity(1 << 20, file);
        let mut downloaded: u64 = 0;
        loop {
            let mut avail: u32 = 0;
            if (wh.query_data_available)(req, &mut avail) == 0 || avail == 0 {
                break;
            }
            let mut buf = vec![0u8; avail as usize];
            let mut got: u32 = 0;
            if (wh.read_data)(req, buf.as_mut_ptr() as *mut c_void, avail, &mut got) == 0 || got == 0 {
                break;
            }
            use std::io::Write;
            out.write_all(&buf[..got as usize]).map_err(|e| HttpErr::Failed(e.to_string()))?;
            downloaded += got as u64;
            progress(downloaded);
        }
        use std::io::Write as _;
        let _ = out.flush();
        (wh.close_handle)(req);
        (wh.close_handle)(conn);
        (wh.close_handle)(session);
        if !length_ok(downloaded, content_len) {
            // Never leave a partial file behind to be mistaken for complete.
            let _ = std::fs::remove_file(dest);
            return Err(HttpErr::Failed(format!(
                "incomplete download ({} of {} bytes) - the connection broke mid-stream; try again",
                downloaded,
                content_len.unwrap_or(0)
            )));
        }
        Ok(downloaded)
    }
}

/// Content-Length of `url` via a throwaway HEAD-style GET (first response
/// headers only). Used for the download progress bar's range.
pub fn content_length(url: &str) -> Option<u64> {
    let wh = winhttp()?;
    unsafe {
        let (secure, host, port, path) = split_url(url);
        let ua = crate::sys::wide(user_agent());
        let session = (wh.open)(ua.as_ptr(), 0, std::ptr::null(), std::ptr::null(), 0);
        if session.is_null() {
            return None;
        }
        let whost = crate::sys::wide(&host);
        let conn = (wh.connect)(session, whost.as_ptr(), port as u16, 0);
        if conn.is_null() {
            (wh.close_handle)(session);
            return None;
        }
        let wpath = crate::sys::wide(&path);
        let req = (wh.open_request)(
            conn,
            cstr16("GET").as_ptr(),
            wpath.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            if secure { WINHTTP_FLAG_SECURE } else { 0 },
        );
        if req.is_null() {
            (wh.close_handle)(conn);
            (wh.close_handle)(session);
            return None;
        }
        let protos: u32 = SP_PROT_TLS1_2_CLIENT;
        (wh.set_option)(req, WINHTTP_OPTION_SECURE_PROTOCOLS, &protos as *const u32 as *mut c_void, 4);
        let mut ok = (wh.send_request)(req, std::ptr::null(), 0, std::ptr::null_mut(), 0, std::ptr::null_mut(), 0) != 0;
        if ok {
            ok = (wh.receive_response)(req, std::ptr::null_mut()) != 0;
        }
        if !ok {
            (wh.close_handle)(req);
            (wh.close_handle)(conn);
            (wh.close_handle)(session);
            return None;
        }
        let mut clen: u64 = 0;
        let mut sz: u32 = 8;
        // WINHTTP_QUERY_CONTENT_LENGTH = 5, WINHTTP_QUERY_FLAG_NUMBER = 0x20000000
        (wh.query_headers)(
            req,
            5 | 0x2000_0000,
            std::ptr::null_mut(),
            &mut clen as *mut u64 as *mut c_void,
            &mut sz,
            std::ptr::null_mut(),
        );
        (wh.close_handle)(req);
        (wh.close_handle)(conn);
        (wh.close_handle)(session);
        if clen > 0 {
            Some(clen)
        } else {
            None
        }
    }
}

pub fn has_transport() -> bool {
    winhttp().is_some()
}

pub fn user_agent() -> &'static str {
    "lsl-usb-installer/1.0"
}

/// Length validation for a finished download: unknown length (chunked /
/// header absent) can't be checked; a known length must match exactly.
fn length_ok(downloaded: u64, content_length: Option<u64>) -> bool {
    match content_length {
        None => true,
        Some(n) => downloaded == n,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn download_length_validation() {
        assert!(length_ok(100, None)); // chunked: nothing to check against
        assert!(length_ok(100, Some(100)));
        assert!(length_ok(0, Some(0)));
        assert!(!length_ok(50, Some(100))); // stalled stream: the Rufus case
        assert!(!length_ok(0, Some(100)));
        assert!(!length_ok(101, Some(100)));
    }
}
