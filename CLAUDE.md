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
| `github-runners/terraform/` | Terraform for the Hetzner Cloud server the GitHub Actions runners live on, and the volume that outlives it |
| `github-runners/nixos/` | The NixOS system of that server: a flake, `configuration.nix` with the list of repositories, and the script its units run |

`home-network/README.md` and `github-runners/README.md` are the operating manuals: daily commands and setting it up from scratch (the network one also has the lessons from the first setup). Read the one for the area before changing it, and keep it in step with the files.

## Home network scripts

The three router scripts run in order on a live router: `r7800-setup.sh` once on a fresh OpenWrt, then `r7800-extras.sh`, then `r7800-direct-sites.sh`. Each starts with `require_*` checks that refuse to run without the previous script's result (the setup also refuses to run twice; that needs a router reset). After the checks come the `configure_*` functions, then a flat list of calls at the bottom.

- The `homenet` command is not a separate file: it is a quoted heredoc inside `install_homenet` in `r7800-extras.sh`, written to `/usr/bin/homenet`. Edit it there and rerun the extras script to install it.
- The split tunnel spans both machines. `direct-sites` on the Pi-hole writes `misc.dnsmasq_lines` to forward the chosen domains to the router (found from the Pi's default route). The router's dnsmasq-full adds the answers to the fw4 set `vpn_bypass`. A MARK rule and an ip rule then route that set through table 100, out over DS-Lite instead of the VPN.
- fw4 picks the nftables chain from a rule's `src` and `dest`, so `uci show` does not prove a rule works. Check the chain with `nft list chain inet fw4 <chain>`, the way `verify` in `r7800-direct-sites.sh` does.
- `NORD_PRIVATE_KEY` in `r7800-setup.sh` stays blank. The key goes only into a copy outside the repository. The NordVPN server public keys in the scripts are public and fine to commit.

Shells: the router runs BusyBox ash and the Pi runs Raspberry Pi OS, so the scripts are POSIX `sh` without bashisms. `.gitattributes` pins LF for `home-network/`, because `.gitconfig` sets `autocrlf = true` and BusyBox fails on CRLF. The router has `apk` (OpenWrt 25.12) and no SFTP server, so `scp` to it needs `-O`.

## GitHub runners server

One Hetzner CX33 (`github-runner`) on NixOS that runs GitHub Actions jobs for the repositories listed in `nixos/configuration.nix`, today TableTab under the runner label `tabletab`. It is a live machine that jobs run on, deploys included: ask before a `terraform apply`, a reinstall or a reboot.

- Terraform only claims the machine (`terraform/main.tf`); NixOS replaces the stock image afterwards, which is why the server resource ignores changes to `image` and `ssh_keys`. The state is in Azure Storage (account `tabletapinfra`, the one TableTab's Terraform uses, container `personal-automation`), so Terraform needs `az login`. That account keeps earlier versions of a state and has a delete lock (`terraform-state`), both set by hand because no Terraform owns it. `HCLOUD_TOKEN` is a user environment variable, never a file here.
- The runners' GitHub token is `/persist/token.env`, on a Hetzner volume (`hcloud_volume.persist`) that a reinstall or a new server leaves alone. NixOS finds the volume through the udev name `/dev/persist-volume`, formats it when empty and mounts it with `nofail`, so a missing volume still leaves a machine that takes SSH. The runner units and the nightly maintenance carry `RequiresMountsFor` and fail without it. Put on the volume only what must outlive the system: images and caches live in each runner user's home on the system disk, which the night wipes on purpose.
- Every unit that runs `runner-server.sh` is built with `lib.mkMerge` from `serverService`. Do not go back to `//`: it replaces a whole nested attribute, and once dropped `RequiresMountsFor` from a unit that set `unitConfig` itself.
- **Nothing from a repository runs outside a runner container.** `repositories` in `configuration.nix` lists what is served: repository, count, labels, volumes. Each runner (`<name>-<n>`, as many as the entry's `count`) gets a system user `runner-<name>-<n>` with linger and a rootless Docker daemon (`virtualisation.docker.rootless`, a unit of that user's manager), and a unit `github-runner-<name>-<n>.service`. The server fetches and executes nothing from a repository, and root has no Docker daemon.
- `nixos/runner-server.sh` has four modes, each run by units in `configuration.nix`: `slot` (one runner, one job), `check` (hourly), `maintain` (nightly) and `report` (after a unit failed).
- **The long-lived token never enters a container.** `slot` asks GitHub for a just-in-time runner configuration (`generate-jitconfig`), good for one job of one runner, and hands the container only that, through the docker client's environment and never on its command line. It unsets the token before it becomes the docker client.
- A slot unit is `Restart=on-success` without a start limit: the container ends with its job and the unit starts again. A failure leaves it failed, which fires `OnFailure` once, and `check` starts failed slots again every hour. Do not make it `Restart=always`: a broken token would then send a span every few seconds.
- Slot units are `restartIfChanged = false`, so a `nixos-rebuild switch` never restarts a runner under a job: a changed definition applies when the runner starts for its next job. Removing a unit (a lower `count`) is the exception, it stops at once.
- **No mode may stop a runner that is running a job.** `maintain` takes a runner down by deleting its registration, which GitHub refuses for a busy runner, then looks for a `Runner.Worker` process in its container, and only then stops the unit. Keep that order in any change.
- A runner container runs with `--network host`, which is its daemon's own network namespace: only then does a job reach on `127.0.0.1` a port published by a container it started (TableTab's screenshot browser). On the default bridge it does not. Tried on the server on 2026-11-27. That shared namespace is why the daemon is per runner and not per repository: TableTab's jobs listen on fixed ports, so two runners on one daemon would collide.
- Failures and the hourly sign of life go to SigNoz as spans (`send_span`): service `github-runner-server`, span `runner_server.run`, attributes `runner_server.unit`, `runner_server.result`, `runner_server.host` and `runner_server.message`. table-tab's alert rules filter on those names, so renaming one is a change in two repositories.
- The `maintain` unit reboots through `SuccessAction=reboot`, not from the script: a script that asks for the reboot is killed by it and leaves a failed unit after a good night.
- The night (04:00 in Japan) is a chain: `nixos-upgrade` builds the newest system from this repository's `master` with `operation = "boot"`, and on success starts the `maintain` unit, which takes the runners down, removes every container, image and volume of every runner's daemon, and reboots. So a merged change to `nixos/` deploys without a step, a broken one fails the build and leaves the machine as it was. Evaluate before merging (Commands).
- `nixos/admin.pub` is read by both sides: Terraform finds the uploaded Hetzner key by it, NixOS authorises it for root. It carries no email comment; keep it that way.
- Windows has no Nix. Anything that needs it runs in the `nixos/nix` Docker image, or on the server itself.
- `.gitattributes` pins LF for `github-runners/`: the script runs on Linux and the flake is read from a Windows mount.

## Commands

Evaluate the NixOS configuration (the whole system, without building it) after changing anything in `github-runners/nixos/`:

```powershell
docker run --rm -e "NIX_CONFIG=experimental-features = nix-command flakes" -v "${PWD}\github-runners\nixos:/flake" nixos/nix nix eval --raw /flake#nixosConfigurations.github-runner.config.system.build.toplevel.drvPath
```

Check the Terraform (needs `az login` and `terraform init` once, README step 2):

```powershell
terraform -chdir=github-runners/terraform validate
```

Lint the runner script, on the server because it has Nix:

```powershell
cmd /c "ssh github-runner nix run nixpkgs#shellcheck -- /dev/stdin < github-runners\nixos\runner-server.sh"
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
