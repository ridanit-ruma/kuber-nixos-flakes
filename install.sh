#!/bin/sh
# install.sh -- turn a fresh NixOS machine into a node of this cluster.
#
#   curl -fsSL https://raw.githubusercontent.com/ridanit-ruma/kuber-nixos-flakes/main/install.sh | sh
#
# Runs on the new machine itself, as root. Asks everything up front (~2min),
# then works unattended: hardware config, flake entry, build, reboot. Run the
# same line again after the reboot and it continues -- join, then storage.
# Answers are saved under /var/lib/kuber-install, so a rerun never asks twice.
#
# POSIX sh, because it is piped into `sh`. Interactive reads go through
# /dev/tty (fd 3): when piped, stdin is the script text, not the keyboard.
#
# Every cluster-specific value it needs -- interface names, both subnets, the
# ssh port, which node is the control plane -- is read from hosts/cluster.nix
# after the clone, so this script and the flake cannot drift apart. Fork this
# repository, point NIXOS_REPO at your fork, and serve this file from anywhere
# (a raw GitHub URL will do).
set -eu

export LANG=C.UTF-8 LC_ALL=C.UTF-8 LC_CTYPE=C.UTF-8

# ── Constants (KI_* overrides exist for the dry-run harness, not for use) ───
SELF_URL=${KI_SELF_URL:-https://raw.githubusercontent.com/ridanit-ruma/kuber-nixos-flakes/main/install.sh}
STATE=${KI_STATE_DIR:-/var/lib/kuber-install}
NIXOS_REPO=${KI_NIXOS_REPO:-https://github.com/ridanit-ruma/kuber-nixos-flakes}
INFRA_REPO=${KI_INFRA_REPO:-https://github.com/ridanit-ruma/kuber-fluxcd}
JOIN_CONF=${KI_JOIN_CONF:-/var/lib/kubeadm/join-config.yaml}
KUBELET_CONF=${KI_KUBELET_CONF:-/etc/kubernetes/kubelet.conf}
BYID_DIR=${KI_BYID_DIR:-/dev/disk/by-id}

# Placeholders only. Every one of these is replaced from hosts/cluster.nix the
# moment the config repository is cloned, so the flake stays the single place
# any of them is written down. They exist because the environment check runs
# before the clone.
#
# kubelet-csr-approver only signs certificates for addresses on these two
# segments, and a denied CSR cannot be approved later -- so the address
# questions refuse anything else outright.
LAN_IF= LAN_PREFIX= GATEWAY=
FAB_IF= FAB_PREFIX= SSH_PORT=22 CONTROL_PLANE=

ANSWERS="$STATE/answers.env"
NIXCFG="$STATE/nixos-config"
INFRA="$STATE/infrastructure"
CURRENT="start"

# ── Small helpers ────────────────────────────────────────────────────────────
say()  { printf '%s\n' "$*"; }
step() { CURRENT="$2"; printf '\n[%s/9] %s\n' "$1" "$2"; }

die() {
  printf '\nSomething went wrong: %s\n' "$1" >&2
  [ $# -ge 2 ] && printf '%s\n' "$2" >&2
  exit 1
}

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\nStopped at: %s\n' "$CURRENT" >&2
    printf 'Answers so far are saved in %s.\n' "$ANSWERS" >&2
    printf 'Fix the problem and run the same command again -- it will not re-ask.\n' >&2
  fi
}
trap on_exit EXIT

ask() { # $1: prompt -> $REPLY (reads the terminal, not the pipe)
  if [ "$NOTTY" = "1" ]; then
    die "Need to ask a question, but there is no terminal (/dev/tty)." \
"The first two minutes ask a few things, so this needs an interactive
ssh session or a console. (A rerun with answers already saved can
continue without a terminal.)"
  fi
  printf '%s' "$1"
  IFS= read -r REPLY <&3 || REPLY=""
}

confirm() { # $1: prompt -> 0 yes / 1 no, default yes
  ask "$1 [Y/n] "
  case "$REPLY" in n|N|no) return 1 ;; *) return 0 ;; esac
}

save_answer() { # $1 key, $2 value -- values are validated, quotes stripped
  val=$(printf '%s' "$2" | tr -d "'")
  { [ -f "$ANSWERS" ] && grep -v "^$1=" "$ANSWERS" || true; } > "$ANSWERS.tmp"
  printf "%s='%s'\n" "$1" "$val" >> "$ANSWERS.tmp"
  mv "$ANSWERS.tmp" "$ANSWERS"
}

# ARP probe: a ping forces ARP resolution even when ICMP itself is filtered,
# so a populated neighbour entry means somebody holds the address.
addr_in_use() { # $1: ip
  ping -c1 -W1 "$1" >/dev/null 2>&1 || true
  ip neigh show "$1" 2>/dev/null | grep -q lladdr
}

is_own_addr() { ip -4 addr show 2>/dev/null | grep -q "inet $1/"; }

valid_ip_in() { # $1 ip, $2 prefix (x.y.z) -- also rejects .0/.1/.255
  case "$1" in
    "$2".*) ;;
    *) return 1 ;;
  esac
  last=${1##*.}
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  [ "$last" -ge 2 ] && [ "$last" -le 254 ]
}

# hosts/cluster.nix is where every node and address is written down. It is
# plain data -- no flake inputs, no module machinery -- so nix can read it
# directly, which beats the greps that used to pick these out of flake.nix: a
# second parser of a format nobody meant to be parsed, returning nothing at all
# the day the shape changed.
# --raw does not terminate its output with a newline; `echo` on success does,
# so a caller can pipe this straight to sed or read it line by line.
cluster_attr() { nix eval --impure --raw --expr \
  "let c = import $NIXCFG/hosts/cluster.nix; lib = (import <nixpkgs> {}).lib; in $1" \
  2>/dev/null && echo; }

flake_hosts()  { cluster_attr 'builtins.concatStringsSep "\n" (builtins.attrNames c.nodes)'; }
flake_addrs()  { cluster_attr 'builtins.concatStringsSep "\n" (builtins.concatMap (n: [ n.lan n.fabric ]) (builtins.attrValues c.nodes))'; }

suggest_addr() { # $1 prefix -> prefix.(max used last octet + 1)
  max=$(flake_addrs | grep "^$1\." | awk -F. '{print $4}' | sort -n | tail -1)
  [ -n "$max" ] || max=99
  echo "$1.$((max + 1))"
}

git_quiet() { git "$@" >/dev/null 2>&1; }

# make-join.sh talks to root@$KI_LAN_IP:$SSH_PORT. Those only exist after reboot:
# fresh NixOS is still on 22 / DHCP. So join waits until this machine is
# reachable at the new address; the script then polls for the token file.
offer_reboot() {
  say ""
  say "After reboot this machine will be $KI_HOST ($KI_LAN_IP, ssh $SSH_PORT)."
  say ""
  say "Once it is back:"
  say ""
  say "  1) SSH in and run the same one-liner:"
  say "       ssh -p $SSH_PORT nixos@$KI_LAN_IP"
  say "       curl -fsSL $SELF_URL | sudo sh"
  say ""
  say "  2) While that script waits for a token, on $CONTROL_PLANE:"
  say "       ~/nixos-config/scripts/make-join.sh $KI_HOST root@$KI_LAN_IP"
  say ""
  say "     Don't run make-join before the reboot -- the new address:$SSH_PORT is not up yet."
  if [ "${KI_AUTO_REBOOT:-}" = "yes" ]; then
    say ""
    say "Rebooting in 10 seconds..."
    sleep 10
    reboot
    exit 0
  fi
  say ""
  say "Reboot when you are ready:  reboot"
  exit 0
}

fresh_clone() { # $1 url, $2 dir -- reruns start from origin/main, not leftovers
  if [ -d "$2/.git" ]; then
    git -C "$2" fetch origin >/dev/null 2>&1 || die "git fetch failed ($1)" \
      "Network or GitHub auth may be the problem. Check with: gh auth status"
    git_quiet -C "$2" checkout main
    git_quiet -C "$2" reset --hard origin/main
  else
    git clone --quiet "$1" "$2" || die "Could not clone $1" \
      "Check gh auth status. If the login expired, run gh auth login and
rerun this script -- saved answers will not be asked again."
  fi
}

push_main() { # $1 dir, $2 what-for-messages
  git -C "$1" push --quiet origin main 2>/dev/null && return 0
  # Somebody pushed meanwhile; replay our commit on top and try once more.
  git_quiet -C "$1" pull --rebase origin main || die "Push of $2 hit a conflict" \
    "Look at git status in $1, tidy up, and rerun."
  git -C "$1" push --quiet origin main || die "Push of $2 was rejected" \
    "Check that gh auth has write access (gh auth status)."
}

# ── Terminal, root, OS ───────────────────────────────────────────────────────
# stdin is curl when piped, so the terminal is opened explicitly. Probed in a
# subshell first: a failed exec-redirect would end a POSIX shell outright.
# No terminal is fine as long as every answer is already saved -- ask() is
# what refuses, the moment a question actually needs a human.
TTYSRC=${KI_TTY:-/dev/tty}
if ( exec 3<"$TTYSRC" ) 2>/dev/null; then
  exec 3<"$TTYSRC"; NOTTY=0
else
  exec 3</dev/null; NOTTY=1
fi

if [ "${KI_UNSAFE_SKIP_CHECKS:-}" != "1" ]; then
  [ "$(id -u)" = "0" ] || die "Run this as root." \
"Disk lookup, the system build, and reboot all need root. Like this:

  curl -fsSL $SELF_URL | sudo sh
"
  grep -q '^ID=nixos' /etc/os-release 2>/dev/null || die "This does not look like NixOS." \
"This script runs on a machine that already has NixOS installed.
See kuber-infrastructure/docs/adding-a-node.md section 1."
fi

mkdir -p "$STATE" && chmod 700 "$STATE"
# shellcheck disable=SC1090  # our own file, written by save_answer above
[ -f "$ANSWERS" ] && . "$ANSWERS"

# ── Tools: fresh NixOS has neither git nor gh; borrow them via nix-shell ────
if ! command -v git >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
  say ""
  say "git and gh are missing; pulling them in with nix-shell. This can take a minute."
  if [ -f "$0" ]; then SELF="$0"; else
    SELF="$STATE/install.sh"
    curl -fsSL "$SELF_URL" -o "$SELF" || die "Could not download this script again." \
      "Check the network and rerun: curl -fsSL $SELF_URL | sh"
  fi
  exec nix-shell -p git -p gh --run "sh '$SELF'"
fi

say ""
say "This will join this machine to the myu cluster as a worker."
say "Questions take about two minutes; after that you can walk away."

# ── [1/9] Environment ────────────────────────────────────────────────────────
step 1 "Checking the environment"

curl -fsm 8 https://github.com >/dev/null 2>&1 || die "Cannot reach GitHub." \
  "Check the internet connection and rerun."

# The config repository comes first, because every fact below is read out of
# it. Cloning needs no login -- the repository is public, and the login in the
# next step is for pushing this machine back into it.
fresh_clone "$NIXOS_REPO" "$NIXCFG"

LAN_IF=$(cluster_attr 'c.lan.interface')
GATEWAY=$(cluster_attr 'c.lan.gateway')
FAB_IF=$(cluster_attr 'c.fabric.interface')
SSH_PORT=$(cluster_attr 'toString c.sshPort')
CONTROL_PLANE=$(cluster_attr \
  'builtins.head (builtins.attrNames (lib.filterAttrs (_: n: n.role == "control-plane") c.nodes))' \
  || true)
[ -n "$CONTROL_PLANE" ] || CONTROL_PLANE="the control plane"

# Both subnets are stated once, as the first address of each. `192.168.1.100`
# and a /24 make the prefix `192.168.1`, which is what the questions below
# offer and validate against.
LAN_PREFIX=$(cluster_attr 'builtins.head (builtins.attrValues c.nodes)' >/dev/null 2>&1; \
  cluster_attr 'let n = builtins.head (builtins.attrValues c.nodes); in builtins.concatStringsSep "." (lib.take 3 (lib.splitString "." n.lan))')
FAB_PREFIX=$(cluster_attr 'let n = builtins.head (builtins.attrValues c.nodes); in builtins.concatStringsSep "." (lib.take 3 (lib.splitString "." n.fabric))')

[ -n "$LAN_IF" ] && [ -n "$FAB_IF" ] && [ -n "$LAN_PREFIX" ] && [ -n "$FAB_PREFIX" ] \
  || die "Could not read hosts/cluster.nix." \
"That file is where the interfaces and both subnets are written down. Check
that $NIXOS_REPO has one, and that `nix` is on this machine's PATH."

# The flake and the worker module name these interfaces outright, so a machine
# with differently-named NICs would misbuild in ways that surface much later.
for ifc in "$LAN_IF" "$FAB_IF"; do
  ip link show "$ifc" >/dev/null 2>&1 || die "Network interface $ifc is missing." \
"hosts/cluster.nix names $LAN_IF (router LAN) and $FAB_IF (cluster fabric).
Interfaces on this machine:

$(ip -o link show 2>/dev/null | awk -F': ' '{print "  " $2}')

Either this machine's NICs are named differently -- change the names in
hosts/cluster.nix, which is the one place they are written down -- or it has
one NIC and the fabric needs to share it. Both are human decisions, so this
stops here."
done

ip link set "$FAB_IF" up 2>/dev/null || true
if [ -r "/sys/class/net/$FAB_IF/carrier" ] && [ "$(cat "/sys/class/net/$FAB_IF/carrier" 2>/dev/null)" != "1" ]; then
  say "  Note: $FAB_IF looks unplugged. Cluster traffic uses that port --"
  say "  plug it into the fabric switch before reboot. Continuing for now."
fi

say "  OK: internet, $LAN_IF ($LAN_PREFIX.0/24) and $FAB_IF ($FAB_PREFIX.0/24)."

# ── [2/9] GitHub ─────────────────────────────────────────────────────────────
step 2 "GitHub login"

if gh auth status -h github.com >/dev/null 2>&1; then
  say "  Already logged in. Using that session."
else
  say "  GitHub login is needed. In a moment an 8-digit code will appear."
  say "  On a phone or laptop, open https://github.com/login/device"
  say "  and type that code. One login reads and writes both config repos."
  say ""
  gh auth login --hostname github.com --git-protocol https --web <&3 \
    || die "GitHub login failed." \
    "Rerun and it continues from here. If the code expired, a new one is shown."
fi
gh auth setup-git >/dev/null 2>&1 || true

# ── [3/9] Hostname ───────────────────────────────────────────────────────────
step 3 "Picking a hostname"

if [ -n "${KI_HOST:-}" ]; then
  say "  Using saved answer: $KI_HOST"
else
  used=$(flake_hosts)
  # $used is a newline-separated list; the unquoted expansions below split it
  # on purpose (into words for display, into grep patterns for filtering).
  # shellcheck disable=SC2086
  say "  Names already in use: $(printf '%s ' $used)"
  while :; do
    # shellcheck disable=SC2086
    pick=$(grep -v '^#' "$NIXCFG/hosts/names.txt" | grep -v '^$' \
      | grep -vxF -e "$(printf '%s\n' $used)" | shuf -n1) || true
    [ -n "$pick" ] || { ask "  Name pool is empty. Type one: "; pick=$REPLY; }
    ask "  Call this machine '$pick'? [Enter=yes / r=pick again / or type a name] "
    case "$REPLY" in
      ""|y|Y|yes|YES) ;;
      r|R) continue ;;
      *) pick=$REPLY ;;
    esac
    # The CSR approver's regex: a name outside it joins fine and then quietly
    # loses kubectl logs/exec against it.
    printf '%s' "$pick" | grep -Eq '^[a-z0-9][a-z0-9-]{0,30}$' \
      || { say "  Names must be lowercase letters, digits, dashes; 31 chars max. ($pick)"; continue; }
    # shellcheck disable=SC2086
    printf '%s\n' $used | grep -qx "$pick" \
      && { say "  $pick is already taken."; continue; }
    break
  done
  KI_HOST=$pick; save_answer KI_HOST "$KI_HOST"
  say "  Chose: $KI_HOST"
fi

# ── [4/9] Addresses ──────────────────────────────────────────────────────────
step 4 "Choosing addresses"

if [ -n "${KI_LAN_IP:-}" ] && [ -n "${KI_FABRIC_IP:-}" ]; then
  say "  Using saved answer: LAN $KI_LAN_IP / fabric $KI_FABRIC_IP"
else
  say "  Addresses already in use:"
  flake_addrs | sed 's/^/    /'
  say ""

  # LAN side ($LAN_IF): ingress, ssh, the API server's view of this node.
  def=$(suggest_addr "$LAN_PREFIX")
  while :; do
    ask "  Router LAN address ($LAN_PREFIX.x) [Enter=$def]: "
    lan=${REPLY:-$def}
    valid_ip_in "$lan" "$LAN_PREFIX" \
      || { say "  Pick something in $LAN_PREFIX.2-254. The CSR approver rejects anything else."; continue; }
    flake_addrs | grep -qx "$lan" && { say "  $lan is already in the flake."; continue; }
    if is_own_addr "$lan"; then
      say "  $lan is already on this machine. Keeping it as the static address."
    elif addr_in_use "$lan"; then
      say "  $lan is already in use on the network (ARP reply). Try another."
      continue
    fi
    break
  done

  # Fabric side ($FAB_IF): node InternalIP -- pods, Ceph, etcd. The interface
  # has no address yet, so borrow one briefly; ARP needs a leg on the subnet.
  def=$(suggest_addr "$FAB_PREFIX")
  ip addr add "$FAB_PREFIX.254/24" dev "$FAB_IF" 2>/dev/null && probe_added=1 || probe_added=0
  while :; do
    ask "  Cluster fabric address ($FAB_PREFIX.x) [Enter=$def]: "
    fab=${REPLY:-$def}
    valid_ip_in "$fab" "$FAB_PREFIX" \
      || { say "  Pick something in $FAB_PREFIX.2-253."; continue; }
    [ "$fab" = "$FAB_PREFIX.254" ] && { say "  .254 is borrowed for the probe. Pick another."; continue; }
    flake_addrs | grep -qx "$fab" && { say "  $fab is already in the flake."; continue; }
    if addr_in_use "$fab"; then
      say "  $fab is already in use on the network (ARP reply). Try another."
      continue
    fi
    break
  done
  [ "$probe_added" = "1" ] && ip addr del "$FAB_PREFIX.254/24" dev "$FAB_IF" 2>/dev/null || true

  KI_LAN_IP=$lan;    save_answer KI_LAN_IP "$KI_LAN_IP"
  KI_FABRIC_IP=$fab; save_answer KI_FABRIC_IP "$KI_FABRIC_IP"
  say "  Chose: LAN $KI_LAN_IP / fabric $KI_FABRIC_IP"
fi

# ── [5/9] Disk ───────────────────────────────────────────────────────────────
step 5 "Choosing a disk for Ceph"

if [ -n "${KI_DISK:-}" ]; then
  if [ "$KI_DISK" = "skip" ]; then say "  Using saved answer: skip storage"
  else say "  Using saved answer: $KI_DISK"; fi
else
  # Candidates: fixed disks that do not hold / or /boot and have no mounts.
  sysdisks=$(findmnt -no SOURCE / /boot 2>/dev/null \
    | xargs -r -n1 lsblk -no PKNAME 2>/dev/null | sort -u)
  cand="$STATE/disk-candidates"; : > "$cand"
  lsblk -dn -o NAME,TYPE,RM,SIZE,MODEL 2>/dev/null | while read -r name type rm size model; do
    [ "$type" = "disk" ] && [ "$rm" = "0" ] || continue
    # shellcheck disable=SC2086  # newline list, splitting intended
    printf '%s\n' $sysdisks | grep -qx "$name" && continue
    lsblk -no MOUNTPOINTS "/dev/$name" 2>/dev/null | grep -q . && continue
    byid=""
    for l in "$BYID_DIR"/*; do
      [ -e "$l" ] || continue
      case "$l" in *-part[0-9]*) continue ;; esac
      [ "$(readlink -f "$l")" = "/dev/$name" ] || continue
      case "$(basename "$l")" in
        nvme-eui.*|wwn-*) [ -n "$byid" ] || byid=$l ;;
        *) byid=$l; break ;;
      esac
    done
    [ -n "$byid" ] || continue
    content=$(lsblk -no FSTYPE "/dev/$name" 2>/dev/null | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')
    [ -n "$content" ] || content="empty"
    printf '%s|%s|%s|%s\n' "$byid" "$size" "${model:-?}" "$content" >> "$cand"
  done

  n=$(wc -l < "$cand" | tr -d ' \t')
  if [ "$n" = "0" ]; then
    say "  No spare disk looks like a Ceph OSD candidate. Continuing without storage."
    say "  How to attach a disk later is in the wrap-up at the end."
    KI_DISK=skip; save_answer KI_DISK skip
  else
    say "  Candidate disks (system disk and anything mounted are omitted):"
    i=0
    while IFS='|' read -r byid size model content; do
      i=$((i + 1))
      say "    $i) $(basename "$byid")"
      say "       size $size / model $model / contents: $content"
    done < "$cand"
    say ""
    say "  Type skip if you are not sure. The node still joins; you can add"
    say "  the disk later."
    while :; do
      ask "  Which disk? [number / skip]: "
      [ "$REPLY" = "skip" ] && { KI_DISK=skip; save_answer KI_DISK skip; break; }
      case "$REPLY" in *[!0-9]*|''|0*) say "  Enter 1-$n or skip."; continue ;; esac
      line=$(sed -n "${REPLY}p" "$cand") || line=""
      [ -n "$line" ] || { say "  Enter 1-$n or skip."; continue; }
      byid=${line%%|*}
      rest=${line#*|}; size=${rest%%|*}
      rest=${rest#*|};  model=${rest%%|*}
      content=${rest#*|}
      say ""
      say "  $byid"
      say "  ($size, $model, contents: $content) will be erased. This cannot be undone."
      say "  The wipe itself runs after reboot -- this is only the confirmation."
      ask "  Type ERASE to confirm [anything else cancels]: "
      [ "$REPLY" = "ERASE" ] || { say "  Cancelled. Pick again."; continue; }
      KI_DISK=$byid
      save_answer KI_DISK "$KI_DISK"
      save_answer KI_DISK_DESC "$model $size"
      break
    done
  fi
fi

# Last question: consent to reboot, so the long stretch truly needs nobody.
if [ -z "${KI_AUTO_REBOOT:-}" ]; then
  say ""
  say "That is all the questions. Next is the build (10-15 min) and a reboot."
  if confirm "Reboot automatically when the build finishes?"; then KI_AUTO_REBOOT=yes; else KI_AUTO_REBOOT=no; fi
  save_answer KI_AUTO_REBOOT "$KI_AUTO_REBOOT"
fi

# ── Phase split ────────────────────────────────────────────────────────────
# `nixos-rebuild boot` stages a generation; it does not apply it. Join and
# disk-wipe need the new sshd port, static addresses, and kubeadm-join unit,
# so they wait until the booted system *is* that generation.
# Hostname is a bad signal: a machine already named $KI_HOST at install time
# would skip the build, and a declined reboot would look like success.
BOOTED=${KI_BOOTED_SYSTEM:-/run/booted-system}
PROFILE=${KI_SYSTEM_PROFILE:-/nix/var/nix/profiles/system}

host_in_flake() { flake_hosts | grep -qx "$KI_HOST"; }
hw_exists()     { [ -f "$NIXCFG/hosts/$KI_HOST/hardware-configuration.nix" ]; }
staged_not_booted() {
  [ -e "$BOOTED" ] && [ -e "$PROFILE" ] &&
    [ "$(readlink -f "$BOOTED")" != "$(readlink -f "$PROFILE")" ]
}

need_build=0
host_in_flake && hw_exists || need_build=1

if [ "$need_build" = 1 ]; then

  # ── [6/9] Configure, build, push, reboot ──────────────────────────────────
  step 6 "Writing config and building (10-15 min, you can walk away)"

  say "  About to:"
  say "    - generate hardware-configuration.nix -> hosts/$KI_HOST/"
  say "    - add $KI_HOST to hosts/cluster.nix (LAN $KI_LAN_IP / fabric $KI_FABRIC_IP)"
  say "    - build on this machine -> commit and push if it succeeds -> reboot"

  mkdir -p "$NIXCFG/hosts/$KI_HOST"
  nixos-generate-config --show-hardware-config > "$NIXCFG/hosts/$KI_HOST/hardware-configuration.nix" \
    || die "nixos-generate-config failed." \
      "Run nixos-generate-config --show-hardware-config yourself and check the output."

  if host_in_flake; then
    say "  hosts/cluster.nix already has $KI_HOST. Leaving it."
  else
    # One entry, appended at a marker the file carries for exactly this. The
    # role is what flake.nix uses to pick k8s-worker.nix over k8s-cluster.nix,
    # so a worker cannot be handed the module that runs `kubeadm init`.
    marker="# NEW NODES ARE INSERTED ABOVE THIS LINE"
    if ! grep -qF "$marker" "$NIXCFG/hosts/cluster.nix"; then
      die "Could not find the insertion marker in hosts/cluster.nix." \
        "Add an entry by hand -- same shape as the entries already there.
(docs/adding-a-node.md section 2)"
    fi
    awk -v host="$KI_HOST" -v lan="$KI_LAN_IP" -v fab="$KI_FABRIC_IP" \
        -v marker="$marker" '
      index($0, marker) {
        printf "    %s = {\n", host
        printf "      role = \"worker\";\n"
        printf "      lan = \"%s\";\n", lan
        printf "      fabric = \"%s\";\n", fab
        printf "    };\n"
      }
      { print }
    ' "$NIXCFG/hosts/cluster.nix" > "$NIXCFG/hosts/cluster.nix.new"
    mv "$NIXCFG/hosts/cluster.nix.new" "$NIXCFG/hosts/cluster.nix"
    say "  Added $KI_HOST to hosts/cluster.nix."
  fi

  # A flake only sees tracked files; stage before building or the new host
  # reads back as "file not found".
  git -C "$NIXCFG" add -A

  say "  Starting the build. The first one downloads a lot..."
  NIX_CONFIG="experimental-features = nix-command flakes" \
    nixos-rebuild boot --flake "$NIXCFG#$KI_HOST" \
    || die "The build failed." \
"The first error in the log above is the cause. The flake edits are still
in $NIXCFG; fix them and rerun -- it continues from the build.
(Nothing has been pushed yet.)"

  # Build proved the config; only now does it land on origin.
  if ! git -C "$NIXCFG" diff --cached --quiet; then
    login=$(gh api user -q .login 2>/dev/null || echo kuber-install)
    git -C "$NIXCFG" -c user.name="$login" -c user.email="$login@users.noreply.github.com" \
      commit --quiet -m "Add $KI_HOST as a worker"
    push_main "$NIXCFG" "kuber-nixos-config"
    say "  Committed and pushed: Add $KI_HOST as a worker"
  else
    say "  Nothing to commit (already on origin)."
  fi

  offer_reboot
fi

if staged_not_booted || [ "$(uname -n)" != "$KI_HOST" ]; then
  say ""
  say "The config is built. This machine needs a reboot to become $KI_HOST ($KI_LAN_IP)"
  say "before it can join the cluster."
  offer_reboot
fi

# ── [7/9] Join (after the reboot) ────────────────────────────────────────────
step 7 "Joining the cluster"

if [ -f "$KUBELET_CONF" ]; then
  say "  Already joined. Moving on."
else
  if [ ! -f "$JOIN_CONF" ]; then
    say "  No join token yet. Only the control plane can mint one."
    say "  On $CONTROL_PLANE, run this (leave this window open):"
    say ""
    say "      ~/nixos-config/scripts/make-join.sh $KI_HOST root@$KI_LAN_IP"
    say ""
    say "  That writes the token to $JOIN_CONF on this machine,"
    say "  and this script continues on its own. Waiting..."
    waited=0
    while [ ! -f "$JOIN_CONF" ]; do
      sleep 5; waited=$((waited + 5))
      [ $((waited % 60)) -eq 0 ] && say "  ...still waiting ($((waited / 60)) min). That command runs on $CONTROL_PLANE."
      [ "$waited" -ge 3600 ] && die "Waited an hour; the token never arrived." \
        "Check make-join.sh on $CONTROL_PLANE. Rerun this script and it continues from here."
    done
    say "  Token arrived."
  fi

  say "  Starting kubeadm join. Pulling images can take a few minutes..."
  systemctl start kubeadm-join || die "kubeadm join failed." \
"See:

  journalctl -u kubeadm-join -e

If the token expired (24h), rerun make-join.sh on $CONTROL_PLANE, then rerun
this script -- it continues from here."
  [ -f "$KUBELET_CONF" ] || die "Join finished but kubelet.conf is missing." \
    "Check: journalctl -u kubeadm-join -e"
  say "  Joined. On $CONTROL_PLANE:  kubectl get nodes"
fi

# ── [8/9] Storage ────────────────────────────────────────────────────────────
step 8 "Attaching Ceph storage"

if [ "${KI_DISK:-skip}" = "skip" ]; then
  say "  Storage was skipped. The node works without it."
  say "  To add a disk later:"
  say "    1) On this machine:  wipe-osd /dev/disk/by-id/<disk>"
  say "    2) In kuber-infrastructure, infrastructure/configs/rook-ceph-cluster.yaml"
  say "       add this node and that by-id path under storage.nodes, then push"
else
  # The wipe. wipe-osd re-checks the system-disk / mounted / by-id guards;
  # --i-typed-erase only stands in for the ERASE collected in the questions.
  if ! command -v wipe-osd >/dev/null 2>&1; then
    die "wipe-osd is not installed." \
"The flake deploys it. Confirm this machine rebooted into the new config.
(If you skipped reboot after nixos-rebuild boot, reboot now.)"
  fi
  if wipefs -n "$(readlink -f "$KI_DISK")" 2>/dev/null | grep -q . \
     || lsblk -no FSTYPE "$(readlink -f "$KI_DISK")" 2>/dev/null | grep -q .; then
    say "  Erasing $KI_DISK (the disk confirmed in the questions)."
    wipe-osd "$KI_DISK" --i-typed-erase || die "Disk wipe failed." \
      "Read wipe-osd's message. Fix it and rerun -- it continues from here."
  else
    say "  $KI_DISK is already empty. Leaving it."
  fi

  # Hand the disk to Rook: one entry in the cluster manifest, applied by Flux.
  fresh_clone "$INFRA_REPO" "$INFRA"
  ROOK_YAML="$INFRA/infrastructure/configs/rook-ceph-cluster.yaml"
  if grep -qE "name: [\"']?$KI_HOST[\"']?\$" "$ROOK_YAML"; then
    say "  Rook already lists $KI_HOST. Leaving it."
  else
    grep -q '^        nodes:$' "$ROOK_YAML" || die "Could not find nodes: in rook-ceph-cluster.yaml." \
      "The manifest shape probably changed. Add storage.nodes by hand."
    entry="$STATE/rook-entry.yaml"
    cat > "$entry" <<EOF
          - name: "$KI_HOST"
            devices:
              # ${KI_DISK_DESC:-disk}. Wiped and handed over by install.sh.
              - fullpath: $KI_DISK
EOF
    awk -v bf="$entry" '
      { print }
      /^        nodes:$/ && !done { while ((getline l < bf) > 0) print l; done=1 }
    ' "$ROOK_YAML" > "$ROOK_YAML.new"
    mv "$ROOK_YAML.new" "$ROOK_YAML"
    rm -f "$entry"
    git -C "$INFRA" add -A
    login=$(gh api user -q .login 2>/dev/null || echo kuber-install)
    git -C "$INFRA" -c user.name="$login" -c user.email="$login@users.noreply.github.com" \
      commit --quiet -m "Add $KI_HOST's disk to the Ceph cluster"
    push_main "$INFRA" "kuber-infrastructure"
    say "  Committed and pushed: Add $KI_HOST's disk to the Ceph cluster"
    say "  Flux picks it up within 10 minutes. To apply now, on $CONTROL_PLANE:"
    say "      flux reconcile kustomization infrastructure-configs --with-source"
  fi
fi

# ── [9/9] Wrap-up ────────────────────────────────────────────────────────────
step 9 "Wrap-up"

mac=$(ip -o link show "$LAN_IF" 2>/dev/null | grep -o 'ether [0-9a-f:]*' | cut -d' ' -f2)

say ""
say "============================================================"
say " $KI_HOST is in the cluster."
say "============================================================"
say ""
say " Done:"
say "   - NixOS config: hosts/$KI_HOST + flake entry (kuber-nixos-config)"
say "   - Cluster join: kubeadm join finished, kubelet running"
if [ "${KI_DISK:-skip}" = "skip" ]; then
  say "   - Storage: skipped (see [8/9] above to add it later)"
else
  say "   - Storage: $KI_DISK wiped and registered in Rook (kuber-infrastructure)"
fi
say ""
say " Still for you:"
say ""
say "   1) Router DHCP reservation -- the node works without it, but this"
say "      stops the router handing the same address to something else."
say "      On the router admin page:"
say "        MAC  ${mac:-($LAN_IF MAC -- ip link show $LAN_IF)}"
say "        IP   $KI_LAN_IP"
say ""
say "   2) On $CONTROL_PLANE, check:"
say "        kubectl get nodes          # $KI_HOST Ready means it worked"
say "        kubectl get csr            # kubelet-serving Approved,Issued"
if [ "${KI_DISK:-skip}" != "skip" ]; then
  say "        kubectl -n rook-ceph get pods | grep osd    # new OSD pod"
fi
say ""
say " Notes:"
say "   - Three nodes is the time to look at Ceph mon 3 / size 3."
say "     (kuber-infrastructure/docs/adding-a-node.md section 7)"
say "   - GitHub login is left in /root/.config/gh on this machine."
say "     If you are done with it:  gh auth logout --hostname github.com"
say ""
CURRENT="done"
