#mkdir -p work; mkdir -p upper; mkdir -p root
#mount -t overlay overlay -o upperdir=/tmp/squashfs/

mount /cdrom -o remount,rw

mkdir -p /cdrom/bin
cp bin/* /cdrom/bin/
#cp ./lsl /cdrom/bin/lsl

# Create desktop shortcut for lsl-gui
mkdir -p /home/mint/Desktop
chown mint:mint /home/mint/Desktop
cat <<EOF > /home/mint/Desktop/lsl-gui.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=lsl-gui
Comment=Launch WSL Distribution (GUI)
Exec=/cdrom/bin/lsl-gui
Icon=terminal
Terminal=false
Categories=System;Utility;
EOF
chmod +x /home/mint/Desktop/lsl-gui.desktop
chown mint:mint /home/mint/Desktop/lsl-gui.desktop

cd /home/ && mksquashfs . /cdrom/home.sfs -comp zstd

mkdir -p /tmp/squashfs/upper/ /tmp/squashfs/work/ /tmp/squashfs/root/
mount -t overlay overlay -o upperdir=/tmp/squashfs/upper/,lowerdir=/rofs,workdir=/tmp/squashfs/work/ /tmp/squashfs/root/
#mount --bind /proc/ /tmp/squashfs/root/proc
#mount --bind /dev /tmp/squashfs/root/dev
#mount --bind /sys /tmp/squashfs/root/sys
mount --bind /var/cache/apt/archives/ /tmp/squashfs/root/var/cache/apt/archives/
cp /etc/resolv.conf /tmp/squashfs/root/etc/resolv.conf



cat <<EOF | chroot /tmp/squashfs/root/

cat <<ONBOOT > /etc/systemd/system/onboot.service
[Unit]
Description=On Boot
After=network-online.target

[Service]
ExecStart=/cdrom/onboot.sh

[Install]
WantedBy=multi-user.target
ONBOOT

systemctl daemon-reload
systemctl enable onboot

apt update
apt upgrade -y
apt install -y guestmount neovim nix-bin git steam-installer zenity
#curl -fsS https://dl.brave.com/install.sh | sh

if ! grep -q '/cdrom/bin' /etc/bash.bashrc; then
    echo 'export PATH="/cdrom/bin:$PATH"' >> /etc/bash.bashrc
fi
EOF

#Create new filesystem.squashfs and move old one to filesystem_<date>.squashfs
mksquashfs /tmp/squashfs/root/ /cdrom/casper/filesystem.squashfs -comp zstd -Xcompression-level 22
#mv /cdrom/casper/filesystem.squashfs /cdrom/casper/filesystem_`date +%Y%m%d%H%M%S`.squashfs
mv /cdrom/casper/filesystem.squashfs /cdrom/casper/filesystem_orig.squashfs
mv /cdrom/casper/filesystem_new.squashfs /cdrom/casper/filesystem.squashfs

#mount | grep tmp/squash | cut -f3 -d\  | while read d; do umount $d; done

#if [ -e /cdrom/casper/filesystem_new.squashfs
