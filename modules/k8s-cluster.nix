# The control plane itself.
#
# modules/k8s-node.nix prepares the node -- containerd, kernel modules, sysctls,
# the kubelet unit -- and stops there. Without a `kubeadm init` the kubelet has
# no /var/lib/kubelet/config.yaml to read and restarts every ten seconds
# forever. This module ends that state.
#
# Everything below is a boot-path unit behind a condition, so applying this
# flake to a bare machine yields a running cluster with no commands typed.
{
  config,
  pkgs,
  lib,
  cluster,
  ...
}:

let
  nodeName = config.networking.hostName;
  node = cluster.nodes.${nodeName};

  # The node's own address. kubeadm binds etcd and the API server to it and
  # writes it into their certificates, which is why it is pinned statically in
  # hosts/cluster.nix rather than left to DHCP.
  apiAddress = node.lan;

  # Certificates are issued for this name, not the address, so a VIP or a
  # second control-plane node can take the endpoint over later without
  # reissuing them. Resolved through networking.hosts.
  inherit (cluster) controlPlaneEndpoint;

  # The node's address on the cluster fabric. This is what Kubernetes calls the
  # node InternalIP: the kubelet is reached here, Cilium routes between nodes
  # here, and the kubelet asks for a serving certificate naming it -- so
  # kubelet-csr-approver in the GitOps repo has to list this segment, or it
  # denies the request and the certificate can never be issued.
  #
  # Deliberately not apiAddress. The API server, ingress and SSH stay on the
  # router LAN; everything the cluster says to itself goes over the switch.
  fabricAddress = node.fabric;

  criSocket = "unix:///run/containerd/containerd.sock";

  # Taken from the package rather than written out, so the cluster cannot end
  # up a different version from the kubelet that joins it. Pinning it at all
  # matters because an unset kubernetesVersion makes kubeadm fetch "stable"
  # from dl.k8s.io at init time.
  kubernetesVersion = "v${pkgs.kubernetes.version}";

  # kubeadm hands each node a slice of podSubnet and Cilium runs with
  # ipam.mode=kubernetes, so pod addresses come out of the node's own PodCIDR.
  # A BGP session can then advertise one prefix per node instead of tracking
  # individual pods.
  podSubnet = "10.244.0.0/16";
  serviceSubnet = "10.96.0.0/12";

  # Pinned rather than left to the cilium-cli default: an unpinned bootstrap
  # would install a different Cilium on a machine built from this flake later.
  ciliumVersion = "v1.20.0";

  adminConf = "/etc/kubernetes/admin.conf";

  # Flux decrypts the sops-encrypted secrets in the GitOps repo with this key.
  # It cannot live in that repo -- it is what reads it -- so it is taken from
  # the machine, where sops already keeps it for command-line use. A user path
  # in a system module is not pretty; the alternative is a second copy of the
  # same private key somewhere else on disk.
  sopsAgeKeyFile = "/home/nixos/.config/sops/age/keys.txt";

  # Every admin account gets its own copy of admin.conf so kubectl works with
  # no KUBECONFIG set. Derived from the wheel group rather than listed, so
  # adding an admin to flake.nix is enough.
  adminUsers = lib.attrNames (
    lib.filterAttrs (
      _: u: (u.isNormalUser or false) && lib.elem "wheel" (u.extraGroups or [ ])
    ) config.users.users
  );

  kubeadmConfig = pkgs.writeText "kubeadm-config.yaml" ''
    apiVersion: kubeadm.k8s.io/v1beta4
    kind: InitConfiguration
    localAPIEndpoint:
      advertiseAddress: ${apiAddress}
      bindPort: 6443
    nodeRegistration:
      criSocket: ${criSocket}
      name: ${nodeName}
    ---
    apiVersion: kubeadm.k8s.io/v1beta4
    kind: ClusterConfiguration
    kubernetesVersion: ${kubernetesVersion}
    controlPlaneEndpoint: ${controlPlaneEndpoint}:6443
    networking:
      podSubnet: ${podSubnet}
      serviceSubnet: ${serviceSubnet}
    apiServer:
      certSANs:
        - ${controlPlaneEndpoint}
        - ${apiAddress}
        - ${nodeName}
        - localhost
        - 127.0.0.1
    ---
    apiVersion: kubelet.config.k8s.io/v1beta1
    kind: KubeletConfiguration
    # Must match containerd's runc runtime, which modules/k8s-node.nix sets to
    # SystemdCgroup. On cgroup v2 a mismatch makes the kubelet and the runtime
    # account the same cgroup twice, and pods fail in ways that do not name
    # the cause.
    cgroupDriver: systemd
    # The kubelet asks for its serving certificate through a CSR rather than
    # signing one itself, which is what lets the API server verify it. Set
    # here because kubeadm renders config.yaml from this, on the control plane
    # and on every node that joins.
    serverTLSBootstrap: true
    ---
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: iptables
  '';

  # kubeadm's preflight refuses to run without conntrack and warns about the
  # rest. They stay out of systemPackages because nothing but the cluster and
  # its bootstrap needs them on PATH.
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
  # modules/k8s-node.nix already reads this file through EnvironmentFile, so
  # setting it here is enough -- no unit override needed.
  #
  # Without --node-ip the kubelet picks the address on the default route,
  # which is the router LAN, and every byte of pod and Ceph traffic goes back
  # out that way. The second NIC would carry BGP keepalives and nothing else.
  environment.etc."default/kubelet".text = ''
    KUBELET_EXTRA_ARGS="--node-ip=${fabricAddress}"
  '';

  # ── Node prerequisites ────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    cri-tools # crictl -- the only way to see containers when the API server is down
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
  ];

  # ── Bootstrap ─────────────────────────────────────────────────────────────
  systemd.services.kubeadm-init = {
    description = "Bootstrap the Kubernetes control plane";
    documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];

    wantedBy = [ "multi-user.target" ];
    after = [
      "containerd.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "containerd.service" ];

    # What makes this safe to leave in the boot path: once the cluster exists
    # admin.conf exists, the condition fails, and systemd skips the unit
    # without marking it failed.
    unitConfig.ConditionPathExists = "!${adminConf}";

    path = clusterPath;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Seven control-plane images over a home connection take longer than the
      # 90s default, and a timeout here leaves a half-built cluster behind.
      TimeoutStartSec = "30min";
    };

    script = ''
      kubeadm init --config=${kubeadmConfig} --skip-token-print
    '';
  };

  # ── Single-node adjustments and admin kubeconfig ──────────────────────────
  systemd.services.k8s-post-init = {
    description = "Single-node cluster adjustments and per-admin kubeconfig";

    wantedBy = [ "multi-user.target" ];
    after = [ "kubeadm-init.service" ];
    requires = [ "kubeadm-init.service" ];

    unitConfig.ConditionPathExists = adminConf;

    path = clusterPath;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "10min";
    };

    # Runs on every boot rather than once: each step is idempotent, so adding
    # an admin to flake.nix gives them a kubeconfig at the next activation.
    script = ''
      export KUBECONFIG=${adminConf}

      echo "waiting for the API server"
      for _ in $(seq 1 120); do
        kubectl get --raw=/readyz >/dev/null 2>&1 && break
        sleep 5
      done
      kubectl get --raw=/readyz >/dev/null

      # Single node: nothing would ever schedule if the control-plane taint
      # stayed. Harmless once a worker joins -- rerunning it is a no-op.
      kubectl taint nodes ${nodeName} \
        node-role.kubernetes.io/control-plane- 2>/dev/null || true

      # The kubeadm config above turns on serverTLSBootstrap, so the kubelet asks
      # for its serving certificate through a CSR. Kubernetes ships no
      # approver for the kubelet-serving signer -- kube-controller-manager
      # auto-approves the client signer and nothing else -- so the request
      # sits Pending, the API server cannot verify the kubelet, and every
      # `kubectl logs` and `kubectl exec` fails with `tls: internal error`.
      #
      # Scoped to this node's own identity and nothing else. Every other
      # node's request is left for kubelet-csr-approver, which runs from the
      # GitOps repo and checks the names and addresses asked for against the
      # node that asked. This unit only has to cover the gap before that
      # controller exists -- on a freshly built cluster, Flux has not
      # installed it yet, and without a serving certificate `kubectl logs`
      # and `kubectl exec` do not work.
      #
      # Widening this back to every `system:node:` requestor would let any
      # node mint a serving certificate for any name in the cluster.
      pending_serving_csrs() {
        kubectl get csr -o json | jq -r --arg me "system:node:${nodeName}" '
          .items[]
          | select(.spec.signerName == "kubernetes.io/kubelet-serving")
          | select(.status.conditions == null)
          | select(.spec.username == $me)
          | .metadata.name'
      }

      # Only wait when the kubelet has no certificate yet. With one already in
      # place there is nothing to approve, and waiting would stall every boot.
      if [ ! -e /var/lib/kubelet/pki/kubelet-server-current.pem ]; then
        echo "kubelet has no serving certificate; waiting for its CSR"
        for _ in $(seq 1 18); do
          [ -n "$(pending_serving_csrs)" ] && break
          sleep 5
        done
      fi

      for csr in $(pending_serving_csrs); do
        echo "approving kubelet-serving CSR $csr"
        kubectl certificate approve "$csr"
      done

      ${lib.concatMapStringsSep "\n" (u: ''
        install -d -o ${u} -g users -m 0700 ${config.users.users.${u}.home}/.kube
        install -o ${u} -g users -m 0600 ${adminConf} \
          ${config.users.users.${u}.home}/.kube/config
      '') adminUsers}
    '';
  };

  # ── GitOps decryption key ─────────────────────────────────────────────────
  # Recreated on every boot rather than left as a one-time `kubectl create`, so
  # a machine rebuilt from this flake can reach its own secrets again. Flux
  # itself still has to be bootstrapped by hand once: `flux bootstrap` needs a
  # GitHub credential and writes a deploy key back to the repo, and neither
  # belongs in a boot path.
  systemd.services.flux-sops-key = {
    description = "Install the age key Flux uses to decrypt SOPS secrets";

    wantedBy = [ "multi-user.target" ];
    after = [ "k8s-post-init.service" ];
    requires = [ "k8s-post-init.service" ];

    unitConfig.ConditionPathExists = [
      adminConf
      sopsAgeKeyFile
    ];

    path = clusterPath;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "5min";
    };

    script = ''
      export KUBECONFIG=${adminConf}

      # flux-system may not exist yet on a cluster that has never been
      # bootstrapped. Creating it here does no harm -- `flux bootstrap` adopts
      # it -- and means the key is in place the moment Flux arrives.
      kubectl create namespace flux-system \
        --dry-run=client -o yaml | kubectl apply -f -

      # The key inside the secret must end in .agekey; Flux looks for that
      # suffix rather than a fixed name.
      kubectl -n flux-system create secret generic sops-age \
        --from-file=age.agekey=${sopsAgeKeyFile} \
        --dry-run=client -o yaml | kubectl apply -f -
    '';
  };

  # ── CNI ───────────────────────────────────────────────────────────────────
  # Installed at bootstrap rather than through Flux: Flux runs as pods, and
  # pods have no network until a CNI is present.
  systemd.services.cilium-bootstrap = {
    description = "Install the Cilium CNI";
    documentation = [ "https://docs.cilium.io/" ];

    wantedBy = [ "multi-user.target" ];
    after = [ "k8s-post-init.service" ];
    requires = [ "k8s-post-init.service" ];

    unitConfig = {
      ConditionPathExists = adminConf;
      # Bounds the Restart set below, so a genuine misconfiguration stops
      # instead of retrying for the life of the machine.
      StartLimitBurst = 3;
    };

    path = clusterPath ++ [ pkgs.cilium-cli ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30min";

      # cilium-cli embeds Helm, and Helm wants somewhere to put its cache and
      # repository config. A systemd service has no HOME, and without one the
      # CLI exits before it reaches the network at all.
      StateDirectory = "cilium-cli";
      Environment = [
        "KUBECONFIG=${adminConf}"
        "HOME=/var/lib/cilium-cli"
      ];

      # The install pulls a Helm chart and container images over a home
      # connection. A dropped request should retry rather than leave the node
      # NotReady until someone notices.
      Restart = "on-failure";
      RestartSec = "60s";
    };

    # Guarded on the DaemonSet rather than a stamp file, so a wiped cluster
    # reinstalls and a surviving one is left alone. Changes to the settings
    # below do NOT reinstall -- this only bootstraps; from here Cilium is
    # upgraded through Helm or Flux.
    script = ''
      if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
        echo "cilium already installed, leaving it alone"
        exit 0
      fi

      cilium install \
        --version ${ciliumVersion} \
        --set ipam.mode=kubernetes \
        --set k8sServiceHost=${controlPlaneEndpoint} \
        --set k8sServicePort=6443 \
        --set operator.replicas=1 \
        --set bgpControlPlane.enabled=true \
        --wait --wait-duration 20m
    '';
  };

  # ── kubectl shortcuts ───────────────────────────────────────────────────────
  # Control plane only. kubbr's abbreviations are all kubectl, and a worker has
  # no kubeconfig for the admin to use -- kgp there would only ever print a
  # connection error.
  #
  # kubbr/kube.bash is generated output from github:mincomk/kubbr at rev
  # 7e3b7bc, carried verbatim under its own BSD-3-Clause terms; see
  # kubbr/LICENSE. Regenerating it from a changed abbr.yml needs GHC, using it
  # does not, so only the output is here.
  programs.bash.interactiveShellInit = ''
    source ${../kubbr/kube.bash}
  '';
}
