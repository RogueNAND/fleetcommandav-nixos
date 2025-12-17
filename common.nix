# /etc/nixos/common.nix
{ config, pkgs, lib, ... }:  # lib is for cockpit bug workaround

{
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


  users.users.fcav = {
    isNormalUser = true;
    uid = 1000;
    description = "fcav";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    initialPassword = "fcav";
  };

  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = true;
  nixpkgs.config.allowUnfree = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;  # TODO: use keys
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
    "d /srv 0755 fcav users -"
  ];

  systemd.services.ensure-fleetcommandav = {
    description = "Ensure /srv/fleetcommandav git checkout exists and is up-to-date";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.git pkgs.coreutils ];

    serviceConfig = {
      Type = "oneshot";
      User = "fcav";
      WorkingDirectory = "/srv";
    };

    script = ''
      set -euo pipefail

      set -e
      if [ ! -d fleetcommandav/.git ]; then
        git clone https://github.com/roguenand/fleetcommandav fleetcommandav
      #else
      #  cd fleetcommandav
      #  git fetch origin
      #  # optional: hard-reset to main
      #  git reset --hard origin/main
      fi
    '';
  };

  services.tailscale.enable = true;

  services.xserver.enable = false;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
