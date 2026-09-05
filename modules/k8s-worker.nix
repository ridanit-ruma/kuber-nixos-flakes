# A node that joins an existing cluster instead of starting one.
#
# Never use this together with modules/k8s-cluster.nix. That module runs
# `kubeadm init`, and a worker running it would quietly stand up a second,
# entirely separate cluster on the same network.
{
  config,
  pkgs,
  lib,
  cluster,
  ...
}:

let
  # Where the kubelet is reached and where pod, Ceph and etcd traffic goes.
  # From hosts/cluster.nix, which is also what modules/network.nix puts on the
  # interface -- so a machine cannot end up announcing one address and holding
  # another.
  fabricAddress = cluster.nodes.${config.networking.hostName}.fabric;

  criSocket = "unix:///run/containerd/containerd.sock";

  # Placed by hand, once per machine. It carries a bootstrap token, which is a
  # credential -- anyone holding it can add a node to the cluster -- so it is
  # read off the disk rather than committed here. See docs/adding-a-node.md.
  joinConfig = "/var/lib/kubeadm/join-config.yaml";

  clusterPath = with pkgs; [
    kubernetes
    iptables
    ipset
    conntrack-tools
    socat
    ethtool
    jq
    util-linux
    systemd
    coreutils
    gnugrep
    gnused
  ];
in
{
  # ── Node identity on the fabric ───────────────────────────────────────────
  # Without --node-ip the kubelet picks the address on the default route, which
  # is the router LAN, and pod and Ceph traffic would go back out that way.
  environment.etc."default/kubelet".text = ''
    KUBELET_EXTRA_ARGS="--node-ip=${fabricAddress}"
  '';

  environment.systemPackages = with pkgs; [
    cri-tools # crictl -- the only way to see containers when the kubelet is unhappy
    conntrack-tools
    ipset
    ethtool
    socat
  ];

  environment.etc."crictl.yaml".text = ''
    runtime-endpoint: ${criSocket}
    image-endpoint: ${criSocket}
    timeout: 10
  '';

  systemd.tmpfiles.rules = [
    # Cilium's install pod drops its CNI binaries here; containerd is already
    # configured to read from it. Neither creates it.
    "d /opt/cni/bin 0755 root root -"
    # 0700: the join token lives here.
    "d /var/lib/kubeadm 0700 root root -"
  ];

  # ── Join ──────────────────────────────────────────────────────────────────
  systemd.services.kubeadm-join = {
    description = "Join this node to the Kubernetes cluster";
    documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/" ];

    wantedBy = [ "multi-user.target" ];
    after = [
      "containerd.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "containerd.service" ];

    # Runs only when the token file is there and this node has not joined yet.
    # Joining writes kubelet.conf, after which the condition fails and systemd
    # skips the unit without marking it failed.
    unitConfig.ConditionPathExists = [
      joinConfig
      "!/etc/kubernetes/kubelet.conf"
    ];

    path = clusterPath;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Pulling the kubelet's images over a home connection takes longer than
      # the 90s default, and a timeout here leaves a half-joined node.
      TimeoutStartSec = "20min";
    };

    # No kubelet settings are given here on purpose: `kubeadm join` fetches the
    # cluster's kubelet-config ConfigMap, so cgroupDriver and serverTLSBootstrap
    # arrive from the control plane and cannot drift from it.
    script = ''
      kubeadm join --config=${joinConfig}
    '';
  };
}
