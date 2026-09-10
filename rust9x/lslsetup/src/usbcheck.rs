//! Whole-USB surface check ("Check Whole USB" checkbox / `--check-usb`).
//!
//! After the write finishes: create `<USB>:\DeleteMe\`, fill it with chunk
//! files of deterministic pseudo-random data (chunk = 4 GiB - 1 MiB, so it
//! fits FAT32's max file size AND stays 4096-aligned), then read every byte
//! back and compare against the regenerated stream. On success `DeleteMe\`
//! is removed; on failure it is left in place and the error names the
//! file + offset.
//!
//! Cache bypass (a cache must never make a bad stick look good): every file
//! is opened with `FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH` and all
//! buffers are 4 MiB, 4096-aligned, in multiples of 4096 bytes - reads and
//! writes go to the device, never the OS page cache. A mismatch therefore
//! means the stick actually returned wrong data (fake-capacity / dying
//! flash), not a stale cache line.

use crate::gui::WorkingUi;
use crate::sys::{self, out};
use winapi::shared::minwindef::{DWORD, FALSE};
use winapi::um::errhandlingapi::GetLastError;
use winapi::um::fileapi::{CreateFileW, FlushFileBuffers, GetDiskFreeSpaceExW, ReadFile, WriteFile};
use winapi::um::handleapi::{CloseHandle, INVALID_HANDLE_VALUE};
use winapi::um::fileapi::{CREATE_ALWAYS, OPEN_EXISTING};
use winapi::um::winbase::{FILE_FLAG_NO_BUFFERING, FILE_FLAG_WRITE_THROUGH};
use winapi::um::winnt::FILE_ATTRIBUTE_NORMAL;
use winapi::shared::winerror::ERROR_DISK_FULL;
use winapi::um::winnt::{FILE_SHARE_READ, FILE_SHARE_WRITE, GENERIC_READ, GENERIC_WRITE};

/// Chunk file size: just under 4 GiB so one file fits FAT32 (max 4 GiB - 1)
/// and stays a multiple of 4096 for unbuffered I/O.
pub const CHUNK_BYTES: u64 = 0xFFF0_0000; // 4 GiB - 1 MiB
/// Transfer unit: multiple of 4096, big enough for throughput.
const BUF_BYTES: usize = 4 * 1024 * 1024;
/// Stop filling while this much free space remains (filesystem headroom).
const MIN_TAIL: u64 = 8 * 1024 * 1024;
/// Smallest final partial chunk worth writing.
const MIN_CHUNK: u64 = 1024 * 1024;

pub struct UsbCheckReport {
    pub files: u32,
    pub bytes_verified: u64,
    pub secs: f64,
}

/// Deterministic PRNG (xorshift128+), seeded per chunk file so the verify
/// pass regenerates exactly the bytes the write pass produced.
struct XorShift {
    s0: u64,
    s1: u64,
}

impl XorShift {
    fn seed(chunk: u32) -> Self {
        let mut s0 = 0x9E37_79B9_7F4A_7C15u64 ^ (chunk as u64).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        let s1 = 0xD1B5_4A32_D192_ED03u64 ^ (chunk as u64).wrapping_mul(0x94D0_49BB_1331_11EB);
        if s0 == 0 && s1 == 0 {
            s0 = 1;
        }
        XorShift { s0, s1 }
    }

    fn next(&mut self) -> u64 {
        let x = self.s0;
        let y = self.s1;
        self.s0 = y;
        let x = x ^ (x << 23);
        self.s1 = x ^ y ^ (x >> 17) ^ (y >> 26);
        self.s1.wrapping_add(y)
    }

    fn fill(&mut self, buf: &mut [u8]) {
        let rest_len = buf.len() % 8;
        let full = buf.len() - rest_len;
        for w in buf[..full].chunks_exact_mut(8) {
            w.copy_from_slice(&self.next().to_le_bytes());
        }
        if rest_len > 0 {
            let last = self.next().to_le_bytes();
            buf[full..].copy_from_slice(&last[..rest_len]);
        }
    }
}

/// 4096-aligned buffer for `FILE_FLAG_NO_BUFFERING` (address and length must
/// both be sector-aligned; 4096 covers 512e and 4Kn sticks).
fn aligned_buf() -> (Vec<u8>, usize) {
    let v = vec![0u8; BUF_BYTES + 4096];
    let off = (4096 - (v.as_ptr() as usize % 4096)) % 4096;
    (v, off)
}

fn free_bytes(root: &str) -> Result<u64, String> {
    let mut wroot = sys::wide(root);
    let mut freeq: winapi::shared::ntdef::ULARGE_INTEGER = unsafe { std::mem::zeroed() };
    let ok = unsafe { GetDiskFreeSpaceExW(wroot.as_mut_ptr(), &mut freeq, std::ptr::null_mut(), std::ptr::null_mut()) };
    if ok == FALSE {
        return Err(format!("cannot query free space on {} (error {})", root, unsafe { GetLastError() }));
    }
    Ok(unsafe { *freeq.QuadPart() } as u64)
}

type Handle = *mut winapi::ctypes::c_void;

fn open_uncached(path: &str, write: bool) -> Result<Handle, String> {
    let mut wpath = sys::wide(path);
    let h = unsafe {
        CreateFileW(
            wpath.as_mut_ptr(),
            if write { GENERIC_READ | GENERIC_WRITE } else { GENERIC_READ },
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null_mut(),
            if write { CREATE_ALWAYS } else { OPEN_EXISTING },
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH,
            std::ptr::null_mut(),
        )
    };
    if h == INVALID_HANDLE_VALUE {
        Err(format!("cannot open {} (error {})", path, unsafe { GetLastError() }))
    } else {
        Ok(h)
    }
}

fn close(h: Handle) {
    unsafe { CloseHandle(h) };
}

/// Throttled progress: console line every ~2 s + GUI status/progress/pump.
struct Tick<'a> {
    ui: Option<&'a WorkingUi>,
    last: std::time::Instant,
    t0: std::time::Instant,
}

impl<'a> Tick<'a> {
    fn tick(&mut self, phase: &str, done: u64, total: u64) {
        if self.last.elapsed().as_secs() < 2 && done < total {
            return;
        }
        self.last = std::time::Instant::now();
        let secs = self.t0.elapsed().as_secs_f64().max(0.1);
        let mbs = done as f64 / secs / (1024.0 * 1024.0);
        let gb = |b: u64| b as f64 / (1024.0 * 1024.0 * 1024.0);
        out::info(&format!(
            "  {}: {:.1} / {:.1} GB ({:.0}%) {:.0} MB/s, cache bypassed",
            phase,
            gb(done),
            gb(total),
            if total > 0 { 100.0 * done as f64 / total as f64 } else { 0.0 },
            mbs
        ));
        if let Some(ui) = self.ui {
            ui.set_status(&format!("Whole-USB check - {}: {:.1}/{:.1} GB", phase, gb(done), gb(total)));
            ui.set_progress(done, total.max(1));
            ui.pump();
        }
    }
}

/// Fill free space with PRNG chunks, read every byte back and compare.
/// `DeleteMe\` is removed on success and left in place on failure.
pub fn check_whole_usb(letter: &str, ui: Option<&WorkingUi>) -> Result<UsbCheckReport, String> {
    let root = format!("{}:\\", letter);
    let dir = format!("{}DeleteMe", root);
    let _ = std::fs::remove_dir_all(&dir); // stale files from an older run
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("cannot create {} ({}); is the stick still plugged in?", dir, e))?;
    let free0 = free_bytes(&root)?;
    if free0 < MIN_CHUNK + MIN_TAIL {
        let _ = std::fs::remove_dir(&dir);
        return Err(format!(
            "only {:.1} MB free on {}: - nothing worth checking (need >{:.0} MB free)",
            free0 as f64 / (1024.0 * 1024.0),
            letter,
            (MIN_CHUNK + MIN_TAIL) as f64 / (1024.0 * 1024.0)
        ));
    }

    out::step("Checking the whole USB surface (DeleteMe fill + read-back verify)...");
    out::info(&format!(
        "  {:.1} GB free; writing 4 GB PRNG chunks with OS caching DISABLED (direct device I/O).",
        free0 as f64 / (1024.0 * 1024.0 * 1024.0)
    ));
    out::warn("  This takes a while on big/slow sticks (USB 2.0 ≈ 10 MB/s ≈ 7 min per 4 GB).");
    let t0 = std::time::Instant::now();
    let mut tick = Tick { ui, last: std::time::Instant::now() - std::time::Duration::from_secs(5), t0 };
    let (mut wbuf, woff) = aligned_buf();
    let mut files: Vec<(String, u64)> = Vec::new();
    let mut written_total: u64 = 0;

    // ---- write phase ----
    let mut idx: u32 = 0;
    loop {
        let free = free_bytes(&root)?;
        let budget = free.saturating_sub(MIN_TAIL);
        if budget < MIN_CHUNK {
            break;
        }
        let target = CHUNK_BYTES.min(budget & !4095);
        if target < MIN_CHUNK {
            break;
        }
        idx += 1;
        let path = format!("{}\\chunk-{:04}.bin", dir, idx);
        let h = open_uncached(&path, true)?;
        let mut prng = XorShift::seed(idx);
        let mut done: u64 = 0;
        let mut full = true;
        while done < target {
            let n = (target - done).min(BUF_BYTES as u64) as usize;
            prng.fill(&mut wbuf[woff..woff + n]);
            let mut wrote_total: usize = 0;
            while wrote_total < n {
                let mut wrote: DWORD = 0;
                let ok = unsafe {
                    WriteFile(
                        h,
                        wbuf[woff + wrote_total..].as_ptr() as *const _,
                        (n - wrote_total) as DWORD,
                        &mut wrote,
                        std::ptr::null_mut(),
                    )
                };
                if ok == FALSE {
                    let e = unsafe { GetLastError() };
                    if e == ERROR_DISK_FULL {
                        full = false;
                        break;
                    }
                    close(h);
                    return Err(format!("write failed on {} at +{:.1} GB (error {}) - DeleteMe left in place", path, done as f64 / 1e9, e));
                }
                if wrote == 0 {
                    close(h);
                    return Err(format!("short write (0 bytes) on {} - DeleteMe left in place", path));
                }
                wrote_total += wrote as usize;
            }
            if !full {
                break;
            }
            done += wrote_total as u64;
        }
        unsafe { FlushFileBuffers(h) };
        close(h);
        files.push((path.clone(), done));
        written_total += done;
        tick.tick("writing", written_total, free0);
        if !full || done < target {
            break; // disk is full: verify what landed
        }
    }
    if files.is_empty() {
        return Err(format!("could not write any test data on {}: - DeleteMe left in place", letter));
    }
    out::info(&format!("  wrote {} chunk file(s), {:.1} GB.", files.len(), written_total as f64 / 1e9));

    // ---- verify phase: re-read uncached, compare against regenerated stream ----
    let (mut rbuf, roff) = aligned_buf();
    let (mut xbuf, xoff) = aligned_buf();
    let mut verified: u64 = 0;
    for (i, (path, len)) in files.iter().enumerate() {
        let h = open_uncached(path, false)?;
        let mut prng = XorShift::seed((i + 1) as u32);
        let mut done: u64 = 0;
        while done < *len {
            let n = (*len - done).min(BUF_BYTES as u64) as usize;
            let mut got_total: usize = 0;
            while got_total < n {
                let mut got: DWORD = 0;
                let ok = unsafe {
                    ReadFile(
                        h,
                        rbuf[roff + got_total..].as_mut_ptr() as *mut _,
                        (n - got_total) as DWORD,
                        &mut got,
                        std::ptr::null_mut(),
                    )
                };
                if ok == FALSE {
                    let e = unsafe { GetLastError() };
                    close(h);
                    return Err(format!("read failed on {} at +{:.1} GB (error {}) - BAD STICK, DeleteMe left in place", path, done as f64 / 1e9, e));
                }
                if got == 0 {
                    break;
                }
                got_total += got as usize;
            }
            if got_total != n {
                close(h);
                return Err(format!(
                    "short file on {} (expected {:.1} GB, device returned {:.1} GB) - FAKE-CAPACITY STICK, DeleteMe left in place",
                    path,
                    *len as f64 / 1e9,
                    (done + got_total as u64) as f64 / 1e9
                ));
            }
            prng.fill(&mut xbuf[xoff..xoff + n]);
            if rbuf[roff..roff + n] != xbuf[xoff..xoff + n] {
                let off = rbuf[roff..roff + n]
                    .iter()
                    .zip(xbuf[xoff..xoff + n].iter())
                    .position(|(a, b)| a != b)
                    .unwrap_or(0);
                close(h);
                return Err(format!(
                    "DATA MISMATCH on {} at file offset {:.3} GB - BAD STICK, DeleteMe left in place",
                    path,
                    (done + off as u64) as f64 / 1e9
                ));
            }
            done += n as u64;
            verified += n as u64;
            tick.tick("verifying", verified, written_total);
        }
        close(h);
    }

    // ---- success: remove the test data so the stick is usable ----
    if let Err(e) = std::fs::remove_dir_all(&dir) {
        out::warn(&format!("check passed but {} could not be removed ({}) - delete it by hand.", dir, e));
    }
    let secs = t0.elapsed().as_secs_f64();
    out::step(&format!(
        "Whole-USB check PASSED: {:.1} GB in {} file(s) written and read back clean ({:.0}s, {:.0} MB/s average).",
        verified as f64 / 1e9,
        files.len(),
        secs,
        verified as f64 / secs.max(1.0) / (1024.0 * 1024.0)
    ));
    Ok(UsbCheckReport { files: files.len() as u32, bytes_verified: verified, secs })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prng_is_deterministic_per_chunk() {
        let mut a = XorShift::seed(7);
        let mut b = XorShift::seed(7);
        let mut c = XorShift::seed(8);
        for _ in 0..100 {
            let x = a.next();
            assert_eq!(x, b.next());
            assert_ne!(x, c.next());
        }
    }

    #[test]
    fn prng_fill_matches_word_stream() {
        let mut s = XorShift::seed(1);
        let mut buf = [0u8; 100];
        s.fill(&mut buf);
        let mut t = XorShift::seed(1);
        for chunk in buf.chunks(8) {
            assert_eq!(chunk, &t.next().to_le_bytes()[..chunk.len()]);
        }
    }

    #[test]
    fn chunk_size_fits_fat32_and_alignment() {
        assert!(CHUNK_BYTES < 0xFFFF_FFFF); // FAT32 max file size
        assert_eq!(CHUNK_BYTES % 4096, 0); // unbuffered I/O alignment
        assert_eq!(BUF_BYTES % 4096, 0);
    }

    #[test]
    fn aligned_buffer_is_sector_aligned() {
        let (v, off) = aligned_buf();
        assert_eq!((v.as_ptr() as usize + off) % 4096, 0);
        assert!(off + BUF_BYTES <= v.len());
    }
}
