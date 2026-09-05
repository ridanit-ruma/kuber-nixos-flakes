# Addresses, name resolution, wake-on-lan and the firewall.
#
# The addresses are not written here: they come from hosts/cluster.nix, which
# is also what flake.nix builds the host list from and what modules/users.nix
# builds the ssh aliases from. A machine can no longer announce one address and
# hold another, because there is only one place to write it.
{
  config,
  lib,
  cluster,
  ...
}:

let
  node = cluster.nodes.${config.networking.hostName};
in
{
  # Static rather than DHCP. kubeadm binds the API server certificate and etcd
  # to the control plane's address, so a changed lease would break the cluster;
  # the workers are static for the same reason their fabric addresses appear in
  # kubelet-csr-approver's allowed range.
  #
  # NetworkManager is off because it also manages interfaces a CNI creates,
  # which it should not.
  networking.useDHCP = false;
  networking.networkmanager.enable = false;

  # One attrset rather than a path per setting: with an interpolated name Nix
  # will not merge `networking.interfaces.${x}.a` with
  # `networking.interfaces.${x}.b` the way it merges static keys, and rejects
  # the second as a redefinition.
  #
  # wakeOnLan is only the operating system's half -- it asks the driver to keep
  # the NIC listening for a magic packet across a shutdown. The firmware has to
  # allow it too: look for "Wake on LAN", "Power On by PCIe" or "ErP" in the
  # UEFI setup. ErP or deep-sleep being enabled is the usual reason a correct
  # configuration still will not wake a machine, and nothing here can set it.
  networking.interfaces = {
    ${cluster.lan.interface} = {
      ipv4.addresses = [
        {
          address = node.lan;
          inherit (cluster.lan) prefixLength;
        }
      ];
      wakeOnLan.enable = true;
    };

    # No gateway on the fabric: nothing routes off it, and the default route
    # stays on the LAN.
    ${cluster.fabric.interface} = {
      ipv4.addresses = [
        {
          address = node.fabric;
          inherit (cluster.fabric) prefixLength;
        }
      ];
      wakeOnLan.enable = true;
    };
  };

  networking.defaultGateway = cluster.lan.gateway;

  # Public resolvers rather than the ISP's, so this config resolves the same way
  # on whatever machine it is applied to.
  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # The control plane endpoint, resolved to whichever node holds that role.
  networking.hosts.${cluster.nodes.${cluster.controlPlane}.lan} = [ cluster.controlPlaneEndpoint ];

  # ── Firewall ────────────────────────────────────────────────────────────────
  # SSH is opened by services.openssh.openFirewall in modules/users.nix.
  networking.firewall = {
    enable = true;

    # The fabric is deliberately NOT trusted. The plan was a switch carrying
    # cluster nodes and nothing else, which would have made trusting it
    # reasonable. It is not that: both NICs learn the same neighbours -- the
    # router and a household device appear in the ARP table on each -- so the
    # fabric shares one L2 segment with everything else on this network.
    #
    # Trusting it would let anything on that switch give itself a fabric
    # address and reach the kubelet, etcd and Ceph with no filtering at all.
    # The ports below are enough for the cluster to talk to itself; BGP's 179
    # belongs here too, once it has a peer.

    # Pod traffic arrives on interfaces the kernel does not consider the
    # reverse route for, so NixOS' default rpfilter drops it. Cilium and Calico
    # both need this off.
    checkReversePath = false;

    allowedTCPPorts = [
      # No 80 or 443. Nothing reaches this machine from the internet:
      # cloudflared holds an outbound tunnel and traffic arrives through it, so
      # there is no inbound port to open and no forward for the router to point
      # here.

      6443 # kube-apiserver
      10250 # kubelet API
      10256 # kube-proxy health
      10257 # kube-controller-manager
      10259 # kube-scheduler
      3300 # Ceph monitor, msgr v2
      6789 # Ceph monitor, msgr v1
    ];

    allowedTCPPortRanges = [
      {
        from = 2379;
        to = 2380;
      } # etcd client + peer
      {
        from = 6800;
        to = 7300;
      } # Ceph OSD / MGR / MDS
      {
        from = 30000;
        to = 32767;
      } # NodePort
    ];

    allowedUDPPorts = [
      8472 # VXLAN, Cilium and Flannel
      4789 # VXLAN, Calico
    ];

    # Once a CNI is picked, putting its interfaces in trustedInterfaces
    # (cni0, flannel.1, cilium_host, ...) is tighter than the port ranges
    # above.
  };
}
