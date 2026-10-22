#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# set-dtb.sh - choose the device tree the P25T uses from the NEXT boot on:
# which camera is wired up and which role the USB-C port has. The two are
# independent settings; changing one keeps the other.
#
#   set-dtb status
#   set-dtb camera rear|front     (also: set-camera rear|front|status)
#   set-dtb usb normal|host       (also: set-usb-role normal|host|status)
#
#   camera rear    the rear GC5035 (the usual one)
#   camera front   the front GC02M2 instead. The SoC has one camera input,
#                  so one camera at a time.
#   usb normal     USB-C as a USB device: the PC gets a serial console and
#                  a network link over the cable
#   usb host       USB-C as a USB host: a wired keyboard/mouse works; no
#                  console/network over that cable. The port powers the
#                  attached device instead of charging the tablet.
#
# Why copies of DTBs: U-Boot always loads rk3566-teclast-p25t.dtb from
# P25TBOOT (/boot/firmware), so the content at that name decides. It is a
# copy of one of four variants, all kept on P25TBOOT by deploy_kernel.sh
# and install_debian.sh:
#   camera  usb     file
#   rear    normal  rk3566-teclast-p25t-normal.dtb
#   rear    host    rk3566-teclast-p25t-usbhost.dtb
#   front   normal  rk3566-teclast-p25t-front.dtb
#   front   host    rk3566-teclast-p25t-front-usbhost.dtb
# A change copies the variant over the active DTB, compares the copy and
# updates and checks CARD-SHA256SUMS. Nothing changes until a reboot: the
# camera and the USB role are fixed when the drivers start.
# Changes need root; the script asks sudo itself, so run it as the user.
#
# Install (the card build does the same):
#   sudo install -m 755 set-dtb.sh /usr/local/bin/set-dtb
#   sudo ln -sf set-dtb /usr/local/bin/set-usb-role
#   sudo ln -sf set-dtb /usr/local/bin/set-camera

set -euo pipefail
BOOT=${BOOT:-/boot/firmware}            # overridable only for testing
ACTIVE=$BOOT/rk3566-teclast-p25t.dtb
SUMS=$BOOT/CARD-SHA256SUMS
die() { echo "set-dtb: $*" >&2; exit 1; }
usage() { sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

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
        echo "next boot: camera $CAM, USB-C $USB ($(variant "$CAM" "$USB"))"
    else
        echo "next boot: unknown - the active DTB is a copy of none of the variants on $BOOT"
    fi
    local c u miss=""
    for c in rear front; do for u in normal host; do
        [ -f "$BOOT/$(variant $c $u)" ] || miss="$miss $(variant $c $u)"
    done; done
    [ -z "$miss" ] || echo "not on the card:$miss (deploy_kernel.sh puts them there)"
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

# --- arguments: the name it is called by picks the setting --------------------
ORIG=("$@")
case "$(basename "$0")" in
    set-usb-role*) WHAT=usb ;;
    set-camera*) WHAT=camera ;;
    *) WHAT=${1:-}; [ $# -gt 0 ] && shift ;;
esac
ARG=${1:-}
case "$WHAT:$ARG" in
    status:|usb:status|camera:status) status; exit 0 ;;
    usb:normal|usb:host|camera:rear|camera:front) ;;
    *) usage ;;
esac

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "${ORIG[@]}"
[ -n "${TESTING:-}" ] || mountpoint -q "$BOOT" || die "$BOOT is not mounted"
current || die "the active DTB is a copy of none of the variants on $BOOT - sort that out first (set-dtb status)"
if [ "$WHAT" = usb ]; then NEWCAM=$CAM; NEWUSB=$ARG; else NEWCAM=$ARG; NEWUSB=$USB; fi
SRC=$BOOT/$(variant "$NEWCAM" "$NEWUSB")
[ -f "$SRC" ] || die "$(basename "$SRC") is not on the card - deploy a kernel that has it (deploy_kernel.sh)"

if [ "$NEWCAM:$NEWUSB" = "$CAM:$USB" ]; then
    echo "already set: camera $CAM, USB-C $USB - nothing to do"
    exit 0
fi
cp "$SRC" "$ACTIVE"
sync
cmp -s "$SRC" "$ACTIVE" || die "$ACTIVE differs from $SRC after copying - CARD-SHA256SUMS not touched"
sums_update
echo "next boot: camera $NEWCAM, USB-C $NEWUSB (was: camera $CAM, USB-C $USB). Reboot now with: sudo reboot"
[ "$NEWUSB" = host ] && [ "$USB" != host ] &&
    echo "Note: in host mode the USB-C port powers the attached device instead of charging the tablet."
exit 0
