# Everything a machine needs before `kubeadm init` or `kubeadm join` will run,
# and nothing that depends on which of the two it gets.
#
# kubeadm installs neither a container runtime nor a kubelet unit. It assumes
# both are already there and writes its configuration into the paths they are
# expected to read, so this module is that other half: containerd on the cgroup
# driver kubeadm will ask for, the kernel state the pod network needs, and a
# kubelet unit pointed at the files kubeadm leaves behind.
{ pkgs, lib, ... }:
{
  # ── Container runtime ───────────────────────────────────────────────────────
  virtualisation.containerd = {
    enable = true;
    settings = {
      # A drop-in directory, so a one-machine runtime tweak does not mean
      # editing this file and rebuilding every node in the cluster.
      imports = [ "/etc/containerd/conf.d/*.toml" ];

      plugins."io.containerd.grpc.v1.cri" = {
        containerd = {
          snapshotter = "overlayfs";

          # runc, on the systemd cgroup driver. Both halves are easy to get
          # wrong and neither failure announces itself.
          #
          # The name has to be the one default_runtime_name selects. Configure
          # a runtime under some other name and the block is simply inert:
          # containerd falls back to a built-in runc on cgroupfs and logs
          # nothing about the settings it ignored.
          #
          # The driver has to match the kubelet's cgroupDriver, which the
          # kubeadm config in modules/k8s-cluster.nix sets to systemd. On
          # cgroup v2 a mismatch leaves the kubelet and the runtime accounting
          # the same cgroup twice, and pods then fail in ways that never name
          # the cause.
          default_runtime_name = "runc";
          runtimes.runc = {
            runtime_type = "io.containerd.runc.v2";
            options.SystemdCgroup = true;
          };
        };

        # Where the network plugin puts its binaries and drops its config.
        # Cilium installs itself as a DaemonSet that writes into both of these
        # directories on the host, so they are a contract with it rather than
        # a preference.
        cni = {
          bin_dir = "/opt/cni/bin";
          conf_dir = "/etc/cni/net.d";
        };
      };
    };
  };

  # NixOS writes a CNI configuration of its own into /etc/cni/net.d whenever
  # something pulls in that module. Cilium owns the directory here, and with
  # two writers the pod network is decided by whichever ran last.
  environment.etc."cni/net.d".enable = lib.mkForce false;
  systemd.tmpfiles.rules = [ "d /etc/cni/net.d 0755 root root -" ];

  # ── Kernel ──────────────────────────────────────────────────────────────────
  # br_netfilter puts bridged frames through iptables, which is how a ClusterIP
  # gets rewritten for a pod talking to a pod on the same node. overlay backs
  # the snapshotter above.
  boot.kernelModules = [
    "br_netfilter"
    "overlay"
  ];

  # mkDefault throughout: these are the minimum kubeadm's preflight checks
  # accept, not a position on what the value ought to be. A host that needs
  # something else can say so without reaching for lib.mkForce.
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
    "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    "net.ipv4.ip_forward" = lib.mkDefault 1;
  };

  environment.systemPackages = [ pkgs.kubernetes ]; # kubeadm, kubelet, kubectl

  # ── kubelet ─────────────────────────────────────────────────────────────────
  # Not services.kubernetes.kubelet: that module wants to own the node's
  # configuration, and kubeadm renders that configuration itself from the
  # cluster's kubelet-config ConfigMap. Running both gives one file two
  # sources. This unit is deliberately thin -- it starts the binary and points
  # it at what kubeadm wrote.
  systemd.services.kubelet = {
    description = "Kubernetes Kubelet";
    documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "containerd.service" ];

    # The kubelet shells out for most of what it does, and a missing binary
    # surfaces as a failed pod rather than as a missing binary: iptables for
    # service rules, util-linux for mount, the mkfs and fsck families for
    # volumes, lvm2 for what Ceph presents, socat for `kubectl port-forward`,
    # ethtool for interface queries, and systemd-run for the cgroup driver
    # chosen above.
    path = with pkgs; [
      kubernetes
      cri-tools
      iptables
      util-linux
      e2fsprogs
      xfsprogs
      lvm2
      socat
      ethtool
      systemd
    ];

    # `after = containerd.service` orders this after containerd reports ready,
    # and that is not the same as containerd answering. It signals readiness
    # once its socket is up, while the CRI v1 plugin behind that socket is
    # still initialising -- and the kubelet validates the CRI API as its first
    # act and exits when it is not there yet.
    #
    # Restart=always does recover from losing that race, in ten seconds. What
    # it does not do is stop `nixos-rebuild switch` reporting the whole deploy
    # as failed when it restarts both units and then looks too early, which is
    # exactly what happened to one worker while the control plane won the
    # same race.
    #
    # crictl is the CRI client, so this asks the question the kubelet is about
    # to ask, and returns the moment the answer is yes.
    preStart = ''
      for _ in $(seq 1 60); do
        if crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
             version >/dev/null 2>&1; then
          exit 0
        fi
        sleep 1
      done
      echo "kubelet: containerd did not serve the CRI API within 60s" >&2
      exit 1
    '';

    # Before the first init or join there is no config.yaml, so the kubelet
    # exits at once and keeps doing so. That window is expected -- the
    # bootstrap units in modules/k8s-cluster.nix run inside it -- but it must
    # not end with systemd giving up on the unit, which its default start rate
    # limit is there to eventually do.
    unitConfig.StartLimitIntervalSec = 0;

    serviceConfig = {
      # None of these three paths is a choice; they are where kubeadm writes.
      #   bootstrap-kubelet.conf  a short-lived credential, spent once asking
      #                           the API server for a real one
      #   kubelet.conf            the real one, written when that succeeds
      #   config.yaml             rendered from the cluster's kubelet-config
      #                           ConfigMap, on init and on join
      ExecStart = ''
        ${pkgs.kubernetes}/bin/kubelet \
          --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
          --kubeconfig=/etc/kubernetes/kubelet.conf \
          --config=/var/lib/kubelet/config.yaml \
          $KUBELET_KUBEADM_ARGS \
          $KUBELET_EXTRA_ARGS
      '';

      # kubeadm-flags.env is kubeadm's, rewritten on every init or join.
      # /etc/default/kubelet is ours: modules/k8s-cluster.nix and
      # modules/k8s-worker.nix put the node's fabric address there. Both are
      # prefixed with `-` because neither exists until the node has joined
      # something, and the kubelet has to be able to start before that.
      EnvironmentFile = [
        "-/var/lib/kubelet/kubeadm-flags.env"
        "-/etc/default/kubelet"
      ];

      Restart = "always";
      RestartSec = 10;
    };
  };
}
