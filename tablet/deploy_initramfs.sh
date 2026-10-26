#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# deploy_initramfs.sh - put a new stage-1 initramfs on the running card's
# P25TBOOT (mounted at /boot/firmware), on the tablet, keeping the previous
# one for a rollback. The kernel and the root filesystem are not touched.
#
#   sudo bash deploy_initramfs.sh <FILE>     install <FILE> (its sha256 must
#                                            match <FILE>.sha256 next to it)
#   sudo bash deploy_initramfs.sh restore    put the previous one back
#   bash deploy_initramfs.sh status          what is on the card
#
# <FILE> is build/stage1/initramfs.cpio.gz of tools/build_initramfs.sh,
# copied from the PC to the tablet together with initramfs.cpio.gz.sha256.
# The outgoing initramfs is kept as initramfs.cpio.gz.previous on
# P25TBOOT and as a copy in ~/boot-backups/ of the user who ran sudo.
# CARD-SHA256SUMS is updated and checked afterwards. Reboot to use it.
# If the card no longer boots: on the PC, copy initramfs.cpio.gz.previous
# over initramfs.cpio.gz on P25TBOOT.
set -euo pipefail

BOOT=${P25T_BOOT:-/boot/firmware}       # set only for testing
CUR="$BOOT/initramfs.cpio.gz"
PREV="$BOOT/initramfs.cpio.gz.previous"
SUMS="$BOOT/CARD-SHA256SUMS"
die() { echo "STOPPED: $*" >&2; exit 1; }
usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

[ -f "$CUR" ] || die "$CUR not found - is P25TBOOT mounted at $BOOT?"
MODE=${1:-}
case "$MODE" in
    "") usage ;;
    status)
        echo "active:   $(sha "$CUR")  initramfs.cpio.gz"
        if [ -f "$PREV" ]; then echo "previous: $(sha "$PREV")  initramfs.cpio.gz.previous"
        else echo "previous: none"; fi
        grep ' initramfs.cpio.gz$' "$SUMS" 2> /dev/null | sed 's/^/listed:   /' || echo "listed:   not in CARD-SHA256SUMS"
        exit 0 ;;
esac
[ "$(id -u)" -eq 0 ] || die "run it with sudo"

update_sums() {
    [ -f "$SUMS" ] || : > "$SUMS"
    { grep -v ' initramfs.cpio.gz$' "$SUMS" || true; echo "$(sha "$CUR")  initramfs.cpio.gz"; } > "$SUMS.new"
    mv "$SUMS.new" "$SUMS"
    sync
    ( cd "$BOOT" && sha256sum -c --quiet CARD-SHA256SUMS ) || die "CARD-SHA256SUMS check failed"
    echo "CARD-SHA256SUMS: all entries OK"
}

if [ "$MODE" = restore ]; then
    [ -f "$PREV" ] || die "no $PREV to restore"
    cp "$PREV" "$CUR.new" && sync
    cmp -s "$PREV" "$CUR.new" || die "copy differs from $PREV"
    mv "$CUR.new" "$CUR"; sync
    echo "restored the previous initramfs ($(sha "$CUR" | cut -c1-16)...)"
    update_sums
    echo "reboot to use it"
    exit 0
fi

NEW=$MODE
[ -f "$NEW" ] || die "$NEW not found"
[ -f "$NEW.sha256" ] || die "$NEW.sha256 not found (copy it with the initramfs)"
[ "$(sha "$NEW")" = "$(cut -d' ' -f1 "$NEW.sha256")" ] || die "$NEW does not match $NEW.sha256 (bad copy?)"
gzip -t "$NEW" 2> /dev/null || die "$NEW is not a valid gzip file"
[ "$(zcat "$NEW" | head -c 6)" = 070701 ] || die "$NEW is not a cpio (newc) archive - not an initramfs"
if command -v cpio > /dev/null; then
    zcat "$NEW" | cpio -it --quiet 2> /dev/null | grep -qx init || die "$NEW has no /init - not an initramfs"
fi
if [ "$(sha "$NEW")" = "$(sha "$CUR")" ]; then
    echo "the card already has this initramfs ($(sha "$CUR" | cut -c1-16)...) - nothing to do"
    exit 0
fi
NEEDED=$(( $(stat -c %s "$NEW") / 1024 + 1024 ))
FREE=$(df -k --output=avail "$BOOT" | tail -1 | tr -d ' ')
[ "$FREE" -gt "$NEEDED" ] || die "only ${FREE} KiB free on $BOOT"

OWNER=${SUDO_USER:-root}
BK=$(getent passwd "$OWNER" | cut -d: -f6)/boot-backups
mkdir -p "$BK"
STAMP=$(date +%Y%m%d-%H%M%S)
cp "$CUR" "$BK/initramfs.cpio.gz.$STAMP"
chown "$OWNER": "$BK" "$BK/initramfs.cpio.gz.$STAMP" 2> /dev/null || true
cp "$CUR" "$PREV"
sync
cmp -s "$CUR" "$PREV" || die "backup on P25TBOOT differs"
echo "kept the outgoing initramfs ($(sha "$PREV" | cut -c1-16)...) as $PREV and $BK/initramfs.cpio.gz.$STAMP"
cp "$NEW" "$CUR.new" && sync
cmp -s "$NEW" "$CUR.new" || die "copy differs from $NEW"
mv "$CUR.new" "$CUR"; sync
echo "installed $NEW ($(sha "$CUR" | cut -c1-16)...)"
update_sums
echo "reboot to use it; to go back: sudo bash $0 restore"
