# The wrappers that get typed by hand. Kept apart from the package list in
# modules/base.nix because these are the repository's own commands rather than
# things installed from nixpkgs, and because they read hosts/cluster.nix -- the
# interface and the ssh port are not written out again here.
{
  pkgs,
  configDir,
  cluster,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    # Manages the Cloudflare Tunnel connectors in the GitOps repo -- register a
    # token, drop one, see whether they are actually connected. Kept as its own
    # file rather than inlined here; it is long enough that a heredoc would
    # bury it.
    (writeShellScriptBin "cf-tunnel" (builtins.readFile ../scripts/cf-tunnel.sh))

    # Clears a disk so Rook can claim it as an OSD. Guarded: by-id paths only,
    # refuses the system disk and anything mounted, asks for ERASE. Deployed
    # everywhere because it is exactly the new, not-yet-trusted machine that
    # needs it -- install.sh calls it after collecting the confirmation up
    # front, and by hand it is the safe way to retry a failed disk.
    (writeShellScriptBin "wipe-osd" (builtins.readFile ../scripts/wipe-osd.sh))

    # Builds a host's configuration here and pushes the result to it. The
    # worker never needs the repo, a checkout to keep in sync, or the CPU to
    # build with -- which matters when the control plane is the bigger machine.
    #
    # `boot` rather than `switch` by default: these configurations set static
    # addresses, and applying that to a running remote machine over the network
    # it is changing is a good way to lose it. Reboot after, or pass --switch
    # when the change cannot touch the network.
    (writeShellScriptBin "nixdeploy" ''
      set -euo pipefail
      host="''${1:-}"
      [ -n "$host" ] || { echo "usage: nixdeploy <host> [user@address] [--switch]" >&2; exit 1; }
      dir="''${NIXOS_CONFIG_DIR:-${configDir}}"
      [ -e "$dir/flake.nix" ] || { echo "nixdeploy: no configuration at $dir" >&2; exit 1; }

      # The address the flake gives that host, so there is one place it is
      # written down. Override by passing a target explicitly.
      target="''${2:-}"
      if [ -z "$target" ]; then
        addr=$(${pkgs.nix}/bin/nix eval --raw \
          "$dir#nixosConfigurations.$host.config.networking.interfaces.${cluster.lan.interface}.ipv4.addresses" \
          --apply "a: (builtins.head a).address" 2>/dev/null) \
          || { echo "nixdeploy: cannot read an address for $host from the flake -- pass one" >&2; exit 1; }
        target="root@$addr"
      fi

      action=boot
      case "''${3:-}" in --switch) action=switch ;; esac

      echo "nixdeploy: $host -> $target ($action)"
      export NIX_SSHOPTS="''${NIX_SSHOPTS:--p ${toString cluster.sshPort}}"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild "$action" \
        --flake "$dir#$host" --target-host "$target"
      [ "$action" = boot ] && echo "nixdeploy: staged. reboot $host to apply." || true
    '')

    # Rebuilds the machine you are sitting on. Workers do not have the repo --
    # they are deployed from the control plane -- so this says so rather than
    # letting nix report a missing flake.
    (writeShellScriptBin "nixbuild" ''
      set -euo pipefail
      dir="''${NIXOS_CONFIG_DIR:-${configDir}}"

      if [ ! -e "$dir/flake.nix" ]; then
        echo "nixbuild: no configuration at $dir" >&2
        echo "" >&2
        echo "This machine is deployed from the control plane, not from here." >&2
        echo "On the control plane, run:  nixdeploy $(${pkgs.nettools}/bin/hostname)" >&2
        exit 1
      fi

      # A flake in a git repo only sees tracked files, so a new but unstaged
      # module reads back as "file not found". Stage first.
      if [ -d "$dir/.git" ]; then
        ${git}/bin/git -C "$dir" add -A \
          || echo "nixbuild: could not stage $dir, continuing" >&2
      fi

      # The host is taken from the hostname, not written in: with more than one
      # machine sharing this module, a fixed name means running nixbuild on one
      # of them quietly builds another one's configuration.
      exec sudo nixos-rebuild switch --flake "$dir#$(${pkgs.nettools}/bin/hostname)" "$@"
    '')
  ];
}
