#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# autorotate.sh - turn the P25T screen with the accelerometer, under sway.
# Repo: debian/sway/config/sway/autorotate.sh, installed as ~/.config/sway/autorotate.sh.
#
#     autorotate.sh run       follow the accelerometer (started by the sway
#                             config with exec_always; a newer copy stops
#                             the older one, so a reload never leaves two)
#     autorotate.sh toggle    lock / unlock the rotation (bound to Super+o)
#     autorotate.sh status    print locked/unlocked and the last orientation
#
# The orientation comes from iio-sensor-proxy (monitor-sensor). Its names
# follow debian/files/61-p25t-sensor.hwdb: "normal" is landscape as the
# console reads. Touch follows the output transform by itself (sway).
set -u
OUT=DSI-1
RUN=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/p25t-autorotate
LOCKED=$RUN/locked
LAST=$RUN/last
PIDF=$RUN/pid
mkdir -p "$RUN"

# orientation name -> sway transform for DSI-1 (native panel is portrait)
transform_for() {
    case "$1" in
        normal)    echo 90  ;;  # landscape as the console reads (sway's own choice at start)
        bottom-up) echo 270 ;;  # landscape upside down
        left-up)   echo 0   ;;  # turned 90 degrees clockwise   (checked 2026-10-15)
        right-up)  echo 180 ;;  # turned 270 degrees clockwise  (checked 2026-10-15)
        *) return 1 ;;          # undefined: leave the screen as it is
    esac
}

# Ask the bar to refresh now: one line into status.sh's FIFO. No signal -
# a USR1 arriving while bash runs a $(...) made status.sh die with "unexpected
# EOF while looking for matching `)'" (bash 5.2, seen 2026-10-15) and swaybar
# showed "[error reading from status command]". dd with oflag=nonblock fails
# at once instead of hanging when no status.sh is reading.
bar_refresh() {
    local f=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/p25t-status.fifo
    [ -p "$f" ] && echo | dd of="$f" oflag=nonblock status=none 2>/dev/null
    return 0
}

apply() {
    local t
    t=$(transform_for "$1") || return 0
    swaymsg -q output "$OUT" transform "$t"
}

case "${1:-}" in
run)
    # stop an older copy (exec_always starts us again on every reload)
    if [ -f "$PIDF" ]; then
        old=$(cat "$PIDF")
        [ "$old" != "$$" ] && kill "$old" 2>/dev/null
    fi
    echo $$ > "$PIDF"
    # monitor-sensor runs as a child we know, so we can stop it with us
    exec 3< <(stdbuf -oL monitor-sensor 2>/dev/null)
    MPID=$!
    trap 'kill "$MPID" 2>/dev/null; exit 0' TERM INT HUP
    # The first line ("Has accelerometer (orientation: X, ...)") can be the
    # daemon's previous value; a "changed" line follows at once if it is
    # stale, so applying both is safe.
    while IFS= read -r line <&3; do
        case "$line" in
            *"orientation changed: "*)        o=${line##*: } ;;
            *"Has accelerometer (orientation: "*) o=${line#*orientation: }; o=${o%%,*} ;;
            *) continue ;;
        esac
        echo "$o" > "$LAST"
        [ -e "$LOCKED" ] || apply "$o"
    done
    kill "$MPID" 2>/dev/null
    ;;
toggle)
    if [ -e "$LOCKED" ]; then
        rm -f "$LOCKED"
        [ -f "$LAST" ] && apply "$(cat "$LAST")"
    else
        touch "$LOCKED"
    fi
    bar_refresh   # let the bar show the change at once
    ;;
status)
    if [ -e "$LOCKED" ]; then echo -n "locked"; else echo -n "unlocked"; fi
    echo ", last orientation: $(cat "$LAST" 2>/dev/null || echo unknown)"
    ;;
*)
    echo "usage: autorotate.sh run | toggle | status" >&2
    exit 1
    ;;
esac
