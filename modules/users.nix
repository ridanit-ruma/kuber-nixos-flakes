# Who can log in, with what, and how this machine reaches the others.
{
  pkgs,
  lib,
  cluster,
  ...
}:
{
  # NetworkManager is disabled in modules/network.nix, so its group no longer
  # exists and must not be referenced here.
  users.users."nixos" = {
    isNormalUser = true;
    description = "nixos";
    extraGroups = [ "wheel" ];
    packages = with pkgs; [ ];
    # From a file rather than a list: adding somebody is one line in a plain
    # authorized_keys file instead of an edit to a Nix expression.
    openssh.authorizedKeys.keyFiles = [ ../keys/admins.pub ];
  };

  # nixdeploy pushes a closure to root@<host>, and nixos-rebuild --target-host
  # has to get in without a prompt for that to be unattended. Key-only:
  # PermitRootLogin stays at its prohibit-password default.
  users.users.root.openssh.authorizedKeys.keyFiles = [ ../keys/admins.pub ];

  services.openssh = {
    enable = true;
    ports = [ cluster.sshPort ];
    settings = {
      PasswordAuthentication = false;
    };
    # AuthorizedKeysFile is left at the NixOS default on purpose. It used to be
    # narrowed to ~/.ssh/authorized_keys here, which looked harmless and was
    # not: sshd takes the first value it is given for an option, so that line
    # won and /etc/ssh/authorized_keys.d was never read -- which is exactly
    # where NixOS writes declaratively-set keys. Every new node therefore had
    # to have ssh-copy-id run against it by hand.
  };

  # Reaching the other machines by name, from any of them. Generated from
  # hosts/cluster.nix, so a node added there is reachable from everywhere
  # without a second edit -- which is the failure this replaced.
  #
  # The LAN address rather than the fabric: the LAN carries the default route
  # and is up whenever the machine is, while an unplugged fabric cable would
  # take the management path down with it.
  #
  # accept-new rather than the default -- a first connection to a machine that
  # was just rebuilt should not stop to ask, while a key that *changes* still
  # should, which is the case worth interrupting for.
  programs.ssh.extraConfig = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: node: ''
      Host ${name}
        HostName ${node.lan}
        Port ${toString cluster.sshPort}
        StrictHostKeyChecking accept-new
    '') cluster.nodes
  );
}
