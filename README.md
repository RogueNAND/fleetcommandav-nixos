# fleetcommand-nixos
Opinionated NixOS appliance configuration

## Fresh Install (from NixOS installer ISO)

Boot the NixOS minimal ISO and run:

```bash
curl -L https://raw.githubusercontent.com/RogueNAND/fleetcommand-nixos/main/bootstrap.sh | sudo bash
```

The script will:
- Prompt for target disk (btrfs with @, @nix, @home subvolumes)
- Partition and format the disk
- Clone the configuration and run `nixos-install`

## Reconfigure (existing NixOS system)

Run the same command on an already-installed system:

```bash
curl -L https://raw.githubusercontent.com/RogueNAND/fleetcommand-nixos/main/bootstrap.sh | sudo bash
```

The script auto-detects the environment and will clone the config if necessary to `/etc/nixos` and run `nixos-rebuild switch`.

## Options

Specify hostname via argument:

```bash
curl -L https://raw.githubusercontent.com/RogueNAND/fleetcommand-nixos/main/bootstrap.sh | sudo bash -s -- myhost
```

## Authentication

After installation/rebuild, Tailscale will display a QR code in the terminal. Scan it to authenticate the device to your Tailnet.
