#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# debian/common/setup.sh - the tablet settings every card gets, whatever
# the desktop. Runs INSIDE the new Debian (chroot), started by
# tools/build_debian.sh, before the desktop's own setup.sh.
#
# Input, from the build, in /root/p25t-build/ (removed afterwards):
#   answers       shell variables: P25T_USER, P25T_HOST, P25T_TZ,
#                 P25T_LANG, P25T_XKBLAYOUT, P25T_XKBVARIANT,
#                 P25T_XKBOPTIONS (what the user answered)
#   common/files/ 61-p25t-sensor.hwdb, asound.state, cam-snap.sh,
#                 raw2png.py, set-dtb.sh
#   authorized_keys  only if the user gave an SSH public key
# Passwords and the Wi-Fi network are not handled here: build_debian.sh
# sets them at the end, without writing them to any file but the card's.
# No service is started here (chroot): units are only enabled.
set -euo pipefail
B=/root/p25t-build
F=$B/common/files
# shellcheck source=/dev/null
. "$B/answers"
U=$P25T_USER

echo "--- host name: $P25T_HOST"
echo "$P25T_HOST" > /etc/hostname
cat > /etc/hosts <<EOT
127.0.0.1	localhost
127.0.1.1	$P25T_HOST
::1		localhost ip6-localhost ip6-loopback
EOT

echo "--- fstab: the card's partitions, by label"
mkdir -p /boot/firmware
cat > /etc/fstab <<'EOT'
# Teclast P25T - SD card
LABEL=p25troot  /               ext4  defaults,noatime,errors=remount-ro  0 1
LABEL=P25TBOOT  /boot/firmware  vfat  defaults,noatime,nofail,flush        0 2
EOT

echo "--- apt: Debian's own mirror network, no Recommends"
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<'EOT'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT
cat > /etc/apt/apt.conf.d/90-p25t-no-recommends <<'EOT'
// P25T: install only real dependencies, to keep the card small and to
// avoid surprises (on the first card a mail server came in through the
// Recommends of an editor). A program that needs one of its Recommends
// gets it listed explicitly (see debian/*/under_test.txt).
APT::Install-Recommends "false";
EOT

echo "--- user $U (groups: sudo, video, render, input, audio, ...)"
id "$U" > /dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm,video,render,input,plugdev,dialout,audio "$U"
passwd -l root > /dev/null
H=$(getent passwd "$U" | cut -d: -f6)

echo "--- time zone: $P25T_TZ"
ln -sf "/usr/share/zoneinfo/$P25T_TZ" /etc/localtime
echo "$P25T_TZ" > /etc/timezone

echo "--- language: $P25T_LANG (and en_US.UTF-8 as a fallback)"
for l in "$P25T_LANG" en_US.UTF-8; do
    case "$l" in C|C.*|POSIX) continue ;; esac      # built in, nothing to generate
    sed -i "s/^# *\($l .*\)/\1/" /etc/locale.gen
    grep -q "^$l " /etc/locale.gen || { echo "language $l not in /etc/locale.gen"; exit 1; }
done
locale-gen
update-locale LANG="$P25T_LANG"
sed -i 's/^#AcceptEnv/AcceptEnv/' /etc/ssh/sshd_config

echo "--- keyboard: layout $P25T_XKBLAYOUT, variant '${P25T_XKBVARIANT}', options '${P25T_XKBOPTIONS}'"
cat > /etc/default/keyboard <<EOT
# Keyboard of the P25T card (asked when the card was built). The text
# console reads this file; the sway desktop reads it too, through
# ~/.config/sway/keyboard made from it.
XKBMODEL="pc105"
XKBLAYOUT="$P25T_XKBLAYOUT"
XKBVARIANT="$P25T_XKBVARIANT"
XKBOPTIONS="$P25T_XKBOPTIONS"
BACKSPACE="guess"
EOT

echo "--- console font: Terminus 10x20 (fits the 800x1280 screen)"
sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/; s/^FONTSIZE=.*/FONTSIZE="10x20"/; s/^CODESET=.*/CODESET="Lat15"/' /etc/default/console-setup

echo "--- USB-C as a USB device: serial console (ACM) + network (NCM)"
cat > /usr/local/sbin/p25t-gadget <<'EOT'
#!/bin/sh
# Set up the USB-C port as a composite USB device: serial console + network.
G=/sys/kernel/config/usb_gadget/p25t
# Host mode (set-dtb host): the port is a USB host, there is no
# device controller (UDC); nothing to do.
M=$(tr -d '\0' < /proc/device-tree/usb@fcc00000/dr_mode 2>/dev/null)
[ "$M" = host ] && { echo "USB-C port in host mode: no gadget"; exit 0; }
[ -d $G ] && exit 0
mkdir -p $G
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0100 > $G/bcdDevice
echo 0x0200 > $G/bcdUSB
mkdir -p $G/strings/0x409
echo "p25t0001"          > $G/strings/0x409/serialnumber
echo "Teclast"           > $G/strings/0x409/manufacturer
echo "P25T Debian"       > $G/strings/0x409/product
mkdir -p $G/configs/c.1/strings/0x409
echo "ACM+NCM" > $G/configs/c.1/strings/0x409/configuration
echo 250 > $G/configs/c.1/MaxPower
mkdir -p $G/functions/acm.usb0 $G/functions/ncm.usb0
# fixed addresses, so the PC always sees the same network device
echo 02:25:54:00:00:01 > $G/functions/ncm.usb0/dev_addr
echo 02:25:54:00:00:02 > $G/functions/ncm.usb0/host_addr
ln -s $G/functions/acm.usb0 $G/configs/c.1/
ln -s $G/functions/ncm.usb0 $G/configs/c.1/
UDC=""
for i in $(seq 1 20); do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
done
[ -n "$UDC" ] || { echo "no UDC"; exit 1; }
echo "$UDC" > $G/UDC
echo "gadget bound to $UDC"
EOT
chmod 755 /usr/local/sbin/p25t-gadget
cat > /etc/systemd/system/p25t-gadget.service <<'EOT'
[Unit]
Description=P25T USB gadget (serial console + network)
After=sys-kernel-config.mount
Requires=sys-kernel-config.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/p25t-gadget

[Install]
WantedBy=multi-user.target
EOT

echo "--- network: usb0 = 192.168.7.2 (the PC gets an address by DHCP), wlan0 by DHCP"
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/50-usb0.network <<'EOT'
[Match]
Name=usb*

[Network]
Address=192.168.7.2/24
DNS=1.1.1.1
DNS=9.9.9.9
DHCPServer=yes
ConfigureWithoutCarrier=yes

[Route]
Gateway=192.168.7.1
Metric=2000

[DHCPServer]
PoolOffset=10
PoolSize=10
EmitDNS=no
EmitRouter=no
EOT
cat > /etc/systemd/network/60-wlan.network <<'EOT'
[Match]
Name=wlan*

[Network]
DHCP=yes
IgnoreCarrierLoss=3s

[DHCPv4]
RouteMetric=600
UseHostname=no
EOT
cat > /etc/systemd/network/10-wlan-kernel-name.link <<'EOT'
[Match]
Type=wlan

[Link]
NamePolicy=kernel
EOT

echo "--- Wi-Fi: the AIC8800 driver at boot (the network itself: build_debian.sh)"
mkdir -p /etc/modules-load.d
echo aic8800_fdrv > /etc/modules-load.d/aic8800.conf

echo "--- Bluetooth: attach the AIC8800 (H4 on ttyS1, 1.5 Mbaud)"
cat > /etc/systemd/system/p25t-bluetooth.service <<'EOT'
[Unit]
Description=P25T: attach the AIC8800 Bluetooth (H4 on ttyS1, 1.5 Mbaud, RTS/CTS)
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/btattach -B /dev/ttyS1 -P h4 -S 1500000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

echo "--- volume buttons and headphone jack (triggerhappy)"
cat > /usr/local/sbin/p25t-audio <<'EOT'
#!/bin/sh
# p25t-audio up|down|hp-in|hp-out|sync - called by triggerhappy (see
# /etc/triggerhappy/triggers.d/p25t-audio.conf) and at boot.
C=RK817
case "$1" in
    up)     amixer -q -c "$C" sset Master 5%+ ;;
    down)   amixer -q -c "$C" sset Master 5%- ;;
    hp-in)  amixer -q -c "$C" sset 'Internal Speakers' off ;;
    hp-out) amixer -q -c "$C" sset 'Internal Speakers' on ;;
    sync)   if amixer -c "$C" cget iface=CARD,name='Headphones Jack' | grep -q 'values=on'
            then "$0" hp-in; else "$0" hp-out; fi ;;
    *)      echo "usage: p25t-audio up|down|hp-in|hp-out|sync" >&2; exit 1 ;;
esac
EOT
chmod 755 /usr/local/sbin/p25t-audio
mkdir -p /etc/triggerhappy/triggers.d
cat > /etc/triggerhappy/triggers.d/p25t-audio.conf <<'EOT'
# P25T: volume buttons and headphone jack (see /usr/local/sbin/p25t-audio)
# event	value	command	(1 = press/in, 2 = held, 0 = release/out)
KEY_VOLUMEUP	1	/usr/local/sbin/p25t-audio up
KEY_VOLUMEUP	2	/usr/local/sbin/p25t-audio up
KEY_VOLUMEDOWN	1	/usr/local/sbin/p25t-audio down
KEY_VOLUMEDOWN	2	/usr/local/sbin/p25t-audio down
SW_HEADPHONE_INSERT	1	/usr/local/sbin/p25t-audio hp-in
SW_HEADPHONE_INSERT	0	/usr/local/sbin/p25t-audio hp-out
EOT
mkdir -p /etc/systemd/system/triggerhappy.service.d
cat > /etc/systemd/system/triggerhappy.service.d/p25t.conf <<'EOT'
# P25T: run thd as root (nobody cannot open the sound card) and set the
# speaker switch from the jack state at start (no event if headphones
# were already plugged in at boot).
[Unit]
After=sound.target alsa-restore.service

[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --deviceglob /dev/input/event*
ExecStartPost=/usr/local/sbin/p25t-audio sync
EOT

echo "--- mixer levels (speaker, headphones, microphone)"
mkdir -p /var/lib/alsa
install -m 644 "$F/asound.state" /var/lib/alsa/asound.state

echo "--- journal: at most 100 MB"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/p25t-size.conf <<'EOT'
[Journal]
SystemMaxUse=100M
EOT

echo "--- cameras: cam-snap (rear-snap, front-snap)"
install -m 755 "$F/cam-snap.sh" /usr/local/bin/cam-snap
ln -sf cam-snap /usr/local/bin/rear-snap
ln -sf cam-snap /usr/local/bin/front-snap
install -D -m 755 "$F/raw2png.py" /usr/local/lib/p25t/raw2png.py
cat > /etc/udev/rules.d/99-p25t-vicap.rules <<'EOT'
# Keep the camera capture block (VICAP, fdfe0000) powered. Mainline rkcif
# pulses the VICAP resets on every runtime suspend, which also wipes its
# IOMMU: the next capture then writes through a dead IOMMU and the tablet
# freezes. With runtime power management off for this device it never
# suspends. Remove once the driver is fixed.
ACTION=="add", SUBSYSTEM=="platform", KERNEL=="fdfe0000.video-capture", ATTR{power/control}="on"
EOT

echo "--- device tree for the next boot: set-dtb (also called set-role)"
install -m 755 "$F/set-dtb.sh" /usr/local/bin/set-dtb
ln -sf set-dtb /usr/local/bin/set-role

echo "--- accelerometer: the P25T mount matrix for iio-sensor-proxy"
# systemd's 60-sensor.hwdb gives every devicetree SC7A20 the PineTab2
# matrix, 90 degrees off here. This file overrides it; see its comments.
install -D -m 644 "$F/61-p25t-sensor.hwdb" /etc/udev/hwdb.d/61-p25t-sensor.hwdb
systemd-hwdb update

echo "--- boot report onto the card (P25TBOOT/logs/boot-N-debian.txt)"
cat > /usr/local/sbin/p25t-bootlog <<'EOT'
#!/bin/sh
# Write a status report onto the card: /boot/firmware/logs/boot-N-debian.txt
D=/boot/firmware/logs
[ -d $D ] || exit 0
N=$(cat $D/bootcount 2>/dev/null || echo 0)
{
    echo "=== $(date)  uptime $(cut -d' ' -f1 /proc/uptime) s"
    echo "=== failed units"; systemctl --failed --no-legend
    echo "=== gadget"; systemctl status --no-pager -n 20 p25t-gadget.service
    for u in /sys/class/udc/*; do echo "$u state: $(cat $u/state)"; done
    echo "=== network"; ip addr
    echo "=== logins"; who
    echo "=== warnings and errors this boot"; journalctl -b -p warning --no-pager
    echo "=== dmesg"; dmesg
} > $D/boot-$N-debian.txt 2>&1
sync
EOT
chmod 755 /usr/local/sbin/p25t-bootlog
cat > /etc/systemd/system/p25t-bootlog.service <<'EOT'
[Unit]
Description=P25T status report onto the SD card

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/p25t-bootlog
EOT
cat > /etc/systemd/system/p25t-bootlog.timer <<'EOT'
[Unit]
Description=P25T status report onto the SD card, 1 min after boot and every 4 min

[Timer]
OnBootSec=60
OnUnitActiveSec=240

[Install]
WantedBy=timers.target
EOT

echo "--- SSH key"
if [ -f "$B/authorized_keys" ]; then
    install -d -m 700 -o "$U" -g "$U" "$H/.ssh"
    install -m 600 -o "$U" -g "$U" "$B/authorized_keys" "$H/.ssh/authorized_keys"
    echo "key installed for $U"
else
    echo "none given (ssh logins with the password only)"
fi

echo "--- services"
# Only getty@tty1 is enabled; logind starts tty2-tty6 on demand.
systemctl enable systemd-networkd.service systemd-resolved.service \
    ssh.service p25t-gadget.service p25t-bootlog.timer \
    getty@tty1.service wpa_supplicant@wlan0.service \
    bluetooth.service p25t-bluetooth.service triggerhappy.service
# No login on the USB serial port: with no USB host reading it (no cable,
# or host mode), systemd's terminal reset before agetty blocks for ever
# holding the console lock, and every other getty then waits on it.
# SSH (Wi-Fi or the USB network) replaces this console.
systemctl mask serial-getty@ttyGS0.service
echo "common setup done"
