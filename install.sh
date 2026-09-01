#!/bin/bash
#mkdir -p work; mkdir -p upper; mkdir -p root
#mount -t overlay overlay -o upperdir=/tmp/squashfs/

mount /cdrom -o remount,rw

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
"$REPO_ROOT/bin/config.sh" --sync-only

#cp ./lsl /cdrom/bin/lsl

cd /home/ && mksquashfs . /cdrom/home.sfs -comp zstd

mkdir -p /tmp/squashfs/upper/ /tmp/squashfs/work/ /tmp/squashfs/root/
mount -t overlay overlay -o upperdir=/tmp/squashfs/upper/,lowerdir=/rofs,workdir=/tmp/squashfs/work/ /tmp/squashfs/root/
#apt complains if proc is not mounted... but it complains worse if it is. Why?
#mount --bind /proc/ /tmp/squashfs/root/proc
#mount --bind /dev /tmp/squashfs/root/dev
#mount --bind /sys /tmp/squashfs/root/sys
mount --bind /var/cache/apt/archives/ /tmp/squashfs/root/var/cache/apt/archives/
cp /etc/resolv.conf /tmp/squashfs/root/etc/resolv.conf

LSL_CONFIG_ROOT=/tmp/squashfs/root "$REPO_ROOT/bin/config.sh" --systemd-only

"$REPO_ROOT/bin/mount_all.sh" &&
    DATA_DIR="${LSL_DATA_DIR:-/mnt/c/Users/lsl-usb}" &&
    mkdir -p "$DATA_DIR" &&
    if [ ! -f /cdrom/find_everything.efu ]; then
        # No Windows-side Everything index (EFU) - index each mounted drive for
        # `lsl --choose` (find catalogs). With an EFU, lsl reads that instead.
        for f in /mnt/*; do
            [ -d "$f" ] || continue
            name="$(basename "$f")"
            ( time find "$f" -xdev -not -path "$DATA_DIR/*" 2>/dev/null | zstd -19 > "$DATA_DIR/find_${name}.zstd" ) &
        done
    fi



# mount_all.sh expects hivexregedit, fdisk, xxd (packages: libhivex-bin or hivex-tools, fdisk, xxd).
#"$REPO_ROOT/bin/mount_all.sh" &&
#cat <<EOF | chroot /tmp/squashfs/root/
if ! cat bin/squashfs_config.sh | chroot /tmp/squashfs/root/; then
    echo "squashfs_config.sh failed inside the chroot; aborting." >&2
    exit 1
fi

#By default, add a new squashfs layer rather than replacing filesystem.squashfs.
#Naming: sort LAST in /cdrom/casper/*.squashfs so casper's reverse-order logic
#gives it HIGHEST precedence (first in lowerdir=...).
#Set LSL_INSTALL_MERGE=1 to rebuild filesystem.squashfs instead (old behavior).
ts="$(date +%Y%m%d%H%M%S)"
if [ "${LSL_INSTALL_MERGE:-0}" = "1" ]; then
    #Create new filesystem.squashfs and move old one to filesystem_<date>.squashfs
    mksquashfs /tmp/squashfs/root/ /cdrom/casper/filesystem_new.squashfs -comp zstd -Xcompression-level 22
    mv /cdrom/casper/filesystem.squashfs /cdrom/casper/filesystem_orig.squashfs
    mv /cdrom/casper/filesystem_new.squashfs /cdrom/casper/filesystem.squashfs
else
    #Append a layer from the overlay upperdir (only the changes).
    mksquashfs /tmp/squashfs/upper/ /cdrom/casper/filesystem_z${ts}.squashfs -comp zstd -Xcompression-level 22
    #Save a companion copy of the config script next to the layer (same basename as .squashfs).
    cp "$REPO_ROOT/bin/squashfs_config.sh" /cdrom/casper/filesystem_z${ts}.sh
fi

# Save the active wifi connection for the next boot (wifi.sh). Only write it
# when there is an active SSID; open networks get no password argument.
SSID="$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2)"
if [ -n "$SSID" ]; then
    PASSWORD="$(nmcli -s -g 802-11-wireless-security.psk connection show "$SSID" 2>/dev/null || true)"
    echo "SSID: $SSID"
    if [ -n "$PASSWORD" ]; then
        printf "nmcli device wifi connect %q password %q\n" "$SSID" "$PASSWORD" > /cdrom/wifi.sh
    else
        printf "nmcli device wifi connect %q\n" "$SSID" > /cdrom/wifi.sh
    fi
    chmod +x /cdrom/wifi.sh
    echo "wifi.sh written."
else
    echo "No active wifi connection; skipping wifi.sh." >&2
fi

#mount | grep tmp/squash | cut -f3 -d\  | while read d; do umount $d; done

#if [ -e /cdrom/casper/filesystem_new.squashfs
