#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# pack_kernel.sh - collect the built kernel for the card: the boot files,
# the modules (with the Wi-Fi modules) and the Wi-Fi firmware, with
# checksums. The card installation (a later step) takes everything from
# here.
#
#     bash <WORK>/p25t-debian/tools/pack_kernel.sh
#
# Run it after build_kernel.sh and build_wifi.sh.
# Output: build/kernel-pack/
#   Image                      the kernel
#   rk3566-teclast-p25t*.dtb   the four device trees (USB-C as a device or
#                              as a host; rear or front camera)
#   modules.tar                lib/modules/<release>/, with extra/aic8800_*.ko
#   firmware-aic8800.tar       lib/firmware/aic8800_fw/
#   release.txt                the kernel release, 7.3.0-p25t
#   files.sha256               checksums of all of the above
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$REPO/build/kernel"
P="$REPO/build/kernel-pack"
B="$OUT/arch/arm64/boot"
DTBS="rk3566-teclast-p25t rk3566-teclast-p25t-usbhost rk3566-teclast-p25t-front rk3566-teclast-p25t-front-usbhost"
die() { echo "STOPPED: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }

say "1/3 Checks"
[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
[ -f "$B/Image" ] || die "$B/Image missing - run tools/build_kernel.sh"
for d in $DTBS; do
    [ -f "$B/dts/rockchip/$d.dtb" ] || die "$d.dtb missing - run tools/build_kernel.sh"
done
N=$(ls "$OUT/modules-staging/lib/modules" 2> /dev/null | wc -l)
[ "$N" -eq 1 ] || die "expected one kernel release in modules-staging, found $N - run tools/build_kernel.sh"
REL=$(ls "$OUT/modules-staging/lib/modules")
IMGREL=$(strings "$B/Image" | sed -n 's/.*Linux version \([0-9][^ ]*\).*/\1/p' | sed -n 1p)
[ "$IMGREL" = "$REL" ] || die "the Image is $IMGREL but the modules are $REL"
M="$OUT/modules-staging/lib/modules/$REL"
[ -f "$M/extra/aic8800_fdrv.ko" ] && [ -f "$M/extra/aic8800_bsp.ko" ] \
    || die "no Wi-Fi modules - run tools/build_wifi.sh (after every build_kernel.sh)"
grep -q 'extra/aic8800_fdrv.ko' "$M/modules.dep" || die "modules.dep does not list the Wi-Fi modules"
[ -d "$OUT/firmware-staging/lib/firmware/aic8800_fw" ] || die "no Wi-Fi firmware - run tools/build_wifi.sh"
echo "release $REL, $(find "$M" -name '*.ko*' | wc -l) modules"

say "2/3 Collect into $P"
rm -rf "$P"
mkdir -p "$P"
cp "$B/Image" "$P/"
for d in $DTBS; do cp "$B/dts/rockchip/$d.dtb" "$P/"; done
tar -C "$OUT/modules-staging" --owner=0 --group=0 --sort=name \
    --exclude="lib/modules/$REL/build" --exclude="lib/modules/$REL/source" \
    -cf "$P/modules.tar" "lib/modules/$REL"
tar -C "$OUT/firmware-staging" --owner=0 --group=0 --sort=name -cf "$P/firmware-aic8800.tar" lib/firmware/aic8800_fw
echo "$REL" > "$P/release.txt"
( cd "$P" && sha256sum Image $(for d in $DTBS; do echo "$d.dtb"; done) \
      modules.tar firmware-aic8800.tar release.txt > files.sha256 )

say "3/3 Check"
( cd "$P" && sha256sum -c --quiet files.sha256 ) || die "files.sha256 check failed"
cat "$P/files.sha256"
echo "OK: kernel $REL packed in $P ($(du -sh "$P" | cut -f1))"
