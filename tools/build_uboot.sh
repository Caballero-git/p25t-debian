#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build_uboot.sh - build the boot loader for the card: mainline U-Boot and
# Rockchip's BL31 in one FIT image, the file the tablet's own first-stage
# loader (in its eMMC, never changed) reads from the card.
#
#     bash <WORK>/p25t-debian/tools/build_uboot.sh
#
# Sources, pinned, downloaded into build/src/ on the first run:
#   U-Boot  github.com/u-boot/u-boot, tag v2026.10-rc5 (commit a06e89ab),
#           shallow clone, about 420 MB
#   BL31    github.com/rockchip-linux/rkbin, bin/rk35/rk3568_bl31_v1.46.elf
#           at commit 3e288fe8, checked by sha256. Only this one file is
#           fetched (the clone has the history but no file contents). It
#           is Rockchip's binary under Rockchip's licence, so it never goes
#           into this repository.
# From this repository:
#   u-boot/p25t-u-boot.config  U-Boot configuration (boot command, no delay)
#   u-boot/split_bl31.py       BL31 ELF -> one file per load segment
#   u-boot/p25t.its            the FIT layout the tablet's loader accepts
# Output, in build/u-boot/:
#   uboot.itb, uboot.itb.sha256    the FIT (must stay below 2 MiB)
#   u-boot.bin, u-boot.dtb, bl31_0x*.bin, p25t.its   what went into it
#
# Reproducible: SOURCE_DATE_EPOCH is the tag's commit time, so the same
# compiler gives the same FIT on every PC. The author's build (Ubuntu
# 24.04's cross compiler, gcc 13.3) is sha256 97dbd0aa...; another
# compiler version gives another checksum, which is no error.
# About a minute, plus the download on the first run.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$REPO/build/src"
UB="$SRC/u-boot"
RKBIN="$SRC/rkbin"
OUT="$REPO/build/u-boot"
UB_URL=https://github.com/u-boot/u-boot.git
UB_TAG=v2026.10-rc5
UB_COMMIT=a06e89ab05eaa2b8344d521319399333cd760ae5
RKBIN_URL=https://github.com/rockchip-linux/rkbin.git
RKBIN_COMMIT=3e288fe814e059dd06833495f845cab04ac20a5c
BL31_PATH=bin/rk35/rk3568_bl31_v1.46.elf
BL31_SHA=c81ac7e8e1fd727cf7f0db62a9aaea760bde2b270e34d98eb264a264b86df749
AUTHOR_FIT_SHA=97dbd0aa7136be06ff9c599184cb17473f6f6a65d2f9fb6420c0a1819e91415a
die() { echo "STOPPED: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }

say "1/4 Checks"
[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
missing=""
for t in git make gcc bison flex swig python3 aarch64-linux-gnu-gcc; do
    command -v "$t" > /dev/null || missing="$missing $t"
done
python3 -c 'import setuptools' 2> /dev/null || missing="$missing python3-setuptools"
[ -f /usr/include/openssl/ssl.h ] || missing="$missing libssl-dev"
[ -f /usr/include/gnutls/gnutls.h ] || missing="$missing libgnutls28-dev"
[ -f /usr/include/uuid/uuid.h ] || missing="$missing uuid-dev"
python3 -c 'import sysconfig, os, sys; sys.exit(not os.path.exists(os.path.join(sysconfig.get_paths()["include"], "Python.h")))' \
    || missing="$missing python3-dev"
[ -z "$missing" ] || die "missing:$missing
  sudo apt install build-essential gcc-aarch64-linux-gnu bison flex swig python3-dev python3-setuptools libssl-dev libgnutls28-dev uuid-dev git"
for f in p25t-u-boot.config split_bl31.py p25t.its; do
    [ -f "$REPO/u-boot/$f" ] || die "$REPO/u-boot/$f missing"
done
echo "OK"

say "2/4 Sources"
mkdir -p "$SRC" "$OUT"
if [ ! -d "$UB/.git" ]; then
    echo "downloading U-Boot $UB_TAG (shallow clone, about 420 MB) ..."
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$UB_TAG" "$UB_URL" "$UB"
fi
[ "$(git -C "$UB" rev-parse HEAD)" = "$UB_COMMIT" ] || die "$UB is not at $UB_TAG ($UB_COMMIT)"
[ -z "$(git -C "$UB" status --porcelain --untracked-files=no)" ] || die "$UB has changed files (git -C $UB status)"
echo "U-Boot: $UB_TAG, ${UB_COMMIT:0:12}, unchanged"
if [ ! -d "$RKBIN/.git" ]; then
    echo "downloading rkbin's history without file contents (a few MB) ..."
    git clone -q --filter=blob:none --no-checkout "$RKBIN_URL" "$RKBIN"
fi
git -C "$RKBIN" show "$RKBIN_COMMIT:$BL31_PATH" > "$OUT/bl31.elf"
echo "$BL31_SHA  $OUT/bl31.elf" | sha256sum -c --quiet || die "BL31 is not the known file (sha256 ${BL31_SHA:0:12}...)"
echo "BL31: $(basename "$BL31_PATH") from rkbin ${RKBIN_COMMIT:0:12}, sha256 ${BL31_SHA:0:12}... OK"

say "3/4 U-Boot build (about a minute: u-boot.bin, u-boot.dtb and the tools)"
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$UB" log -1 --format=%ct)
cp "$REPO/u-boot/p25t-u-boot.config" "$UB/.config"
make -C "$UB" -s CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
cmp -s "$REPO/u-boot/p25t-u-boot.config" "$UB/.config" \
    || echo "note: olddefconfig changed the config (diff $REPO/u-boot/p25t-u-boot.config $UB/.config)"
make -C "$UB" -s CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" u-boot.bin u-boot.dtb tools
strings "$UB/u-boot.bin" | grep -m1 'U-Boot 20.*(' || true

say "4/4 FIT image"
rm -f "$OUT"/bl31_0x*.bin "$OUT/uboot.itb"
python3 "$REPO/u-boot/split_bl31.py" "$OUT/bl31.elf" "$OUT"
cp "$UB/u-boot.bin" "$UB/u-boot.dtb" "$REPO/u-boot/p25t.its" "$OUT/"
# mkimage runs "dtc" from PATH: use the one U-Boot just built
( cd "$OUT" && PATH="$UB/scripts/dtc:$PATH" "$UB/tools/mkimage" -E -B 0x200 -p 0x1000 \
      -f p25t.its uboot.itb > mkimage.log ) || { cat "$OUT/mkimage.log"; die "mkimage failed"; }
SIZE=$(stat -c %s "$OUT/uboot.itb")
[ "$SIZE" -lt 2097152 ] || die "the FIT is $SIZE bytes, more than 2 MiB"
( cd "$OUT" && sha256sum uboot.itb > uboot.itb.sha256 )
SHA=$(cut -d' ' -f1 "$OUT/uboot.itb.sha256")
echo "$OUT/uboot.itb: $SIZE bytes, sha256 ${SHA:0:16}..."
if [ "$SHA" = "$AUTHOR_FIT_SHA" ]; then
    echo "identical to the author's build"
else
    echo "differs from the author's build (${AUTHOR_FIT_SHA:0:8}...): expected with another compiler version"
fi
echo "OK: boot loader built"
echo "next: bash $REPO/tools/build_initramfs.sh"
