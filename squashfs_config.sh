
apt update
apt upgrade -y
apt install -y btrfs-progs guestmount neovim nix-bin git steam-installer zenity libhivex-bin chntpw guestfish kexec-tools kitty pv tmux libwin-hivex-perl fdisk xxd asciinema
#curl -fsS https://dl.brave.com/install.sh | sh
#Install WezTerm. Good looking terminal that supports Windows Style Cut and Paste.
curl -fsSL https://apt.fury.io/wez/gpg.key | gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' | tee /etc/apt/sources.list.d/wezterm.list
#NOTE: do not use sudo inside the chroot!
apt update
apt install wezterm

#Install modern a browser
# Might be better to install in a WSL vhdx?
curl -fsS https://dl.brave.com/install.sh | sh
