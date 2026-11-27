# GitHub runners

One Hetzner Cloud server on NixOS that runs the GitHub Actions runners for [TableTab](https://github.com/RobertvBraam/table-tab), so its CI does not wait for a laptop to be awake. It can serve more repositories: each is an entry in a list. Every job gets a fresh container, on a Docker daemon that belongs to its runner alone and has no root on the server.

| Part | What it is |
|---|---|
| Server | `github-runner`, a CX33 (4 vCPU, 8 GB, 80 GB) in Nuremberg, EUR 8.49 a month. Find its address with `terraform output` (below) |
| Volume | `github-runner-persist`, 10 GB, EUR 0.57 a month, mounted at `/persist`. The one disk a reinstall or a new server leaves alone. It holds the runners' GitHub token |
| `terraform/` | Claims the server and the volume: a stock image, the admin SSH key and a firewall that lets only SSH and ping in. State is in Azure Storage |
| `nixos/` | The system that replaces the stock image: `configuration.nix` with the list of repositories, and `runner-server.sh`, the script its units run |
| Runners | Two for TableTab, labelled `tabletab`, next to whatever runs on a laptop. GitHub gives a job to any idle one |

## How it works

Nothing here ever stops a runner that is running a job, and nothing from a repository runs outside a runner container.

- **A repository is an entry in a list** (`repositories` in `nixos/configuration.nix`): its name, how many runners, their labels, and the volumes a job should find again in the next one. Each runner is an unprivileged user on the server with a Docker daemon of its own.
- **A runner takes one job.** `github-runner-<repository>-<number>.service` asks GitHub for a registration that is good for one job, starts a fresh container with it on its own daemon, and starts again when the job is done. What the job before left running is removed first, and so is its workspace; the volumes stay.
- **The token stays with root.** Only the one-job registration enters a container. A job can read it, and it is worth nothing once that job is over.
- **A job can start containers of its own**, on its runner's daemon. They run as that runner's user and share its network, so `127.0.0.1` is the job's own, as on a GitHub-hosted runner: two jobs that listen on the same port do not meet. They reach nothing of the server's and nothing of another runner's.
- **A runner that fails stays down and says so.** A runner, the hourly check, the nightly build and the nightly clean start each send a span to SigNoz when they fail, and an alert rule in table-tab posts it to Slack. Every hour `runner-server-check` starts the failed runners again and sends a sign of life; a second rule fires when none arrived for two hours.
- **Every night at 04:00 in Japan** (19:00 UTC) the server starts clean. It builds its newest system from this repository's `master` on the newest commit of the NixOS release branch. Then it takes the runners down one by one: it deletes an idle runner's registration, which GitHub refuses while a job is assigned to it, and only then stops it. It waits up to two hours for the busy ones, removes every container, image and volume, and reboots into the new system. A build that fails leaves the machine as it was, and a job that outlasts the two hours skips that night.
- **Routing is the repository's.** A job lands here when its `runs-on` names a label of these runners. For TableTab that is the repository variables `RUNNER_LABEL` and `GATE_RUNNER_LABEL`, both `tabletab`. The server never reads or changes them.

So a merged change to `nixos/` deploys itself the next night, and the first jobs of the day download their images and tools again (the .NET SDK, Node, packages, browsers).

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
| The runners, and whether one failed | `ssh github-runner "systemctl status 'github-runner-*' --no-pager"` |
| What a runner printed | `ssh github-runner "journalctl -u github-runner-table-tab-1 -n 50 --no-pager"` |
| Did the last hourly check work, and when is the next | `ssh github-runner "systemctl status runner-server-check.service runner-server-check.timer"` |
| How last night went | `ssh github-runner "journalctl -u nixos-upgrade -u runner-server-maintenance --since yesterday --no-pager"` |
| A runner's containers | `ssh github-runner 'docker -H unix:///run/user/$(id -u runner-table-tab-1)/docker.sock ps'` |
| Is the volume mounted | `ssh github-runner "findmnt /persist"` |
| Start the failed runners again now | `ssh github-runner "systemctl start runner-server-check"` |
| Clean start now: wait for jobs, wipe, reboot | `ssh github-runner "systemctl start --no-block runner-server-maintenance"` |
| The whole night now: new system, then the clean start | `ssh github-runner "systemctl start --no-block nixos-upgrade"` |
| Apply a merged change to `nixos/` now, without a reboot | `ssh github-runner "nixos-rebuild switch --refresh --flake 'github:RobertvBraam/PersonalAutomation?dir=github-runners/nixos#github-runner'"` |

A change applied by hand reaches a runner when it starts its next job, never under a running one. There are two exceptions, so let the night do these: a change that takes a runner away (a lower `count`, a repository removed) stops that runner at once, job or not, and a change to Docker itself (a new version, its settings) restarts every runner's Docker with the job in it.

What GitHub sees, from the laptop:

```powershell
gh api repos/RobertvBraam/table-tab/actions/runners --jq ".runners[] | [.name, .status, (.busy|tostring), (.labels | map(.name) | tostring)] | @tsv"
```

A runner is away from that list for a few seconds between two jobs: it registers again for each one. When jobs stay queued, start with `systemctl status 'github-runner-*'`: a failed runner names what is wrong, and an expired token is the usual cause. "Dependency failed" means the volume is not mounted.

## Changing it

| To change | Edit |
|---|---|
| Which repositories | An entry in `repositories` in `nixos/configuration.nix`. The token must cover it (step 1), and its workflows must ask for one of its `labels` |
| How many jobs of a repository run at once | Its `count` |
| What a job finds again in the next one on the same runner | Its `volumes` |
| The runner image and version | `runnerImage` in `nixos/configuration.nix` |
| Where failures are reported | `otlpEndpoint` in `nixos/configuration.nix` |
| How long the night waits for running jobs | `drainPatienceMinutes` in `nixos/configuration.nix` |
| When the night starts | `dates` under `system.autoUpgrade` in `nixos/configuration.nix` |
| The NixOS release | `nixosRelease` in `nixos/configuration.nix` and the `nixpkgs` input in `nixos/flake.nix` |
| Server size | `server_type` in `terraform/main.tf` |
| Location | `location` in `terraform/main.tf`. It replaces the server, and the volume cannot follow: Terraform refuses until `prevent_destroy` and `delete_protection` are off the volume, and the new volume needs step 4 again |

Never attach this server to a public repository: a pull request from a stranger would then run its code here.

## Setting it up again

Run the PowerShell commands from the root of this repository. Docker Desktop must be running: it provides Nix, which Windows does not have.

### 1. Tokens and logins

Neither token goes into this repository. Both are stored as user environment variables, replacing `<token>`:

- **Hetzner**: in the [Hetzner Console](https://console.hetzner.cloud/), the project, Security, API tokens, a Read & Write token.
  ```powershell
  [Environment]::SetEnvironmentVariable('HCLOUD_TOKEN', '<token>', 'User')
  ```
- **GitHub**: a [fine-grained token](https://github.com/settings/personal-access-tokens/new) for the repositories in the list and no other, with Administration: Read and write (to register runners and remove their registrations) and nothing else.
  ```powershell
  [Environment]::SetEnvironmentVariable('TABLETAB_RUNNER_TOKEN', '<token>', 'User')
  ```

Open a new terminal afterwards, so it sees them. The Terraform state is in Azure Storage (account `tabletapinfra`, container `personal-automation`), so Terraform also needs `az login`.

That account keeps every earlier version of a state (the blob's versions in the Azure portal) and carries a lock that refuses to delete it. TableTab's state shares both. They were set by hand, once, and only an account that is created again needs them again:

```powershell
az storage account blob-service-properties update --account-name tabletapinfra --resource-group infrastructure --enable-versioning true
```

```powershell
az lock create --name terraform-state --lock-type CanNotDelete --resource-group infrastructure --resource-name tabletapinfra --resource-type Microsoft.Storage/storageAccounts
```

### 2. Claim the server

```powershell
terraform -chdir=github-runners/terraform init
```

```powershell
terraform -chdir=github-runners/terraform apply
```

The apply creates whatever is missing: the server, the volume, or both. A server that was lost comes back next to the volume that is still there.

CX stock comes and goes per location. When the apply fails with `resource_unavailable` and no volume exists yet, try the others: `-var location=fsn1` or `-var location=hel1`, then set that location as the default in `main.tf`, because a later apply with another location replaces the server. Once the volume exists, the server has to come back in the volume's location.

The admin key (`nixos/admin.pub`, the public half of `C:\Users\Robert\.ssh\hetzner_ed25519`) must already be uploaded to the Hetzner project. TableTab's Terraform uploads it as `signoz-admin-prod`; in an empty project, add it by hand under Security, SSH keys.

### 3. Install NixOS

[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) boots an installer on the server, partitions the disk and installs the system from `nixos/`. **It erases the server's system disk** (`/dev/sda`). The volume is not part of the layout it writes, so the token on it stays. It runs from a Nix container and builds on the server itself.

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

Only for a new volume or a new token. The token lives on the volume, so a reinstalled or replaced server finds it there and starts its runners by itself.

The `mountpoint` check stops the command when the volume is not mounted, so the token cannot land on the system disk. The `tr` keeps only the characters a token line can hold, which drops the byte-order mark and the Windows line ending that PowerShell adds to a pipe.

```powershell
"RUNNER_ACCESS_TOKEN=$([Environment]::GetEnvironmentVariable('TABLETAB_RUNNER_TOKEN', 'User'))" | ssh github-runner "mountpoint /persist && umask 077 && tr -cd 'A-Za-z0-9_=\n' > /persist/token.env"
```

```powershell
ssh github-runner "systemctl start runner-server-check"
```

That starts the runners that failed for want of a token. On a fresh server a runner's first start takes a minute or two, because it pulls the runner image. `systemctl status 'github-runner-*'` shows them, and GitHub lists them online.

### 5. Route jobs to it

Only when the variables are not already `tabletab`:

```powershell
gh variable set RUNNER_LABEL --repo RobertvBraam/table-tab --body tabletab
```

```powershell
gh variable set GATE_RUNNER_LABEL --repo RobertvBraam/table-tab --body tabletab
```

### Reinstalling the server that is running

Step 3 alone, with a command before it and one after. The token stays on the volume, so the fresh system starts its runners by itself, about a minute after its first boot. Count on ten minutes without the server's runners.

Before step 3, let running jobs finish and stop the runners. This is the nightly clean start without its reboot, and it waits up to two hours for jobs:

```powershell
ssh github-runner "mkdir -p /run/systemd/system/runner-server-maintenance.service.d && printf '[Unit]\nSuccessAction=none\n' > /run/systemd/system/runner-server-maintenance.service.d/no-reboot.conf && systemctl daemon-reload && systemctl start runner-server-maintenance"
```

If you do not reinstall after all, reboot the server: that brings the runners and the nightly reboot back.

After step 3 the server has a new host key, so forget the old one before the first login, with the server's address:

```powershell
ssh-keygen -R <address>
```

## Good to know

- **A job has no root here.** It runs as its runner's user. It reaches that runner's images and volumes, and through those the next job on the same runner, until the night removes them. It reaches nothing else on the server: not the token, not root's files, not another runner's containers or ports.
- **Deploy jobs run here too.** Every TableTab job routes by label, so the Azure and Terraform credentials of a deploy pass through this machine, inside a runner's container (table-tab's `ci-runners` skill, "What the user should know").
- **A container a job starts does not see the job's files**: the workspace lives in the runner's container, not on the server. So a workflow's `container:` and `services:` and Docker container actions are not expected to work, and were not tried.
- **A port a job listens on or publishes** (TableTab's backend, its screenshot browser) exists in its runner's network only. It does not answer on the server itself or in another runner, so two runners can use the same port at once.
- **A runner's traffic goes through a network in user space** (slirp4netns), not straight through the server's own. That is slower; how much was not measured.
- **Each runner keeps its own images and caches**, about 7 GB of images for one TableTab runner, and each downloads them again after the night.
- **A failed runner is away for up to an hour.** It reports once, and the hourly check starts it again.
- **A job longer than two hours blocks that night's clean start** and reports that night as failed, and the runners that were idle stay down while the night waits. TableTab's weekly mutation run is one: it starts on Friday at 17:23 UTC, before the night does.
- **Only IPv4 is configured.** The runners dial out and nothing dials in but SSH.
- **The token is plain text on the volume**, readable by root only. Whoever has the Hetzner project can read it too, by attaching the volume to another server.
- **Without the volume the server still boots and takes SSH**, and the runner services refuse to start. Nothing else is kept on the volume: the images and the caches are wiped every night on purpose.

## Known shortcuts

`git grep -n "TODO: " -- github-runners` lists them where they live:

- The system finds the volume as "the Hetzner volume", which is right while the server has one. A second volume needs the rule in `nixos/configuration.nix` narrowed to this one's id.
- The runner image is raised by hand. GitHub stops sending jobs to a runner version some weeks after a newer one is out, which shows as runners that are online and never get a job.
- One token serves every repository, so they all belong to one owner.
- Images and volumes stay between the jobs of one runner, so a job can leave a changed image or cache for the next one, until the night removes them.
- A failed runner waits for the hourly check before it starts again.
- Taking a runner down rests on GitHub refusing to delete the registration of a busy runner, which GitHub does not document as a guarantee. The look for a running job afterwards does not catch a job assigned in the same second.
- The versioning and the delete lock on the state's storage account were set by hand (step 1), because no Terraform owns that account. An account that is created again comes back without them.
