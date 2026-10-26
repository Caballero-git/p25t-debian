#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# install_modules.sh - install the kernel modules and the Wi-Fi firmware of
# a new kernel on the running tablet, keeping a backup of what they
# replace. First of the two steps of a kernel update; the second is
# deploy_kernel.sh, then a reboot.
#
#     sudo bash install_modules.sh <TAG> <PACK>    install
#     sudo bash install_modules.sh restore <TAG>   put the backed-up modules
#                                                  and firmware back
#
# <PACK>  the folder build/kernel-pack/ of tools/pack_kernel.sh, copied
#         from the PC to the tablet (scp -r).
# <TAG>   a short name for this update, used in the backup names: letters,
#         digits, . _ - (for example the date, 20261026, or the number of
#         the newest patch, 0031). Use the same TAG for deploy_kernel.sh.
#
# Backups go to ~/boot-backups/ of the user who runs sudo:
#   modules-<release>.pre-<TAG>-backup.tar   (if that release was installed)
#   firmware-aic8800.pre-<TAG>-backup.tar    (if the firmware changes)
# Nothing is ever deleted from there.
#
# The modules of every P25T kernel have the same release name (7.3.0-p25t),
# so this replaces the running kernel's modules: run deploy_kernel.sh and
# reboot right after it.
set -euo pipefail

ROOT=${P25T_ROOT:-}                     # set only for testing: a root folder
MODS=$ROOT/usr/lib/modules
FW=$ROOT/usr/lib/firmware
die() { echo "STOPPED: $*" >&2; exit 1; }
usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
depmod_rel() { if [ -n "$ROOT" ]; then depmod -a -b "$ROOT" "$1"; else depmod -a "$1"; fi; }

[ $# -ge 1 ] || usage
[ "$(id -u)" -eq 0 ] || die "run it with sudo"
OWNER=${SUDO_USER:-root}
BK=$(getent passwd "$OWNER" | cut -d: -f6)/boot-backups
check_tag() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "TAG '$1': use letters, digits, . _ - only"; }

if [ "$1" = restore ]; then
    [ $# -eq 2 ] || usage
    TAG=$2; check_tag "$TAG"
    T=$(find "$BK" -maxdepth 1 -name "modules-*.pre-$TAG-backup.tar" 2> /dev/null | head -1)
    [ -n "$T" ] || die "no modules backup for $TAG in $BK"
    REL=$(basename "$T"); REL=${REL#modules-}; REL=${REL%.pre-"$TAG"-backup.tar}
    echo "restoring $MODS/$REL from $T"
    rm -rf "$MODS/.$REL.restore" && mkdir -p "$MODS/.$REL.restore"
    tar -C "$MODS/.$REL.restore" -xf "$T" || die "unpacking the backup failed (nothing replaced)"
    [ -d "$MODS/.$REL.restore/$REL" ] || die "the backup does not contain $REL"
    rm -rf "${MODS:?}/${REL:?}" && mv "$MODS/.$REL.restore/$REL" "$MODS/$REL" && rmdir "$MODS/.$REL.restore"
    F=$BK/firmware-aic8800.pre-$TAG-backup.tar
    if [ -f "$F" ]; then
        echo "restoring $FW/aic8800_fw from $F"
        rm -rf "$FW/aic8800_fw" && tar -C "$FW" -xf "$F" || die "firmware restore failed"
    fi
    depmod_rel "$REL"
    sync
    echo "OK: modules of $REL restored. Put the previous kernel back too:"
    echo "    sudo bash $(dirname "$0")/deploy_kernel.sh restore $TAG"
    exit 0
fi

[ $# -eq 2 ] || usage
TAG=$1; check_tag "$TAG"
DIR=$2
[ -d "$DIR" ] || die "folder $DIR not found"
DIR=$(cd "$DIR" && pwd)

echo "=== 1/5 The new kernel's files"
[ -f "$DIR/files.sha256" ] || die "$DIR/files.sha256 missing - is $DIR the kernel-pack folder?"
( cd "$DIR" && sha256sum -c --quiet files.sha256 ) || die "the files in $DIR do not match files.sha256 (bad copy?)"
REL=$(cat "$DIR/release.txt")
IMGREL=$(strings "$DIR/Image" | sed -n 's/.*Linux version \([0-9][^ ]*\).*/\1/p' | sed -n 1p)
[ "$IMGREL" = "$REL" ] || die "the Image is $IMGREL, the modules are $REL"
tar -tf "$DIR/modules.tar" | grep -q "^lib/modules/$REL/extra/aic8800_fdrv.ko$" \
    || die "modules.tar has no Wi-Fi module for $REL"
echo "release $REL (running now: $(uname -r))"

echo "=== 2/5 Space"
need=$(( $(stat -c %s "$DIR/modules.tar") * 2 + 10485760 ))
mkdir -p "$MODS"
free=$(df -B1 --output=avail "$MODS" | tail -1 | tr -d ' ')
echo "need about $((need / 1048576)) MB, free $((free / 1048576)) MB"
[ "$free" -gt "$need" ] || die "not enough space on the root file system"

echo "=== 3/5 Backup into $BK"
mkdir -p "$BK"
chown "$OWNER": "$BK" 2> /dev/null || true
MB=$BK/modules-$REL.pre-$TAG-backup.tar
[ ! -e "$MB" ] || die "$MB exists already - this TAG was used before; choose another"
if [ -d "$MODS/$REL" ]; then
    tar -C "$MODS" -cf "$MB" "$REL" || die "backup of $MODS/$REL failed"
    chown "$OWNER": "$MB" 2> /dev/null || true
    echo "backup: $MB ($(tar -tf "$MB" | grep -c '\.ko') modules)"
else
    echo "no $MODS/$REL yet - nothing to back up"
fi

echo "=== 4/5 Modules"
NEW=$MODS/.$REL.new
rm -rf "$NEW" && mkdir -p "$NEW"
tar -C "$NEW" -xf "$DIR/modules.tar" || die "unpacking failed (nothing replaced)"
[ -d "$NEW/lib/modules/$REL" ] || die "unexpected layout in modules.tar (nothing replaced)"
rm -rf "${MODS:?}/${REL:?}" && mv "$NEW/lib/modules/$REL" "$MODS/$REL" && rm -rf "$NEW" \
    || die "replacing failed - restore with: sudo bash $0 restore $TAG"
depmod_rel "$REL" || die "depmod failed"
grep -q 'extra/aic8800_fdrv.ko' "$MODS/$REL/modules.dep" || die "modules.dep does not list the Wi-Fi module"
( cd "$MODS" && for k in $(tar -tf "$DIR/modules.tar" | grep '\.ko'); do
      r=${k#lib/modules/}
      cmp -s <(tar -xOf "$DIR/modules.tar" "$k") "$r" || { echo "differs: $r"; exit 1; }
  done ) || die "an installed module differs from modules.tar"
echo "installed and checked $(find "$MODS/$REL" -name '*.ko*' | wc -l) modules in $MODS/$REL"

echo "=== 5/5 Wi-Fi firmware"
T=$(mktemp -d)
tar -C "$T" -xf "$DIR/firmware-aic8800.tar"
if [ -d "$FW/aic8800_fw" ] && diff -rq "$T/lib/firmware/aic8800_fw" "$FW/aic8800_fw" > /dev/null; then
    echo "the same as the installed firmware - left as it is"
else
    if [ -d "$FW/aic8800_fw" ]; then
        tar -C "$FW" -cf "$BK/firmware-aic8800.pre-$TAG-backup.tar" aic8800_fw
        chown "$OWNER": "$BK/firmware-aic8800.pre-$TAG-backup.tar" 2> /dev/null || true
        echo "backup: $BK/firmware-aic8800.pre-$TAG-backup.tar"
    fi
    mkdir -p "$FW" && rm -rf "$FW/aic8800_fw" && cp -r "$T/lib/firmware/aic8800_fw" "$FW/aic8800_fw" \
        || die "copying the firmware failed"
    diff -rq "$T/lib/firmware/aic8800_fw" "$FW/aic8800_fw" > /dev/null || die "the firmware differs after copying"
    echo "firmware installed"
fi
rm -rf "$T"
sync

echo "OK: modules of $REL installed. Next, at once:"
echo "    sudo bash $(dirname "$0")/deploy_kernel.sh $TAG $DIR"
echo "To go back: sudo bash $0 restore $TAG"
