# Boot, nix itself, locale, and the packages every machine carries.
#
# What is deliberately not here: addresses and the firewall (modules/
# network.nix), accounts and ssh (modules/users.nix), and this repository's own
# commands (modules/tools.nix).
{
  pkgs,
  inputs,
  ...
}:
{
  # ── Boot ────────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # No swap: kubelet refuses to start with swap enabled unless it is explicitly
  # configured for it. Leave it off.

  # ── Nix ─────────────────────────────────────────────────────────────────────
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  # Channels stop being updated once the system is built from this flake. Point
  # `<nixpkgs>` and `nix shell nixpkgs#...` at the same pin so they cannot
  # drift from the running system.
  nix.registry.nixpkgs.flake = inputs.nixpkgs;
  nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

  # ── Locale ──────────────────────────────────────────────────────────────────
  time.timeZone = "Asia/Seoul";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ko_KR.UTF-8";
    LC_IDENTIFICATION = "ko_KR.UTF-8";
    LC_MEASUREMENT = "ko_KR.UTF-8";
    LC_MONETARY = "ko_KR.UTF-8";
    LC_NAME = "ko_KR.UTF-8";
    LC_NUMERIC = "ko_KR.UTF-8";
    LC_PAPER = "ko_KR.UTF-8";
    LC_TELEPHONE = "ko_KR.UTF-8";
    LC_TIME = "ko_KR.UTF-8";
  };

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # ── Runtime for prebuilt binaries ───────────────────────────────────────────
  # mason.nvim downloads prebuilt language servers linked against
  # /lib64/ld-linux-x86-64.so.2, which does not exist here. nix-ld supplies a
  # loader so they run without patching the nvim config.
  programs.nix-ld.enable = true;

  # ── Packages ────────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Requested tools
    neovim
    btop
    curl
    wget
    git
    gh

    vim

    # Disk work for the Rook OSD device
    gptfdisk

    # Sends the magic packet: `wol <mac>` from a machine on the same segment.
    wol

    # Cluster tooling. kubectl, kubeadm and kubelet come from the kubernetes
    # package in modules/k8s-node.nix.
    kubernetes-helm
    fluxcd
    cilium-cli

    # Secrets for GitOps. The Cloudflare token cert-manager needs for DNS-01 is
    # encrypted with age and committed to the infra repo; Flux decrypts it
    # in-cluster, so the plaintext never reaches git.
    sops
    age
    jq

    # nvim: lazy.nvim build steps. nvim-treesitter is on the `main` branch,
    # which shells out to the tree-sitter CLI, and telescope-fzf-native runs
    # `make`.
    gcc
    gnumake
    tree-sitter
    unzip

    # nvim: plugins that shell out
    ripgrep
    fd
    fzf
    lazygit

    # nvim: luarocks-backed plugins
    lua5_1
    luarocks

    # nvim: language runtimes. init.lua pins vim.g.python3_host_prog to the
    # literal name "python3.13".
    nodejs
    python313

    # nvim: LSP and formatters that are not left to mason
    clang-tools
    direnv
    stylua
    black
    isort

    # Deliberately not installed: rustup, ghc + haskell-language-server, julia,
    # deno. The config enables the hls and julials clients unconditionally, so
    # those two log a start failure when their language is opened, and
    # saghen/blink.nvim shows a failed `cargo build` in :Lazy. Everything else
    # works. Add rustup first if that build error is worth clearing.
  ];

  environment.variables.EDITOR = "nvim";

  # ── State ───────────────────────────────────────────────────────────────────
  system.stateVersion = "26.05";
}
