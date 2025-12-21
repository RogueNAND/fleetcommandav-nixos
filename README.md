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

```bash
curl -L https://raw.githubusercontent.com/RogueNAND/fleetcommand-nixos/main/bootstrap.sh | sudo bash -s
```
