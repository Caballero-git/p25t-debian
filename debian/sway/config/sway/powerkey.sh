#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# powerkey.sh - power key and idle screen-off for the P25T under sway
#. Repo: debian/sway/config/sway/powerkey.sh, installed as
# ~/.config/sway/powerkey.sh.
#
#     powerkey.sh press      power key (short press): screen off / on
#     powerkey.sh idle-off   swayidle, after 5 min: screen off
#     powerkey.sh wake       swayidle, on any key or touch: screen on
#
# A press that itself woke the screen from idle-off must not switch it
# straight off again: swayidle's "wake" runs first, so a press within 1 s
# of a wake is ignored. logind does not power the tablet off on a short
# press while sway runs: the sway config holds a handle-power-key
# inhibitor (systemd-inhibit around swayidle). A long press is still the
# RK817's hardware power-off.
set -u
OUT=DSI-1
RUN=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/p25t-powerkey
mkdir -p "$RUN"

is_on() { swaymsg -t get_outputs | grep -q '"power": true'; }

case "${1:-}" in
    press)
        if [ -f "$RUN/woke" ]; then
            age=$(( $(date +%s%N) / 1000000 - $(cat "$RUN/woke") ))
            [ "$age" -lt 1000 ] && exit 0
        fi
        if is_on; then swaymsg -q output "$OUT" power off
        else swaymsg -q output "$OUT" power on
        fi ;;
    idle-off)
        swaymsg -q output "$OUT" power off ;;
    wake)
        echo $(( $(date +%s%N) / 1000000 )) > "$RUN/woke"
        swaymsg -q output "$OUT" power on ;;
    *)
        echo "usage: powerkey.sh press | idle-off | wake" >&2; exit 1 ;;
esac
