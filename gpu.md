# GPU Node (node4): Raspberry Pi 5 + AMD RX 6700 XT eGPU

## Overview

Node4 is a Raspberry Pi 5 (8GB) with an AMD Radeon RX 6700 XT (Navi 22, RDNA 2) connected as an external GPU. It runs NixOS, boots from an SD card, and operates as a K3s agent in the cluster. The GPU provides Vulkan compute (e.g. llama.cpp inference) and VAAPI hardware video transcoding.

## Hardware

| Component | Details |
|-----------|---------|
| SBC | Raspberry Pi 5 8GB |
| GPU | AMD Radeon RX 6700 XT (12 GB VRAM, 40 CUs, Navi 22) |
| Connection | M.2 to OCuLink adapter + eGPU dock |
| GPU Power | External ATX PSU |
| Boot Device | SD card (no NVMe SSD) |
| Network | Ethernet at `10.0.0.144` |

## Architecture

The configuration is split across several files:

| File | Purpose |
|------|---------|
| `flake.nix` | Defines `gpuBaseConfig` with the custom kernel override and node4's `nixosConfiguration` |
| `gpu.nix` | GPU-specific NixOS config: kernel params, PCIe Gen 3, amdgpu module, Vulkan/VAAPI tools |
| `k3s-agent.nix` | K3s agent configuration (joins cluster at `10.0.0.200:6443`) |
| `k3s-token-secrets.nix` | Ensures `/etc/rancher/k3s/` directory exists for runtime token injection |
| `k3s-common.nix` | Shared K3s config, including `ConditionPathExists` so K3s waits for the token file |

Node4 uses `gpuBaseConfig` which differs from the other nodes' `baseConfig`:

- **No `page-size-16k`** -- 4K pages are required for amdgpu TTM/DRM compatibility
- **No `disko`** -- boots from SD card, not NVMe
- **Includes `sd-image` module** -- for building flashable SD card images
- **Custom 6.17 kernel** -- with GPU patches (see below)

## Custom Kernel

### Why a custom kernel is needed

The default `nixos-raspberrypi` kernel (6.12.x) has an amdgpu VRAM mapping bug on ARM64 that prevents the driver from reading the GPU's IP discovery table. This causes `amdgpu_discovery_init failed` with error -22, and VRAM is completely inaccessible (`dd` on `resource0` returns I/O error). The TTM cache coherency patch alone is insufficient -- a newer kernel base (6.17+) with the amdgpu ARM64 fixes is required.

### Kernel source

The kernel uses [geerlingguy's `rpi-6.17.y-gpu` branch][geerlingguy-gpu-pr], which is based on the Raspberry Pi 6.17 kernel with two additional commits:

1. TTM cache coherency patch for ARM64 (from [raspberrypi/linux#7113][rpi-gpu-pr])
2. Intel Xe fix

### Kernel configuration

The kernel is built with `buildLinux` + `bcm2712_defconfig` and the following overrides:

| Config | Value | Reason |
|--------|-------|--------|
| `ARM64_4K_PAGES` | `yes` | Required for amdgpu TTM/DRM. BCM2712 defaults to 16K pages which are [incompatible with GPU workloads][4k-pages-issue]. |
| `ARM64_16K_PAGES` | `no` | Mutually exclusive with 4K pages |
| `DRM_AMDGPU` | `module` | AMD GPU driver |
| `HSA_AMD` | `yes` | HSA (Heterogeneous System Architecture) support for GPU compute |
| `DRM_SIMPLEDRM` | `no` (forced) | Crashes with a level 1 translation fault on BCM2712 + 4K pages when mapping the firmware framebuffer (16K-aligned). See [meta-raspberrypi#1394][simpledrm-crash]. |
| `FB_SIMPLE` | `no` (forced) | Related to simpledrm; disabled for the same reason |
| `SYSFB_SIMPLEFB` | `no` (forced) | Related to simpledrm; disabled for the same reason |
| `BCACHEFS_FS` | `no` | Fails to link with nixpkgs binutils on 6.17 (not needed; node4 uses ext4) |
| `GPIO_PWM` | `no` | Has a void/int return type mismatch build error in 6.17 |

The `DRM_SIMPLEDRM`, `FB_SIMPLE`, and `SYSFB_SIMPLEFB` options are enforced via both `structuredExtraConfig` (`lib.mkForce`) and `postConfigure` sed overrides, because kconfig dependency resolution can re-enable them during `make oldconfig`.

## Boot Requirements

Several issues were resolved to get the SD card image booting on the RPi5:

### 1. Device tree overlays (`bcm2712d0.dtbo`)

The RPi5 (D0 silicon revision) requires the `bcm2712d0.dtbo` overlay to be present on the firmware partition. Without it, the kernel accesses incorrect MMIO register offsets for the BCM2712 pin controller, causing an `Asynchronous SError Interrupt` kernel panic during `brcmuart_init`. See [meta-raspberrypi#1394][simpledrm-crash] for the identical crash and fix.

The overlay is built automatically by `make dtbs` because the RPi 6.17 kernel's `arch/arm64/boot/dts/Makefile` includes `subdir-y += overlays`. The `nixos-raspberrypi` sd-image bootloader module copies them to the firmware partition.

### 2. VC4 overlay disabled

The `vc4-kms-v3d` overlay (used for the RPi's built-in VC4 GPU) is disabled in `gpu.nix` via:

```nix
dt-overlays.vc4-kms-v3d.enable = false;
```

This prevents the firmware from trying to load an overlay file that, while present in the overlays directory, is not needed on node4 (which uses the AMD eGPU for display).

### 3. No HDMI output from RPi

With `vc4-kms-v3d` disabled and `simpledrm` removed, the RPi's HDMI port produces no output. This is expected for a headless K3s node. If a display is connected to the AMD GPU's HDMI/DP outputs, the `amdgpu` driver handles display. The UART serial console (`enable_uart=1` in config.txt) can be used for debugging.

## PCIe Link Speed

The RPi5's PCIe controller supports Gen 2 natively and can be overclocked to Gen 3 via `dtparam=pciex1_gen=3` (set in `gpu.nix`). The link is a single lane (x1).

| | Gen 2 x1 | Gen 3 x1 |
|---|---|---|
| Speed | 5 GT/s | 8 GT/s |
| Bandwidth | ~500 MB/s | ~985 MB/s |

The firmware correctly configures the target link speed to Gen 3 (`LnkCtl2: Target Link Speed: 8GT/s`), but the actual negotiated speed depends on signal integrity through the adapter chain (M.2 connector, OCuLink cable, eGPU dock). The link may fall back to Gen 2 if the signal path is too long or the adapter lacks a retimer. This is a [known hardware limitation][geerlingguy-amd-blog] and is not a software issue.

Check the current link speed:

```bash
# Root port (RPi5 PCIe controller) — shows actual negotiated speed
sudo lspci -vvs 0001:00:00.0 | grep LnkSta

# GPU endpoint — shows the GPU's own capabilities (not the RPi link)
sudo lspci -vvs 0001:03:00.0 | grep LnkSta
```

## Verification

```bash
# Check GPU initialization
sudo dmesg | grep amdgpu

# Check PCI device
lspci | grep -i amd

# Check PCIe link speed (root port)
sudo lspci -vvs 0001:00:00.0 | grep LnkSta

# Check Vulkan
vulkaninfo --summary

# Check VAAPI
vainfo

# GPU monitor (utilization, VRAM, temp, fan, power)
nvtop

# K3s status
sudo systemctl status k3s-agent
kubectl get nodes  # from control plane
```

### Expected dmesg output

```
amdgpu 0001:03:00.0: amdgpu: Fetched VBIOS from ROM BAR
amdgpu: ATOM BIOS: 113-67HA6SSD1-D01
amdgpu 0001:03:00.0: amdgpu: VRAM: 12272M (12272M used)
amdgpu 0001:03:00.0: amdgpu: GART: 512M
amdgpu 0001:03:00.0: amdgpu: SE 2, SH per SE 2, CU per SH 10, active_cu_number 40
[drm] Initialized amdgpu 3.64.0 for 0001:03:00.0 on minor 0
```

## Usage

### Running LLMs with llama.cpp (Vulkan)

```bash
# Clone and build llama.cpp with Vulkan support
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build -DGGML_VULKAN=1
cmake --build build --config Release -j $(nproc)

# Download a model
mkdir -p models && cd models
wget https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf
cd ..

# Run inference (offload all layers to GPU)
./build/bin/llama-cli \
  -m models/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
  -p "Why is the sky blue?" \
  -no-cnv -e -ngl 100 -t 4

# Or start the web server
./build/bin/llama-server \
  -m models/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
  --jinja -c 0 --host 0.0.0.0 --port 8033 -ngl 100
```

### Hardware Video Transcoding

```bash
# Verify VAAPI support
vainfo
```

## Known Issues and Limitations

| Issue | Details |
|-------|---------|
| PCIe Gen 2 fallback | The link may negotiate Gen 2 (5 GT/s) instead of Gen 3 (8 GT/s) depending on adapter/cable quality. This is a hardware signal integrity limitation, not a software bug. |
| No RPi HDMI output | The RPi's HDMI port is non-functional (VC4 disabled, simpledrm disabled). Use the AMD GPU's display outputs or SSH. |
| Large BAR warning | `amdgpu: Not enough PCI address space for a large BAR` is expected. The RPi5's PCIe address space is limited. The driver falls back to a smaller BAR mapping and functions correctly. |
| `Cannot find any crtc or sizes` | Logged by amdgpu when no display is connected to the GPU. Harmless for headless operation. |
| SMU driver version mismatch | `SMU driver if version not matched` is a warning, not an error. SMU initializes successfully regardless. |
| 4K page size trade-offs | Using 4K pages instead of 16K pages may have minor performance implications for non-GPU workloads. See [raspberrypi/linux#6605][4k-pages-sideeffects]. |

## References

- [geerlingguy/linux#10 -- GPU kernel branch (rpi-6.17.y-gpu)][geerlingguy-gpu-pr]
- [raspberrypi/linux#7113 -- 6by9's GPU testing PR with TTM patch][rpi-gpu-pr]
- [geerlingguy/raspberry-pi-pcie-devices#222 -- 4K pages + amdgpu compatibility][4k-pages-issue]
- [raspberrypi/linux#6605 -- 4K page size side effects on BCM2712][4k-pages-sideeffects]
- [agherzan/meta-raspberrypi#1394 -- bcm2712d0.dtbo fix for SError crash][simpledrm-crash]
- [Jeff Geerling -- Full eGPU acceleration on Pi 500 (15-line patch)][geerlingguy-egpu-blog]
- [Jeff Geerling -- LLMs accelerated by eGPU on Raspberry Pi 5][geerlingguy-llm-blog]
- [Jeff Geerling -- Using AMD GPUs on Raspberry Pi without recompiling Linux][geerlingguy-amd-blog]
- [NixOS Wiki -- AMD GPU][nixos-amd-gpu]
- [nvmd/nixos-raspberrypi -- NixOS flake for Raspberry Pi][nixos-raspberrypi]

[geerlingguy-gpu-pr]: https://github.com/geerlingguy/linux/pull/10
[rpi-gpu-pr]: https://github.com/raspberrypi/linux/pull/7113
[4k-pages-issue]: https://github.com/geerlingguy/raspberry-pi-pcie-devices/issues/222
[4k-pages-sideeffects]: https://github.com/raspberrypi/linux/issues/6605
[simpledrm-crash]: https://github.com/agherzan/meta-raspberrypi/issues/1394
[geerlingguy-egpu-blog]: https://www.jeffgeerling.com/blog/2025/full-egpu-acceleration-on-pi-500-15-line-patch
[geerlingguy-llm-blog]: https://www.jeffgeerling.com/blog/2024/llms-accelerated-egpu-on-raspberry-pi-5/
[geerlingguy-amd-blog]: https://www.jeffgeerling.com/blog/2025/using-amd-gpus-on-raspberry-pi-without-recompiling-linux
[nixos-amd-gpu]: https://wiki.nixos.org/wiki/AMD_GPU
[nixos-raspberrypi]: https://github.com/nvmd/nixos-raspberrypi
[cachix-cache]: https://app.cachix.org/cache/rpi5-k3s
