# /etc/nixos/common.nix
{ config, pkgs, lib, ... }:  # lib is for cockpit bug workaround

let
  cfg = config.fleetcommand;
  sshKeysUrl = cfg.sshKeysUrl or null;
  userPasswordHashFile = "/var/lib/fleetcommand/secrets/fleetcommand.passwd";
in
{
  options.fleetcommand.sshKeysUrl = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "URL to fetch SSH authorized_keys for the fleetcommand user.";
  };

  options.fleetcommand.disablePowerButton = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to ignore the power button (prevent accidental shutdowns).";
  };

  options.fleetcommand.volatileJournald = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Store journald logs in RAM only (volatile storage with 32M limit).";
  };

  config = {
    # Bootloader.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    zramSwap.enable = true;

    # Select internationalisation properties.
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_ADDRESS = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT = "en_US.UTF-8";
      LC_MONETARY = "en_US.UTF-8";
      LC_NAME = "en_US.UTF-8";
      LC_NUMERIC = "en_US.UTF-8";
      LC_PAPER = "en_US.UTF-8";
      LC_TELEPHONE = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
    };


    ############
    ### USER ###
    ############


    users.users.fleetcommand = {
      isNormalUser = true;
      uid = 1000;
      description = "fleetcommand";
      extraGroups = [ "networkmanager" "wheel" "docker" ];
      hashedPasswordFile = userPasswordHashFile;
    };

    security.sudo.enable = true;
    security.sudo.wheelNeedsPassword = true;
    nixpkgs.config.allowUnfree = true;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = sshKeysUrl == null;
        PermitRootLogin = "no";
      };
    };


    #################################
    ### Journald / logging tweaks ###
    #################################


    # Log to ram
    services.journald = lib.mkIf cfg.volatileJournald {
      storage = "volatile";
      extraConfig = ''
        RuntimeMaxUse=32M
      '';
    };

    fileSystems."/tmp" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=1777" "nosuid" "nodev" "noatime" ];
    };

    fileSystems."/var/tmp" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=1777" "nosuid" "nodev" "noatime" ];
    };


    #############################
    ### Power / sleep control ###
    #############################


    # Disable power button
    services.logind.settings.Login = lib.mkIf cfg.disablePowerButton {
      HandlePowerKey = "ignore";
    };

    # Disable sleep / hibernate
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
    };

    powerManagement.cpuFreqGovernor = "performance";  # CPU power saving
    boot.kernelParams = [
      "pcie_aspm=off"  # PCIE power saving
      "usbcore.autosuspend=-1"  # USB suspend
    ];


    ##################
    ### Networking ###
    ##################


    networking.wireless.iwd.enable = true;
    networking.firewall.enable = false;

    networking.networkmanager = {
      enable = true;
      unmanaged = [
        "interface-name:docker0"
        "interface-name:br-*"
        "interface-name:veth*"
      ];

      dispatcherScripts = [
        # Tailscale UDP tweak whenever network is connected
        {
          source = pkgs.writeShellScript "50-fleetcommand-tailscale-udp-gro" ''
            set -euo pipefail

            # NM passes: $1=interface, $2=event
            case "''${2:-}" in
              up|dhcp4-change|dhcp6-change|connectivity-change) ;;
              *) exit 0 ;;
            esac

            NETDEV="$(ip route show default 0.0.0.0/0 2>/dev/null | ${pkgs.gawk}/bin/awk '/default/ {print $5; exit}')"
            [ -n "$NETDEV" ] || exit 0

            ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off || true
          '';
        }

        # Disable EEE on the interface that just came up (deterministic per-port)
        {
          source = pkgs.writeShellScript "50-fleetcommand-disable-eee" ''
            set -euo pipefail

            IFACE="''${1:-}"
            EVENT="''${2:-}"

            case "$EVENT" in
              up|dhcp4-change|dhcp6-change|connectivity-change) ;;
              *) exit 0 ;;
            esac

            # Skip obvious virtual interfaces
            case "$IFACE" in
              lo|tailscale0|docker0|br-*|veth*|virbr*|wg*|zt*|tun*|tap*) exit 0 ;;
            esac

            ${pkgs.ethtool}/bin/ethtool --set-eee "$IFACE" eee off 2>/dev/null || true
          '';
        }
      ];
    };

    services.avahi = {
      enable = true;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
      };
    };


    ##############
    ### Docker ###
    ##############


    virtualisation.docker = {
      enable = true;
      enableOnBoot = true;
      autoPrune.enable = true;
      liveRestore = true;  # Containers survive daemon restarts

      logDriver = "journald";
      daemon.settings = {
        storage-driver = "btrfs";
        "shutdown-timeout" = 15;  # Grace period for container shutdown
      };
    };

    # Make docker.service more resilient
    systemd.services.docker.serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";
    };

    # Monthly btrfs scrub to detect/repair filesystem errors
    systemd.services.btrfs-scrub = {
      description = "Btrfs scrub on root filesystem";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.btrfs-progs}/bin/btrfs scrub start -B /";
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "idle";
      };
    };

    systemd.timers.btrfs-scrub = {
      description = "Monthly btrfs scrub";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "monthly";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    environment.systemPackages = with pkgs; [
      git
      docker-compose
      tailscale
      iwd  # wifi tools
      cockpit
      ethtool
      btrfs-progs  # btrfs management tools
    ];

    # Tailscale authentication reminder on login (fallback if wall broadcast missed)
    programs.bash.interactiveShellInit = ''
      # Tailscale authentication reminder (runs once per shell session)
      _fleetcommand_check_tailscale() {
        [ -n "$_FLEETCOMMAND_TS_CHECKED" ] && return
        export _FLEETCOMMAND_TS_CHECKED=1

        command -v tailscale >/dev/null 2>&1 || return

        # Check if tailscale has an IP (authenticated) or not
        if ! tailscale ip -4 >/dev/null 2>&1; then
          echo ""
          echo -e "\e[33m============================================\e[0m"
          echo -e "\e[33m   TAILSCALE AUTHENTICATION REQUIRED\e[0m"
          echo -e "\e[33m============================================\e[0m"
          echo ""
          echo "This device needs to authenticate with Tailscale."
          echo ""
          echo "To see the QR code, run:"
          echo "  sudo journalctl -u fleetcommand-tailscale-up -n 60"
          echo ""
          echo "Or re-trigger authentication:"
          echo "  sudo tailscale up --qr"
          echo ""
        fi
      }
      _fleetcommand_check_tailscale
    '';

    services.cockpit = {
      enable = true;
      port = 9099;

      settings.WebService = {
        AllowUnencrypted = true;

        # Work around the NixOS origin bug: explicitly allow these URLs
        Origins = lib.mkForce ''
          http://localhost:9099
          https://localhost:9099
        '';
      };
    };


    ######################
    ### Git Repository ###
    ######################


    # Make sure base directory exists
    systemd.tmpfiles.rules = [
      "d /srv 0755 fleetcommand users -"
      "d /var/lib/fleetcommand/secrets 0700 root root -"
      "d /home/fleetcommand/.ssh 0700 fleetcommand users -"
    ];

    systemd.services.fleetcommand-ssh-keys = lib.mkIf (sshKeysUrl != null) {
      description = "Fleetcommand appliance: refresh SSH authorized_keys";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = { Type = "oneshot"; };
      path = [ pkgs.curl pkgs.coreutils ];

      script = ''
        set -euo pipefail

        tmp="$(mktemp)"
        ${pkgs.curl}/bin/curl -fsSL ${lib.escapeShellArg sshKeysUrl} -o "$tmp"
        install -m 600 -o fleetcommand -g users "$tmp" /home/fleetcommand/.ssh/authorized_keys
        rm -f "$tmp"
      '';
    };

    systemd.timers.fleetcommand-ssh-keys = lib.mkIf (sshKeysUrl != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "24h";
      };
    };

    services.xserver.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  };
}
