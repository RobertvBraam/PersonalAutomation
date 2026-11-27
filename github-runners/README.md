# GitHub runners

One Hetzner Cloud server on NixOS that runs the GitHub Actions runners for [TableTab](https://github.com/RobertvBraam/table-tab), so its CI does not wait for a laptop to be awake. The runners are the same Docker containers `pnpm runner:up` starts on a laptop: the server takes table-tab's own compose file from `master`, so the runner image and the Playwright browser follow that repository with no copy here.

| Part | What it is |
|---|---|
| Server | `github-runner`, a CX33 (4 vCPU, 8 GB, 80 GB) in Nuremberg, EUR 8.49 a month. Find its address with `terraform output` (below) |
| `terraform/` | Claims the server: a stock image, the admin SSH key and a firewall that lets only SSH and ping in. State is in Azure Storage |
| `nixos/` | The system that replaces the stock image: `configuration.nix`, and the script its two runner services run |
| Runners | Two, labelled `tabletab`, next to whatever runs on a laptop. GitHub gives a job to any idle one |

## How it works

Nothing here ever stops a runner that is running a job.

- **Every hour** (and at boot) `tabletab-runners.service` fetches table-tab's `master`. When what the runners are built from changed there (the `.github/runner` folder, `scripts/runner.sh`, the Playwright version in `tests/e2e/pnpm-lock.yaml`), it replaces the runners with `scripts/runner.sh down` and `up 2`. When nothing changed it only makes sure they are up.
- **Before it replaces them, it takes them out of rotation.** It removes the `tabletab` label from the server's runners on GitHub, so they get no new job while a running one carries on. If a job is running, the change waits for the next hour and the labels go back. A run that dies half way leaves a note, and the next run puts the labels back.
- **Every night at 04:00 in Japan** (19:00 UTC) the server starts clean. It builds its newest system from this repository's `master` on the newest commit of the NixOS release branch. Then it takes the runners out of rotation, waits up to two hours for running jobs, removes every container, image, volume and its table-tab checkout, and reboots into the new system. At boot the hourly service brings fresh runners up. A build that fails leaves the machine as it was, and a job that outlasts the two hours skips that night.
- **Routing is not the server's business.** The repository variables `RUNNER_LABEL` and `GATE_RUNNER_LABEL` decide where jobs go, and the server never touches them. Both must be `tabletab` for jobs to land here.

So a merged change to `nixos/` deploys itself the next night, and the first jobs of the day download their tools again (the .NET SDK, Node, packages, browsers).

## Daily use

Add the server to `C:\Users\Robert\.ssh\config` once, with the address from `terraform -chdir=github-runners/terraform output -raw ipv4`:

```
Host github-runner
    HostName <address>
    User root
    IdentityFile C:\Users\Robert\.ssh\hetzner_ed25519
    IdentitiesOnly yes
```

| What | Command |
|---|---|
| Did the last hourly run work, and when is the next | `ssh github-runner "systemctl status tabletab-runners.service tabletab-runners.timer"` |
| What the last runs printed | `ssh github-runner "journalctl -u tabletab-runners -n 80 --no-pager"` |
| How last night went | `ssh github-runner "journalctl -u nixos-upgrade -u tabletab-runners-maintenance --since yesterday --no-pager"` |
| The containers | `ssh github-runner "docker ps"` |
| What a runner is doing | `ssh github-runner "docker compose -p tabletab-runner logs --tail 50 runner"` |
| Run the hourly check now | `ssh github-runner "systemctl start tabletab-runners"` |
| Clean start now: wait for jobs, wipe, reboot | `ssh github-runner "systemctl start --no-block tabletab-runners-maintenance"` |
| The whole night now: new system, then the clean start | `ssh github-runner "systemctl start --no-block nixos-upgrade"` |
| Apply a merged change to `nixos/` now, without a reboot | `ssh github-runner "nixos-rebuild switch --refresh --flake 'github:RobertvBraam/PersonalAutomation?dir=github-runners/nixos#github-runner'"` |

What GitHub sees, from the laptop:

```powershell
gh api repos/RobertvBraam/table-tab/actions/runners --jq ".runners[] | [.name, .status, (.busy|tostring), (.labels | map(.name) | tostring)] | @tsv"
```

A server runner that is online without the `tabletab` label is out of rotation on purpose: at night, or for a few seconds while the hourly run checks for a running job. When jobs stay queued, start with `systemctl status tabletab-runners`: a failed run names what is wrong, and an expired token is the usual cause.

## Changing it

| To change | Edit |
|---|---|
| How many jobs run at once | `runnerCount` in `nixos/configuration.nix` |
| How long the night waits for running jobs | `drainPatienceMinutes` in `nixos/configuration.nix` |
| When the night starts | `dates` under `system.autoUpgrade` in `nixos/configuration.nix` |
| Which repository | `repository` in `nixos/configuration.nix`. It must have table-tab's `scripts/runner.sh` |
| The NixOS release | `nixosRelease` in `nixos/configuration.nix` and the `nixpkgs` input in `nixos/flake.nix` |
| Server size or location | `server_type` and `location` in `terraform/main.tf`. A new location replaces the server |

Never attach this server to a public repository: a pull request from a stranger would then run its code here.

## Setting it up again

Run the PowerShell commands from the root of this repository. Docker Desktop must be running: it provides Nix, which Windows does not have.

### 1. Tokens and logins

Neither token goes into this repository. Both are stored as user environment variables, replacing `<token>`:

- **Hetzner**: in the [Hetzner Console](https://console.hetzner.cloud/), the project, Security, API tokens, a Read & Write token.
  ```powershell
  [Environment]::SetEnvironmentVariable('HCLOUD_TOKEN', '<token>', 'User')
  ```
- **GitHub**: a [fine-grained token](https://github.com/settings/personal-access-tokens/new) for `RobertvBraam/table-tab` only, with Administration: Read and write (to register runners and take them out of rotation) and Contents: Read-only (to fetch the compose file).
  ```powershell
  [Environment]::SetEnvironmentVariable('TABLETAB_RUNNER_TOKEN', '<token>', 'User')
  ```

Open a new terminal afterwards, so it sees them. The Terraform state is in Azure Storage (account `tabletapinfra`, container `personal-automation`), so Terraform also needs `az login`.

### 2. Claim the server

```powershell
terraform -chdir=github-runners/terraform init
```

```powershell
terraform -chdir=github-runners/terraform apply
```

CX stock comes and goes per location. When the apply fails with `resource_unavailable`, try the others: `-var location=fsn1` or `-var location=hel1`, then set that location as the default in `main.tf`, because a later apply with another location replaces the server.

The admin key (`nixos/admin.pub`, the public half of `C:\Users\Robert\.ssh\hetzner_ed25519`) must already be uploaded to the Hetzner project. TableTab's Terraform uploads it as `signoz-admin-prod`; in an empty project, add it by hand under Security, SSH keys.

### 3. Install NixOS

[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) boots an installer on the server, partitions the disk and installs the system from `nixos/`. **It erases the server's disk.** It runs from a Nix container and builds on the server itself.

The installer gets a throwaway key, so the real one never enters a container that runs downloaded code. Replace `<address>` with the server's address in the second and third command:

```powershell
ssh-keygen -q -t ed25519 -N '""' -f C:\Users\Robert\.ssh\runner-install-throwaway
```

```powershell
cmd /c "ssh -i C:\Users\Robert\.ssh\hetzner_ed25519 root@<address> tee -a /root/.ssh/authorized_keys < C:\Users\Robert\.ssh\runner-install-throwaway.pub"
```

```powershell
docker run --rm -e "NIX_CONFIG=experimental-features = nix-command flakes" -v "${PWD}\github-runners\nixos:/flake" -v "C:\Users\Robert\.ssh\runner-install-throwaway:/key:ro" nixos/nix sh -c "install -m 600 /key /root/key && nix run github:nix-community/nixos-anywhere/1.13.0 -- --flake /flake#github-runner --build-on remote -i /root/key root@<address>"
```

After about ten minutes the server reboots into NixOS with a new host key, and only the admin key gets in. Delete the throwaway key and add the `Host github-runner` entry from "Daily use":

```powershell
Remove-Item C:\Users\Robert\.ssh\runner-install-throwaway, C:\Users\Robert\.ssh\runner-install-throwaway.pub
```

### 4. Give it the GitHub token

The `tr` keeps only the characters a token line can hold, which drops the byte-order mark and the Windows line ending that PowerShell adds to a pipe.

```powershell
"RUNNER_ACCESS_TOKEN=$([Environment]::GetEnvironmentVariable('TABLETAB_RUNNER_TOKEN', 'User'))" | ssh github-runner "umask 077; mkdir -p /var/lib/tabletab-runners; tr -cd 'A-Za-z0-9_=\n' > /var/lib/tabletab-runners/token.env"
```

```powershell
ssh github-runner "systemctl start tabletab-runners"
```

The first run takes about a minute: it pulls the runner image and the Playwright image. It ends without an error once GitHub sees the runners online. Replacing an expired token is this same step.

### 5. Route jobs to it

Only when the variables are not already `tabletab`:

```powershell
gh variable set RUNNER_LABEL --repo RobertvBraam/table-tab --body tabletab
```

```powershell
gh variable set GATE_RUNNER_LABEL --repo RobertvBraam/table-tab --body tabletab
```

## Good to know

- **Whoever can push to table-tab's `master` controls this server.** The hourly run executes that repository's `scripts/runner.sh` as root. That is the price of following the compose file without a copy; the jobs themselves already run whatever a workflow says.
- **Deploy jobs run here too.** Every TableTab job routes by label, so the Azure and Terraform credentials of a deploy pass through this machine (table-tab's `ci-runners` skill, "What the user should know").
- **Jobs cannot use Docker**, exactly as on a laptop runner: the runner is a container without the Docker socket.
- **A job longer than two hours blocks that night's clean start**, and the server takes no new job while the night waits for it.
- **Only IPv4 is configured.** The runners dial out and nothing dials in but SSH.

## Known shortcuts

`git grep -n "TODO: " -- github-runners` lists them where they live:

- The GitHub token is a root-only file on the server, copied by hand. A reinstall needs step 4 again.
- The hourly run knows which three paths in table-tab the runners are built from. If `scripts/runner.sh` starts reading a fourth, the copy here has to follow.
- After taking the runners out of rotation, the script waits 15 seconds before it trusts that no job is on its way. That number is a guess.
