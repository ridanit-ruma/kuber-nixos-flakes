#!/usr/bin/env bash
# Generate a bootstrap token and write the join configuration onto a worker.
#
# The token never leaves this machine except into the file it is meant for:
# it is captured into a variable, written straight through ssh, and the only
# thing printed is whether it worked. Anyone holding it can add a node to the
# cluster, so it does not belong in a terminal scrollback or a repo.
set -euo pipefail

usage() {
  echo "usage: make-join.sh <node-name> <ssh-target> [port]" >&2
  echo "   eg: make-join.sh worker-2 root@192.168.1.102" >&2
  echo "" >&2
  echo "Run this on the control plane (ken). It mints a bootstrap token and" >&2
  echo "writes the join config straight onto the node over ssh; the token is" >&2
  echo "never printed. The port defaults to 2212, the cluster's sshd port." >&2
  exit 1
}

NODE=${1:-}; TARGET=${2:-}
[ -n "$NODE" ] && [ -n "$TARGET" ] || usage
PORT=${3:-2212}
# Matches controlPlaneEndpoint in hosts/cluster.nix.
ENDPOINT=${ENDPOINT:-k8s-cp.cluster.lan:6443}
KUBECONFIG_FILE="$HOME/.kube/config"

command -v kubeadm >/dev/null || {
  echo "kubeadm not found -- this runs on the control plane, not on the new node." >&2
  exit 1
}

# 24 hours is the default and plenty: the token is only needed for the one
# join, and a shorter life means a leaked one is useless sooner.
JOIN=$(kubeadm token create --print-join-command --ttl 24h \
         --description "join $NODE" --kubeconfig "$KUBECONFIG_FILE" 2>/dev/null)

TOKEN=$(printf '%s' "$JOIN" | grep -oE -- '--token [^ ]+' | cut -d' ' -f2)
HASH=$(printf '%s' "$JOIN" | grep -oE -- '--discovery-token-ca-cert-hash [^ ]+' | cut -d' ' -f2)
[ -n "$TOKEN" ] && [ -n "$HASH" ] || { echo "could not parse the join command"; exit 1; }

echo "  token created for $NODE (${#TOKEN} chars), ca hash ${HASH:0:14}…"

ssh -o BatchMode=yes -p "$PORT" "$TARGET" "install -d -m 700 /var/lib/kubeadm && cat > /var/lib/kubeadm/join-config.yaml && chmod 600 /var/lib/kubeadm/join-config.yaml" <<YAML
# Written by make-join.sh. Carries a bootstrap token -- keep it off git.
# modules/k8s-worker.nix runs kubeadm with this file and then never again:
# joining writes /etc/kubernetes/kubelet.conf, and the unit's condition fails
# from that point on.
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: $TOKEN
    apiServerEndpoint: $ENDPOINT
    caCertHashes:
      - $HASH
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: "$NODE"
YAML

unset TOKEN HASH JOIN

echo "  written to $TARGET:/var/lib/kubeadm/join-config.yaml"
ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
  'echo "  mode $(stat -c %a /var/lib/kubeadm/join-config.yaml), $(wc -l < /var/lib/kubeadm/join-config.yaml) lines"'

echo ""
echo "  If install.sh is waiting on $NODE it picks this up by itself."
echo "  Joining by hand instead? On $NODE run:  systemctl start kubeadm-join"
echo "  Then check from here:                   kubectl get nodes"
