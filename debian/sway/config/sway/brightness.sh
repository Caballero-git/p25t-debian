#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# brightness.sh - backlight for the P25T under sway.
# Repo: debian/sway/config/sway/brightness.sh, installed as ~/.config/sway/brightness.sh.
#
#     brightness.sh up | down     5 % steps (Super+F6 / Super+F5)
#     brightness.sh set <N>       raw level 0..max (sway start: 80)
#     brightness.sh dim | undim   used by swayidle: save + floor / restore
#     brightness.sh get           print "<level> <max>"
#
# Never below a floor (5 % of max, at least 10): the screen cannot go
# black by mistake. Writes through logind (SetBrightness on our own
# session), so no sudo and no udev rule are needed - it works from sway
# (the active session on the tablet), not from an ssh login.
set -u
D=${BL_DIR:-/sys/class/backlight/backlight}   # BL_DIR: only for testing
RUN=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/p25t-brightness
mkdir -p "$RUN"
MAX=$(cat "$D/max_brightness")
CUR=$(cat "$D/brightness")
STEP=$(( MAX * 5 / 100 )); [ "$STEP" -ge 1 ] || STEP=1
FLOOR=$(( MAX * 5 / 100 )); [ "$FLOOR" -ge 10 ] || FLOOR=10

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

setb() {
    local v=$1
    [ "$v" -lt "$FLOOR" ] && v=$FLOOR
    [ "$v" -gt "$MAX" ] && v=$MAX
    busctl call org.freedesktop.login1 /org/freedesktop/login1/session/auto \
        org.freedesktop.login1.Session SetBrightness ssu backlight backlight "$v"
    bar_refresh
}

case "${1:-}" in
    up)    setb $(( CUR + STEP )) ;;
    down)  setb $(( CUR - STEP )) ;;
    set)   setb "${2:?usage: brightness.sh set N}" ;;
    dim)   [ -f "$RUN/saved" ] || echo "$CUR" > "$RUN/saved"; setb "$FLOOR" ;;
    undim) if [ -f "$RUN/saved" ]; then setb "$(cat "$RUN/saved")"; rm -f "$RUN/saved"; fi ;;
    get)   echo "$CUR $MAX" ;;
    *)     echo "usage: brightness.sh up | down | set N | dim | undim | get" >&2; exit 1 ;;
esac
