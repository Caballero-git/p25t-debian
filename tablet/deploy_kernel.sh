#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# deploy_kernel.sh - put a new kernel Image and its four device trees on
# the running card's P25TBOOT (mounted at /boot/firmware), keeping the
# outgoing ones for a rollback. Second of the two steps of a kernel
# update, after install_modules.sh; then reboot.
#
#     sudo bash deploy_kernel.sh <TAG> <PACK>   install
#     sudo bash deploy_kernel.sh restore <TAG>  put the kernel and device
#                                               trees of before <TAG> back
#     bash deploy_kernel.sh status              what is on the card
#
# <PACK> and <TAG> as for install_modules.sh (the same TAG).
#
# The camera and USB-C role chosen with set-dtb stay as they are: the
# active device tree is replaced by the new copy of the same variant.
# The outgoing files stay on P25TBOOT as <name>.pre-<TAG>-backup, with
# copies in ~/boot-backups/ of the user who runs sudo. CARD-SHA256SUMS is
# updated and checked. Nothing is deleted; when P25TBOOT gets full,
# remove old *.pre-*-backup files from it by hand (copies stay in
# ~/boot-backups/).
#
# If the new kernel does not start: card into the PC, on P25TBOOT copy
#   Image.pre-<TAG>-backup over Image, and the backup of the variant in
#   use (set-dtb's table: rk3566-teclast-p25t-<variant>.dtb.pre-<TAG>-backup)
#   over rk3566-teclast-p25t.dtb;
# then on the tablet: sudo bash install_modules.sh restore <TAG>
#                     sudo bash deploy_kernel.sh restore <TAG>
set -euo pipefail

BOOT=${P25T_BOOT:-/boot/firmware}       # set only for testing
ROOT=${P25T_ROOT:-}                     # set only for testing
ACTIVE=$BOOT/rk3566-teclast-p25t.dtb
SUMS=$BOOT/CARD-SHA256SUMS
# variant name on P25TBOOT <- name in kernel-pack
VARIANTS="normal usbhost front front-usbhost"
packname() { [ "$1" = normal ] && echo rk3566-teclast-p25t.dtb || echo "rk3566-teclast-p25t-$1.dtb"; }
cardname() { echo "rk3566-teclast-p25t-$1.dtb"; }
# the boot files a kernel update changes, as named on P25TBOOT
FILES=(Image rk3566-teclast-p25t-normal.dtb rk3566-teclast-p25t-usbhost.dtb
       rk3566-teclast-p25t-front.dtb rk3566-teclast-p25t-front-usbhost.dtb)
backups() {   # list the *.pre-*-backup files on P25TBOOT
    local f n=0
    for f in "$BOOT"/*.pre-*-backup; do [ -e "$f" ] && { echo "  $(basename "$f")"; n=1; }; done
    [ $n = 1 ] || echo "  none"
}
die() { echo "STOPPED: $*" >&2; exit 1; }
usage() { sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
version() { strings "$1" | grep -m1 'Linux version' | cut -c1-100; }
check_tag() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "TAG '$1': use letters, digits, . _ - only"; }

# the variant the active device tree is a copy of
current() {
    local v
    for v in $VARIANTS; do
        if [ -f "$BOOT/$(cardname "$v")" ] && cmp -s "$ACTIVE" "$BOOT/$(cardname "$v")"; then
            echo "$v"; return 0
        fi
    done
    return 1
}

sums_update() {   # sums_update <name>... : replace or add their lines, check all
    python3 - "$SUMS" "$BOOT" "$@" <<'PYEOF'
import sys, os, hashlib
sums, boot, names = sys.argv[1], sys.argv[2], sys.argv[3:]
lines = open(sums).read().splitlines() if os.path.exists(sums) else []
lines = [l for l in lines if len(l.split()) == 2 and l.split()[1] not in names]
for n in names:
    lines.append(hashlib.sha256(open(os.path.join(boot, n), "rb").read()).hexdigest() + "  " + n)
open(sums, "w").write("\n".join(lines) + "\n")
PYEOF
    sync
    ( cd "$BOOT" && sha256sum -c --quiet CARD-SHA256SUMS ) || die "CARD-SHA256SUMS check failed - see above"
    echo "CARD-SHA256SUMS updated and checked"
}

[ $# -ge 1 ] || usage
[ -n "${TESTING:-}" ] || mountpoint -q "$BOOT" || die "$BOOT is not mounted"
[ -f "$BOOT/Image" ] && [ -f "$ACTIVE" ] || die "no Image or $(basename "$ACTIVE") on $BOOT"

if [ "$1" = status ]; then
    echo "running: $(uname -r) $(uname -v)"
    echo "on the card: $(version "$BOOT/Image")"
    if v=$(current); then echo "active device tree: $v ($(cardname "$v"))"
    else echo "active device tree: a copy of none of the variants (set-dtb status)"; fi
    echo "backups on the card:"
    backups
    df -h --output=avail "$BOOT" | tail -1 | sed 's/^ */free on P25TBOOT: /'
    ( cd "$BOOT" && sha256sum -c --quiet CARD-SHA256SUMS ) && echo "CARD-SHA256SUMS: all entries OK"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "run it with sudo"
OWNER=${SUDO_USER:-root}
BK=$(getent passwd "$OWNER" | cut -d: -f6)/boot-backups
V=$(current) || die "the active device tree is a copy of none of the variants - sort that out first (set-dtb status)"

if [ "$1" = restore ]; then
    [ $# -eq 2 ] || usage
    TAG=$2; check_tag "$TAG"
    [ -f "$BOOT/Image.pre-$TAG-backup" ] || die "no Image.pre-$TAG-backup on $BOOT"
    for v in $VARIANTS; do
        [ -f "$BOOT/$(cardname "$v").pre-$TAG-backup" ] || die "no $(cardname "$v").pre-$TAG-backup on $BOOT"
    done
    echo "putting back the kernel of before $TAG: $(version "$BOOT/Image.pre-$TAG-backup")"
    for f in "${FILES[@]}"; do
        cp "$BOOT/$f.pre-$TAG-backup" "$BOOT/$f.new" && sync
        cmp -s "$BOOT/$f.pre-$TAG-backup" "$BOOT/$f.new" || die "copy of $f.pre-$TAG-backup differs"
        mv "$BOOT/$f.new" "$BOOT/$f"
    done
    cp "$BOOT/$(cardname "$V")" "$ACTIVE" && sync
    cmp -s "$BOOT/$(cardname "$V")" "$ACTIVE" || die "the active device tree differs after copying"
    sums_update rk3566-teclast-p25t.dtb "${FILES[@]}"
    echo "OK: previous kernel back, device tree variant $V kept. If not done yet:"
    echo "    sudo bash $(dirname "$0")/install_modules.sh restore $TAG"
    echo "then: sudo reboot"
    exit 0
fi

[ $# -eq 2 ] || usage
TAG=$1; check_tag "$TAG"
DIR=$2
[ -d "$DIR" ] || die "folder $DIR not found"
DIR=$(cd "$DIR" && pwd)

echo "=== 1/6 The new kernel's files"
[ -f "$DIR/files.sha256" ] || die "$DIR/files.sha256 missing - is $DIR the kernel-pack folder?"
( cd "$DIR" && sha256sum -c --quiet files.sha256 ) || die "the files in $DIR do not match files.sha256 (bad copy?)"
[ "$(dd if="$DIR/Image" bs=1 skip=56 count=4 2> /dev/null)" = ARMd ] || die "$DIR/Image is not an arm64 kernel"
for v in $VARIANTS; do [ -f "$DIR/$(packname "$v")" ] || die "$(packname "$v") missing in $DIR"; done
REL=$(cat "$DIR/release.txt")
[ -f "$ROOT/usr/lib/modules/$REL/extra/aic8800_fdrv.ko" ] \
    || die "no modules for $REL installed - run install_modules.sh first"
cmp -s <(tar -xOf "$DIR/modules.tar" "lib/modules/$REL/extra/aic8800_fdrv.ko") \
       "$ROOT/usr/lib/modules/$REL/extra/aic8800_fdrv.ko" \
    || die "the installed modules are not this kernel's - run install_modules.sh $TAG $DIR first"
echo "new:  $(version "$DIR/Image")"
echo "card: $(version "$BOOT/Image")"
same=1
cmp -s "$DIR/Image" "$BOOT/Image" || same=0
for v in $VARIANTS; do cmp -s "$DIR/$(packname "$v")" "$BOOT/$(cardname "$v")" || same=0; done
if [ $same = 1 ]; then echo "the card has this kernel and these device trees already - nothing to do"; exit 0; fi

echo "=== 2/6 Device tree variant in use"
echo "$V (set-dtb keeps it)"

echo "=== 3/6 Space on P25TBOOT"
need=$(( $(stat -c %s "$DIR/Image") + 1048576 ))
for v in $VARIANTS; do need=$(( need + 2 * $(stat -c %s "$DIR/$(packname "$v")") )); done
free=$(df -B1 --output=avail "$BOOT" | tail -1 | tr -d ' ')
echo "need about $((need / 1048576)) MB, free $((free / 1048576)) MB"
if [ "$free" -lt "$need" ]; then
    echo "backups on the card:"; backups
    die "not enough space - remove old *.pre-*-backup files from $BOOT (copies are in $BK)"
fi
for f in "${FILES[@]}"; do
    [ ! -e "$BOOT/$f.pre-$TAG-backup" ] || die "$f.pre-$TAG-backup exists already - this TAG was used before"
done

echo "=== 4/6 Backups: on the card (*.pre-$TAG-backup) and in $BK"
mkdir -p "$BK"; chown "$OWNER": "$BK" 2> /dev/null || true
for f in "${FILES[@]}"; do
    cp -p "$BOOT/$f" "$BK/$f.pre-$TAG-backup" && cmp -s "$BOOT/$f" "$BK/$f.pre-$TAG-backup" \
        || die "backup of $f into $BK failed"
    chown "$OWNER": "$BK/$f.pre-$TAG-backup" 2> /dev/null || true
    cp -p "$BOOT/$f" "$BOOT/$f.pre-$TAG-backup" && sync
    cmp -s "$BOOT/$f" "$BOOT/$f.pre-$TAG-backup" || die "backup of $f on the card failed"
done
cp -p "$SUMS" "$BK/CARD-SHA256SUMS.pre-$TAG-backup"
chown "$OWNER": "$BK/CARD-SHA256SUMS.pre-$TAG-backup" 2> /dev/null || true
echo "done"

echo "=== 5/6 New files onto the card"
cp "$DIR/Image" "$BOOT/Image" || die "copying Image failed - restore with: sudo bash $0 restore $TAG"
for v in $VARIANTS; do
    cp "$DIR/$(packname "$v")" "$BOOT/$(cardname "$v")" || die "copying $(packname "$v") failed - restore with: sudo bash $0 restore $TAG"
done
sync
cmp -s "$DIR/Image" "$BOOT/Image" || die "Image differs on the card after copying"
for v in $VARIANTS; do
    cmp -s "$DIR/$(packname "$v")" "$BOOT/$(cardname "$v")" || die "$(cardname "$v") differs after copying"
done
cp "$BOOT/$(cardname "$V")" "$ACTIVE" && sync
cmp -s "$BOOT/$(cardname "$V")" "$ACTIVE" || die "the active device tree differs after copying"
echo "Image and device trees copied and compared; active: $V"

echo "=== 6/6 CARD-SHA256SUMS"
sums_update rk3566-teclast-p25t.dtb "${FILES[@]}"

echo "OK: new kernel on the card ($REL, variant $V). Now: sudo reboot"
echo "To go back: sudo bash $0 restore $TAG"
