#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build_kernel.sh - configure and build the P25T kernel (step 2 of
# "Building a card" in README.org).
#
#     bash <WORK>/p25t-debian/tools/build_kernel.sh
#
# Source: <WORK>/linux, branch p25t (made by tools/get_kernel.sh).
# Config: kernel/p25t-base.config + kernel/p25t.fragment; every line of
#         the fragment must survive in the final configuration.
# Output: <WORK>/p25t-debian/build/kernel/ (objects, Image, device trees,
#         the final .config), and build/kernel/modules-staging/ (the
#         modules, as they go onto the card). The source tree stays clean.
# LOCALVERSION= on the make line keeps the release name exactly
# 7.3.0-p25t (git would otherwise add a "+" for the patches).
# Steps 1-3 take seconds; step 4 compiles and takes long (half an hour
# with two cores, more on a slow laptop). If it stops, run it again: make
# continues where it was. Disk: about 0.8 GB in build/kernel/.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(dirname "$REPO")
SRC="$WORK/linux"
OUT="$REPO/build/kernel"
K="$REPO/kernel"
BRANCH=p25t
MAKE=(make -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=)
DTBS="rk3566-teclast-p25t rk3566-teclast-p25t-usbhost rk3566-teclast-p25t-front rk3566-teclast-p25t-front-usbhost"
die() { echo "STOPPED: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }

say "1/5 Checks"
[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
missing=""
for t in make gcc aarch64-linux-gnu-gcc bc bison flex depmod cpio perl; do
    command -v "$t" > /dev/null || missing="$missing $t"
done
[ -f /usr/include/openssl/opensslv.h ] || missing="$missing (openssl headers)"
[ -f /usr/include/libelf.h ] || [ -f /usr/include/elfutils/libelf.h ] || missing="$missing (libelf headers)"
[ -z "$missing" ] || die "missing:$missing
  sudo apt install build-essential gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev kmod cpio"
[ -d "$SRC/.git" ] || die "no kernel source in $SRC - run tools/get_kernel.sh first"
[ "$(git -C "$SRC" rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "$SRC is not on branch $BRANCH"
[ -z "$(git -C "$SRC" status --porcelain)" ] || die "$SRC has changes or untracked files"
[ ! -e "$SRC/.config" ] || die "$SRC/.config exists (an in-tree build); the build here needs a clean source"
echo "source $SRC: $(git -C "$SRC" log --oneline -1)"
echo "output $OUT"
mkdir -p "$OUT"

say "2/5 Config: p25t-base.config + p25t.fragment"
( cd "$SRC" && scripts/kconfig/merge_config.sh -m -O "$OUT" \
      "$K/p25t-base.config" "$K/p25t.fragment" > "$OUT/merge.log" )
"${MAKE[@]}" -s olddefconfig
lost=0
while IFS= read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    grep -qxF -- "$line" "$OUT/.config" || { echo "NOT IN THE FINAL CONFIG: $line"; lost=1; }
done < "$K/p25t.fragment"
[ "$lost" -eq 0 ] || die "an option of p25t.fragment did not survive (see above)"
echo "all options of p25t.fragment present"
echo "changes against p25t-base.config:"
"$SRC/scripts/diffconfig" "$K/p25t-base.config" "$OUT/.config" | sed 's/^/    /'

say "3/5 Release name"
REL=$("${MAKE[@]}" -s kernelrelease)
echo "kernel release: $REL"

say "4/5 Build Image, device trees, modules (long)"
"${MAKE[@]}" -j"$(nproc)" Image dtbs modules

say "5/5 Modules into build/kernel/modules-staging"
rm -rf "$OUT/modules-staging"
"${MAKE[@]}" -s INSTALL_MOD_PATH="$OUT/modules-staging" modules_install
D="$OUT/arch/arm64/boot"
( cd "$D" && sha256sum Image $(for d in $DTBS; do echo "dts/rockchip/$d.dtb"; done) )
echo "modules: $(find "$OUT/modules-staging" -name '*.ko*' | wc -l) files in $OUT/modules-staging/lib/modules/$REL"
echo "OK: kernel $REL built"
echo "next: bash $REPO/tools/build_wifi.sh"
