#!/usr/bin/env python3
"""
FUSE passthrough that stores Linux metadata (mode, uid, gid, symlinks, devices,
optional xattrs) in a single sidecar file so a FAT (or similar) tree can back
Linux software without losing permissions and special file types.

Files larger than the FAT32 per-file limit (~4GiB - 1 byte) are stored as a
sequence of chunk files on the backing store; the FUSE view exposes a single
logical file. Optional metadata key ``logical_size`` can extend the visible
size beyond stored bytes (sparse tail reads as zeros).

**Symbolic links:** When the backing filesystem cannot create symlinks (e.g. FAT),
``symlink`` stores the target in metadata and a small stub file; ``readlink``
returns the stored target. Native symlinks on the backing store are merged with
metadata. Read/write/truncate on a symlink path return ``EINVAL``; use
``readlink`` / follow the target. Chmod/utimens use symlink-aware APIs where
available.

Backing store layout:
  <backing>/              — FAT mount or directory
  <backing>/<meta-file>   — JSON for entries in this directory (default basename: .linux-meta.json)
  <backing>/a/b/<meta-file> — metadata for names directly inside a/b/
  <backing>/path/to/file.__part0001 …  — optional extra chunks (hidden in FUSE)

Legacy: a single monolithic JSON at <backing>/<meta-file> with full-path keys is migrated
on startup into per-directory files.

Usage:
  python3 fat_linux_meta_fs.py <backing-dir> <fuse-mountpoint> [--meta-file NAME]

Requires: fusepy, Linux with FUSE (fuse package / kernel module).
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import re
import stat
import threading
import time
from typing import Any

import fuse


META_VERSION = 1

# renameat2 / Linux UAPI (used when FUSE passes rename flags)
RENAME_NOREPLACE = 1
RENAME_EXCHANGE = 2

# FAT32 maximum file size; chunk so each backing segment stays within this limit.
CHUNK_MAX: int = 2**32 - 1

def _is_chunk_part_filename(name: str) -> bool:
    return bool(re.search(r"\.__(?:part|chunk)\d{4}$", name))


def _chunk_suffix(part_index: int) -> str:
    if part_index <= 0:
        return ""
    return f".__part{part_index:04d}"


def _stat_to_dict(st: os.stat_result) -> dict[str, Any]:
    keys = (
        "st_atime",
        "st_ctime",
        "st_gid",
        "st_ino",
        "st_mode",
        "st_mtime",
        "st_nlink",
        "st_size",
        "st_uid",
        "st_dev",
        "st_rdev",
        "st_blksize",
        "st_blocks",
    )
    out: dict[str, Any] = {}
    for k in keys:
        if hasattr(st, k):
            out[k] = getattr(st, k)
    return out


def _norm_rel(path: str) -> str:
    if path in ("/", ""):
        return ""
    p = path.lstrip("/")
    return os.path.normpath(p)


def _parent_base(rel: str) -> tuple[str, str]:
    """Directory-relative parent key (posix) and basename for metadata storage."""
    if rel in ("", "."):
        return "", ""
    rel = os.path.normpath(rel.replace("\\", "/"))
    parent = os.path.dirname(rel)
    if parent == ".":
        parent = ""
    base = os.path.basename(rel)
    return parent, base


class _FifoStub:
    """Single pipe per path; dup reader/writer fds for emulated FIFO on FAT."""

    __slots__ = ("r", "w", "r_n", "w_n")

    def __init__(self) -> None:
        self.r, self.w = os.pipe()
        self.r_n = 0
        self.w_n = 0

    def open_read(self) -> int:
        self.r_n += 1
        return os.dup(self.r)

    def open_write(self) -> int:
        self.w_n += 1
        return os.dup(self.w)

    def release_reader(self) -> None:
        self.r_n -= 1
        if self.r_n <= 0 and self.r >= 0:
            try:
                os.close(self.r)
            except OSError:
                pass
            self.r = -1

    def release_writer(self) -> None:
        self.w_n -= 1
        if self.w_n <= 0 and self.w >= 0:
            try:
                os.close(self.w)
            except OSError:
                pass
            self.w = -1

    def dead(self) -> bool:
        return self.r < 0 and self.w < 0


class FatLinuxMetaFS(fuse.Operations):
    """Passthrough with per-directory JSON sidecar metadata."""

    def __init__(self, backing_root: str, meta_file: str) -> None:
        self.backing_root = os.path.realpath(backing_root)
        self.meta_basename = os.path.basename(meta_file)
        if not self.meta_basename:
            raise ValueError("meta_file must have a non-empty basename")
        self._legacy_meta_path = (
            meta_file if os.path.isabs(meta_file) else os.path.join(self.backing_root, meta_file)
        )
        self._lock = threading.RLock()
        self._dir_cache: dict[str, dict[str, Any]] = {}
        # Per-open file descriptor: original open(2) flags (for O_APPEND, etc.)
        self._fh_flags: dict[int, int] = {}
        # Emulated FIFO (stub mknod): fh -> (rel_path, is_read_end)
        self._fh_fifo: dict[int, tuple[str, bool]] = {}
        self._fifo_stubs: dict[str, _FifoStub] = {}
        self._migrate_legacy_json_if_present()

    def _dir_meta_path(self, parent_rel: str) -> str:
        """Absolute path to the JSON file listing metadata for children of parent_rel."""
        if parent_rel == "":
            return os.path.join(self.backing_root, self.meta_basename)
        return os.path.join(self.backing_root, parent_rel, self.meta_basename)

    def _migrate_legacy_json_if_present(self) -> None:
        """Split monolithic entries{full/relpath: ...} into per-directory JSON files."""
        legacy = self._legacy_meta_path
        if not os.path.isfile(legacy):
            return
        try:
            with open(legacy, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            return
        if not isinstance(data, dict) or "entries" not in data:
            return
        raw_entries = data.get("entries") or {}
        if not isinstance(raw_entries, dict) or not raw_entries:
            return
        needs_migrate = any(
            isinstance(k, str) and ("/" in k or "\\" in k) for k in raw_entries
        )
        if not needs_migrate:
            return
        merged: dict[str, dict[str, Any]] = {}
        for k, v in raw_entries.items():
            if not isinstance(k, str) or not isinstance(v, dict):
                continue
            nk = os.path.normpath(k.replace("\\", "/"))
            parent, base = _parent_base(nk)
            if not base:
                continue
            merged.setdefault(parent, {}).setdefault("entries", {})[base] = v
        migrated = legacy + ".migrated"
        try:
            if os.path.lexists(migrated):
                os.unlink(migrated)
            os.replace(legacy, migrated)
        except OSError:
            return
        for parent, blob in merged.items():
            blob["version"] = META_VERSION
            self._write_dir_meta_file(parent, blob)

    def _write_dir_meta_file(self, parent_rel: str, data: dict[str, Any]) -> None:
        """Persist metadata JSON for one directory (internal; no FUSE checks)."""
        path = self._dir_meta_path(parent_rel)
        entries = data.get("entries") or {}
        if not entries:
            try:
                if os.path.isfile(path):
                    os.unlink(path)
            except OSError:
                pass
            with self._lock:
                self._dir_cache.pop(parent_rel, None)
            return
        data = {"version": META_VERSION, "entries": dict(entries)}
        tmp = path + ".tmp"
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=0, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)
        with self._lock:
            self._dir_cache[parent_rel] = data

    def _load_dir_meta(self, parent_rel: str) -> dict[str, Any]:
        """Load (cached) metadata document for one parent directory."""
        with self._lock:
            if parent_rel in self._dir_cache:
                return self._dir_cache[parent_rel]
        path = self._dir_meta_path(parent_rel)
        if not os.path.isfile(path):
            data: dict[str, Any] = {"version": META_VERSION, "entries": {}}
            with self._lock:
                self._dir_cache[parent_rel] = data
            return data
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict) or "entries" not in data:
                data = {"version": META_VERSION, "entries": {}}
        except (json.JSONDecodeError, OSError):
            data = {"version": META_VERSION, "entries": {}}
        with self._lock:
            self._dir_cache[parent_rel] = data
        return data

    def _invalidate_dir_cache_all(self) -> None:
        with self._lock:
            self._dir_cache.clear()

    def _backing(self, path: str) -> str:
        rel = _norm_rel(path)
        if rel == "":
            return self.backing_root
        return os.path.join(self.backing_root, rel)

    def _chunk_backing_paths(self, rel: str) -> list[str]:
        """Ordered backing paths for a logical file (main + .__part0001 …)."""
        base = os.path.join(self.backing_root, rel)
        paths: list[str] = []
        if os.path.lexists(base):
            paths.append(base)
        i = 1
        while True:
            p = base + _chunk_suffix(i)
            if os.path.lexists(p):
                paths.append(p)
                i += 1
            else:
                break
        return paths if paths else [base]

    def _physical_size(self, rel: str) -> int:
        n = 0
        for p in self._chunk_backing_paths(rel):
            if os.path.isfile(p):
                n += os.path.getsize(p)
        return n

    def _visible_size(self, path: str) -> int:
        """Logical size exposed in stat (sparse tail allowed)."""
        rel = _norm_rel(path)
        phys = self._physical_size(rel)
        ent = self._get_entry(path)
        if ent and ent.get("logical_size") is not None:
            return max(int(ent["logical_size"]), phys)
        return phys

    def _has_multi_chunk(self, rel: str) -> bool:
        base = os.path.join(self.backing_root, rel)
        return os.path.lexists(base + _chunk_suffix(1))

    def _fuse_needs_chunked_io(self, path: str) -> bool:
        if not os.path.isfile(self._backing(path)):
            return False
        rel = _norm_rel(path)
        ent = self._get_entry(path)
        phys = self._physical_size(rel)
        if self._has_multi_chunk(rel):
            return True
        if phys > CHUNK_MAX:
            return True
        if ent and ent.get("logical_size") is not None:
            if int(ent["logical_size"]) != phys:
                return True
        return False

    def _read_physical_span(self, rel: str, offset: int, length: int) -> bytes:
        if length <= 0:
            return b""
        out = bytearray(length)
        walk = 0
        for p in self._chunk_backing_paths(rel):
            if not os.path.isfile(p):
                continue
            sz = os.path.getsize(p)
            chunk_lo = walk
            chunk_hi = walk + sz
            if offset + length <= chunk_lo:
                break
            if offset >= chunk_hi:
                walk = chunk_hi
                continue
            rd_lo = max(offset, chunk_lo)
            rd_hi = min(offset + length, chunk_hi)
            foff = rd_lo - chunk_lo
            flen = rd_hi - rd_lo
            boff = rd_lo - offset
            with open(p, "rb") as f:
                f.seek(foff)
                out[boff : boff + flen] = f.read(flen)
            walk = chunk_hi
        return bytes(out)

    def _read_virtual(self, path: str, size: int, offset: int) -> bytes:
        rel = _norm_rel(path)
        total = self._visible_size(path)
        if offset >= total:
            return b""
        want = min(size, total - offset)
        phys_total = self._physical_size(rel)
        if offset + want <= phys_total:
            return self._read_physical_span(rel, offset, want)
        if offset >= phys_total:
            return bytes(want)
        first = phys_total - offset
        buf = bytearray(want)
        buf[:first] = self._read_physical_span(rel, offset, first)
        return bytes(buf)

    def _append_chunk(self, rel: str) -> str:
        base = os.path.join(self.backing_root, rel)
        paths = self._chunk_backing_paths(rel)
        n = len(paths)
        new_p = base + _chunk_suffix(n)
        open(new_p, "ab").close()
        return new_p

    def _pad_physical_to(self, rel: str, target_pos: int) -> None:
        """Zero-fill from current physical end up to target_pos (exclusive)."""
        phys = self._physical_size(rel)
        if phys >= target_pos:
            return
        gap = target_pos - phys
        base = os.path.join(self.backing_root, rel)
        os.makedirs(os.path.dirname(base), exist_ok=True)
        if not os.path.lexists(base):
            open(base, "ab").close()
        while gap > 0:
            paths = self._chunk_backing_paths(rel)
            last = paths[-1]
            lz = os.path.getsize(last) if os.path.isfile(last) else 0
            if lz >= CHUNK_MAX:
                last = self._append_chunk(rel)
                lz = 0
            take = min(gap, CHUNK_MAX - lz)
            with open(last, "r+b") as f:
                f.seek(lz)
                f.write(b"\x00" * take)
            gap -= take

    def _write_virtual(self, path: str, buf: bytes, offset: int) -> int:
        rel = _norm_rel(path)
        base = os.path.join(self.backing_root, rel)
        os.makedirs(os.path.dirname(base), exist_ok=True)
        if not os.path.lexists(base):
            open(base, "ab").close()
        if not buf:
            return 0
        self._pad_physical_to(rel, offset)
        pos = offset
        i = 0
        n = len(buf)
        while i < n:
            walk = 0
            cur: str | None = None
            inner = 0
            for p in self._chunk_backing_paths(rel):
                sz = os.path.getsize(p) if os.path.isfile(p) else 0
                if pos < walk + sz:
                    cur = p
                    inner = pos - walk
                    break
                walk += sz
            else:
                last = self._chunk_backing_paths(rel)[-1]
                lz = os.path.getsize(last) if os.path.isfile(last) else 0
                if lz < CHUNK_MAX:
                    cur = last
                    inner = lz
                else:
                    cur = self._append_chunk(rel)
                    inner = 0
            if cur is None:
                raise fuse.FuseOSError(errno.EIO)
            room = CHUNK_MAX - inner
            take = min(n - i, room)
            with open(cur, "r+b") as f:
                f.seek(inner)
                f.write(buf[i : i + take])
            i += take
            pos += take
        new_phys = self._physical_size(rel)
        end = offset + n
        ent = self._get_entry(path) or {}
        log = int(ent["logical_size"]) if ent.get("logical_size") is not None else new_phys
        self._set_entry(path, {"logical_size": max(log, end, new_phys)})
        return n

    def _truncate_virtual(self, path: str, length: int) -> None:
        rel = _norm_rel(path)
        phys = self._physical_size(rel)
        if length < phys:
            self._truncate_physical_to(rel, length)
        self._set_entry(path, {"logical_size": length})

    def _truncate_physical_to(self, rel: str, length: int) -> None:
        """Shrink physical chunks so total byte count == length."""
        if length < 0:
            raise fuse.FuseOSError(errno.EINVAL)
        paths = self._chunk_backing_paths(rel)
        if length == 0:
            for p in paths:
                if os.path.lexists(p):
                    os.unlink(p)
            return
        remaining = length
        for i, p in enumerate(paths):
            if not os.path.isfile(p):
                continue
            sz = os.path.getsize(p)
            if remaining > sz:
                remaining -= sz
                continue
            if remaining == sz:
                for q in paths[i + 1 :]:
                    if os.path.lexists(q):
                        os.unlink(q)
                return
            with open(p, "r+b") as f:
                f.truncate(remaining)
            for q in paths[i + 1 :]:
                if os.path.lexists(q):
                    os.unlink(q)
            return

    def _get_entry(self, path: str) -> dict[str, Any] | None:
        rel = _norm_rel(path)
        parent, base = _parent_base(rel)
        if not base:
            return None
        with self._lock:
            data = self._load_dir_meta(parent)
            ent = data.get("entries", {}).get(base)
            return ent if isinstance(ent, dict) else None

    def _set_entry(self, path: str, updates: dict[str, Any]) -> None:
        rel = _norm_rel(path)
        parent, base = _parent_base(rel)
        if not base:
            return
        with self._lock:
            data = self._load_dir_meta(parent)
            cur = data.setdefault("entries", {}).get(base, {})
            if not isinstance(cur, dict):
                cur = {}
            cur = {**cur, **updates}
            data.setdefault("entries", {})[base] = cur
            self._write_dir_meta_file(parent, data)

    def _set_entry_raw(self, path: str, ent: dict[str, Any]) -> None:
        rel = _norm_rel(path)
        parent, base = _parent_base(rel)
        if not base:
            return
        with self._lock:
            data = self._load_dir_meta(parent)
            data.setdefault("entries", {})[base] = dict(ent)
            self._write_dir_meta_file(parent, data)

    def _pop_entry(self, path: str) -> dict[str, Any] | None:
        rel = _norm_rel(path)
        parent, base = _parent_base(rel)
        if not base:
            return None
        with self._lock:
            data = self._load_dir_meta(parent)
            ent = data.get("entries", {}).pop(base, None)
            self._write_dir_meta_file(parent, data)
        return ent if isinstance(ent, dict) else None

    def _del_entry(self, path: str) -> None:
        self._pop_entry(path)

    def _rename_metadata(self, old: str, new: str) -> None:
        """Update metadata after os.rename on backing (file or directory)."""
        old_rel = _norm_rel(old)
        new_rel = _norm_rel(new)
        try:
            st = os.lstat(os.path.join(self.backing_root, new_rel))
        except OSError:
            return
        if stat.S_ISDIR(st.st_mode):
            self._invalidate_dir_cache_all()
            return
        ent = self._pop_entry(old)
        if ent:
            self._set_entry_raw(new, ent)

    def _apply_entry_to_stat(self, path: str, st: os.stat_result) -> dict[str, Any]:
        d = _stat_to_dict(st)
        ent = self._get_entry(path)
        if not ent:
            return d
        if "mode" in ent:
            d["st_mode"] = int(ent["mode"])
        if "uid" in ent:
            d["st_uid"] = int(ent["uid"])
        if "gid" in ent:
            d["st_gid"] = int(ent["gid"])
        if "rdev" in ent:
            d["st_rdev"] = int(ent["rdev"])
        if ent.get("symlink"):
            target = str(ent["symlink"])
            d["st_mode"] = (d.get("st_mode", 0) & ~stat.S_IFMT) | stat.S_IFLNK
            d["st_size"] = len(target.encode("utf-8"))
        if ent.get("special") == "socket":
            d["st_size"] = 0
            d["st_blocks"] = 0
        elif ent.get("special") == "fifo":
            d["st_size"] = 0
            d["st_blocks"] = 0
        if "mtime" in ent:
            d["st_mtime"] = float(ent["mtime"])
        if "atime" in ent:
            d["st_atime"] = float(ent["atime"])
        mode = int(d.get("st_mode", 0))
        rel = _norm_rel(path)
        if not ent.get("symlink") and stat.S_ISREG(mode):
            if ent.get("logical_size") is not None or self._has_multi_chunk(rel):
                vs = self._visible_size(path)
                d["st_size"] = vs
                d["st_blocks"] = (vs + 511) // 512
        return d

    # --- FUSE operations ---

    def _fuse_hide_reserved_path(self, path: str) -> bool:
        """True if path is hidden from FUSE (chunk part file or per-dir metadata JSON)."""
        if path in ("/", ""):
            return False
        b = os.path.basename(path.rstrip("/"))
        if _is_chunk_part_filename(b):
            return True
        if b == self.meta_basename:
            return True
        return False

    def _path_is_symlink_logical(self, path: str) -> bool:
        """True if this path is a symlink in the logical view (metadata or backing lstat)."""
        ent = self._get_entry(path)
        if ent and ent.get("symlink"):
            return True
        full = self._backing(path)
        try:
            return os.path.islink(full)
        except OSError:
            return False

    def _path_is_fifo_emulated(self, path: str) -> bool:
        """True when metadata says FIFO but backing is a regular-file stub (or explicit special=fifo)."""
        ent = self._get_entry(path)
        if not ent:
            return False
        if ent.get("special") == "fifo":
            return True
        m = int(ent.get("mode", 0))
        if not stat.S_ISFIFO(m):
            return False
        full = self._backing(path)
        try:
            st = os.lstat(full)
        except OSError:
            return False
        if os.path.islink(full):
            return False
        # Real FIFO on backing: open the backing node normally.
        return not stat.S_ISFIFO(st.st_mode)

    def _path_is_socket_stub(self, path: str) -> bool:
        ent = self._get_entry(path)
        if not ent:
            return False
        if ent.get("special") == "socket":
            return True
        m = int(ent.get("mode", 0))
        if not stat.S_ISSOCK(m):
            return False
        full = self._backing(path)
        try:
            st = os.lstat(full)
        except OSError:
            return False
        return not stat.S_ISSOCK(st.st_mode)

    def _open_fifo_stub(self, path: str, flags: int) -> int:
        """Open emulated FIFO (pipe pair) for paths stored as stub files on FAT."""
        rel = _norm_rel(path)
        accmode = getattr(os, "O_ACCMODE", 3)
        acc = flags & accmode
        if acc == os.O_RDWR:
            raise fuse.FuseOSError(errno.EINVAL)
        if rel not in self._fifo_stubs:
            self._fifo_stubs[rel] = _FifoStub()
        stub = self._fifo_stubs[rel]
        if acc == os.O_WRONLY:
            fd = stub.open_write()
            self._fh_fifo[fd] = (rel, False)
        else:
            fd = stub.open_read()
            self._fh_fifo[fd] = (rel, True)
        self._fh_flags[fd] = flags
        return fd

    def getattr(self, path: str, fh: Any = None) -> dict[str, Any]:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        full = self._backing(path)
        ent = self._get_entry(path)
        if ent and ent.get("symlink"):
            if not os.path.lexists(full):
                raise fuse.FuseOSError(errno.ENOENT)
            target = str(ent["symlink"])
            now = time.time()
            return {
                "st_atime": float(ent.get("atime", now)),
                "st_ctime": float(ent.get("ctime", now)),
                "st_gid": int(ent.get("gid", 0)),
                "st_ino": hash(_norm_rel(path)) & 0xFFFFFFFF,
                "st_mode": stat.S_IFLNK | int(ent.get("mode", 0o777) & 0o777),
                "st_mtime": float(ent.get("mtime", now)),
                "st_nlink": 1,
                "st_size": len(target.encode("utf-8")),
                "st_uid": int(ent.get("uid", 0)),
                "st_dev": 0,
                "st_blksize": 512,
                "st_blocks": 0,
                "st_rdev": 0,
            }
        if not os.path.lexists(full):
            raise fuse.FuseOSError(errno.ENOENT)
        st = os.lstat(full)
        d = self._apply_entry_to_stat(path, st)
        rel = _norm_rel(path)
        ent = self._get_entry(path)
        if (
            ent is None
            and stat.S_ISREG(st.st_mode)
            and (self._has_multi_chunk(rel) or self._physical_size(rel) > CHUNK_MAX)
        ):
            vs = self._visible_size(path)
            d["st_size"] = vs
            d["st_blocks"] = (vs + 511) // 512
        return d

    def readdir(self, path: str, fh: Any) -> list[str]:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        full = self._backing(path)
        if not os.path.isdir(full):
            raise fuse.FuseOSError(errno.ENOTDIR)
        names = [
            n
            for n in os.listdir(full)
            if not _is_chunk_part_filename(n) and n != self.meta_basename
        ]
        return [".", "..", *names]

    def readlink(self, path: str) -> str:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        ent = self._get_entry(path)
        if ent and ent.get("symlink"):
            return str(ent["symlink"])
        full = self._backing(path)
        if not os.path.islink(full):
            raise fuse.FuseOSError(errno.EINVAL)
        target = os.readlink(full)
        if isinstance(target, bytes):
            return os.fsdecode(target)
        return target

    def open(self, path: str, flags: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        full = self._backing(path)
        if self._path_is_symlink_logical(path):
            nofollow = getattr(os, "O_NOFOLLOW", 0)
            opath = getattr(os, "O_PATH", 0)
            if nofollow and (flags & nofollow):
                fd = os.open(full, flags)
                self._fh_flags[fd] = flags
                return fd
            if opath and (flags & opath) == opath:
                fd = os.open(full, flags)
                self._fh_flags[fd] = flags
                return fd
            raise fuse.FuseOSError(errno.ELOOP)
        if self._path_is_socket_stub(path):
            raise fuse.FuseOSError(getattr(errno, "ENOTSUP", errno.EOPNOTSUPP))
        if self._path_is_fifo_emulated(path):
            return self._open_fifo_stub(path, flags)
        fd = os.open(full, flags)
        self._fh_flags[fd] = flags
        return fd

    def create(self, path: str, mode: int, fi: Any = None) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.EPERM)
        full = self._backing(path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        cflags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
        fd = os.open(full, cflags, mode & 0o777)
        self._fh_flags[fd] = cflags
        u = os.geteuid()
        g = os.getegid()
        self._set_entry(
            path,
            {
                "mode": stat.S_IFREG | (mode & 0o777),
                "uid": u,
                "gid": g,
            },
        )
        return fd

    def read(self, path: str, size: int, offset: int, fh: int) -> bytes:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        if fh in self._fh_fifo:
            return os.read(fh, size)
        if self._path_is_symlink_logical(path):
            raise fuse.FuseOSError(errno.EINVAL)
        if self._fuse_needs_chunked_io(path):
            return self._read_virtual(path, size, offset)
        os.lseek(fh, offset, os.SEEK_SET)
        return os.read(fh, size)

    def write(self, path: str, buf: bytes, offset: int, fh: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        if fh in self._fh_fifo:
            return os.write(fh, buf)
        if self._path_is_symlink_logical(path):
            raise fuse.FuseOSError(errno.EINVAL)
        rel = _norm_rel(path)
        oapp = getattr(os, "O_APPEND", 0)
        appending = bool(self._fh_flags.get(fh, 0) & oapp)
        need_chunk = (
            self._fuse_needs_chunked_io(path)
            or offset + len(buf) > CHUNK_MAX
            or self._physical_size(rel) >= CHUNK_MAX
        )
        if need_chunk:
            off = self._visible_size(path) if appending else offset
            return self._write_virtual(path, buf, off)
        if appending:
            os.lseek(fh, 0, os.SEEK_END)
        else:
            os.lseek(fh, offset, os.SEEK_SET)
        return os.write(fh, buf)

    def truncate(self, path: str, length: int, fh: int | None = None) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        if fh is not None and fh in self._fh_fifo:
            raise fuse.FuseOSError(errno.EINVAL)
        if self._path_is_fifo_emulated(path) or self._path_is_socket_stub(path):
            raise fuse.FuseOSError(errno.EINVAL)
        if self._path_is_symlink_logical(path):
            raise fuse.FuseOSError(errno.EINVAL)
        if self._fuse_needs_chunked_io(path) or length > CHUNK_MAX:
            self._truncate_virtual(path, length)
            return 0
        if fh is not None:
            os.ftruncate(fh, length)
        else:
            os.truncate(self._backing(path), length)
        ent = self._get_entry(path) or {}
        if ent.get("logical_size") is not None:
            self._set_entry(path, {"logical_size": length})
        return 0

    def flush(self, path: str, fh: int) -> int:
        return 0

    def release(self, path: str, fh: int) -> int:
        self._fh_flags.pop(fh, None)
        if fh in self._fh_fifo:
            rel, is_read = self._fh_fifo.pop(fh)
            stub = self._fifo_stubs.get(rel)
            if stub is not None:
                if is_read:
                    stub.release_reader()
                else:
                    stub.release_writer()
                if stub.dead():
                    del self._fifo_stubs[rel]
            os.close(fh)
            return 0
        os.close(fh)
        return 0

    def fsync(self, path: str, datasync: bool, fh: int) -> int:
        try:
            os.fsync(fh)
        except OSError as e:
            raise fuse.FuseOSError(e.errno)
        return 0

    def fsyncdir(self, path: str, datasync: bool, fh: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        try:
            os.fsync(fh)
        except OSError as e:
            raise fuse.FuseOSError(e.errno)
        return 0

    def fallocate(self, path: str, mode: int, offset: int, length: int, fh: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        if fh in self._fh_fifo or self._path_is_socket_stub(path):
            raise fuse.FuseOSError(errno.EINVAL)
        if self._path_is_symlink_logical(path):
            raise fuse.FuseOSError(errno.EINVAL)
        if mode != 0:
            raise fuse.FuseOSError(errno.EOPNOTSUPP)
        if self._fuse_needs_chunked_io(path):
            raise fuse.FuseOSError(errno.EOPNOTSUPP)
        if not hasattr(os, "posix_fallocate"):
            raise fuse.FuseOSError(errno.EOPNOTSUPP)
        try:
            os.posix_fallocate(fh, offset, length)
        except OSError as e:
            if e.errno in (errno.EOPNOTSUPP, errno.ENOTSUP):
                raise fuse.FuseOSError(errno.EOPNOTSUPP)
            raise fuse.FuseOSError(e.errno)
        return 0

    def lock(self, path: str, fh: int, cmd: int, lock) -> int:
        try:
            return fcntl.fcntl(fh, cmd, lock)
        except OSError as e:
            raise fuse.FuseOSError(e.errno)

    def copy_file_range(
        self,
        path_in: str,
        fh_in: int,
        path_out: str,
        fh_out: int,
        offset_in: int,
        offset_out: int,
        length: int,
        flags: int = 0,
    ) -> int:
        if self._fuse_hide_reserved_path(path_in) or self._fuse_hide_reserved_path(path_out):
            raise fuse.FuseOSError(errno.ENOENT)
        if fh_in in self._fh_fifo or fh_out in self._fh_fifo:
            raise fuse.FuseOSError(errno.EINVAL)

        def _manual() -> int:
            total = 0
            buf = bytearray(min(1024 * 1024, length) if length > 0 else 1)
            while total < length:
                chunk = min(len(buf), length - total)
                os.lseek(fh_in, offset_in + total, os.SEEK_SET)
                got = os.read(fh_in, buf[:chunk])
                if not got:
                    break
                os.lseek(fh_out, offset_out + total, os.SEEK_SET)
                m = 0
                while m < len(got):
                    w = os.write(fh_out, got[m:])
                    if w == 0:
                        raise OSError(errno.EIO, "short write in copy_file_range fallback")
                    m += w
                total += len(got)
            return total

        if not hasattr(os, "copy_file_range"):
            try:
                return _manual()
            except OSError as e:
                raise fuse.FuseOSError(e.errno)
        try:
            try:
                return int(os.copy_file_range(fh_in, fh_out, length, offset_in, offset_out, flags))
            except TypeError:
                return int(os.copy_file_range(fh_in, fh_out, length, offset_in, offset_out))
        except OSError as e:
            if e.errno in (errno.EOPNOTSUPP, errno.EXDEV, errno.ENOSYS):
                try:
                    return _manual()
                except OSError as e2:
                    raise fuse.FuseOSError(e2.errno)
            raise fuse.FuseOSError(e.errno)

    def mkdir(self, path: str, mode: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.EPERM)
        full = self._backing(path)
        os.mkdir(full, mode & 0o777)
        u = os.geteuid()
        g = os.getegid()
        self._set_entry(
            path,
            {"mode": stat.S_IFDIR | (mode & 0o777), "uid": u, "gid": g},
        )
        return 0

    def rmdir(self, path: str) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        os.rmdir(self._backing(path))
        self._del_entry(path)
        return 0

    def unlink(self, path: str) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        rel = _norm_rel(path)
        if not any(r == rel for r, _ in self._fh_fifo.values()):
            self._fifo_stubs.pop(rel, None)
        self._truncate_physical_to(rel, 0)
        self._del_entry(path)
        return 0

    def _rename_chunk_files(self, old_rel: str, new_rel: str) -> None:
        old_base = os.path.join(self.backing_root, old_rel)
        new_base = os.path.join(self.backing_root, new_rel)
        os.makedirs(os.path.dirname(new_base), exist_ok=True)
        for p in self._chunk_backing_paths(old_rel):
            if not os.path.lexists(p):
                continue
            suffix = p[len(old_base) :] if p.startswith(old_base) else ""
            dest = new_base + suffix
            os.rename(p, dest)

    def rename(self, old: str, new: str, *rest: Any) -> int:
        flags = int(rest[0]) if rest else 0
        if flags & RENAME_EXCHANGE:
            raise fuse.FuseOSError(errno.EOPNOTSUPP)
        if self._fuse_hide_reserved_path(old) or self._fuse_hide_reserved_path(new):
            raise fuse.FuseOSError(errno.EPERM)
        old_rel = _norm_rel(old)
        new_rel = _norm_rel(new)
        new_full = self._backing(new)
        if flags & RENAME_NOREPLACE and os.path.lexists(new_full):
            raise fuse.FuseOSError(errno.EEXIST)
        self._rename_chunk_files(old_rel, new_rel)
        self._rename_metadata(old, new)
        if old_rel in self._fifo_stubs:
            self._fifo_stubs[new_rel] = self._fifo_stubs.pop(old_rel)
        for fhd, (rel, is_read) in list(self._fh_fifo.items()):
            if rel == old_rel:
                self._fh_fifo[fhd] = (new_rel, is_read)
        return 0

    def chmod(self, path: str, mode: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        full = self._backing(path)
        ent = self._get_entry(path) or {}
        cur_mode = ent.get("mode")
        if cur_mode is None and os.path.lexists(full):
            cur_mode = os.lstat(full).st_mode
        else:
            cur_mode = cur_mode or stat.S_IFREG | 0o644
        new_mode = (int(cur_mode) & stat.S_IFMT) | (mode & 0o777)
        self._set_entry(path, {"mode": new_mode})
        try:
            os.chmod(full, mode & 0o777, follow_symlinks=False)
        except TypeError:
            try:
                os.chmod(full, mode & 0o777)
            except OSError:
                pass
        except OSError:
            pass
        return 0

    def chown(self, path: str, uid: int, gid: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        upd: dict[str, Any] = {}
        if uid != -1:
            upd["uid"] = uid
        if gid != -1:
            upd["gid"] = gid
        self._set_entry(path, upd)
        try:
            os.chown(self._backing(path), uid, gid, follow_symlinks=False)
        except OSError:
            pass
        return 0

    def symlink(self, target: str, source: str) -> int:
        # Symlink path is target; points to source (ln -s source target)
        if self._fuse_hide_reserved_path(target):
            raise fuse.FuseOSError(errno.EPERM)
        full = self._backing(target)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        try:
            os.symlink(source, full)
        except OSError:
            # FAT and similar: store target in metadata + opaque stub bytes on disk.
            with open(full, "wb") as f:
                f.write(b"LNK\x00" + os.fsencode(source))
        u = os.geteuid()
        g = os.getegid()
        self._set_entry(
            target,
            {
                "symlink": source,
                "mode": stat.S_IFLNK | 0o777,
                "uid": u,
                "gid": g,
            },
        )
        return 0

    def link(self, target: str, source: str) -> int:
        # Hard link: ln source target  →  new name is target, existing file is source
        if self._fuse_hide_reserved_path(target) or self._fuse_hide_reserved_path(source):
            raise fuse.FuseOSError(errno.EPERM)
        os.link(self._backing(source), self._backing(target))
        st = os.lstat(self._backing(target))
        self._set_entry(
            target,
            {
                "mode": st.st_mode,
                "uid": st.st_uid,
                "gid": st.st_gid,
            },
        )
        return 0

    def mknod(self, path: str, mode: int, dev: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.EPERM)
        full = self._backing(path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        kind = stat.S_IFMT(mode)
        u = os.geteuid()
        g = os.getegid()
        meta: dict[str, Any] = {"mode": mode, "uid": u, "gid": g, "rdev": dev}

        if kind == stat.S_IFIFO:
            try:
                os.mkfifo(full)
                self._set_entry(path, meta)
                return 0
            except OSError:
                open(full, "ab").close()
                meta["special"] = "fifo"
                self._set_entry(path, meta)
                return 0

        if kind == stat.S_IFSOCK:
            try:
                os.mknod(full, mode, dev)
                self._set_entry(path, meta)
                return 0
            except OSError:
                open(full, "ab").close()
            meta["special"] = "socket"
            self._set_entry(path, meta)
            return 0

        try:
            os.mknod(full, mode, dev)
        except OSError:
            open(full, "ab").close()
        self._set_entry(path, meta)
        return 0

    def utimens(self, path: str, times: tuple[int | float, int | float] | None) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        full = self._backing(path)
        if times is None:
            at_s = mt_s = time.time()
        else:
            at, mt = times
            at_s = float(at)
            mt_s = float(mt)
        try:
            os.utime(full, ns=(at_s, mt_s), follow_symlinks=False)
        except TypeError:
            try:
                os.utime(full, ns=(at_s, mt_s))
            except OSError:
                pass
        except OSError:
            pass
        self._set_entry(path, {"atime": at_s, "mtime": mt_s})
        return 0

    def statfs(self, path: str) -> dict[str, int]:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        stv = os.statvfs(self._backing(path))
        return {
            "f_bavail": stv.f_bavail,
            "f_bfree": stv.f_bfree,
            "f_blocks": stv.f_blocks,
            "f_bsize": stv.f_bsize,
            "f_favail": getattr(stv, "f_favail", 0),
            "f_ffree": stv.f_ffree,
            "f_files": stv.f_files,
            "f_flag": getattr(stv, "f_flag", 0),
            "f_frsize": stv.f_frsize,
            "f_namemax": stv.f_namemax,
        }

    def access(self, path: str, amode: int) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        if not os.access(self._backing(path), amode, follow_symlinks=False):
            raise fuse.FuseOSError(errno.EACCES)
        return 0

    # --- xattrs (stored in metadata; no kernel xattr support on FAT) ---

    def getxattr(self, path: str, name: str, position: int = 0) -> bytes:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        ent = self._get_entry(path)
        if not ent:
            raise fuse.FuseOSError(errno.ENODATA)
        xattrs = ent.get("xattrs") or {}
        if name not in xattrs:
            raise fuse.FuseOSError(errno.ENODATA)
        v = xattrs[name]
        if isinstance(v, str):
            return v.encode("utf-8")
        return bytes(v)

    def setxattr(self, path: str, name: str, value: bytes, options: int, position: int = 0) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        ent = self._get_entry(path) or {}
        xattrs = dict(ent.get("xattrs") or {})
        xattrs[name] = value.decode("utf-8", errors="surrogateescape")
        self._set_entry(path, {"xattrs": xattrs})
        return 0

    def listxattr(self, path: str) -> list[str]:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        ent = self._get_entry(path)
        if not ent:
            return []
        xattrs = ent.get("xattrs") or {}
        return sorted(xattrs.keys())

    def removexattr(self, path: str, name: str) -> int:
        if self._fuse_hide_reserved_path(path):
            raise fuse.FuseOSError(errno.ENOENT)
        ent = self._get_entry(path)
        if not ent:
            raise fuse.FuseOSError(errno.ENODATA)
        xattrs = dict(ent.get("xattrs") or {})
        if name not in xattrs:
            raise fuse.FuseOSError(errno.ENODATA)
        del xattrs[name]
        self._set_entry(path, {"xattrs": xattrs})
        return 0


def main() -> None:
    p = argparse.ArgumentParser(
        description="FUSE passthrough with per-directory Linux metadata JSON sidecars (for FAT backends)."
    )
    p.add_argument("backing", help="Directory where the FAT filesystem is mounted (backing store)")
    p.add_argument("mountpoint", help="FUSE mount point")
    p.add_argument(
        "--meta-file",
        default=".linux-meta.json",
        help="Metadata filename inside backing dir (or absolute path) [default: .linux-meta.json]",
    )
    p.add_argument(
        "-f",
        "--foreground",
        action="store_true",
        help="Run in foreground (log to terminal; default is background daemon)",
    )
    p.add_argument(
        "--allow-other",
        action="store_true",
        help="Allow other users to access the mount (needs user_allow_other in fuse.conf)",
    )
    args = p.parse_args()

    if not os.path.isdir(args.backing):
        raise SystemExit(f"backing is not a directory: {args.backing}")

    fs = FatLinuxMetaFS(args.backing, args.meta_file)
    fuse.FUSE(
        fs,
        args.mountpoint,
        foreground=args.foreground,
        allow_other=args.allow_other,
        nothreads=True,
    )


if __main__ == "__main__":
    main()
