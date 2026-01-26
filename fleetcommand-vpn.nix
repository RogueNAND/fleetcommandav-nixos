{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types optional optionalString concatStringsSep escapeShellArg;

  cfg = config.fleetcommand.vpn;

  routesFlags =
    lib.concatMap (r: [ "--advertise-routes=${r}" ]) (cfg.advertiseRoutes or []);

  upFlags =
    (optional cfg.ssh "--ssh")
    ++ (optional cfg.exitNode "--advertise-exit-node")
    ++ (optional (cfg.loginServer != null) ("--login-server=" + cfg.loginServer))
    ++ [
      "--hostname=${config.networking.hostName}"
      "--qr"
    ]
    ++ routesFlags;


  upFlagsStr = concatStringsSep " " (map escapeShellArg upFlags);
in
{
  options.fleetcommand.vpn = {
    enable = mkEnableOption "Appliance VPN (Tailscale/Headscale)";

    loginServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional Headscale login server URL.";
    };

    ssh = mkOption { type = types.bool; default = false; };
    exitNode = mkOption { type = types.bool; default = true; };

    advertiseRoutes = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Routes to advertise via Tailscale (IPv4 or IPv6 CIDRs). For 4via6, put the computed IPv6 prefix here.";
      example = [ "fd7a:115c:a1e0:ab12::/64" ];
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.exitNode || (cfg.advertiseRoutes != []);
        message = "fleetcommand.vpn: set exitNode=true and/or provide advertiseRoutes.";
      }
    ];

    # tailscaled daemon enabled; the "up" flags are handled by fleetcommand-tailscale-up service
    services.tailscale.enable = true;
    services.tailscale.useRoutingFeatures =
      if cfg.exitNode && (cfg.advertiseRoutes != []) then "both"
      else if cfg.exitNode then "client"
      else if (cfg.advertiseRoutes != []) then "server"
      else "client"; # harmless default, but you probably always do one of the above

    # Run tailscale up deterministically each boot (with --reset fallback)
    systemd.services.fleetcommand-tailscale-up = {
      description = "Fleetcommand appliance: run tailscale up with config-derived flags";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      path = [ pkgs.tailscale pkgs.coreutils pkgs.util-linux ];

      script = ''
        set -euo pipefail

        for i in $(seq 1 10); do
          tailscale status >/dev/null 2>&1 && break || true
          sleep 1
        done

        # Check if already authenticated
        if tailscale ip -4 >/dev/null 2>&1; then
          echo "Tailscale already authenticated."
          exit 0
        fi

        cmd="tailscale up ${upFlagsStr}"
        echo "Running: $cmd"

        # Capture QR output and broadcast to all terminals
        qr_output=$(eval "$cmd" 2>&1) || {
          echo "tailscale up failed; retrying with --reset"
          qr_output=$(eval "tailscale up --reset ${upFlagsStr}" 2>&1) || true
        }

        # Display to console/journal
        echo "$qr_output"

        # Broadcast to all logged-in users via wall (if auth needed)
        if ! tailscale ip -4 >/dev/null 2>&1; then
          {
            echo ""
            echo "============================================"
            echo "   TAILSCALE AUTHENTICATION REQUIRED"
            echo "============================================"
            echo ""
            echo "Scan the QR code below or visit the URL to authenticate:"
            echo ""
            echo "$qr_output"
            echo ""
          } | wall
        fi
      '';
    };

    # Tweak UDP for optimal performance
    systemd.services.fleetcommand-tailscale-udp-gro-tune = {
      description = "Fleetcommand appliance: tune NIC UDP GRO settings for Tailscale exit/subnet routing";
      after = [ "network.target" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {Type = "oneshot";};

      path = [ pkgs.iproute2 pkgs.ethtool pkgs.coreutils pkgs.gawk ];

      script = ''
        set -euo pipefail

        # Wait up to 60s for a default route to appear
        for i in $(seq 1 30); do
          NETDEV="$(ip route show default 0.0.0.0/0 2>/dev/null | ${pkgs.gawk}/bin/awk '/default/ {print $5; exit}')"
          [ -n "$NETDEV" ] && break
          sleep 2
        done

        if [ -z "${NETDEV:-}" ]; then
          echo "No default route found; skipping UDP GRO tuning."
          exit 0
        fi

        echo "Applying Tailscale UDP GRO tuning on $NETDEV"
        ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off || true
      '';
    };
  };
}
