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
  # Apply the 15-line TTM cache coherency patch for ARM64 eGPU support.
  # This patch fixes DMA cache coherency in the TTM memory manager, enabling
  # AMD (and Intel) GPUs to work correctly on ARM64 platforms like the Pi 5.
  # Source: https://github.com/geerlingguy/raspberry-pi-pcie-devices/discussions/756
  boot.kernelPatches = [
    {
      name = "ttm-arm64-gpu-cache-coherency";
      patch = ./patches/ttm-arm64-gpu-cache-coherency.patch;
      # Enable the amdgpu kernel driver and DRM subsystem
      extraStructuredConfig = with lib.kernel; {
        DRM = module;
        DRM_AMDGPU = module;
        HSA_AMD = yes;
      };
    }
  ];

  # Load amdgpu module early in boot
  boot.initrd.kernelModules = [ "amdgpu" ];

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
    nvtop              # GPU process monitor (supports AMD)

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
