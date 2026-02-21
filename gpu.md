
## GPU Node Usage

After deploying the GPU node, verify the AMD GPU is detected:

```bash
ssh pi@node4.local

# Check GPU is recognized
lspci | grep -i amd

# Check kernel driver loaded
dmesg | grep amdgpu

# Verify Vulkan acceleration
vulkaninfo --summary

# Monitor GPU usage
nvtop
```

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

# Or start the web UI
./build/bin/llama-server \
  -m models/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
  --jinja -c 0 --host 0.0.0.0 --port 8033 -ngl 100
```

### Hardware Video Transcoding

```bash
# Verify VAAPI support
vainfo
```

---

Goal: Add node4 (Raspberry Pi 5 + AMD RX 6700 XT eGPU) to my NixOS K3s cluster flake. Node4 is a K3s agent that boots from SD card (no NVMe SSD) with full AMD GPU acceleration.

What's been done:

gpu.nix — Created. Configures: TTM cache coherency kernel patch (structuredExtraConfig), amdgpu kernel module, PCIe Gen 3 via base-dt-params, hardware.graphics.enable, Vulkan/VAAPI tools, nvtopPackages.amd, build tools for llama.cpp.
patches/ttm-arm64-gpu-cache-coherency.patch — Created. The 15-line TTM DMA coherency fix from raspberrypi/linux#7113.
flake.nix — Refactored:
sharedConfig = common modules (no disko, no bluetooth)
baseConfig = sharedConfig + page-size-16k + disko (for NVMe nodes 0–3)
gpuBaseConfig = sharedConfig + nixos-raspberrypi.nixosModules.sd-image + gpu.nix (no page-size-16k, no disko)
node4 added as K3s agent at 10.0.0.144
packages.node4 outputs system.build.sdImage
README.md — Updated with node4 SD card flash instructions.
.github/workflows/update.yaml — Updated to include node4 in the matrix (IP 10.0.0.144, standard K3s health check).
gpu.md — Created with GPU verification and llama.cpp usage instructions.
Where we're stuck:

Building nix build .#node4 on an x86_64 machine fails because the target is aarch64-linux:

error: a 'aarch64-linux' with features {} is required to build '...mounts.sh.drv', but I am a 'x86_64-linux'
Need to either:

Enable QEMU binfmt emulation on the x86 build machine (boot.binfmt.emulatedSystems = ["aarch64-linux"]; if NixOS, or qemu-user-static + binfmt-support otherwise)
Build natively on an existing Pi node
Configure a Pi as a Nix remote builder
Repo: rpi5-nixos