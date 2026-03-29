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

cat <<EOF | chroot /tmp/squashfs/root/

apt update
apt upgrade -y
apt install -y btrfs-progs guestmount neovim nix-bin git steam-installer zenity libhivex-bin chntpw guestfish kexec-tools
#curl -fsS https://dl.brave.com/install.sh | sh

EOF

#Create new filesystem.squashfs and move old one to filesystem_<date>.squashfs
mksquashfs /tmp/squashfs/root/ /cdrom/casper/filesystem_new.squashfs -comp zstd -Xcompression-level 22
#mv /cdrom/casper/filesystem.squashfs /cdrom/casper/filesystem_`date +%Y%m%d%H%M%S`.squashfs
mv /cdrom/casper/filesystem.squashfs /cdrom/casper/filesystem_orig.squashfs
mv /cdrom/casper/filesystem_new.squashfs /cdrom/casper/filesystem.squashfs

#save SSID from nmcli
SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
#PASSWORD=$(nmcli -s -g 802-11-wireless-security.psk connection show "$SSID" 2>/dev/null)
PASSWORD=$(nmcli device wifi show-password | grep ^Password: | sed s/^Password:\ //)

echo "SSID: $SSID"
echo "PASSWORD: $PASSWORD"

echo "nmcli device wifi connect '$SSID' password '$PASSWORD'" > /cdrom/wifi.sh
chmod +x /cdrom/wifi.sh

#mount | grep tmp/squash | cut -f3 -d\  | while read d; do umount $d; done

#if [ -e /cdrom/casper/filesystem_new.squashfs
