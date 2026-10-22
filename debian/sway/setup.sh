#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# debian/sway/setup.sh - the sway desktop. Runs INSIDE the new Debian
# (chroot), started by tools/build_debian.sh after debian/common/setup.sh.
#
# Input in /root/p25t-build/: answers (P25T_USER, ...) and sway/config/,
# this folder's config/, which becomes the user's ~/.config: sway (config,
# bar, rotation, brightness, power key and idle, autostart), foot, fuzzel,
# GTK dark theme, zathura, mimeapps.list (xdg-open defaults).
#
# sway starts after the login on tty1 (~/.config/sway/autostart.sh, read
# by ~/.profile): tty2-6 and ssh stay text consoles; ~/.no-sway or a key
# during the 3 s countdown keeps tty1 a text console too.
set -euo pipefail
B=/root/p25t-build
# shellcheck source=/dev/null
. "$B/answers"
U=$P25T_USER
H=$(getent passwd "$U" | cut -d: -f6)

echo "--- sway: the user's ~/.config"
[ -f "$B/sway/config/sway/config" ] || { echo "$B/sway/config/sway/config missing"; exit 1; }
install -d -m 755 -o "$U" -g "$U" "$H/.config"
cp -r "$B/sway/config/." "$H/.config/"
# plain modes whatever the copies had: folders 755, files 644, scripts 755
for f in "$B"/sway/config/*; do
    n=$H/.config/$(basename "$f")
    find "$n" -type d -exec chmod 755 {} +
    find "$n" -type f -exec chmod 644 {} +
done
chmod 755 "$H"/.config/sway/*.sh
chmod 644 "$H/.config/sway/autostart.sh"     # read by the login shell, not run

echo "--- sway: keyboard from /etc/default/keyboard"
# shellcheck source=/dev/null
. /etc/default/keyboard
{
    echo "# Made by the card build from /etc/default/keyboard; included by"
    echo "# ~/.config/sway/config. Change the layouts here (or there) and"
    echo "# reload sway (Super+Shift+c)."
    echo "input type:keyboard {"
    echo "    xkb_layout ${XKBLAYOUT:-us}"
    [ -n "${XKBVARIANT:-}" ] && echo "    xkb_variant $XKBVARIANT"
    [ -n "${XKBOPTIONS:-}" ] && echo "    xkb_options $XKBOPTIONS"
    echo "}"
} > "$H/.config/sway/keyboard"
cat "$H/.config/sway/keyboard"
chown -R "$U:$U" "$H/.config"

echo "--- sway starts after the login on tty1"
[ -f "$H/.profile" ] || install -m 644 -o "$U" -g "$U" /etc/skel/.profile "$H/.profile"
grep -q 'sway/autostart.sh' "$H/.profile" || cat >> "$H/.profile" <<'EOT'

# P25T: start sway after the login on tty1 (see that file)
[ -f "$HOME/.config/sway/autostart.sh" ] && . "$HOME/.config/sway/autostart.sh"
EOT
echo "sway setup done"
