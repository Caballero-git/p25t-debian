#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# cam-snap.sh - take a photo with a P25T camera as a PNG.
#
#   cam-snap   [-c rear|front] [-e EXPOSURE] [-g GAIN] [-n FRAMES]
#              [-r auto|0|90|180|270] [-k] [-v] [FILE]
#   rear-snap  [options] [FILE]      the same, rear camera
#   front-snap [options] [FILE]      the same, front camera
#
#   FILE  output PNG; "{now}" in the name becomes the date and time,
#         e.g. photo_{now}.png -> photo_20261021-191530.png.
#         Default: photo_{now}.png in the current folder.
#   -c    camera; default: the one the active device tree wires up (the SoC
#         has one camera input: set-dtb rear|front switches, then reboot)
#   -e    exposure in lines. rear: 4..1992 (default 1992, the longest at
#         1296x972). front: 4..16367 (default 1252, the longest at the
#         normal frame rate; longer values slow the frames down)
#   -g    analogue gain. rear: 256 = 1x .. 4096 = 16x (default 1024 = 4x).
#         front: 64 = 1x .. 646 = 10x (default 256 = 4x)
#   -n    frames to capture; the last one is kept (default 20 - the first
#         frames after stream-on are dark)
#   -r    clockwise rotation of the picture (default auto: from the
#         accelerometer, so the picture is upright in any tablet position)
#   -k    also keep the raw frame next to the PNG (FILE with .raw)
#   -v    show the photo with imv-wayland (inside the sway session only)
#
# Picture: half the raw size (2x2 binning of the Bayer RGGB frame): rear
# 648x486 (from 1296x972), front 800x600 (from 1600x1200); grey-world
# white balance, auto brightness - see raw2png.py. The front camera's
# picture shows the scene as it is, not mirrored.
# Needs: RK817 LDO2 at 1.2 V (patch 0026) and the udev rule
# 99-p25t-vicap.rules (VICAP kept powered; without it a second capture
# freezes the tablet). Both are checked first.
# Access: be in group "video" (the card's user is) or run with sudo.
#
# Install on the tablet (from the repo's tools folder; the card build does
# the same):
#   sudo install -m 755 cam-snap.sh /usr/local/bin/cam-snap
#   sudo ln -sf cam-snap /usr/local/bin/rear-snap
#   sudo ln -sf cam-snap /usr/local/bin/front-snap
#   sudo install -D -m 755 raw2png.py /usr/local/lib/p25t/raw2png.py
# python3-numpy makes the PNG step fast (without it: pure Python, slow).

set -u
die() { echo "cam-snap: $*" >&2; exit 1; }
usage() { sed -n '4,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

case "$(basename "$0")" in
    rear-snap*) CAM=rear ;; front-snap*) CAM=front ;; *) CAM=auto ;;
esac
EXP=""; GAIN=""; FRAMES=20; ROT=auto; KEEP=0; VIEW=0
while getopts "c:e:g:n:r:kvh" o; do
    case $o in
        c) CAM=$OPTARG ;; e) EXP=$OPTARG ;; g) GAIN=$OPTARG ;; n) FRAMES=$OPTARG ;;
        r) ROT=$OPTARG ;; k) KEEP=1 ;; v) VIEW=1 ;; h) usage 0 ;; *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
DEFAULT='photo_{now}.png'; NOWTAG='{now}'
OUT=${1:-$DEFAULT}
OUT=${OUT//"$NOWTAG"/$(date +%Y%m%d-%H%M%S)}
case "$OUT" in *.png) ;; *) OUT=$OUT.png ;; esac
case "$CAM" in auto|rear|front) ;; *) die "-c must be rear or front" ;; esac
case "$ROT" in auto|0|90|180|270) ;; *) die "-r must be auto, 0, 90, 180 or 270" ;; esac
[ "$FRAMES" -ge 2 ] 2>/dev/null || die "-n must be 2 or more"

# --- safety checks ----------------------------------------------------------
LDO2=""
for n in /sys/class/regulator/*/name; do
    [ "$(cat "$n" 2>/dev/null)" = vdda_0v9 ] && LDO2=$(cat "${n%/name}/microvolts" 2>/dev/null)
done
[ "$LDO2" = 1200000 ] || die "RK817 LDO2 (vdda_0v9) is '${LDO2:-not found}' uV, not 1200000 - the camera sensors cannot stream"
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
[ -n "$VDEV" ] || die "camera capture block (fdfe0000) not found"
[ "$(cat "$VDEV/power/control")" = on ] || die "VICAP power/control is not 'on' - install 99-p25t-vicap.rules first (a second capture would freeze the tablet)"

R2P=""
for f in "$(dirname "$(readlink -f "$0")")/raw2png.py" /usr/local/lib/p25t/raw2png.py; do
    [ -f "$f" ] && { R2P=$f; break; }
done
[ -n "$R2P" ] || die "raw2png.py not found (next to this script or in /usr/local/lib/p25t/)"
command -v media-ctl >/dev/null && command -v v4l2-ctl >/dev/null || die "v4l-utils missing (sudo apt install v4l-utils)"
M=/dev/media0
[ -w $M ] || die "no access to $M - join group video or run with sudo"

# --- which camera -----------------------------------------------------------
REAR_ENT="gc5035 2-0037"; FRONT_ENT="gc02m2 2-0010"
# a sensor is in the graph when its driver is bound to it (media-ctl -e
# cannot tell: it exits 0 for an entity that does not exist)
ACTIVE=""
[ -e /sys/bus/i2c/drivers/gc5035/2-0037 ] && ACTIVE=rear
[ -e /sys/bus/i2c/drivers/gc02m2/2-0010 ] && ACTIVE=front
[ -n "$ACTIVE" ] || die "no camera sensor in the media graph"
[ "$CAM" = auto ] && CAM=$ACTIVE
[ "$CAM" = "$ACTIVE" ] || die "the $CAM camera is not wired up (the $ACTIVE one is): set-dtb $CAM, then reboot"

if [ "$CAM" = rear ]; then
    ENT=$REAR_ENT; W=1296; H=972; FMT=SGRBG10_1X10; PIX=BA10   # the data is RGGB
    EXP=${EXP:-1992}; GAIN=${GAIN:-1024}
else
    ENT=$FRONT_ENT; W=1600; H=1200; FMT=SRGGB10_1X10; PIX=RG10
    EXP=${EXP:-1252}; GAIN=${GAIN:-256}
fi
[ "$EXP" -ge 4 ] 2>/dev/null || die "-e must be a number of lines, 4 or more"

# --- rotation from the accelerometer (SC7A20, mount-matrix of patch 0022:
# device frame = landscape the usual way, x right, y up, z out of the screen)
pose() {
    local d found=""
    for d in /sys/bus/iio/devices/iio:device*; do
        case "$(cat "$d/name" 2>/dev/null)" in *sc7a20*|*accel*) found=$d ;; esac
    done
    [ -n "$found" ] || { echo "none"; return; }
    python3 - "$found" <<'PYEOF'
import sys
d = sys.argv[1]
rd = lambda f: open(d + "/" + f).read().strip()
mm = ""
for f in ("mount_matrix", "in_mount_matrix", "in_accel_mount_matrix"):
    try:
        mm = rd(f)
        break
    except OSError:
        pass
M = [[float(v) for v in r.split(",")] for r in mm.split(";")] if mm else [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
raw = [float(rd("in_accel_%s_raw" % a)) for a in "xyz"]
x, y, z = (sum(M[i][j] * raw[j] for j in range(3)) for i in range(3))
if abs(z) > max(abs(x), abs(y)):
    print("flat")
elif abs(y) >= abs(x):
    print("landscape" if y > 0 else "landscape-upside-down")
else:
    print("portrait-left-up" if x < 0 else "portrait-right-up")
PYEOF
}
# Clockwise turn per position. Rear: the sensor's picture is upside down
# in the usual landscape position. Front: with both sensor flips on (set
# below) the picture is upright in that position.
if [ "$ROT" = auto ]; then
    P=$(pose 2>/dev/null) || P=""
    case "$CAM:$P" in
        rear:landscape|rear:flat)      ROT=180 ;;
        rear:landscape-upside-down)    ROT=0 ;;
        front:landscape|front:flat)    ROT=0 ;;
        front:landscape-upside-down)   ROT=180 ;;
        *:portrait-left-up)            ROT=270 ;;
        *:portrait-right-up)           ROT=90 ;;
        rear:*) ROT=180; P="accelerometer not readable" ;;
        front:*) ROT=0; P="accelerometer not readable" ;;
    esac
    POSE="$ROT ($P)"
else
    POSE="$ROT (by -r)"
fi

# --- pipeline ---------------------------------------------------------------
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0" 2>/dev/null)
case "$VID" in /dev/*) ;; *) die "video node rkcif-mipi0-id0 not found" ;; esac
SENS=$(media-ctl -d $M -e "$ENT" 2>/dev/null)
case "$SENS" in /dev/*) ;; *) die "sensor subdev '$ENT' not found" ;; esac
media-ctl -d $M -V "\"$ENT\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || die "media-ctl format setup failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=$PIX >/dev/null || die "video format setup failed"

if [ "$CAM" = rear ]; then
    v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0 --set-ctrl=exposure="$EXP" --set-ctrl=analogue_gain="$GAIN" ||
        die "sensor controls failed (exposure 4..1992, gain 256..4096)"
    TIMEOUT=20
else
    # frame length = height + vertical blanking; exposure up to frame length - 16
    VB=$((EXP + 16 - H)); [ $VB -lt 68 ] && VB=68
    v4l2-ctl -d "$SENS" --set-ctrl=horizontal_flip=1 --set-ctrl=vertical_flip=1 --set-ctrl=vertical_blanking=$VB ||
        die "sensor controls failed (flips, vertical blanking $VB; exposure 4..16367)"
    v4l2-ctl -d "$SENS" --set-ctrl=exposure="$EXP" --set-ctrl=analogue_gain="$GAIN" ||
        die "sensor controls failed (exposure 4..16367, gain 64..646)"
    # one frame: (H + VB) lines of 2192 pixel clocks at 67.2 MHz; allow twice that
    FRAME_MS=$(( (H + VB) * 2192 / 67200 ))
    TIMEOUT=$(( 10 + FRAMES * FRAME_MS * 2 / 1000 ))
fi

TMP=$(mktemp -d /tmp/cam-snap.XXXXXX) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
FR=$((W * H * 2))
timeout "$TIMEOUT" v4l2-ctl -d "$VID" --stream-mmap --stream-count="$FRAMES" --stream-to="$TMP/all.raw" >/dev/null 2>&1
SZ=$(stat -c %s "$TMP/all.raw" 2>/dev/null || echo 0)
[ "$SZ" -ge "$FR" ] || die "capture failed ($SZ bytes)"
tail -c $FR "$TMP/all.raw" > "$TMP/last.raw"

python3 "$R2P" "$TMP/last.raw" $W $H --order RGGB --rotate "$ROT" --out "$OUT" >/dev/null || die "raw2png failed"
if [ $KEEP -eq 1 ]; then cp "$TMP/last.raw" "${OUT%.png}.raw"; fi
if [ -n "${SUDO_USER:-}" ]; then chown "$SUDO_USER": "$OUT" 2>/dev/null; [ $KEEP -eq 1 ] && chown "$SUDO_USER": "${OUT%.png}.raw"; fi
echo "$OUT ($CAM camera, exposure $EXP, gain $GAIN, rotation $POSE)$([ $KEEP -eq 1 ] && echo "; raw: ${OUT%.png}.raw")"

if [ $VIEW -eq 1 ]; then
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -z "${SUDO_USER:-}" ] && command -v imv-wayland >/dev/null; then
        imv-wayland "$OUT" >/dev/null 2>&1 &
        disown
    else
        echo "cam-snap: -v works only inside the sway session, without sudo" >&2
    fi
fi
