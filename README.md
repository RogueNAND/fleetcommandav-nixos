# fleetcommand-nixos
Opinionated NixOS appliance configuration

# NixOS Installation (via GUI installer)
- User setup
  - Set admin password
  - Create a default user
- No desktop environment
- Allow unfree software
- Setup disk
  - No swap partition (zram is used for swap)

# Configure OS
- Run bootstrap.sh (this repository)

## Basic usage

```bash
curl -L https://raw.githubusercontent.com/RogueNAND/fleetcommand-nixos/main/bootstrap.sh | sudo bash -s
```

## Advanced usage

Specify hostname:

```bash
curl -L https://raw.githubusercontent.com/RogueNAND/fleetcommand-nixos/main/bootstrap.sh | sudo bash -s -- myhost
```

## Authentication

After the system rebuild completes, Tailscale will display a QR code in the terminal. Scan this QR code with your phone to authenticate the device to your Tailnet.
