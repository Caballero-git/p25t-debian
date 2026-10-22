#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# get_kernel.sh - get the Linux 7.3 source and apply the P25T patches.
# Step 1 of "Building a card" in README.org.
#
#     bash <WORK>/p25t-debian/tools/get_kernel.sh
#
# <WORK> is the folder you cloned this repository into (for example
# ~/P25T). The kernel source goes next to the repository, into
# <WORK>/linux, so the two never mix.
#
# 1. Checks the patches in kernel/patches/ and that they are made for 7.3.
# 2. If <WORK>/linux does not exist yet: downloads Linux 7.3 from
#    kernel.org as a shallow git clone of the release tag v7.3 (only the
#    release, no history: about 300 MB to download, 2 GB on disk).
# 3. Checks that the tree is exactly Linux 7.3, creates the branch p25t
#    there and applies the patches with git am.
# Run it once. If the branch p25t exists already it stops and changes
# nothing.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(dirname "$REPO")
KERNEL="$WORK/linux"
PATCHES="$REPO/kernel/patches"
URL="${P25T_KERNEL_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
TAG=v7.3
BASE=c03c1a14507dfaf8b856c2608f9ac216021fc222      # "Linux 7.3", 2026-10-18
N_EXPECTED=30
BRANCH=p25t
die() { echo "STOPPED: $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run it as your normal user, not with sudo"
command -v git > /dev/null || die "git not found (sudo apt install git)"
N=$(ls "$PATCHES"/0*.patch 2> /dev/null | wc -l)
[ "$N" -eq "$N_EXPECTED" ] || die "$PATCHES holds $N patches, expected $N_EXPECTED"
# git format-patch writes the base into the first patch only
NAMED=$(cat "$PATCHES"/0*.patch | sed -n 's/^base-commit: //p' | sort -u)
[ "$NAMED" = "$BASE" ] || die "the patches do not name $TAG ($BASE) as their base: ${NAMED:-none}"
echo "1/3 $N patches in $PATCHES, made for Linux $TAG"

if [ ! -e "$KERNEL" ]; then
    echo "2/3 downloading Linux $TAG into $KERNEL (shallow clone of the release tag)"
    git -c advice.detachedHead=false clone --depth 1 --branch "$TAG" "$URL" "$KERNEL"
else
    echo "2/3 $KERNEL exists, using it"
fi
cd "$KERNEL"
[ "$(git rev-parse --show-toplevel 2> /dev/null)" = "$(pwd -P)" ] \
    || die "$KERNEL exists but is not a git tree of its own - move it away and run again"
[ ! -d "$(git rev-parse --git-dir)/rebase-apply" ] || die "an unfinished 'git am' in $KERNEL (git -C $KERNEL am --abort)"
! git rev-parse --verify -q "$BRANCH" > /dev/null \
    || die "branch $BRANCH exists already in $KERNEL (patches applied before?) - nothing changed"
git cat-file -e "$BASE^{commit}" 2> /dev/null || die "$KERNEL does not contain Linux $TAG ($BASE)"
[ -z "$(git status --porcelain)" ] || die "$KERNEL has changes or untracked files"

echo "3/3 branch $BRANCH at $TAG, applying the patches"
git checkout -q -b "$BRANCH" "$BASE"
# git am records who applied the patches; a PC without a git identity
# gets a neutral one (the patches keep their own authors)
if [ -z "$(git config user.email || true)" ]; then
    export GIT_COMMITTER_NAME="p25t build" GIT_COMMITTER_EMAIL="p25t-build@localhost"
fi
git am -q "$PATCHES"/0*.patch || die "a patch did not apply (git -C $KERNEL am --abort, then report it)"

APPLIED=$(git rev-list --count "$BASE"..HEAD)
[ "$APPLIED" -eq "$N" ] || die "$APPLIED commits on $BRANCH, expected $N"
[ -z "$(git status --porcelain)" ] || die "the tree has changes after git am"
echo
git diff --shortstat "$BASE" HEAD
echo "OK: $KERNEL, branch $BRANCH = Linux $TAG + $N P25T patches ($(git rev-parse --short HEAD))"
