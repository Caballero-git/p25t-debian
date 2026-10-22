#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build_initramfs.sh - build the card's start-up system ("stage 1",
# initramfs.cpio.gz): a static arm64 busybox and initramfs/init, nothing
# else.
#
#     bash <WORK>/p25t-debian/tools/build_initramfs.sh
#
# What stage 1 does on the tablet (initramfs/init): mounts the card's
# P25TBOOT partition, writes a log of every boot into its logs/ folder,
# and hands over to Debian. Holding a volume key at power-on keeps it in
# stage 1 instead: a rescue system with a shell on the USB-C port.
#
# Source, pinned: busybox 1.37.0, the release tarball (sha256 3311dff3...),
# from busybox.net or, if that fails, the identical Debian/Ubuntu "orig"
# tarball; kept in build/src/.
# Busybox configuration: defconfig, plus three changes:
#   CONFIG_STATIC=y                      no shared libraries in the initramfs
#   CONFIG_SHA1_HWACCEL, SHA256_HWACCEL  off: x86-only code that breaks
#                                        a cross build in 1.37.0
#   CONFIG_TC                            off: does not build against current
#                                        kernel headers (CBQ was removed)
# Output, in build/stage1/:
#   initramfs.cpio.gz, .sha256     what goes onto the card
#   initramfs.list                 its contents (mode, owner, name, link)
# Reproducible: fixed file times (SOURCE_DATE_EPOCH = the busybox release
# date), sorted names, cpio --reproducible, gzip -n, UTC. Built with
# Ubuntu 24.04's cross compiler (gcc 13.3) it is sha256 30364a9e..., on
# every PC tried so far; another compiler version gives another checksum,
# which is no error.
# About a minute, plus the download on the first run.
set -euo pipefail
umask 022                       # the same file modes for every user

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$REPO/build/src"
OUT="$REPO/build/stage1"
BB_VER=1.37.0
BB_TAR="busybox-$BB_VER.tar.bz2"
BB_SHA=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
BB_URLS="https://busybox.net/downloads/$BB_TAR
http://archive.ubuntu.com/ubuntu/pool/main/b/busybox/busybox_$BB_VER.orig.tar.bz2"
AUTHOR_SHA=30364a9eed88b256ad6931529c7582c1761efba6249a8d3d07774c9627b0c3a0
die() { echo "STOPPED: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }

# one line per cpio entry: mode owner group name [-> target] (no dates, no sizes)
cpio_list() {
    zcat "$1" | cpio -itv --quiet 2> /dev/null \
        | awk '{ l = $1 " " $3 " " $4 " " $9; if ($10 == "->") l = l " -> " $11; print l }' \
        | sort -k4
}

say "1/4 Checks"
[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
missing=""
for t in make gcc cpio curl bzip2 gzip aarch64-linux-gnu-gcc; do
    command -v "$t" > /dev/null || missing="$missing $t"
done
[ -z "$missing" ] || die "missing:$missing
  sudo apt install build-essential gcc-aarch64-linux-gnu cpio curl bzip2"
[ -f "$REPO/initramfs/init" ] || die "$REPO/initramfs/init missing"
echo "OK"

say "2/4 Source: busybox $BB_VER"
mkdir -p "$SRC" "$OUT"
if [ ! -f "$SRC/$BB_TAR" ]; then
    for u in $BB_URLS; do
        echo "downloading $u"
        if curl -fsSL --max-time 300 -o "$SRC/$BB_TAR.part" "$u"; then
            mv "$SRC/$BB_TAR.part" "$SRC/$BB_TAR"; break
        fi
        rm -f "$SRC/$BB_TAR.part"
    done
fi
[ -f "$SRC/$BB_TAR" ] || die "could not download $BB_TAR"
echo "$BB_SHA  $SRC/$BB_TAR" | sha256sum -c --quiet || die "$SRC/$BB_TAR is not the known release (sha256 ${BB_SHA:0:12}...)"
echo "$BB_TAR: sha256 ${BB_SHA:0:12}... OK"

say "3/4 Busybox build (about a minute)"
BB="$SRC/busybox-$BB_VER"
rm -rf "$BB"                                   # always from a fresh tree
tar -xjf "$SRC/$BB_TAR" -C "$SRC"
export SOURCE_DATE_EPOCH TZ=UTC                # same banner date on every PC
SOURCE_DATE_EPOCH=$(stat -c %Y "$BB/Makefile")  # the release date
make -C "$BB" -s defconfig > /dev/null
sed -i -e 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' \
       -e 's/^CONFIG_SHA1_HWACCEL=y$/# CONFIG_SHA1_HWACCEL is not set/' \
       -e 's/^CONFIG_SHA256_HWACCEL=y$/# CONFIG_SHA256_HWACCEL is not set/' \
       -e 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' "$BB/.config"
grep -qx 'CONFIG_STATIC=y' "$BB/.config" || die "CONFIG_STATIC not set"
for c in SHA1_HWACCEL SHA256_HWACCEL TC; do
    grep -qx "# CONFIG_$c is not set" "$BB/.config" || die "CONFIG_$c not switched off"
done
make -C "$BB" -s CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" > "$OUT/busybox-build.log" 2>&1 \
    || { tail -20 "$OUT/busybox-build.log"; die "busybox build failed (log: $OUT/busybox-build.log)"; }
cp "$BB/.config" "$OUT/busybox.config"
strings "$BB/busybox" | grep -m1 '^BusyBox v' || true

say "4/4 initramfs"
ROOT="$OUT/root"
rm -rf "$ROOT"; mkdir -p "$ROOT"
make -C "$BB" -s CROSS_COMPILE=aarch64-linux-gnu- CONFIG_PREFIX="$ROOT" install > /dev/null
mkdir -p "$ROOT"/boot "$ROOT"/dev "$ROOT"/etc "$ROOT"/proc "$ROOT"/sys "$ROOT"/tmp
install -m 755 "$REPO/initramfs/init" "$ROOT/init"
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
( cd "$ROOT" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet ) \
    | gzip -9 -n > "$OUT/initramfs.cpio.gz"
( cd "$OUT" && sha256sum initramfs.cpio.gz > initramfs.cpio.gz.sha256 )
cpio_list "$OUT/initramfs.cpio.gz" > "$OUT/initramfs.list"
SHA=$(cut -d' ' -f1 "$OUT/initramfs.cpio.gz.sha256")
echo "$OUT/initramfs.cpio.gz: $(stat -c %s "$OUT/initramfs.cpio.gz") bytes, $(wc -l < "$OUT/initramfs.list") entries, sha256 ${SHA:0:16}..."
if [ "$SHA" = "$AUTHOR_SHA" ]; then
    echo "identical to the author's build"
else
    echo "differs from the author's build (${AUTHOR_SHA:0:8}...): expected with another compiler version"
fi
echo "OK: stage-1 initramfs built"
