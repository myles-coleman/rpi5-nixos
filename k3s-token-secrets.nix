{
  config,
  pkgs,
  lib,
  ...
}: {
  # The K3s token is injected at deploy time (via SSH) to avoid embedding
  # secrets in the Nix store, Cachix cache, or SD card images.
  # The deploy workflow writes the token to /etc/rancher/k3s/token.
  # See: .github/workflows/update.yaml (deploy job)

  # Ensure the directory exists with restrictive permissions
  systemd.tmpfiles.rules = [
    "d /etc/rancher/k3s 0700 root root -"
  ];
}
