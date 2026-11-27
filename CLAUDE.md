# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Robert's personal setup files, the scripts that run his home network, and the server that runs his GitHub Actions runners. Apart from `github-runners/`, nothing here is built or installed by a tool: each file is copied or run by hand where it belongs. **The repository is public.**

## Layout

| Path | What it is |
|---|---|
| `Chocolatey.config` | Windows package list, installed with `choco install Chocolatey.config -y` |
| `CmderConfig.xml` | Cmder (ConEmu) settings export, the old terminal setup |
| `.wezterm.lua`, `aliases` | The move from Cmder: a WezTerm config, and the aliases as Cmder, Git and PowerShell versions |
| `.gitconfig` | Personal Git config. The email is the placeholder `%SECRET%`; keep it that way |
| `sql/` | One-off SQL Server queries |
| `home-network/router/` | OpenWrt scripts for the Netgear R7800 router |
| `home-network/pihole/` | The `direct-sites` command for the Pi-hole, and its test |
| `github-runners/terraform/` | Terraform for the Hetzner Cloud server the GitHub Actions runners live on |
| `github-runners/nixos/` | The NixOS system of that server: a flake, `configuration.nix` and the script its runner service runs |

`home-network/README.md` and `github-runners/README.md` are the operating manuals: daily commands and setting it up from scratch (the network one also has the lessons from the first setup). Read the one for the area before changing it, and keep it in step with the files.

## Home network scripts

The three router scripts run in order on a live router: `r7800-setup.sh` once on a fresh OpenWrt, then `r7800-extras.sh`, then `r7800-direct-sites.sh`. Each starts with `require_*` checks that refuse to run without the previous script's result (the setup also refuses to run twice; that needs a router reset). After the checks come the `configure_*` functions, then a flat list of calls at the bottom.

- The `homenet` command is not a separate file: it is a quoted heredoc inside `install_homenet` in `r7800-extras.sh`, written to `/usr/bin/homenet`. Edit it there and rerun the extras script to install it.
- The split tunnel spans both machines. `direct-sites` on the Pi-hole writes `misc.dnsmasq_lines` to forward the chosen domains to the router (found from the Pi's default route). The router's dnsmasq-full adds the answers to the fw4 set `vpn_bypass`. A MARK rule and an ip rule then route that set through table 100, out over DS-Lite instead of the VPN.
- fw4 picks the nftables chain from a rule's `src` and `dest`, so `uci show` does not prove a rule works. Check the chain with `nft list chain inet fw4 <chain>`, the way `verify` in `r7800-direct-sites.sh` does.
- `NORD_PRIVATE_KEY` in `r7800-setup.sh` stays blank. The key goes only into a copy outside the repository. The NordVPN server public keys in the scripts are public and fine to commit.

Shells: the router runs BusyBox ash and the Pi runs Raspberry Pi OS, so the scripts are POSIX `sh` without bashisms. `.gitattributes` pins LF for `home-network/`, because `.gitconfig` sets `autocrlf = true` and BusyBox fails on CRLF. The router has `apk` (OpenWrt 25.12) and no SFTP server, so `scp` to it needs `-O`.

## GitHub runners server

One Hetzner CX33 (`github-runner`) on NixOS, serving TableTab's CI under the runner label `tabletab`. It is a live machine that jobs run on, deploys included: ask before a `terraform apply`, a reinstall or a reboot.

- Terraform only claims the machine (`terraform/main.tf`); NixOS replaces the stock image afterwards, which is why the server resource ignores changes to `image` and `ssh_keys`. The state file is outside the checkout, at the path given to `terraform init -backend-config` (README, step 2). `HCLOUD_TOKEN` is a user environment variable, never a file here.
- The runners are not defined here. `tabletab-runners.service` fetches table-tab's `master` every hour and runs its `scripts/runner.sh up`, so the runner image and the Playwright browser follow that repository. `nixos/tabletab-runners.sh` is the whole of this side: skip when a job is running, sync the checkout, call the script.
- The server rebuilds itself every night from this repository's `master` (`system.autoUpgrade`), so a merged change to `nixos/` deploys without a step, and a broken one breaks the server the same night. Evaluate before merging (Commands).
- `nixos/admin.pub` is read by both sides: Terraform finds the uploaded Hetzner key by it, NixOS authorises it for root. It carries no email comment; keep it that way.
- Windows has no Nix. Anything that needs it runs in the `nixos/nix` Docker image, or on the server itself.
- `.gitattributes` pins LF for `github-runners/`: the script runs on Linux and the flake is read from a Windows mount.

## Commands

Evaluate the NixOS configuration (the whole system, without building it) after changing anything in `github-runners/nixos/`:

```powershell
docker run --rm -e "NIX_CONFIG=experimental-features = nix-command flakes" -v "${PWD}\github-runners\nixos:/flake" nixos/nix nix eval --raw /flake#nixosConfigurations.github-runner.config.system.build.toplevel.drvPath
```

Check the Terraform (needs `terraform init` once, README step 2):

```powershell
terraform -chdir=github-runners/terraform validate
```

Test `direct-sites` (stubs `pihole-FTL`, `ip` and `id`, so it runs on Windows in Git Bash or WSL). It runs every check and names the ones that fail:

```sh
sh home-network/pihole/direct-sites-test.sh
```

Run a router script from PowerShell (it has no `<` redirect, hence `cmd /c`). These change the live network, so ask before running them:

```powershell
cmd /c "ssh root@192.168.0.1 sh -s < home-network\router\r7800-extras.sh"
```

There is no linter or build step beyond these.

## Conventions

- Every deliberate shortcut is a `TODO: ` comment where it lives: `git grep -n "TODO: "` lists them.
- Script errors go through `fail`, which prints a message saying what to do and exits non-zero.
- Commit subjects are plain imperative sentences; PR titles follow Conventional Commits (`feat(home-network): ...`).
