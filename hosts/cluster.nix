# Every fact about the cluster that more than one file needs, and the only
# place any of them is written down.
#
# This is data, not a NixOS module: no `config`, no `pkgs`, nothing imported.
# flake.nix reads it to build the host list, and the modules receive it through
# specialArgs.
#
# It exists because these facts used to live in four places — the per-host
# blocks in flake.nix, the ssh alias list, and two literals in k8s-cluster.nix —
# and only the first was updated when a node was added. A node added by
# install.sh therefore had no ssh alias anywhere, which is the kind of gap that
# is found weeks later by someone typing `ssh <node>`.
#
# ── Everything here is an example. Every value is meant to be replaced. ──
{
  # sshd listens here and the ssh aliases dial here. Changing it means changing
  # the router forward for the control plane at the same time, or losing remote
  # access to it. 22 works; a high port keeps the logs readable.
  sshPort = 2212;

  # A name rather than an address for the API server, because certificates are
  # issued for it. A VIP or a second control-plane node can take the endpoint
  # over later without reissuing anything. Resolved through networking.hosts,
  # which modules/network.nix points at whichever node has the control-plane
  # role below — so this name does not need to exist in any DNS server.
  controlPlaneEndpoint = "k8s-cp.cluster.lan";

  # The network that carries the default route, ssh, and the API server. The
  # interface name is what NixOS calls it on your hardware: check with `ip link`
  # on the machine, it is rarely `eth0` any more.
  lan = {
    interface = "enp3s0";
    prefixLength = 24;
    gateway = "192.168.1.1";
  };

  # The cluster fabric: pod traffic, Ceph replication, etcd peers, and BGP once
  # it has a peer. No gateway — nothing routes off it. A second NIC per machine
  # on its own switch is the intent; one NIC works if you give both addresses to
  # the same interface.
  fabric = {
    interface = "enp4s0";
    prefixLength = 24;
  };

  # ── nodes ───────────────────────────────────────────────────────────────────
  # One entry per machine. Exactly one must have role = "control-plane"; the
  # flake refuses to evaluate otherwise, rather than silently picking one.
  #
  # Adding a machine is this line plus hosts/<name>/hardware-configuration.nix,
  # which `nixos-generate-config` writes on the machine itself. install.sh does
  # both for you and inserts immediately above the marker at the end of this set
  # — keep that marker, and keep one node per line.
  #
  # `kata = true` gives a node the Kata Containers runtime as well, for pods
  # that should run in a VM rather than a namespace. Omit it and the node runs
  # ordinary containers.
  nodes = {
    example = {
      role = "control-plane";
      lan = "192.168.1.100";
      fabric = "10.10.0.1";
    };
    # NEW NODES ARE INSERTED ABOVE THIS LINE
  };
}
