#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build_debian.sh - build the Debian 13 (trixie) arm64 system for the card,
# on pc_linux. Nothing here touches a card or the tablet: the result is the
# folder build/rootfs-<DESKTOP>, which the card installation copies.
#
#     bash <WORK>/p25t-debian/tools/build_debian.sh <DESKTOP>
#     bash <WORK>/p25t-debian/tools/build_debian.sh            lists the desktops
#
# <DESKTOP> is a folder in debian/ other than common: "sway" (graphical) or
# "console" (text only). A desktop is debian/<DESKTOP>/ with packages.txt,
# setup.sh and, if it needs one, config/ - copy a folder to add another.
#
# Run it as your normal user; it asks for sudo itself. First it asks its
# questions, then it works on its own for 10-25 minutes:
#   - user name and password for the tablet, host name
#   - Wi-Fi network and password (optional: leave the name empty)
#   - an SSH public key for logins from the PC (optional)
#   - time zone, language and keyboard: the PC's values, or others
#   - whether to add the optional programs of debian/*/tested.txt
# The passwords are written only into the new system (the user's password
# as a hash, the Wi-Fi password as the hash wpa_passphrase makes); the
# answers file and the log never contain them.
#
# What goes in:
#   debian/common/packages.txt + debian/<DESKTOP>/packages.txt (+ the two
#   tested.txt lists, if wanted), without Recommends, from deb.debian.org;
#   the kernel modules and Wi-Fi firmware of build/kernel-pack/;
#   debian/common/setup.sh, then debian/<DESKTOP>/setup.sh, run inside it.
# under_test.txt and discarded.txt are never installed.
#
# Needs: tools/pack_kernel.sh done; 6 GB free; the packages
#   mmdebstrap qemu-user-static binfmt-support debian-archive-keyring gpg curl
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
D="$REPO/debian"
KP="$REPO/build/kernel-pack"
SUITE=trixie
MIRROR=http://deb.debian.org/debian
COMPONENTS="main contrib non-free non-free-firmware"
die() { echo; echo "STOPPED: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }
pkglist() { cat "$@" | sed 's/#.*//' | tr -s ' \t' '\n' | grep -v '^$' | paste -sd, ; }
desktops() { for d in "$D"/*/; do d=$(basename "$d"); [ "$d" != common ] && [ -f "$D/$d/packages.txt" ] && echo "$d"; done; }

DESKTOP="${1:-}"
if [ -z "$DESKTOP" ]; then
    echo "usage: bash $0 <DESKTOP>"
    echo "desktops in $D: $(desktops | paste -sd' ')"
    exit 1
fi

# --- run as the normal user, then as root through sudo ---------------------
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi
[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || die "run it as your normal user (it asks for sudo itself)"
# The PC's own language settings would follow into the new system's
# commands (sudo keeps LANG, LC_*, LANGUAGE): any language the new system
# has not generated makes perl and apt warn ("Setting locale failed").
# C.UTF-8 is built in everywhere.
unset LANGUAGE; export LC_ALL=C.UTF-8
PCUSER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
R="$REPO/build/rootfs-$DESKTOP"
LOG="$REPO/build/rootfs-$DESKTOP-build-log.txt"

say "1/9 Checks ($DESKTOP)"
[ "$(uname -m)" = x86_64 ] || die "this script expects an x86-64 PC"
[ -f "$D/$DESKTOP/packages.txt" ] && [ -f "$D/$DESKTOP/setup.sh" ] \
    || die "no desktop '$DESKTOP' (debian/$DESKTOP/packages.txt and setup.sh); desktops: $(desktops | paste -sd' ')"
for f in packages.txt setup.sh files/61-p25t-sensor.hwdb files/asound.state files/cam-snap.sh files/raw2png.py files/set-dtb.sh; do
    [ -f "$D/common/$f" ] || die "debian/common/$f missing"
done
[ ! -e "$R" ] || die "$R exists (an earlier build). Remove it first with:  sudo rm -rf $R"
[ -f "$KP/files.sha256" ] || die "no kernel in $KP - run tools/pack_kernel.sh first"
( cd "$KP" && sha256sum -c --quiet files.sha256 ) || die "the files in $KP do not match files.sha256"
REL=$(cat "$KP/release.txt")
missing=""
for t in mmdebstrap gpg curl update-binfmts; do command -v "$t" > /dev/null || missing="$missing $t"; done
[ -f /usr/share/keyrings/debian-archive-keyring.gpg ] || missing="$missing debian-archive-keyring"
[ -z "$missing" ] || die "missing:$missing
  sudo apt install mmdebstrap qemu-user-static binfmt-support debian-archive-keyring gpg curl"
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || update-binfmts --enable qemu-aarch64 > /dev/null 2>&1 || true
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "arm64 emulation (binfmt qemu-aarch64) is not active - is qemu-user-static installed?"
mkdir -p "$REPO/build"
FREE_KB=$(df -Pk "$REPO/build" | awk 'NR == 2 {print $4}')
[ "$FREE_KB" -gt 6000000 ] || die "need at least 6 GB free in $REPO/build"
echo "kernel $REL, arm64 emulation active, $((FREE_KB / 1024 / 1024)) GB free"

# --- questions ---------------------------------------------------------------
ask() {   # ask VAR "question" "default"
    local a
    read -r -p "$2${3:+ [$3]}: " a || die "no answer"
    printf -v "$1" '%s' "${a:-$3}"
}
ask_secret() {   # ask_secret VAR "question" MINLEN
    local a b
    while true; do
        read -r -s -p "$2: " a || die "no answer"; echo
        read -r -s -p "the same again: " b || die "no answer"; echo
        if [ "$a" != "$b" ]; then echo "  they differ - again"
        elif [ "${#a}" -lt "$3" ]; then echo "  at least $3 characters - again"
        else break; fi
    done
    printf -v "$1" '%s' "$a"
}

say "2/9 Questions (Enter accepts the value in [brackets])"
while true; do
    ask TUSER "user name on the tablet" ""
    [[ "$TUSER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$TUSER" != root ] && break
    echo "  lower-case letters, digits, - and _, starting with a letter - again"
done
ask_secret TPASS "password for $TUSER (also for sudo)" 1
while true; do
    ask THOST "host name of the tablet" "p25t"
    [[ "$THOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && break
    echo "  letters, digits and -, not at the start or end - again"
done
echo
echo "Wi-Fi: the network the tablet joins at boot. Leave it empty for none"
echo "(it can be added later on the tablet)."
ask WSSID "Wi-Fi network name (SSID)" ""
WPASS=""
if [ -n "$WSSID" ]; then
    while true; do
        ask_secret WPASS "Wi-Fi password" 8
        [ "${#WPASS}" -le 63 ] && break; echo "  at most 63 characters - again"
    done
fi
echo
KEYDEF=""
for k in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
    [ -f "$PCUSER_HOME/.ssh/$k" ] && { KEYDEF="$PCUSER_HOME/.ssh/$k"; break; }
done
echo "SSH: a public key lets you log in from this PC without the password."
while true; do
    ask SSHKEY "public key file (- for none)" "${KEYDEF:--}"
    [ "$SSHKEY" = - ] && { SSHKEY=""; break; }
    grep -q '^\(ssh-\|ecdsa-\)' "$SSHKEY" 2> /dev/null && break
    echo "  $SSHKEY is not a public key file (ssh-... or ecdsa-...) - again"
done
echo
# the PC's settings (any of these files may be missing: then a default)
pcval() { sed -n "s/^$1=//p" "$2" 2> /dev/null | tr -d '"' || true; }
PC_TZ=$(cat /etc/timezone 2> /dev/null || readlink /etc/localtime 2> /dev/null | sed 's|.*/zoneinfo/||' || true)
PC_LANG=$(pcval LANG /etc/default/locale)
PC_LANG=${PC_LANG:-en_US.UTF-8}
PC_LAYOUT=$(pcval XKBLAYOUT /etc/default/keyboard)
PC_VARIANT=$(pcval XKBVARIANT /etc/default/keyboard)
PC_OPTIONS=$(pcval XKBOPTIONS /etc/default/keyboard)
echo "This PC uses:"
echo "  time zone        ${PC_TZ:-?}"
echo "  language         $PC_LANG"
echo "  keyboard layout  ${PC_LAYOUT:-us}   variant '${PC_VARIANT}'   options '${PC_OPTIONS}'"
ask KEEP "use the same on the tablet? (y/n)" "y"
TZONE=${PC_TZ:-UTC}; TLANG=$PC_LANG; KLAYOUT=${PC_LAYOUT:-us}; KVARIANT=$PC_VARIANT; KOPTIONS=$PC_OPTIONS
case "$KEEP" in
    y|Y|yes) ;;
    *)
        while true; do
            ask TZONE "time zone, e.g. Europe/Madrid, America/New_York, UTC" "$TZONE"
            [ -f "/usr/share/zoneinfo/$TZONE" ] && break; echo "  unknown time zone - again"
        done
        while true; do
            ask TLANG "language, e.g. es_ES.UTF-8, en_GB.UTF-8, de_DE.UTF-8" "$TLANG"
            [ ! -f /usr/share/i18n/SUPPORTED ] || grep -q "^$TLANG " /usr/share/i18n/SUPPORTED && break
            echo "  unknown language (see /usr/share/i18n/SUPPORTED) - again"
        done
        ask KLAYOUT "keyboard layout(s), e.g. es, us, es,us" "$KLAYOUT"
        ask KVARIANT "keyboard variant(s), usually empty" "$KVARIANT"
        ask KOPTIONS "keyboard options, e.g. grp:alt_shift_toggle (switches layouts)" "$KOPTIONS"
        ;;
esac
echo
TESTED=""
TFILES=()
for f in "$D/common/tested.txt" "$D/$DESKTOP/tested.txt"; do [ -f "$f" ] && TFILES+=("$f"); done
if [ "${#TFILES[@]}" -gt 0 ] && [ -n "$(pkglist "${TFILES[@]}")" ]; then
    echo "Optional programs, proven on the tablet (debian/common/tested.txt, debian/$DESKTOP/tested.txt):"
    pkglist "${TFILES[@]}" | tr ',' ' ' | fold -s -w 72 | sed 's/^/  /'
    ask WANT "install them too? (y/n)" "n"
    case "$WANT" in y|Y|yes) TESTED=$(pkglist "${TFILES[@]}") ;; esac
fi

PKGS=$(pkglist "$D/common/packages.txt" "$D/$DESKTOP/packages.txt")
[ -z "$TESTED" ] || PKGS="$PKGS,$TESTED"
NPKG=$(echo "$PKGS" | tr ',' '\n' | wc -l)
echo
echo "Summary:"
echo "  desktop     $DESKTOP"
echo "  user        $TUSER (password set)"
echo "  host name   $THOST"
if [ -n "$WSSID" ]; then echo "  Wi-Fi       $WSSID (password set)"; else echo "  Wi-Fi       none"; fi
echo "  SSH key     ${SSHKEY:-none}"
echo "  time zone   $TZONE;  language $TLANG"
echo "  keyboard    $KLAYOUT  variant '$KVARIANT'  options '$KOPTIONS'"
echo "  packages    $NPKG listed$([ -n "$TESTED" ] && echo ", with the tested optional programs")"
echo "  kernel      $REL"
echo "  into        $R"
ask GO "build now? (y/n)" "n"
case "$GO" in y|Y|yes) ;; *) die "nothing done" ;; esac

# --- the build -----------------------------------------------------------------
say "3/9 Debian signing keys"
KEYS=$(mktemp -d)
trap 'rm -rf "$KEYS"' EXIT
cp /usr/share/keyrings/debian-archive-keyring.gpg "$KEYS/"
# a PC with an older keyring (Ubuntu, Mint) may lack the Debian 13 keys
for k in archive-key-13 archive-key-13-security release-13; do
    if curl -fsS -m 30 "https://ftp-master.debian.org/keys/$k.asc" -o "$KEYS/$k.asc"; then
        gpg --dearmor < "$KEYS/$k.asc" > "$KEYS/$k.gpg" && echo "added $k"
    else
        echo "could not download $k (continuing with the installed keyring)"
    fi
    rm -f "$KEYS/$k.asc"
done

say "4/9 Downloading and installing Debian $SUITE arm64 ($NPKG packages, 10-25 minutes)"
mmdebstrap --architectures=arm64 --variant=minbase \
    --components="$COMPONENTS" --keyring="$KEYS" \
    --aptopt='Apt::Install-Recommends "false"' \
    --include="$PKGS" \
    "$SUITE" "$R" \
    "deb $MIRROR $SUITE $COMPONENTS" \
    "deb $MIRROR $SUITE-updates $COMPONENTS" \
    "deb http://security.debian.org/debian-security $SUITE-security $COMPONENTS" \
    > "$LOG" 2>&1 || { tail -25 "$LOG"; die "mmdebstrap failed, full log $LOG"; }
rm -rf "$KEYS"
[ -x "$R/usr/lib/systemd/systemd" ] || die "the Debian install failed, see $LOG"
echo "Debian installed ($(du -sh "$R" | cut -f1))"

say "5/9 Kernel modules ($REL) and Wi-Fi firmware"
tar -C "$R/usr" -xf "$KP/modules.tar"
tar -C "$R/usr" -xf "$KP/firmware-aic8800.tar"
chroot "$R" depmod -a "$REL"
grep -q 'extra/aic8800_fdrv.ko' "$R/usr/lib/modules/$REL/modules.dep" || die "modules.dep does not list aic8800_fdrv"
echo "$(find "$R/usr/lib/modules/$REL" -name '*.ko*' | wc -l) modules, $(ls "$R/usr/lib/firmware/aic8800_fw/SDIO/aic8800" | wc -l) firmware files"

say "6/9 Tablet settings: debian/common/setup.sh, then debian/$DESKTOP/setup.sh"
B="$R/root/p25t-build"
mkdir -p "$B"
cp -r "$D/common" "$B/common"
cp -r "$D/$DESKTOP" "$B/$DESKTOP"
{
    printf 'P25T_USER=%q\n' "$TUSER"
    printf 'P25T_HOST=%q\n' "$THOST"
    printf 'P25T_TZ=%q\n' "$TZONE"
    printf 'P25T_LANG=%q\n' "$TLANG"
    printf 'P25T_XKBLAYOUT=%q\n' "$KLAYOUT"
    printf 'P25T_XKBVARIANT=%q\n' "$KVARIANT"
    printf 'P25T_XKBOPTIONS=%q\n' "$KOPTIONS"
    printf 'P25T_DESKTOP=%q\n' "$DESKTOP"
} > "$B/answers"
[ -z "$SSHKEY" ] || install -m 600 "$SSHKEY" "$B/authorized_keys"
if ! chroot "$R" /bin/bash /root/p25t-build/common/setup.sh 2>&1 | tee -a "$LOG"; then
    die "debian/common/setup.sh failed, see $LOG"
fi
if ! chroot "$R" /bin/bash "/root/p25t-build/$DESKTOP/setup.sh" 2>&1 | tee -a "$LOG"; then
    die "debian/$DESKTOP/setup.sh failed, see $LOG"
fi
rm -rf "$B"

say "7/9 Password and Wi-Fi"
printf '%s:%s\n' "$TUSER" "$TPASS" | chroot "$R" chpasswd
echo "password of $TUSER set"
# The file always exists (wpa_supplicant@wlan0 starts at boot); networks
# can be added later on the tablet (README.org, "On the tablet").
W="$R/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
{
    echo "ctrl_interface=/run/wpa_supplicant"
    echo "update_config=1"
} > "$W"
chmod 600 "$W"
if [ -n "$WSSID" ]; then
    # wpa_passphrase reads the password from stdin; its comment lines,
    # among them the plain-text copy ("#psk="), are dropped
    printf '%s\n' "$WPASS" | chroot "$R" wpa_passphrase "$WSSID" | grep -v '^[[:space:]]*#' >> "$W"
    grep -q '^[[:space:]]*psk=[0-9a-f]\{64\}$' "$W" || die "wpa_passphrase did not make a network entry"
    echo "Wi-Fi network set (password stored as a hash only)"
else
    echo "no Wi-Fi network (add one later on the tablet, see README.org)"
fi
TPASS=""; WPASS=""

say "8/9 Clean up"
chroot "$R" apt-get clean
rm -f "$R"/var/lib/apt/lists/*_Packages "$R"/var/lib/apt/lists/*_Release "$R"/var/lib/apt/lists/*_InRelease
echo "done"

say "9/9 Summary"
N=$(chroot "$R" dpkg-query -W -f='${Package}\n' | wc -l)
{
    echo "desktop: $DESKTOP"
    echo "host name: $(cat "$R/etc/hostname")"
    echo "user: $TUSER"
    echo "Wi-Fi: $([ -n "$WSSID" ] && echo configured || echo none)"
    echo "SSH key: $([ -n "$SSHKEY" ] && echo yes || echo no)"
    echo "time zone: $TZONE, language: $TLANG, keyboard: $KLAYOUT"
    echo "tested optional programs: $([ -n "$TESTED" ] && echo yes || echo no)"
    echo "kernel modules: $REL"
    echo "packages installed: $N"
    echo "size: $(du -sh "$R" | cut -f1)"
    echo "built: $(date -u '+%F %T') UTC"
} | tee "$R.info"
chown "$SUDO_USER:" "$R.info" "$LOG"
echo "log: $LOG"
echo "OK: Debian ($DESKTOP) built in $R"
