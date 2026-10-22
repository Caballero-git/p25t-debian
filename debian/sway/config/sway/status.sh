#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# status.sh - the text in the P25T's sway bar.
# Repo: debian/sway/config/sway/status.sh, installed as ~/.config/sway/status.sh and
# started by swaybar (status_command in the sway config).
#
#     status.sh          one line every 2 s, for swaybar
#     status.sh once     print a single line and exit (to test over ssh)
#
# Fields, left to right:
#   kb es | rot lock | bl 32% | vol 70% | wifi <SSID> -55dBm | bat 85% chg | date time
# "rot lock" only appears while the rotation is locked (Super+o).
# A line written to $XDG_RUNTIME_DIR/p25t-status.fifo refreshes at once
# (brightness.sh and autorotate.sh do it).
# Only reads files in /sys and asks sway, iw and amixer: cheap.
set -u
RUN=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

# the active layout's code from the list in /etc/default/keyboard
# (XKBLAYOUT="es,us": index 0 -> es, 1 -> us)
kb() {
    local i layouts
    i=$(swaymsg -t get_inputs 2>/dev/null | grep -m1 '"xkb_active_layout_index"' | tr -dc '0-9')
    layouts=$(sed -n 's/^XKBLAYOUT="\(.*\)"/\1/p' /etc/default/keyboard 2>/dev/null)
    IFS=, read -r -a layouts <<< "$layouts"
    echo "kb ${layouts[${i:-0}]:-?}"
}

rot() {
    [ -e "$RUN/p25t-autorotate/locked" ] && echo "rot lock"
}

backlight() {
    local d=/sys/class/backlight/backlight b m
    b=$(cat "$d/brightness" 2>/dev/null) || { echo "bl ?"; return; }
    m=$(cat "$d/max_brightness" 2>/dev/null)
    echo "bl $(( b * 100 / ${m:-255} ))%"
}

volume() {
    local a v
    a=$(amixer -c RK817 sget Master 2>/dev/null) || { echo "vol ?"; return; }
    # first channel only (Master can list one value per channel)
    v=$(printf '%s\n' "$a" | grep -o '\[[0-9]*%\]' | head -n1 | tr -d '[]')
    case "$a" in *"[off]"*) echo "vol ${v:-?} off" ;; *) echo "vol ${v:-?}" ;; esac
}

wifi() {
    local a ssid sig
    # iw lives in /usr/sbin, which is not in a normal user's PATH
    a=$(/usr/sbin/iw dev wlan0 link 2>/dev/null)
    case "$a" in
        *"Not connected"*|"") echo "wifi -" ; return ;;
    esac
    ssid=$(printf '%s\n' "$a" | sed -n 's/^[[:space:]]*SSID: //p')
    sig=$(printf '%s\n' "$a" | sed -n 's/^[[:space:]]*signal: \(-*[0-9]*\).*/\1/p')
    echo "wifi ${ssid:-?} ${sig:-?}dBm"
}

battery() {
    local p cap st on=""
    for p in /sys/class/power_supply/*; do
        [ "$(cat "$p/type" 2>/dev/null)" = Battery ] || continue
        cap=$(cat "$p/capacity" 2>/dev/null)
        st=$(cat "$p/status" 2>/dev/null)
        case "$st" in
            Charging)    on=" chg" ;;
            Full)        on=" full" ;;
            "Not charging") on=" plugged" ;;
        esac
        echo "bat ${cap:-?}%$on"
        return
    done
    echo "bat ?"
}

line() {
    local f out=""
    for f in "$(kb)" "$(rot)" "$(backlight)" "$(volume)" "$(wifi)" "$(battery)" "$(date '+%a %d %b %H:%M')"; do
        [ -n "$f" ] || continue
        out="${out:+$out | }$f"
    done
    printf '%s\n' "$out"
}

if [ "${1:-}" = once ]; then line; exit 0; fi

# Refresh requests arrive as lines on a FIFO (bar_refresh in brightness.sh
# and autorotate.sh); read -t waits for one or for 2 s, whichever is first.
# Opened read-write, so it never blocks and never sees end-of-file.
FIFO="$RUN/p25t-status.fifo"
[ -p "$FIFO" ] || { rm -f "$FIFO"; mkfifo -m 600 "$FIFO"; }
exec 3<> "$FIFO"
while :; do
    line
    read -r -t 2 -u 3 _ || true
done
