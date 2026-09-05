{
  stdenvNoCC,
  fetchurl,
  gnutar,
  makeWrapper,
  zstd,
}:

stdenvNoCC.mkDerivation rec {
  pname = "kata-static";
  version = "4.1.0";

  src = fetchurl {
    url = "https://github.com/kata-containers/kata-containers/releases/download/${version}/kata-static-${version}-amd64.tar.zst";
    hash = "sha256-Pca2nErLeHuWewS2RZmiDQKovrGo6qswhBEN+dCwjJY=";
  };

  nativeBuildInputs = [
    gnutar
    makeWrapper
    zstd
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    tar --use-compress-program=unzstd \
      --extract \
      --file="$src" \
      --directory="$out"

    upstreamConfig="$out/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml"
    hardenedConfig="$out/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-ssh-gpt.toml"

    test -x "$out/opt/kata/runtime-rs/bin/containerd-shim-kata-v2"
    test -x "$out/opt/kata/bin/qemu-system-x86_64"
    test -x "$out/opt/kata/libexec/virtiofsd"
    test -f "$out/opt/kata/share/kata-containers/vmlinux.container"
    test -f "$out/opt/kata/share/kata-containers/kata-containers.img"
    test -d "$out/opt/kata/share/kata-qemu/qemu"

    if find "$out/opt/kata" -type l -lname '/opt/kata*' -print -quit | grep -q .; then
      echo "absolute /opt/kata symlink remains in Kata distribution" >&2
      exit 1
    fi

    wrapProgram "$out/opt/kata/bin/qemu-system-x86_64" \
      --add-flags "-L $out/opt/kata/share/kata-qemu/qemu"

    cp "$upstreamConfig" "$hardenedConfig"
    substituteInPlace "$hardenedConfig" \
      --replace-fail "/opt/kata" "$out/opt/kata" \
      --replace-fail 'enable_annotations = ["enable_iommu", "kernel_params", "kernel_verity_params", "default_vcpus", "default_memory"]' 'enable_annotations = []' \
      --replace-fail 'seccomp_sandbox = ""' 'seccomp_sandbox = "on,obsolete=deny,spawn=deny,resourcecontrol=deny"' \
      --replace-fail 'default_maxvcpus = 0' 'default_maxvcpus = 2' \
      --replace-fail 'default_maxmemory = 0' 'default_maxmemory = 4096' \
      --replace-fail 'disable_block_device_use = false' 'disable_block_device_use = true' \
      --replace-fail 'disable_vhost_net = false' 'disable_vhost_net = true' \
      --replace-fail 'disable_guest_seccomp = true' 'disable_guest_seccomp = false'

    grep -Fq 'enable_annotations = []' "$hardenedConfig"
    grep -Fq 'rootless = false' "$hardenedConfig"
    grep -Fq 'disable_guest_seccomp = false' "$hardenedConfig"
    if grep -Fq '"/opt/kata' "$hardenedConfig"; then
      echo "unpatched /opt/kata path remains in hardened Kata configuration" >&2
      exit 1
    fi

    runHook postInstall
  '';

  meta = {
    description = "Kata Containers runtime-rs static distribution";
    homepage = "https://katacontainers.io/";
    platforms = [ "x86_64-linux" ];
  };
}
