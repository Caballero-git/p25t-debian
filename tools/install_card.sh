#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# install_card.sh - put the built Debian, the kernel and the start-up
# system onto the card (step 6 of "Building a card" in README.org).
#
#     bash <WORK>/p25t-debian/tools/install_card.sh <DESKTOP>
#
# Run it as your normal user; it asks for sudo itself. Needs:
#   build/rootfs-<DESKTOP>   tools/build_debian.sh <DESKTOP>
#   build/kernel-pack/       tools/pack_kernel.sh
#   build/stage1/            tools/build_initramfs.sh
#   the card in the PC, with its boot part (tools/make_boot_part.sh); only
#   one P25T card in the PC (all of them carry the labels P25TBOOT and
#   p25troot).
#
# What it does to the card, and nothing else:
#   - moves the partition table's backup to the real end of the card
#   - partition 5 "P25TROOT" from 1 GiB to the end (made if missing),
#     formatted ext4 with the label p25troot; it starts at 1 GiB because
#     U-Boot writes its status note at sector 1331200 (~650 MB), outside
#     every partition
#   - copies the Debian system and checks every file by checksum
#   - P25TBOOT: Image, the four device trees (the active one: rear camera,
#     USB-C as a host, for a keyboard at the first login; set-dtb changes
#     it), the initramfs, the flag file
#     boot-debian; clears old boot logs; writes and checks CARD-SHA256SUMS
# A card that holds a Debian already: it says which (host name) and
# replaces it after the same confirmation.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KP="$REPO/build/kernel-pack"
INITD="$REPO/build/stage1"
ROOT_START=2097152          # sector of 1 GiB
DTBS="rk3566-teclast-p25t rk3566-teclast-p25t-usbhost rk3566-teclast-p25t-front rk3566-teclast-p25t-front-usbhost"
die() { echo; echo "STOPPED: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }

DESKTOP="${1:-}"
[ -n "$DESKTOP" ] || { sed -n '3,27p' "$0"; exit 1; }
if [ "$(id -u)" -ne 0 ]; then exec sudo bash "$0" "$@"; fi
[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || die "run it as your normal user (it asks for sudo itself)"
unset LANGUAGE; export LC_ALL=C.UTF-8
R="$REPO/build/rootfs-$DESKTOP"

say "1/9 The built system, kernel and initramfs"
for t in sgdisk partprobe blkid lsblk mkfs.ext4 e2fsck rsync python3; do
    command -v "$t" > /dev/null || die "missing $t (sudo apt install gdisk parted util-linux e2fsprogs rsync python3)"
done
[ -x "$R/usr/lib/systemd/systemd" ] || die "no Debian in $R - run tools/build_debian.sh $DESKTOP first"
[ -f "$R.info" ] || die "$R.info missing - the build did not finish; build again"
TUSER=$(sed -n 's/^user: //p' "$R.info")
THOST=$(cat "$R/etc/hostname")
PWFIELD=$(awk -F: -v u="$TUSER" '$1 == u {print $2}' "$R/etc/shadow")
case "$PWFIELD" in ""|"!"*|"*"*) die "the user '$TUSER' in $R has no password - build again" ;; esac
( cd "$KP" && sha256sum -c --quiet files.sha256 ) || die "the files in $KP do not match files.sha256 - run tools/pack_kernel.sh"
REL=$(cat "$KP/release.txt")
[ -f "$R/usr/lib/modules/$REL/extra/aic8800_fdrv.ko" ] \
    || die "the built Debian has no modules for kernel $REL - it was built with another kernel; build it again"
[ -f "$INITD/initramfs.cpio.gz" ] && [ -f "$INITD/initramfs.cpio.gz.sha256" ] \
    || die "no initramfs in $INITD - run tools/build_initramfs.sh"
( cd "$INITD" && sha256sum -c --quiet initramfs.cpio.gz.sha256 ) \
    || die "$INITD/initramfs.cpio.gz does not match its .sha256 - run tools/build_initramfs.sh again"
INIT_SHA=$(cut -c1-16 "$INITD/initramfs.cpio.gz.sha256")
echo "Debian: $R ($(du -sh "$R" | cut -f1)), desktop $DESKTOP, host name $THOST, user $TUSER"
echo "kernel $REL, initramfs $INIT_SHA..."

say "2/9 The card"
N=$(blkid -t LABEL=P25TBOOT -o device | wc -l)
[ "$N" -eq 1 ] || die "found $N partitions labelled P25TBOOT - exactly one P25T card must be in the PC (tools/make_boot_part.sh makes one)"
BOOTPART=$(blkid -L P25TBOOT)
DISK=/dev/$(lsblk -no PKNAME "$BOOTPART" | head -n 1)
[ -b "$DISK" ] || die "cannot find the disk of $BOOTPART"
DNAME=$(basename "$DISK")
SIZE_GB=$(( $(cat /sys/block/"$DNAME"/size) / 2097152 ))
REMOVABLE=$(cat /sys/block/"$DNAME"/removable)
TRAN=$(lsblk -dno TRAN "$DISK" || true)
if findmnt -no SOURCE / | grep -q "^$DISK"; then die "$DISK holds the PC's own system"; fi
[ "$SIZE_GB" -ge 4 ] && [ "$SIZE_GB" -le 256 ] || die "$DISK is $SIZE_GB GB - not a plausible SD card"
case "$DNAME" in
    mmcblk*) ;;
    loop*) [ "${P25T_TEST_LOOP:-}" = 1 ] || die "$DISK is a loop device (tests only: P25T_TEST_LOOP=1)" ;;
    *) [ "$REMOVABLE" = 1 ] || [ "$TRAN" = usb ] || die "$DISK is not removable/USB/SD" ;;
esac
case "$DISK" in *[0-9]) P5="${DISK}p5" ;; *) P5="${DISK}5" ;; esac
echo "card: $DISK, $SIZE_GB GB, transport ${TRAN:-?}, removable $REMOVABLE, P25TBOOT = $BOOTPART"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$DISK"
P4_END=$( (sgdisk -i 4 "$DISK" 2> /dev/null || true) | awk '/^Last sector/ {print $3}')
[ -n "$P4_END" ] && [ "$P4_END" -lt 1331200 ] || die "unexpected layout: partition 4 ends at ${P4_END:-?}"
EXISTING=$( (sgdisk -i 5 "$DISK" 2> /dev/null || true) | awk -F"'" '/^Partition name/ {print $2}')
if [ -n "$EXISTING" ] && [ "$EXISTING" != P25TROOT ]; then
    die "partition 5 exists and is called '$EXISTING' - not touching it"
fi
OLDHOST=""
if [ -n "$EXISTING" ] && [ -b "$P5" ]; then
    MNT=$(mktemp -d)
    if mount -o ro "$P5" "$MNT" 2> /dev/null; then
        OLDHOST=$(cat "$MNT/etc/hostname" 2> /dev/null || echo "?")
        umount "$MNT"
    fi
    rmdir "$MNT"
fi

echo
if [ -n "$OLDHOST" ]; then
    echo "The card holds a Debian already: host name '$OLDHOST'. It will be REPLACED."
fi
echo "This will ERASE partition 5 (P25TROOT) on $DISK and install there the"
echo "'$DESKTOP' Debian (host name '$THOST'), and put kernel $REL and the"
echo "initramfs on P25TBOOT."
read -r -p "Type YES to continue: " ANSWER
[ "$ANSWER" = YES ] || die "not confirmed"

say "3/9 Unmounting the card's partitions"
for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
    if umount "$p" 2> /dev/null; then echo "unmounted $p"; fi
done

say "4/9 Partition 5 (P25TROOT, from 1 GiB to the end)"
sgdisk -e "$DISK" > /dev/null
if [ -z "$EXISTING" ]; then
    sgdisk -n 5:$ROOT_START:0 -c 5:P25TROOT -t 5:8300 "$DISK" > /dev/null
fi
partprobe "$DISK" 2> /dev/null || partx -u "$DISK" 2> /dev/null || true
for _ in $(seq 1 10); do [ -b "$P5" ] && break; sleep 1; done
[ -b "$P5" ] || die "$P5 did not appear"
P5_START=$( (sgdisk -i 5 "$DISK" 2> /dev/null || true) | awk '/^First sector/ {print $3}')
[ -n "$P5_START" ] && [ "$P5_START" -ge $ROOT_START ] || die "partition 5 starts at $P5_START, below 1 GiB"
(sgdisk -p "$DISK" || true) | tail -n 7

say "5/9 Formatting ext4 (label p25troot)"
umount "$P5" 2> /dev/null || true
mkfs.ext4 -F -q -L p25troot "$P5"

say "6/9 Copying Debian onto the card (several minutes)"
MNT=$(mktemp -d)
mount "$P5" "$MNT"
rsync -aHAX --numeric-ids "$R"/ "$MNT"/
sync
echo "copied; now checking every file by checksum ..."
DIFFS=$(rsync -aHAXn --checksum --numeric-ids --itemize-changes "$R"/ "$MNT"/ | wc -l)
umount "$MNT"
[ "$DIFFS" -eq 0 ] || die "$DIFFS files differ between $R and the card"
e2fsck -fn "$P5" > /dev/null || die "file system check of $P5 failed"
echo "Debian on the card: every file checked"

say "7/9 P25TBOOT: kernel, device trees, initramfs, boot-debian"
mount "$BOOTPART" "$MNT"
if [ -d "$MNT/logs" ]; then rm -f "$MNT"/logs/*; echo "old boot logs cleared"; fi
rm -f "$MNT"/*.pre-*-backup "$MNT/autorun.sh"
cp "$KP/Image" "$MNT/Image"
for d in $DTBS; do cp "$KP/$d.dtb" "$MNT/$d.dtb"; done
# set-dtb: -normal is the base variant (rear camera, USB-C as a device),
# kept under its own name because the active name is overwritten
cp "$KP/rk3566-teclast-p25t.dtb" "$MNT/rk3566-teclast-p25t-normal.dtb"
# The first boot uses USB-C as a host, so a keyboard on the USB-C port
# works for the first login (and for pairing a Bluetooth keyboard).
# set-usb-role normal switches to USB-C as a device (console and network
# for a PC over the cable) from the next boot on.
cp "$KP/rk3566-teclast-p25t-usbhost.dtb" "$MNT/rk3566-teclast-p25t.dtb"
cp "$INITD/initramfs.cpio.gz" "$MNT/initramfs.cpio.gz"
echo "Delete this file to stay in the stage-1 system instead of starting Debian." > "$MNT/boot-debian"
sync
cmp -s "$KP/Image" "$MNT/Image" || die "Image differs on the card after copying"
for d in rk3566-teclast-p25t-usbhost rk3566-teclast-p25t-front rk3566-teclast-p25t-front-usbhost; do
    cmp -s "$KP/$d.dtb" "$MNT/$d.dtb" || die "$d.dtb differs on the card after copying"
done
cmp -s "$KP/rk3566-teclast-p25t-usbhost.dtb" "$MNT/rk3566-teclast-p25t.dtb" || die "the active device tree differs after copying"
cmp -s "$KP/rk3566-teclast-p25t.dtb" "$MNT/rk3566-teclast-p25t-normal.dtb" || die "the -normal device tree differs after copying"
cmp -s "$INITD/initramfs.cpio.gz" "$MNT/initramfs.cpio.gz" || die "initramfs differs after copying"

say "8/9 CARD-SHA256SUMS"
python3 - "$MNT" <<'PYEOF'
import sys, os, hashlib
boot = sys.argv[1]
path = os.path.join(boot, "CARD-SHA256SUMS")
lines = open(path).read().splitlines() if os.path.exists(path) else []
changed = ["Image", "rk3566-teclast-p25t.dtb", "rk3566-teclast-p25t-normal.dtb",
           "rk3566-teclast-p25t-usbhost.dtb", "rk3566-teclast-p25t-front.dtb",
           "rk3566-teclast-p25t-front-usbhost.dtb", "initramfs.cpio.gz"]
out = []
for l in lines:
    p = l.split()
    if len(p) != 2 or p[1] in changed:
        continue
    if not os.path.exists(os.path.join(boot, p[1])):
        print("dropped (no longer on the card):", p[1])
        continue
    out.append(l)
for name in changed:
    h = hashlib.sha256(open(os.path.join(boot, name), "rb").read()).hexdigest()
    out.append(h + "  " + name)
open(path, "w").write("\n".join(out) + "\n")
print(len(out), "entries")
PYEOF
sync
( cd "$MNT" && sha256sum -c --quiet CARD-SHA256SUMS ) || die "the P25TBOOT check failed"
echo "CARD-SHA256SUMS: all entries OK"
umount "$MNT"
rmdir "$MNT"
sync

say "9/9 Done"
echo "OK: the card is ready ($DESKTOP, host name $THOST, kernel $REL)."
echo "If the file manager mounted P25TROOT or P25TBOOT again, eject them there;"
echo "then put the card into the tablet and power it on."
