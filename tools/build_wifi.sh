#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build_wifi.sh - build the AIC8800 Wi-Fi/Bluetooth driver (not part of
# mainline Linux) for the kernel built by tools/build_kernel.sh.
#
#     bash <WORK>/p25t-debian/tools/build_wifi.sh
#
# Run it after build_kernel.sh, and again after every build_kernel.sh run
# (that script recreates modules-staging/ and so removes these modules).
#
# Source: github.com/radxa-pkg/aic8800 at commit 516e3b0, downloaded once
#         into build/src/aic8800, with its own Debian patch series applied
#         and kernel/aic8800-fix-linux-7.3-build.patch (two changes for the
#         7.3 Wi-Fi API). The prepared SDIO driver source is checked
#         against a fingerprint: the exact source of the driver that runs
#         on the tablet.
# Output: build/kernel/aic8800/ (objects)
#         build/kernel/modules-staging/lib/modules/<release>/extra/
#             aic8800_bsp.ko, aic8800_fdrv.ko
#         build/kernel/firmware-staging/lib/firmware/aic8800_fw/SDIO/aic8800/
# About a minute (the first run also downloads the source).
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(dirname "$REPO")
SRC="$WORK/linux"
OUT="$REPO/build/kernel"
AIC="$REPO/build/src/aic8800"
URL=https://github.com/radxa-pkg/aic8800.git
COMMIT=516e3b087763d80c44f5e3b6d2dd63e0d925c91d
FIX="$REPO/kernel/aic8800-fix-linux-7.3-build.patch"
DRV=src/SDIO/driver_fw/driver/aic8800
FW=src/SDIO/driver_fw/fw/aic8800
# sha256 over the sorted sha256sum lines of the SDIO driver's *.c *.h
# Makefile Kconfig (no *.mod.c): the source of the working driver, 140 files
FINGERPRINT=446581def81b0cd6ca576ac6d00a2770bd8ca19d3278624eb8d212af5ac5f55d
# the only two Debian patches that may fail (USB and line-ending hunks only)
EXPECTED_FAILS="fix-usb-firmware-path.patch fix-Lower-the-debugging-log-level.patch"
MAKE=(make -C "$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=)
die() { echo "STOPPED: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }
fingerprint() {
    ( cd "$AIC" && find "$DRV" -type f \( -name '*.c' -o -name '*.h' -o -name Makefile -o -name Kconfig \) \
          ! -name '*.mod.c' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-64 )
}

say "1/5 Checks"
[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
for t in git patch aarch64-linux-gnu-gcc depmod modinfo; do
    command -v "$t" > /dev/null || die "$t not found (sudo apt install git patch gcc-aarch64-linux-gnu kmod)"
done
[ -f "$OUT/Module.symvers" ] || die "no kernel build in $OUT - run tools/build_kernel.sh first"
[ -d "$OUT/modules-staging/lib/modules" ] || die "$OUT/modules-staging missing - build_kernel.sh did not finish"
[ -f "$FIX" ] || die "$FIX not found"
REL=$(make -s -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease)
echo "kernel build $OUT, release $REL"

say "2/5 Source $AIC"
if [ ! -d "$AIC/.git" ]; then
    mkdir -p "$(dirname "$AIC")"
    git clone -q "$URL" "$AIC"
    echo "downloaded $URL"
fi
[ "$(git -C "$AIC" rev-parse HEAD)" = "$COMMIT" ] || git -C "$AIC" -c advice.detachedHead=false checkout -q "$COMMIT"
echo "at $(git -C "$AIC" log --oneline -1)"

say "3/5 Patches (the source's Debian series + the 7.3 fix)"
if [ "$(fingerprint)" = "$FINGERPRINT" ]; then
    echo "already prepared - the source matches the working driver"
else
    [ -z "$(git -C "$AIC" status --porcelain)" ] || die "$AIC has changes but not the expected source.
  Start clean with:  git -C $AIC checkout -- .  and  git -C $AIC clean -fd"
    FAILS=""
    cd "$AIC"
    while read -r p; do
        [ -n "$p" ] || continue
        patch -p1 --forward -s < "debian/patches/$p" > /dev/null 2>&1 || FAILS="$FAILS $p"
    done < debian/patches/series
    echo "Debian patches that did not apply fully:${FAILS:- none}"
    for p in $FAILS; do
        case " $EXPECTED_FAILS " in *" $p "*) ;; *) die "unexpected failure: $p" ;; esac
    done
    patch -p1 -s < "$FIX"
    echo "applied $(basename "$FIX")"
    [ "$(fingerprint)" = "$FINGERPRINT" ] || die "the prepared source differs from the working driver"
    echo "the source matches the working driver"
fi

say "4/5 Build against $OUT"
rm -rf "$OUT/aic8800"
cp -r "$AIC/$DRV" "$OUT/aic8800"
"${MAKE[@]}" M="$OUT/aic8800" -j"$(nproc)" modules > "$OUT/aic8800/build.log" 2>&1 || {
    tail -20 "$OUT/aic8800/build.log"; die "build failed, full log $OUT/aic8800/build.log"; }
for m in aic8800_bsp/aic8800_bsp.ko aic8800_fdrv/aic8800_fdrv.ko; do
    VM=$(modinfo -F vermagic "$OUT/aic8800/$m" | cut -d' ' -f1)
    [ "$VM" = "$REL" ] || die "$m is for '$VM', not $REL"
done
echo "built for $REL (log: $OUT/aic8800/build.log)"

say "5/5 Into modules-staging and firmware-staging"
EXTRA="$OUT/modules-staging/lib/modules/$REL/extra"
mkdir -p "$EXTRA"
cp "$OUT/aic8800/aic8800_bsp/aic8800_bsp.ko" "$OUT/aic8800/aic8800_fdrv/aic8800_fdrv.ko" "$EXTRA/"
depmod -b "$OUT/modules-staging" -F "$OUT/System.map" "$REL"
grep -q "extra/aic8800_fdrv.ko" "$OUT/modules-staging/lib/modules/$REL/modules.dep" || die "depmod did not list the modules"
FWD="$OUT/firmware-staging/lib/firmware/aic8800_fw/SDIO"
rm -rf "$FWD"; mkdir -p "$FWD"
cp -r "$AIC/$FW" "$FWD/"
( cd "$EXTRA" && sha256sum aic8800_bsp.ko aic8800_fdrv.ko )
echo "firmware: $FWD/aic8800 ($(ls "$FWD/aic8800" | wc -l) files)"
echo "OK: Wi-Fi driver built for $REL"
echo "next: bash $REPO/tools/pack_kernel.sh"
