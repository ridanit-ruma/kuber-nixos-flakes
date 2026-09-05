#!/usr/bin/env bash
# Clear a disk so Rook can claim it as an OSD.
#
# Rook takes a device only when it carries no partition table and no
# filesystem signature, so "adding a disk" is mostly "making sure it is
# genuinely blank". That is one wipefs away from eating the system disk,
# hence the guards:
#
#   - the path must be /dev/disk/by-id/...: kernel names shift between boots,
#     and a config that said nvme0n1 has already pointed at the system disk
#     here once.
#   - the disk holding / or /boot is refused, whatever the caller says.
#   - anything mounted (the disk or any partition on it) is refused.
#   - a disk already carrying a Ceph OSD is refused unless --force-ceph says
#     otherwise. This one is here because its absence cost an OSD: an earlier
#     version recognised one specific partition layout and refused everything
#     else, which covered this case by accident, and taking by-id paths dropped
#     it. The next run erased a live OSD -- reporting success, leaving the pool
#     degraded at half capacity, and saying nothing about where the data went.
#   - the word ERASE has to be typed, unless --i-typed-erase says the caller
#     already collected exactly that confirmation (install.sh does, in its
#     question phase, so the wipe can run unattended later).
#
# Deployed to every node by modules/common.nix as `wipe-osd`.
set -euo pipefail

usage() {
  echo "usage: wipe-osd /dev/disk/by-id/<disk> [--i-typed-erase] [--force-ceph]" >&2
  echo "       --i-typed-erase skips the prompt; only for callers that already" >&2
  echo "       collected an explicit ERASE from the user (install.sh does)." >&2
  echo "       --force-ceph erases a disk that still holds a Ceph OSD." >&2
  exit 1
}

DEV=""
FLAG=""
FORCE_CEPH=0
for a in "$@"; do
  case "$a" in
    --i-typed-erase) FLAG=--i-typed-erase ;;
    --force-ceph)    FORCE_CEPH=1 ;;
    -*)              usage ;;
    *)               [ -n "$DEV" ] && usage; DEV=$a ;;
  esac
done
[ -n "$DEV" ] || usage

# ── Guards ──────────────────────────────────────────────────────────────────

case "$DEV" in
  /dev/disk/by-id/*) ;;
  *)
    echo "wipe-osd: refusing '$DEV' -- use a /dev/disk/by-id/ path." >&2
    echo "Kernel names like /dev/nvme0n1 change between boots; by-id does not." >&2
    echo "Find it with: ls -l /dev/disk/by-id/" >&2
    exit 1 ;;
esac

[ -e "$DEV" ] || { echo "wipe-osd: $DEV does not exist." >&2; exit 1; }

REAL=$(readlink -f "$DEV")
[ -b "$REAL" ] || { echo "wipe-osd: $DEV ($REAL) is not a block device." >&2; exit 1; }
KNAME=$(basename "$REAL")

# The disks carrying the running system, resolved to their parent devices.
# findmnt gives the partition; lsblk PKNAME walks up to the whole disk.
#
# One --target per mountpoint. Passing two paths at once reads as "is the
# device / mounted at /boot", which is false: findmnt exits 1 with no output,
# and under pipefail that took the whole script down before any guard ran. It
# failed safe by accident, and the guard had never once fired.
SYSTEM_DISKS=$(
  for m in / /boot /nix; do
    src=$(findmnt -no SOURCE --target "$m" 2>/dev/null) || continue
    lsblk -no PKNAME "$src" 2>/dev/null || true
  done | grep -v '^$' | sort -u
)
[ -n "$SYSTEM_DISKS" ] || {
  echo "wipe-osd: could not work out which disk holds the system. Refusing." >&2
  exit 1
}
for d in $SYSTEM_DISKS; do
  if [ "$d" = "$KNAME" ]; then
    echo "wipe-osd: $DEV is $KNAME, which holds / or /boot. Refusing." >&2
    exit 1
  fi
done

# Anything mounted on the disk or its partitions. MOUNTPOINTS is one line pe
# device in the tree; any non-empty line is a live mount.
if lsblk -no MOUNTPOINTS "$REAL" | grep -q .; then
  echo "wipe-osd: something on $KNAME is mounted:" >&2
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$REAL" >&2
  echo "Unmount it first. If this is the disk you meant, look again." >&2
  exit 1
fi

# A disk Ceph is already using. Erasing one silently halves the pool: the
# cluster reports HEALTH_WARN about redundancy rather than about a missing
# disk, and nothing connects that to the command that was just run.
#
# Rebuilding an OSD in place is a real thing to want, so there is a way
# through -- it just has to be a deliberate word rather than the default.
if [ "$(lsblk -nro FSTYPE "$REAL" | head -1)" = "ceph_bluestore" ] && [ "$FORCE_CEPH" != 1 ]; then
  cat >&2 <<MSG
wipe-osd: $DEV carries a live Ceph OSD.

Erasing it destroys that OSD and leaves the pool degraded. If the OSD is
already out of the cluster and you are rebuilding it, remove it there first
and then say so here:

  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd purge <id> --yes-i-really-mean-it

  wipe-osd $DEV --force-ceph
MSG
  exit 1
fi
if [ "$FORCE_CEPH" = 1 ]; then
  echo "--force-ceph: erasing a disk that holds a Ceph OSD."
fi

# ── Show what is about to happen, then confirm ─────────────────────────────

echo "About to erase:"
lsblk -o NAME,SIZE,MODEL,FSTYPE "$REAL"
SIGS=$(wipefs -n "$REAL" 2>/dev/null || true)
if [ -n "$SIGS" ]; then
  echo
  echo "Current signatures (all of this is destroyed):"
  echo "$SIGS"
else
  echo
  echo "No filesystem signatures found on the whole-disk device."
fi
echo

if [ "$FLAG" != "--i-typed-erase" ]; then
  # From a pipe -- `curl ... | sh` -- stdin is the script itself, so the prompt
  # has to come off the terminal. Without one there is nobody to ask, and
  # exiting on a failed read would look like the wipe simply did nothing.
  if [ ! -r /dev/tty ]; then
    echo "wipe-osd: no terminal to ask on." >&2
    echo "Run this from a shell, or pass --i-typed-erase if the caller already" >&2
    echo "collected an explicit ERASE from the person at the keyboard." >&2
    exit 1
  fi
  printf 'Type ERASE to wipe %s beyond recovery: ' "$DEV"
  read -r answer < /dev/tty || answer=""
  if [ "$answer" != "ERASE" ]; then
    echo "Not confirmed; nothing was touched."
    exit 1
  fi
fi

# ── Wipe ────────────────────────────────────────────────────────────────────
# Signatures on partitions first (they vanish with the table, but wipefs on a
# gone partition is an error, so children go before the parent), then the
# GPT/MBR itself, then the first stretch of the disk -- Ceph bluestore and
# LVM leave labels wipefs knows nothing about.

lsblk -nro NAME,TYPE "$REAL" | while read -r name type; do
  [ "$type" = "part" ] && wipefs -a "/dev/$name"
done
sgdisk --zap-all "$REAL" >/dev/null
wipefs -a "$REAL" >/dev/null
dd if=/dev/zero of="$REAL" bs=1M count=100 conv=fsync status=none

# Force the kernel to read the device again. Zeroing it is not enough on its
# own: the old label survives in cache, so wipefs and blkid report a blank disk
# while `ceph-volume inventory` goes on seeing a BlueStore label and Rook keeps
# skipping the device as already configured -- with nothing anywhere saying so.
blockdev --rereadpt "$REAL" 2>/dev/null || true
partprobe "$REAL" 2>/dev/null || true
udevadm settle 2>/dev/null || true

echo "Done. $DEV is blank; Rook will claim it once the node is listed in"
echo "rook-ceph-cluster.yaml (kuber-infrastructure) with this disk's by-id path."
