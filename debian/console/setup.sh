#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# debian/console/setup.sh - the console desktop (text only). Runs INSIDE
# the new Debian (chroot), started by tools/build_debian.sh after
# debian/common/setup.sh.
#
# The console shows the screen in landscape (the kernel turns the panel);
# touch is turned to match, and consolation lets a finger or a mouse
# select and paste text. A dimmer colour palette and the backlight at 80
# are set at boot.
set -euo pipefail

echo "--- console: consolation without mouse reporting"
C=/etc/default/consolation
touch "$C"
if grep -q '^DAEMON_OPTS=' "$C"; then
    sed -i 's|^DAEMON_OPTS=.*|DAEMON_OPTS="--disable-mouse-reporting"|' "$C"
else
    echo 'DAEMON_OPTS="--disable-mouse-reporting"' >> "$C"
fi

echo "--- console: palette dim, backlight 80 at boot"
cat > /etc/p25t-vtrgb <<'EOT'
28,170,58,170,58,154,58,176,92,200,100,200,100,180,100,208
28,58,154,122,90,74,154,176,92,100,180,180,130,100,180,208
28,58,58,42,170,154,154,176,92,100,100,100,200,180,180,208
EOT
cat > /etc/systemd/system/p25t-console-colors.service <<'EOT'
[Unit]
Description=P25T console palette (dim) and backlight (80)
After=systemd-vconsole-setup.service console-setup.service systemd-backlight@backlight:backlight.service
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/bin/setvtrgb /etc/p25t-vtrgb
ExecStart=/bin/sh -c 'echo 80 > /sys/class/backlight/backlight/brightness'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOT

echo "--- console: touch in landscape, like the screen"
cat > /etc/udev/rules.d/99-p25t-touch-landscape.rules <<'EOT'
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="silead_ts", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
EOT

systemctl enable p25t-console-colors.service consolation.service
echo "console setup done"
