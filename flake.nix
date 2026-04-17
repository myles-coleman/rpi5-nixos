{
  description = "Multi-node K3s cluster on Raspberry Pi 5";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Raspberry Pi Linux kernel with AMD/Intel GPU patches
    # geerlingguy's branch with the GPU fix on top of rpi-6.17.y
    # See: https://github.com/geerlingguy/linux/pull/10
    rpi-linux-gpu = {
      url = "github:geerlingguy/linux/rpi-6.17.y-gpu";
      flake = false;
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
      "https://rpi5-k3s.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      "rpi5-k3s.cachix.org-1:SH8ZlBgEj/jr0Facr2dnlXOyH7vzUe5W5YYQn70L7KA="
    ];
  };

  outputs = {
    self,
    nixpkgs,
    nixos-raspberrypi,
    disko,
    rpi-linux-gpu,
  } @ inputs: let
    system = "x86_64-linux";
    targetSystem = "aarch64-linux";

    # Shared configuration for all nodes (users, SSH, mDNS, locale, etc.)
    sharedConfig = [
      nixos-raspberrypi.nixosModules.raspberry-pi-5.base
      nixos-raspberrypi.nixosModules.raspberry-pi-5.display-vc4

      ({pkgs, ...}: {
        users.users.pi = {
          initialPassword = "raspberry";
          isNormalUser = true;
          extraGroups = ["wheel"];
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzbHiGJguieUhUnv5ktHoLjOhN9TqEUJS/zwDFZqrsC github-actions"
          ];
        };

        security.sudo.wheelNeedsPassword = false;

        services.openssh = {
          enable = true;
          settings.PasswordAuthentication = false;
          settings.PermitRootLogin = "no";
        };

        # enable mDNS for .local domain resolution
        services.avahi = {
          enable = true;
          nssmdns4 = true;
          publish = {
            enable = true;
            addresses = true;
            domain = true;
            hinfo = true;
            userServices = true;
            workstation = true;
          };
        };

        time.timeZone = "America/Los_Angeles";
        i18n.defaultLocale = "en_US.UTF-8";

        hardware.enableRedistributableFirmware = true;
        system.stateVersion = "25.05";
      })
    ];

    # K3s cluster nodes (NVMe): 16K page size + disko for NVMe partitioning
    baseConfig =
      sharedConfig
      ++ [
        nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
        disko.nixosModules.disko
        ./disko-config.nix
      ];

    # GPU node (SD card boot): no page-size-16k (16K pages cause issues with
    # GPU workloads). Uses sd-image module instead of disko (no NVMe SSD).
    # Reference: https://github.com/raspberrypi/linux/pull/7113
    gpuBaseConfig =
      sharedConfig
      ++ [
        nixos-raspberrypi.nixosModules.sd-image
        ./gpu.nix
        # Override kernel to use geerlingguy's GPU-patched branch (rpi-6.17.y-gpu)
        # This branch includes TTM cache coherency fixes + PCIe GPU enablement
        # that are not yet in the upstream RPi kernel used by nixos-raspberrypi.
        # We build the kernel directly using buildLinux + bcm2712_defconfig rather
        # than trying to override nixos-raspberrypi's kernel package.
        ({
          pkgs,
          lib,
          ...
        }: {
          # ZFS doesn't support kernel 6.17 yet — disable it (node4 uses ext4 on SD card)
          boot.supportedFilesystems.zfs = lib.mkForce false;
          boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor ((pkgs.buildLinux {
              version = "6.17.0-rpi-gpu";
              modDirVersion = "6.17.0";
              src = rpi-linux-gpu;
              defconfig = "bcm2712_defconfig";
              kernelPatches = with pkgs.kernelPatches; [
                bridge_stp_helper
                request_key_helper
              ];
              structuredExtraConfig = with lib.kernel; {
                DRM_AMDGPU = module;
                HSA_AMD = yes;
                # Force 4K page size — bcm2712_defconfig defaults to 16K pages,
                # which are incompatible with GPU workloads (amdgpu TTM/DRM).
                # Reference: https://github.com/geerlingguy/raspberry-pi-pcie-devices/issues/222
                ARM64_4K_PAGES = yes;
                ARM64_16K_PAGES = no;
                # Clear LOCALVERSION set by bcm2712_defconfig ("-v8-16k")
                # so modDirVersion stays "6.17.0"
                LOCALVERSION = freeform "";
                # Disable bcachefs — fails to link with nixpkgs binutils on 6.17
                # (not needed; node4 uses ext4 on SD card)
                BCACHEFS_FS = no;
                # gpio-pwm.c has void/int return type mismatch in 6.17
                GPIO_PWM = no;
                # Disable simpledrm and simplefb — simpledrm crashes with a level 1
                # translation fault on BCM2712 + 4K pages when mapping the firmware
                # framebuffer (16K-aligned). Node4 uses amdgpu for display.
                DRM_SIMPLEDRM = lib.mkForce no;
                FB_SIMPLE = lib.mkForce no;
                SYSFB_SIMPLEFB = lib.mkForce no;
              };
              features = {
                efiBootStub = false;
              };
              extraMeta = {
                platforms = with lib.platforms; arm ++ aarch64;
              };
              ignoreConfigErrors = true;
            }).overrideAttrs (old: {
              # Append to (not replace) buildLinux's postConfigure which runs make oldconfig.
              postConfigure =
                (old.postConfigure or "")
                + ''
                  # bcm2712_defconfig sets CONFIG_LOCALVERSION="-v8-16k"; clear it
                  sed -i $buildRoot/.config -e 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=""/'
                  # Force 4K page size — bcm2712_defconfig defaults to 16K which breaks amdgpu
                  sed -i $buildRoot/.config -e 's/^CONFIG_ARM64_16K_PAGES=.*/# CONFIG_ARM64_16K_PAGES is not set/'
                  sed -i $buildRoot/.config -e 's/^.*CONFIG_ARM64_4K_PAGES.*/CONFIG_ARM64_4K_PAGES=y/'
                  # Force-disable bcachefs (linker failure with nixpkgs binutils on 6.17)
                  sed -i $buildRoot/.config -e 's/^CONFIG_BCACHEFS_FS=.*/# CONFIG_BCACHEFS_FS is not set/'
                  # gpio-pwm.c has void/int return type mismatch in 6.17
                  sed -i $buildRoot/.config -e 's/^CONFIG_GPIO_PWM=.*/# CONFIG_GPIO_PWM is not set/'
                  # Force-disable simpledrm/simplefb (translation fault on BCM2712 + 4K pages)
                  sed -i $buildRoot/.config -e 's/^CONFIG_DRM_SIMPLEDRM=.*/# CONFIG_DRM_SIMPLEDRM is not set/'
                  sed -i $buildRoot/.config -e 's/^CONFIG_FB_SIMPLE=.*/# CONFIG_FB_SIMPLE is not set/'
                  sed -i $buildRoot/.config -e 's/^CONFIG_SYSFB_SIMPLEFB=.*/# CONFIG_SYSFB_SIMPLEFB is not set/'
                '';

              # Copy overlays README to match raspberrypifw layout.
              # The .dtbo overlay files (including bcm2712d0.dtbo required for D0
              # silicon) are built automatically by 'make dtbs' since the RPi 6.17
              # kernel's arch/arm64/boot/dts/Makefile includes 'subdir-y += overlays'.
              postFixup =
                (old.postFixup or "")
                + ''
                  if [ -d "$srcs/arch/arm64/boot/dts/overlays" ]; then
                    cp "$srcs/arch/arm64/boot/dts/overlays/README" "$out/dtbs/overlays/" 2>/dev/null || true
                  fi
                '';
            })));
        })
      ];
  in {
    nixosConfigurations.node0 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules =
        baseConfig
        ++ [
          ./k3s-server.nix
          ({...}: {
            networking.hostName = "node0";
            networking.interfaces.end0.ipv4.addresses = [
              {
                address = "10.0.0.140";
                prefixLength = 24;
              }
            ];
            networking.defaultGateway = "10.0.0.1";
            networking.nameservers = ["1.1.1.1"];
          })
        ];
    };

    nixosConfigurations.node1 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules =
        baseConfig
        ++ [
          ./k3s-agent.nix
          ({...}: {
            networking.hostName = "node1";
            networking.interfaces.end0.ipv4.addresses = [
              {
                address = "10.0.0.141";
                prefixLength = 24;
              }
            ];
            networking.defaultGateway = "10.0.0.1";
            networking.nameservers = ["1.1.1.1"];
          })
        ];
    };

    nixosConfigurations.node2 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules =
        baseConfig
        ++ [
          ./k3s-agent.nix
          ({...}: {
            networking.hostName = "node2";
            networking.interfaces.end0.ipv4.addresses = [
              {
                address = "10.0.0.142";
                prefixLength = 24;
              }
            ];
            networking.defaultGateway = "10.0.0.1";
            networking.nameservers = ["1.1.1.1"];
          })
        ];
    };

    nixosConfigurations.node3 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules =
        baseConfig
        ++ [
          ./k3s-agent.nix
          ({...}: {
            networking.hostName = "node3";
            networking.interfaces.end0.ipv4.addresses = [
              {
                address = "10.0.0.143";
                prefixLength = 24;
              }
            ];
            networking.defaultGateway = "10.0.0.1";
            networking.nameservers = ["1.1.1.1"];
          })
        ];
    };

    # GPU-enabled Raspberry Pi 5 (8GB) with AMD RX 6700 XT eGPU (SD card)
    nixosConfigurations.node4 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules =
        gpuBaseConfig
        ++ [
          ./k3s-agent.nix
          ({
            config,
            lib,
            ...
          }: {
            networking.hostName = "node4";
            networking.interfaces.end0.ipv4.addresses = [
              {
                address = "10.0.0.144";
                prefixLength = 24;
              }
            ];
            networking.defaultGateway = "10.0.0.1";
            networking.nameservers = ["10.0.0.1"];

            # GPU node labels and taint for Kubernetes scheduling
            services.k3s.extraFlags = lib.mkForce [
              "--node-ip=${(builtins.elemAt config.networking.interfaces.end0.ipv4.addresses 0).address}"
              "--node-external-ip=${(builtins.elemAt config.networking.interfaces.end0.ipv4.addresses 0).address}"
              "--flannel-iface=end0"
              "--node-label=gpu.node/type=amd-vulkan"
              "--node-label=gpu.node/vram=12Gi"
              "--node-taint=gpu=amd:NoSchedule"
            ];
          })
        ];
    };

    packages.${system} = {
      node0 = self.nixosConfigurations.node0.config.system.build.sdImage;
      node1 = self.nixosConfigurations.node1.config.system.build.sdImage;
      node2 = self.nixosConfigurations.node2.config.system.build.sdImage;
      node3 = self.nixosConfigurations.node3.config.system.build.sdImage;
      node4 = self.nixosConfigurations.node4.config.system.build.sdImage;

      default = self.packages.${system}.node0;
    };
  };
}
