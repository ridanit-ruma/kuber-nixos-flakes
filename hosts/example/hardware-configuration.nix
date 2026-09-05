# A placeholder, and the one file in this repository that cannot be shared.
#
# `nixos-generate-config` writes this on the machine itself, from the disks and
# controllers it actually finds: filesystem UUIDs, the modules needed to see the
# root device before the system is up, the CPU's microcode. None of it is
# portable, and a machine booted with somebody else's copy does not come back.
#
# Replace this file with the one from your own machine:
#
#     nixos-generate-config --show-hardware-config > hosts/<name>/hardware-configuration.nix
#
# install.sh does exactly that as its first step.
{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
}
