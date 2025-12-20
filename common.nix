# /etc/nixos/common.nix
{ config, pkgs, lib, ... }:  # lib is for cockpit bug workaround

let
  sshKeysUrl = config.fleetcommand.sshKeysUrl or null;
  userPasswordHashFile = "/var/lib/fleetcommand/secrets/fleetcommand.passwd";
in
{
  options.fleetcommand.sshKeysUrl = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "URL to fetch SSH authorized_keys for the fleetcommand user.";
  };

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


  users.users.fleetcommand =
    {
      isNormalUser = true;
      uid = 1000;
      description = "fleetcommand";
      extraGroups = [ "networkmanager" "wheel" "docker" ];
    }
    // lib.optionalAttrs (builtins.pathExists userPasswordHashFile) {
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
  services.journald = {
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
  services.logind.settings.Login = {
    HandlePowerKey="ignore";
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

    # Log to ram
    logDriver = "journald";
    daemon.settings = {
      storage-driver = "overlay2";
    };
  };

  environment.systemPackages = with pkgs; [
    git
    docker-compose
    tailscale
    iwd  # wifi tools
    cockpit
    pkgs.ethtool
  ];

  services.cockpit = {
    enable = true;
    port = 9090;

    settings.WebService = {
      AllowUnencrypted = true;

      # Work around the NixOS origin bug: explicitly allow these URLs
      Origins = lib.mkForce ''
        http://localhost:9090
        https://localhost:9090
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
    "d /var/lib/fleetcommand/ssh 0700 fleetcommand users -"
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
      install -m 600 -o fleetcommand -g users "$tmp" /var/lib/fleetcommand/ssh/authorized_keys
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

  users.users.fleetcommand.openssh.authorizedKeys.keyFiles =
    lib.mkIf (sshKeysUrl != null) [ "/var/lib/fleetcommand/ssh/authorized_keys" ];

  services.xserver.enable = false;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
