#!/bin/sh
# lsl-f2fs-tools.sh - put casper's initrd tools on PATH before the hook needs them.
#
# The tools (sfdisk, fatresize, mkfs.f2fs and fatresize's library closure) are
# cpio MEMBERS OF THIS INITRAMFS, not a payload to unpack. The kernel has
# already put them on the root filesystem by the time any hook runs - that is
# what initramfs unpacking is - so there is nothing to extract here.
#
# WHY THERE IS NO UNPACKING STEP (measured on the real Mint 22.3 initrd):
# casper's initrd ships `gzip` and `cpio` but NO `tar`, and its busybox has no
# `untar` applet. An earlier version carried a gzipped tarball and tried
# `tar -xzf`; a QEMU boot logged `tar: not found` and skipped the whole feature.
# So the files are members at their final paths instead.
#
# All this script has to do is export the two variables that make them
# findable: PATH for the executables, LD_LIBRARY_PATH for fatresize's libs
# (casper's initrd has libc/libm/libselinux/libdevmapper but NOT libparted,
# libblkid, libuuid, libcap, libpcre2 or libparted-fs-resize).
#
# Contract, same as every hook in initramfs/: safe to source, never a bare
# `exit`, and any problem degrades to "no provisioning this boot".
set +e

lsl_tools_dbg() {
    echo "lsl-f2fs-tools: $*" > /dev/console 2>/dev/null || echo "lsl-f2fs-tools: $*" >&2
    return 0
}

# The staging directories are baked in at build time (build.sh and
# lslfiles.rs both write LSL_F2FS_TOOLS_* into the copy of this script), so the
# defaults here are only a fallback for a hand-copied script.
: "${LSL_F2FS_TOOLS_DIR:=/usr/lib/lsl-f2fs}"

# Find where the tools actually landed. They are cpio members of this initramfs,
# so the kernel has already put them at their final paths - both sbin/ and the
# library dir - before any hook runs.
LSL_F2FS_TOOLS_BIN=""
LSL_F2FS_TOOLS_DIR=""
for _lsl_bin in /usr/sbin /sbin /usr/bin /bin; do
    if [ -x "$_lsl_bin/mkfs.f2fs" ]; then
        LSL_F2FS_TOOLS_BIN="$_lsl_bin"
        break
    fi
done
for _lsl_lib in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /lib/x86_64-linux-gnu /lib64 /lib; do
    if [ -e "$_lsl_lib/libuuid.so.1" ] || [ -e "$_lsl_lib/libparted.so.2" ]; then
        LSL_F2FS_TOOLS_DIR="$_lsl_lib"
        break
    fi
done

# BOTH /usr/sbin and /usr/bin go on PATH: mkfs.f2fs and fatresize land in
# sbin, but `od` lands in bin (it is a general utility, not a system tool), and
# the hook needs all three. Adding only one directory produces tools that exist
# on the initrd but are never found - which is indistinguishable from a missing
# tool.
PATH="$LSL_F2FS_TOOLS_BIN:$LSL_F2FS_TOOLS_DIR:/usr/bin:/usr/sbin:$PATH"
export PATH
LD_LIBRARY_PATH="$LSL_F2FS_TOOLS_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

# Report every tool the hook will call, so a missing one is named rather than
# discovered later as an unexplained refusal.
for _lsl_need in mkfs.f2fs fatresize od; do
    command -v "$_lsl_need" >/dev/null 2>&1 \
        || lsl_tools_dbg "WARNING: $_lsl_need is NOT on PATH - the F2FS path will stop here"
done
if command -v mkfs.f2fs >/dev/null 2>&1 && command -v fatresize >/dev/null 2>&1; then
    lsl_tools_dbg "tools ready (PATH=$LSL_F2FS_TOOLS_BIN, LD_LIBRARY_PATH=$LSL_F2FS_TOOLS_DIR)"
elif command -v mkfs.f2fs >/dev/null 2>&1; then
    lsl_tools_dbg "mkfs.f2fs found but fatresize missing - cannot shrink FAT; provisioning skipped"
else
    lsl_tools_dbg "no F2FS tools on PATH - provisioning will be skipped this boot"
fi
return 0 2>/dev/null || exit 0