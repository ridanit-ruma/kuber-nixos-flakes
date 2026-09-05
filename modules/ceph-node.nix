# What a machine needs to be usable by Rook Ceph.
#
# On every node, not only the ones currently holding an OSD: a pod that mounts
# an RBD volume can be scheduled anywhere, and a node missing these fails the
# mount with an error that points at the volume rather than at the node.
{ pkgs, ... }:
{
  # rbd maps a block image to /dev/rbdN; ceph is the kernel client for CephFS.
  # The CSI plugin does not load either on demand -- it expects them present
  # and reports a mount failure when they are not.
  boot.kernelModules = [
    "rbd"
    "ceph"
  ];

  # The CSI plugin runs in a container but does its work in the host's mount
  # namespace, so these are the host binaries it reaches for: lvm2 for the
  # volume group an OSD sits on, and the mkfs and fsck for whatever filesystem
  # a PersistentVolumeClaim asks for.
  environment.systemPackages = with pkgs; [
    lvm2
    util-linux
    e2fsprogs
    xfsprogs
  ];

  # dataDirHostPath -- left at the chart default, which is this. The operator
  # keeps each daemon's keyring and the monitor's store here, and it has to
  # outlive the pod, which is the whole reason it is a host path.
  systemd.tmpfiles.rules = [ "d /var/lib/rook 0755 root root -" ];
}
