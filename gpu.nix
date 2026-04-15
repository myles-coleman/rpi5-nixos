# GPU configuration for Raspberry Pi 5 with AMD RX 6700 XT (Navi 22, RDNA 2)
#
# This module configures:
#   - Custom kernel with the TTM cache coherency patch for ARM64 eGPU support
#   - AMD GPU kernel modules and firmware
#   - Vulkan (RADV) and OpenGL (radeonsi) via Mesa
#   - PCIe Gen 3 for maximum bandwidth to the eGPU
#   - VAAPI for hardware video transcoding
#   - Userspace tools for GPU compute (llama.cpp with Vulkan)
#
# Hardware:
#   - Raspberry Pi 5 8GB
#   - AMD RX 6700 XT via M.2 to OCuLink adapter + eGPU dock
#   - External ATX PSU for the GPU
#
# References:
#   - https://www.jeffgeerling.com/blog/2025/full-egpu-acceleration-on-pi-500-15-line-patch
#   - https://www.jeffgeerling.com/blog/2024/llms-accelerated-egpu-on-raspberry-pi-5/
#   - https://www.jeffgeerling.com/blog/2025/using-amd-gpus-on-raspberry-pi-without-recompiling-linux
#   - https://github.com/raspberrypi/linux/pull/7113
#   - https://wiki.nixos.org/wiki/AMD_GPU

{ config, pkgs, lib, ... }:

{
  # --- Kernel configuration ---
  # The GPU kernel (geerlingguy's rpi-6.17.y-gpu branch) already includes:
  # - TTM cache coherency patch for ARM64
  # - AMD GPU driver support
  # - All necessary PCIe fixes for eGPU support
  # The kernel override is in flake.nix (gpuBaseConfig).

  # DRM_AMDGPU and HSA_AMD are configured in flake.nix (gpuBaseConfig kernel build).

  # Load amdgpu module
  boot.kernelModules = [ "amdgpu" ];

  # Kernel parameters for AMD GPU on ARM64 PCIe
  # - pci=realloc: Reallocate PCI resources to fix "resources unassigned" errors
  # - initcall_blacklist=simpledrm_platform_driver_init: Prevent simpledrm from
  #   probing. It crashes with a level 1 translation fault on BCM2712 with 4K
  #   pages due to firmware framebuffer memory being mapped with 16K alignment.
  #   Node4 uses the AMD eGPU (amdgpu) for display, not the firmware FB.
  boot.kernelParams = [
    "pci=realloc"
    "initcall_blacklist=simpledrm_platform_driver_init"
  ];

  # --- PCIe configuration ---
  # Enable PCIe Gen 3 for maximum bandwidth to the eGPU (8 GT/s on single lane)
  # Reference: https://www.jeffgeerling.com/blog/2025/using-amd-gpus-on-raspberry-pi-without-recompiling-linux
  hardware.raspberry-pi.config = {
    all = {
      base-dt-params = {
        pciex1_gen = {
          enable = true;
          value = 3;
        };
      };
      # Disable vc4-kms-v3d overlay — the custom GPU kernel (buildLinux +
      # bcm2712_defconfig) does not build RPi-specific DT overlays from
      # arch/arm/boot/dts/overlays/. The RPi5 EEPROM firmware will fail at
      # boot if config.txt references an overlay file that doesn't exist on
      # the firmware partition. Node4 uses the AMD eGPU, not the VC4 GPU.
      dt-overlays = {
        vc4-kms-v3d = {
          enable = false;
        };
      };
    };
  };

  # --- GPU firmware and drivers ---
  # AMD GPU firmware is included via hardware.enableRedistributableFirmware
  # (already set in the shared base config), which pulls in linux-firmware
  # including all amdgpu firmware blobs for Navi 22 (RX 6700 XT)

  # Enable OpenGL/Vulkan hardware acceleration
  # Mesa provides the RADV Vulkan driver and radeonsi OpenGL driver by default
  # Reference: https://wiki.nixos.org/wiki/AMD_GPU
  hardware.graphics.enable = true;

  # --- Userspace packages ---
  environment.systemPackages = with pkgs; [
    # Vulkan SDK and tools
    vulkan-tools       # vulkaninfo
    vulkan-loader
    vulkan-headers
    vulkan-validation-layers
    glslang            # GLSL to SPIR-V compiler (needed for llama.cpp Vulkan build)

    # GPU monitoring
    nvtopPackages.amd  # GPU process monitor for AMD

    # Mesa utilities
    mesa-demos         # glxinfo, glxgears, etc.

    # VAAPI tools for hardware video transcoding verification
    libva-utils        # vainfo

    # Build tools for compiling GPU-accelerated software (e.g. llama.cpp)
    cmake
    gcc
    gnumake
    pkg-config
    curl
  ];
}
