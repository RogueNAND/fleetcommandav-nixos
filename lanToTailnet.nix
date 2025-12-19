{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.fcav.virtualSubnet;
in {
  options.fcav.virtualSubnet = {
    enable = mkEnableOption "FCAV virtual subnet translation (Tailscale <-> client LAN)";

    # The interface that is connected to the client's LAN
    lanInterface = mkOption {
      type = types.str;
      description = "Name of the interface connected to the client's LAN (e.g. \"enp3s0\").";
      example = "enp3s0";
    };

    # The real client LAN you want to reach (the one that might collide across sites)
    localSubnet = mkOption {
      type = types.str;
      description = "Real client LAN subnet (e.g. \"192.168.10.0/24\").";
      example = "192.168.10.0/24";
    };

    # The unique virtual subnet you expose on the tailnet for THIS site
    virtualSubnet = mkOption {
      type = types.str;
      description = "Virtual subnet exposed via Tailscale for this site (e.g. \"100.64.42.0/24\"). Must be unique per site.";
      example = "100.64.42.0/24";
    };

    # Tailscale interface name (usually tailscale0)
    tailscaleInterface = mkOption {
      type = types.str;
      default = "tailscale0";
      description = "Name of the Tailscale interface.";
      example = "tailscale0";
    };

    # If true, allow LAN -> tailnet forwarding as well (bidirectional).
    # If false, block LAN -> tailnet (translator mode, tailnet -> LAN only).
    lanToTailnet = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to allow forwarding from the client LAN towards the tailnet.

        false (default): tailnet -> LAN only; LAN cannot use this box to reach the tailnet.
        true: allow LAN -> tailnet as well (gateway mode), so that LAN can
        reach other tailnet devices via this box.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.enable || config.services.tailscale.useRoutingFeatures == "both";
        message = ''
          fcav.virtualSubnet.enable = true requires:
            services.tailscale.useRoutingFeatures = "both";
        '';
      }
      {
        assertion = !cfg.enable || lib.any
            (flag: lib.hasPrefix "--advertise-routes=${cfg.virtualSubnet}" flag)
            config.services.tailscale.extraUpFlags;
        message = ''
          fcav.virtualSubnet.enable = true but the virtual subnet
          "${cfg.virtualSubnet}" is not advertised via Tailscale.

          Add:
            "--advertise-routes=${cfg.virtualSubnet}"
        '';
      }
      {
        assertion = !cfg.enable || builtins.hasAttr cfg.lanInterface config.networking.interfaces;
        message = ''
          fcav.virtualSubnet.lanInterface "${cfg.lanInterface}"
          does not exist on this system.
        '';
      }
      {
        assertion = !cfg.enable || (lib.isString cfg.localSubnet && lib.hasInfix "/" cfg.localSubnet);
        message = ''
          fcav.virtualSubnet.localSubnet must be CIDR notation,
          e.g. "192.168.10.0/24".
        '';
      }
    ];

    # Allow forwarding in the kernel
    boot.kernel.sysctl."net.ipv4.ip_forward" = true;

    systemd.services.fcav-virtual-subnet-nat = {
      description = "FCAV virtual subnet NAT (Tailscale <-> client LAN)";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          #!/bin/sh
          set -e

          IPT=${pkgs.iptables}/bin/iptables

          # Clean up any old rules for idempotency
          $IPT -t nat -D PREROUTING -i ${cfg.tailscaleInterface} -d ${cfg.virtualSubnet} -j NETMAP --to ${cfg.localSubnet} 2>/dev/null || true
          $IPT -t nat -D POSTROUTING -o ${cfg.lanInterface} -s ${cfg.virtualSubnet} -j MASQUERADE 2>/dev/null || true
          $IPT -D FORWARD -i ${cfg.tailscaleInterface} -o ${cfg.lanInterface} -s ${cfg.virtualSubnet} -d ${cfg.localSubnet} -j ACCEPT 2>/dev/null || true
          $IPT -D FORWARD -i ${cfg.lanInterface} -o ${cfg.tailscaleInterface} -j DROP 2>/dev/null || true
          $IPT -D FORWARD -i ${cfg.lanInterface} -o ${cfg.tailscaleInterface} -j ACCEPT 2>/dev/null || true

          # Map virtual subnet -> real LAN (preserve host bits)
          $IPT -t nat -A PREROUTING -i ${cfg.tailscaleInterface} -d ${cfg.virtualSubnet} -j NETMAP --to ${cfg.localSubnet}

          # SNAT traffic from the virtual subnet when leaving to LAN
          $IPT -t nat -A POSTROUTING -o ${cfg.lanInterface} -s ${cfg.virtualSubnet} -j MASQUERADE

          # Allow forwarding from Tailscale -> LAN (virtual -> real)
          $IPT -A FORWARD -i ${cfg.tailscaleInterface} -o ${cfg.lanInterface} -s ${cfg.virtualSubnet} -d ${cfg.localSubnet} -j ACCEPT

          # Configure LAN -> Tailscale behavior based on lanToTailnet
          if [ "${toString cfg.lanToTailnet}" = "true" ]; then
            # Gateway mode: allow LAN to reach tailnet
            $IPT -A FORWARD -i ${cfg.lanInterface} -o ${cfg.tailscaleInterface} -j ACCEPT
          else
            # Translator mode: block LAN -> tailnet
            $IPT -A FORWARD -i ${cfg.lanInterface} -o ${cfg.tailscaleInterface} -j DROP
          fi
        '';

        ExecStop = ''
          #!/bin/sh
          IPT=${pkgs.iptables}/bin/iptables

          $IPT -t nat -D PREROUTING -i ${cfg.tailscaleInterface} -d ${cfg.virtualSubnet} -j NETMAP --to ${cfg.localSubnet} 2>/dev/null || true
          $IPT -t nat -D POSTROUTING -o ${cfg.lanInterface} -s ${cfg.virtualSubnet} -j MASQUERADE 2>/dev/null || true
          $IPT -D FORWARD -i ${cfg.tailscaleInterface} -o ${cfg.lanInterface} -s ${cfg.virtualSubnet} -d ${cfg.localSubnet} -j ACCEPT 2>/dev/null || true
          $IPT -D FORWARD -i ${cfg.lanInterface} -o ${cfg.tailscaleInterface} -j DROP 2>/dev/null || true
          $IPT -D FORWARD -i ${cfg.lanInterface} -o ${cfg.tailscaleInterface} -j ACCEPT 2>/dev/null || true
        '';
      };
    };
  };
}
