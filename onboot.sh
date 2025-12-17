#!/bin/bash
mount /cdrom/ -o remount,rw
#mount /cdrom/home.btrfs /home/ -t btrfs -o relatime,compress=zstd:3
#mount -t btrfs -o loop,relatime,compress=zstd:3 /cdrom/home.btrfs /rofs/home

mount / -o remount

#mkdir /tmp/cache; sudo mount --bind /tmp/cache /home/mint/.cache
#cd /cdrom
#cp 90-NM* /etc/netplan

#Stop remove boot installation hardware prompt.
sudo touch /run/casper-no-prompt

mkdir -p /media/mint/Games
mkdir -p /media/mint/Windows
mount -o ro /dev/nvme1n1p2 /media/mint/Games
mount -o ro /dev/nvme0n1p3 /media/mint/Windows

mkdir -p /tmp/steam ; cd /tmp/steam/ && mkdir upper && mkdir work && mkdir root
mkdir -p /tmp/steam2 ; cd /tmp/steam2/ && mkdir upper && mkdir work && mkdir root
mkdir -p /tmp/home/lower ; cd /tmp/home && mkdir upper && mkdir work && mkdir root

mount /cdrom/home.sfs /tmp/home/lower
mount -t overlay overlay -olowerdir=/tmp/home/lower/,upperdir=/tmp/home/upper,workdir=/tmp/home/work /home
mount -t overlay overlay -olowerdir=/media/mint/Games/SteamLibrary/,upperdir=/tmp/steam/upper,workdir=/tmp/steam/work /tmp/steam/root
mount -t overlay overlay -olowerdir='/media/mint/Windows/Program Files (x86)/Steam',upperdir=/tmp/steam2/upper,workdir=/tmp/steam2/work /tmp/steam2/root

chown mint /tmp/steam/root
chown mint /tmp/steam2/root

until bash /cdrom/wifi.sh
do
	sleep 1
done
echo FINISHED

#Stop Systemd breaking mounts.
while true; do sleep 99999; done



