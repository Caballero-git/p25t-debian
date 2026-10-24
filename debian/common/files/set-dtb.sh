#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# set-dtb - choose what the tablet starts with at the NEXT boot: which
# camera works and what the USB-C port does. Also called set-role (the
# same command).
#
#   set-dtb                  show both settings (also: set-dtb status)
#   set-dtb rear | front     the camera: rear (GC5035) or front (GC02M2);
#                            the SoC has one camera input, so one at a time
#   set-dtb host | device    USB-C as a host: a keyboard, mouse or stick on
#                            the port works, the port powers it and the
#                            tablet does not charge; or as a device: the
#                            tablet charges, and a PC on the cable gets a
#                            serial console and a network link
#                            ("normal" and "charge" mean device too)
#   set-dtb rear host        both at once (any order)
# A change keeps the other setting as it is. Nothing changes until a
# reboot: the camera and the port role are fixed when the drivers start.
#
# How: U-Boot always loads rk3566-teclast-p25t.dtb from P25TBOOT
# (/boot/firmware); that file is a copy of one of four device trees kept
# next to it:
#   camera  USB-C   file
#   rear    device  rk3566-teclast-p25t-normal.dtb
#   rear    host    rk3566-teclast-p25t-usbhost.dtb
#   front   device  rk3566-teclast-p25t-front.dtb
#   front   host    rk3566-teclast-p25t-front-usbhost.dtb
# A change copies one over the active file, compares the copy, and
# updates and checks CARD-SHA256SUMS. It needs root and asks sudo itself:
# run it as the user.
set -euo pipefail
BOOT=${BOOT:-/boot/firmware}            # overridable only for testing
ACTIVE=$BOOT/rk3566-teclast-p25t.dtb
SUMS=$BOOT/CARD-SHA256SUMS
die() { echo "set-dtb: $*" >&2; exit 1; }
usage() { sed -n '7,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
role() { [ "$1" = host ] && echo host || echo device; }   # internal "normal" = device

variant() {   # variant <camera> <usb> -> file name on P25TBOOT
    case "$1:$2" in
        rear:normal) echo rk3566-teclast-p25t-normal.dtb ;;
        rear:host) echo rk3566-teclast-p25t-usbhost.dtb ;;
        front:normal) echo rk3566-teclast-p25t-front.dtb ;;
        front:host) echo rk3566-teclast-p25t-front-usbhost.dtb ;;
    esac
}

# the variant the active DTB is a copy of: sets CAM and USB, or fails
current() {
    local c u f
    for c in rear front; do
        for u in normal host; do
            f=$BOOT/$(variant $c $u)
            if [ -f "$f" ] && cmp -s "$ACTIVE" "$f"; then CAM=$c; USB=$u; return 0; fi
        done
    done
    return 1
}

status() {
    if current; then
        echo "next boot: camera $CAM, USB-C $(role "$USB") ($(variant "$CAM" "$USB"))"
    else
        echo "next boot: unknown - the active device tree is a copy of none of the variants on $BOOT"
    fi
    local c u miss=""
    for c in rear front; do for u in normal host; do
        [ -f "$BOOT/$(variant $c $u)" ] || miss="$miss $(variant $c $u)"
    done; done
    [ -z "$miss" ] || echo "not on the card:$miss (tools/install_card.sh puts them there)"
    echo "running kernel: $(uname -r) $(uname -v)"
}

sums_update() {
    [ -f "$SUMS" ] || { echo "WARNING: $SUMS not found - checksum list not updated" >&2; return; }
    local sum
    sum=$(sha256sum "$ACTIVE" | cut -d' ' -f1)
    if grep -q '^[0-9a-f]\{64\}  rk3566-teclast-p25t\.dtb$' "$SUMS"; then
        sed -i "s/^[0-9a-f]\{64\}  rk3566-teclast-p25t\.dtb\$/$sum  rk3566-teclast-p25t.dtb/" "$SUMS"
    else
        echo "$sum  rk3566-teclast-p25t.dtb" >> "$SUMS"
    fi
    sync
    ( cd "$BOOT" && sha256sum -c --quiet CARD-SHA256SUMS ) || die "CARD-SHA256SUMS check failed after the update - see above"
    echo "CARD-SHA256SUMS updated and checked"
}

# --- arguments: any of rear/front and host/device, in any order -----------
ORIG=("$@")
WANTCAM=""; WANTUSB=""
[ $# -gt 0 ] || set -- status
for a in "$@"; do
    case "$a" in
        status)                 [ $# -eq 1 ] || usage; status; exit 0 ;;
        rear|front)             WANTCAM=$a ;;
        host)                   WANTUSB=host ;;
        device|normal|charge)   WANTUSB=normal ;;
        *)                      usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "${ORIG[@]}"
[ -n "${TESTING:-}" ] || mountpoint -q "$BOOT" || die "$BOOT is not mounted"
current || die "the active device tree is a copy of none of the variants on $BOOT - sort that out first (set-dtb status)"
NEWCAM=${WANTCAM:-$CAM}; NEWUSB=${WANTUSB:-$USB}
SRC=$BOOT/$(variant "$NEWCAM" "$NEWUSB")
[ -f "$SRC" ] || die "$(basename "$SRC") is not on the card"

if [ "$NEWCAM:$NEWUSB" = "$CAM:$USB" ]; then
    echo "already set: camera $CAM, USB-C $(role "$USB") - nothing to do"
    exit 0
fi
cp "$SRC" "$ACTIVE"
sync
cmp -s "$SRC" "$ACTIVE" || die "$ACTIVE differs from $SRC after copying - CARD-SHA256SUMS not touched"
sums_update
echo "next boot: camera $NEWCAM, USB-C $(role "$NEWUSB") (now: camera $CAM, USB-C $(role "$USB")). Reboot with: sudo reboot"
[ "$NEWUSB" = host ] && [ "$USB" != host ] &&
    echo "Note: as a host the USB-C port powers the attached device; the tablet does not charge."
exit 0
