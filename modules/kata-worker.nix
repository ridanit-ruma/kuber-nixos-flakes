# One-node Kata canary for SSH_GPT. Keep the default runc runtime unchanged;
# only pods selecting the matching RuntimeClass are sent to this handler.
{ pkgs, ... }:
let
  kataStatic = pkgs.callPackage ../packages/kata-static.nix { };
  kataConfig = "${kataStatic}/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-ssh-gpt.toml";
in
{
  boot.kernelModules = [
    "vhost_vsock"
  ];

  virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".containerd.runtimes."kata-qemu-runtime-rs" = {
    runtime_type = "io.containerd.kata-qemu-runtime-rs.v2";
    runtime_path = "${kataStatic}/opt/kata/runtime-rs/bin/containerd-shim-kata-v2";
    privileged_without_host_devices = true;
    container_annotations = [ "io.kubernetes.container.terminationMessage*" ];
    options.ConfigPath = kataConfig;
  };
}
