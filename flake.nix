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
    # geerlingguy's branch with the 2-commit GPU fix on top of rpi-6.17.y
    # See: https://github.com/geerlingguy/linux/pull/10
    rpi-linux-gpu = {
      url = "github:geerlingguy/linux/rpi-6.17.y-gpu";
      flake = false;
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
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
    baseConfig = sharedConfig ++ [
      nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
      disko.nixosModules.disko
      ./disko-config.nix
    ];

    # GPU node (SD card boot): no page-size-16k (16K pages cause issues with
    # GPU workloads). Uses sd-image module instead of disko (no NVMe SSD).
    # Reference: https://github.com/raspberrypi/linux/pull/7113
    gpuBaseConfig = sharedConfig ++ [
      nixos-raspberrypi.nixosModules.sd-image
      ./gpu.nix
      # Override kernel to use the GPU-patched branch (6by9's rpi-6.18.y-pcie-gpu)
      ({pkgs, lib, ...}: {
        boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor (pkgs.rpi.linux_rpi.bcm2712.override {
          argsOverride = {
            src = inputs.rpi-linux-gpu;
            version = "6.18.0-pcie-gpu";
          };
        }));
      })
    ];
  in {
    nixosConfigurations.node0 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules = baseConfig ++ [
        ./k3s-server.nix
        ({...}: {
          networking.hostName = "node0";
          networking.interfaces.end0.ipv4.addresses = [{
            address = "10.0.0.140";
            prefixLength = 24;
          }];
          networking.defaultGateway = "10.0.0.1";
          networking.nameservers = [ "10.0.0.1" ];
        })
      ];
    };

    nixosConfigurations.node1 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules = baseConfig ++ [
        ./k3s-agent.nix
        ({...}: {
          networking.hostName = "node1";
          networking.interfaces.end0.ipv4.addresses = [{
            address = "10.0.0.141";
            prefixLength = 24;
          }];
          networking.defaultGateway = "10.0.0.1";
          networking.nameservers = [ "10.0.0.1" ];
        })
      ];
    };

    nixosConfigurations.node2 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules = baseConfig ++ [
        ./k3s-agent.nix
        ({...}: {
          networking.hostName = "node2";
          networking.interfaces.end0.ipv4.addresses = [{
            address = "10.0.0.142";
            prefixLength = 24;
          }];
          networking.defaultGateway = "10.0.0.1";
          networking.nameservers = [ "10.0.0.1" ];
        })
      ];
    };

    nixosConfigurations.node3 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules = baseConfig ++ [
        ./k3s-agent.nix
        ({...}: {
          networking.hostName = "node3";
          networking.interfaces.end0.ipv4.addresses = [{
            address = "10.0.0.143";
            prefixLength = 24;
          }];
          networking.defaultGateway = "10.0.0.1";
          networking.nameservers = [ "10.0.0.1" ];
        })
      ];
    };

    # GPU-enabled Raspberry Pi 5 (8GB) with AMD RX 6700 XT eGPU (SD card)
    nixosConfigurations.node4 = nixos-raspberrypi.lib.nixosSystem {
      system = targetSystem;
      specialArgs = inputs;
      modules = gpuBaseConfig ++ [
        ./k3s-agent.nix
        ({...}: {
          networking.hostName = "node4";
          networking.interfaces.end0.ipv4.addresses = [{
            address = "10.0.0.144";
            prefixLength = 24;
          }];
          networking.defaultGateway = "10.0.0.1";
          networking.nameservers = [ "10.0.0.1" ];
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
