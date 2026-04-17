# Node health, observability, and auto-recovery for all cluster nodes
#
# This module configures:
#   - Persistent journald logging (survives reboots for post-mortem analysis)
#   - Hardware watchdog (auto-reboot on kernel hang via bcm2835_wdt)
#   - Network connectivity watchdog (logs failures with interface state)
#   - zram swap (compressed in-memory swap to handle memory pressure)
{pkgs, ...}: {
  # --- Persistent journal ---
  # Default NixOS journald uses volatile storage (tmpfs), so logs are lost on
  # reboot or crash. Persistent storage writes to /var/log/journal, letting us
  # inspect previous boot logs with: journalctl --boot=-1
  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=200M
  '';

  # --- Hardware watchdog ---
  # RPi 5 has a built-in bcm2835_wdt hardware watchdog. systemd pets it at
  # half the runtimeTime interval. If systemd hangs, the watchdog fires and
  # the hardware reboots the node after rebootTime.
  systemd.watchdog = {
    runtimeTime = "30s";
    rebootTime = "60s";
  };

  # --- Network connectivity watchdog ---
  # Pings the default gateway every 30s and logs failures with full interface
  # state. Gives us timestamps to correlate network drops with kernel/GPU errors.
  systemd.services.network-watchdog = {
    description = "Network connectivity watchdog";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 10;
    };
    path = with pkgs; [iputils iproute2 coreutils gawk];
    script = ''
      gateway=$(ip route show default | awk '/default/ {print $3; exit}')
      if [ -z "$gateway" ]; then
        echo "No default gateway found, waiting..." >&2
        sleep 30
        exit 1
      fi
      echo "Network watchdog started, monitoring gateway $gateway on end0"
      consecutive_failures=0
      while true; do
        if ! ping -c 3 -W 5 "$gateway" >/dev/null 2>&1; then
          consecutive_failures=$((consecutive_failures + 1))
          echo "NETWORK UNREACHABLE (attempt $consecutive_failures) - gateway $gateway" >&2
          echo "--- ip addr show end0 ---" >&2
          ip addr show end0 >&2 || true
          echo "--- ip link show end0 ---" >&2
          ip link show end0 >&2 || true
          echo "--- ip route ---" >&2
          ip route >&2 || true
          # After 5 consecutive failures (2.5 min), try bouncing the interface
          # and re-adding the default route (link bounce drops static routes)
          if [ "$consecutive_failures" -ge 5 ]; then
            echo "5 consecutive failures, attempting interface restart" >&2
            ip link set end0 down 2>/dev/null || true
            sleep 2
            ip link set end0 up 2>/dev/null || true
            sleep 2
            echo "Re-adding default route via $gateway" >&2
            ip route replace default via "$gateway" dev end0 proto static 2>/dev/null || true
            consecutive_failures=0
          fi
        else
          if [ "$consecutive_failures" -gt 0 ]; then
            echo "Network recovered after $consecutive_failures failed attempts" >&2
          fi
          consecutive_failures=0
        fi
        sleep 30
      done
    '';
  };

  # --- zram swap ---
  # Compressed in-memory swap. Much better than SD card swap (avoids wear) and
  # faster than NVMe swap (no I/O). zstd compression typically achieves 3:1,
  # so 2GB zram ~ 6GB effective swap on 8GB RAM nodes.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
  };
}
