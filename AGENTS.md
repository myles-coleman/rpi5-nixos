# AGENTS.md — rpi5-nixos

This file provides guidance to AI coding agents working in this repository.

## Purpose

NixOS configurations for a 5-node k3s Kubernetes cluster running on Raspberry Pi 5 hardware. The cluster manifests live in a separate repo (homelab-cluster).

## Domain Glossary

- **node0** — K3s server (control plane), 10.0.0.140, NVMe SSD
- **node1-node3** — K3s agents (workers), 10.0.0.141-143, NVMe SSD
- **node4** — K3s agent (GPU worker), 10.0.0.144, SD card, AMD RX 6700 XT eGPU via PCIe
- **nixos-raspberrypi** — Flake input providing RPi 5 NVMe and GPU support
- **disko** — Declarative disk partitioning (NVMe nodes only)
- **kube-vip** — Virtual IP for k3s API server (10.0.0.200)

## Commands

- **Build installer SD image**: `nix build github:nvmd/nixos-raspberrypi#installerImages.rpi5`
- **Deploy new node**: `nixos-anywhere --flake .#nodeN root@nixos-installer.local`
- **Update existing node**: `nixos-rebuild switch --flake .#nodeN --target-host pi@nodeN.local --use-remote-sudo`
- **Format code**: `alejandra .` (never use nixfmt)

## Architecture

- `flake.nix` — All 5 node definitions, shared config, flake inputs (nixpkgs-unstable, nixos-raspberrypi, disko, rpi-linux-gpu)
- `k3s-server.nix` — Control plane config (node0 only)
- `k3s-agent.nix` — Worker node config (node1-4)
- `k3s-common.nix` — Shared k3s settings (version, networking, flannel)
- `k3s-token-secrets.nix` — Cluster join token management
- `disko-config.nix` — NVMe disk partitioning layout (node0-3)
- `gpu.nix` — AMD eGPU drivers and Vulkan setup (node4 only, uses custom kernel from geerlingguy's 6.17.y branch)
- `patches/` — Custom kernel patches

## Conventions

- Commit style: conventional commits (semantic-release via `.releaserc.json`)
- Two Nix substituters configured (cachix) for pre-built binary caches
- Node4 uses SD card (no NVMe) since PCIe is occupied by the eGPU

## Guardrails

- Never change k3s token secrets without coordinating across all nodes — mismatched tokens break cluster joins
- GPU kernel patches are fragile — test node4 changes carefully before deploying
- Node0 is the control plane — an outage takes down the cluster API; test node0 changes with extra care
- NVMe partitioning (disko) is destructive on first deploy — never re-run nixos-anywhere on a node with data unless you intend to wipe it
