# kuber-nixos-flakes

**A Kubernetes cluster of NixOS machines, declared once.**

Every machine in the cluster is described by one entry in one file. Adding a node is that
entry plus the hardware configuration NixOS generates on the machine itself — everything else
follows: addresses, ssh aliases, firewall, the kubelet, containerd, Ceph's prerequisites, and
whether the machine runs `kubeadm init` or `kubeadm join`.

There is an installer for the machine that has never been touched: it asks about five things,
then builds, reboots, joins the cluster and hands its disks to Ceph.

This is the host half. The cluster's own workloads — CNI, ingress, storage, certificates —
live in [kuber-fluxcd](https://github.com/ridanit-ruma/kuber-fluxcd) and arrive through Flux.

> **Built for a four-node cluster of small x86 machines at home.** It is a working setup, not
> a distribution: read it, take what you need, and expect to change the addresses.

---

## The one file

`hosts/cluster.nix` is data — no `config`, no `pkgs`, nothing imported. The flake reads it to
build the host list and passes it to every module.

```nix
{
  sshPort = 2212;
  controlPlaneEndpoint = "k8s-cp.cluster.lan";   # a name, so certificates survive a move

  lan    = { interface = "enp3s0"; prefixLength = 24; gateway = "192.168.1.1"; };
  fabric = { interface = "enp4s0"; prefixLength = 24; };

  nodes = {
    example = { role = "control-plane"; lan = "192.168.1.100"; fabric = "10.10.0.1"; };
    # worker = { role = "worker"; lan = "192.168.1.101"; fabric = "10.10.0.2"; kata = true; };
  };
}
```

Two networks per machine, on purpose. The LAN carries the default route, ssh and the API
server; the fabric carries pod traffic, Ceph replication and etcd peers, and has no gateway
because nothing should route off it.

Exactly one node may be `control-plane`. The flake refuses to evaluate otherwise rather than
picking one — two `kubeadm init`s on one network is two clusters, discovered later.

## What a machine gets

| Module | |
|---|---|
| `base.nix` | boot, nix settings, locale, the packages a node actually needs |
| `network.nix` | both addresses, resolvers, wake-on-LAN, firewall |
| `users.nix` | accounts, keys, sshd, and an ssh alias per node from the same data |
| `tools.nix` | `nixbuild`, `nixdeploy`, `cf-tunnel`, `wipe-osd` |
| `k8s-node.nix` | containerd, the kernel settings kubelet insists on, the kubelet unit |
| `ceph-node.nix` | what Rook needs of a host before it will take a disk |
| `k8s-cluster.nix` / `k8s-worker.nix` | `kubeadm init` on the control plane, `kubeadm join` on a worker |
| `kata-worker.nix` | Kata Containers, on the nodes that ask for it |

## Installing a node

On a machine with NixOS freshly installed and nothing else done to it:

```sh
curl -fsSL https://raw.githubusercontent.com/ridanit-ruma/kuber-nixos-flakes/main/install.sh | sudo sh
```

It asks about five things in the first two minutes — hostname, both addresses, which disk to
give Ceph — and then works unattended. Answers are saved, so a rerun after the reboot picks up
where it left off rather than asking again. Nine steps, and it says which one it is on.

Everything it needs about your network it reads from `hosts/cluster.nix`: interface names, both
subnets, the ssh port, which node is the control plane. Point `KI_NIXOS_REPO` at your own fork
and it installs your cluster instead of this one.

Joining needs a token, which only the control plane can mint:

```sh
scripts/make-join.sh <new-node> root@<its-lan-address>
```

Run it after the new machine has rebooted onto its own address, not before.

## Day to day

```sh
nixbuild                 # build this flake for this machine and switch to it
nixdeploy <node>         # build here, copy the closure, switch there
scripts/wipe-osd.sh      # give a disk back to Ceph after removing an OSD
scripts/cf-tunnel.sh     # create a Cloudflare tunnel and seal its token with sops
```

## Thanks

The kubelet unit and the Ceph host preparation here started from
[minco](https://github.com/mincomk)'s
[server-nixos-flakes](https://github.com/mincomk/server-nixos-flakes) — the ordering that makes
containerd and the kubelet come up in the right order, and what a host has to do before Rook
will take one of its disks, are both problems that repository had already solved carefully.
Thank you.

`kubbr/kube.bash` is generated output from [mincomk/kubbr](https://github.com/mincomk/kubbr),
carried verbatim under its own BSD-3-Clause licence — see `kubbr/LICENSE`.

## License

Apache License 2.0 — see [LICENSE](LICENSE), except `kubbr/`, which keeps its own.
