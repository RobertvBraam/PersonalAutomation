{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  # The repositories this machine runs jobs for. Each gets an unprivileged user
  # with a Docker daemon of its own and `count` runners, and every runner takes
  # one job in a fresh container. `labels` are what a workflow's `runs-on` asks
  # for. `volumes` are named volumes of that daemon, mounted in every runner of
  # the repository: what a job should find again in the next one. The job's
  # workspace is /_work/<runner>, removed before every job.
  repositories = {
    table-tab = {
      repository = "RobertvBraam/table-tab";
      # The CX33 has 4 vCPUs and 8 GB, and one PR gate alone starts a backend, a
      # dev server and four browsers.
      count = 2;
      labels = [ "tabletab" ];
      volumes = [
        "work:/_work"
        "toolcache:/opt/hostedtoolcache"
        "cache:/root/.cache"
        "nuget:/root/.nuget"
      ];
    };
  };

  # TODO: raised by hand. GitHub stops sending jobs to a runner version some
  # weeks after a newer one is out, which shows as runners that are online and
  # never get a job. Something that raises the pin by itself would remove the
  # chore (table-tab's Dependabot does it for the laptops' compose file).
  runnerImage = "myoung34/github-runner:2.338.2-ubuntu-resolute";

  # Where failures and the hourly sign of life go: TableTab's SigNoz, whose
  # alert rules post to Slack.
  otlpEndpoint = "https://otel.tabletab.app";

  # How long the nightly maintenance waits for running jobs before it gives up
  # for that night. Longer than a PR gate, shorter than the weekly mutation run.
  drainPatienceMinutes = 120;

  nixosRelease = "26.05";

  # Where the volume from ../terraform/main.tf is mounted: the one disk a
  # reinstall or a new server leaves alone.
  persist = "/persist";

  # One line, RUNNER_ACCESS_TOKEN=<token>, written to the volume once
  # (../README.md) and never to this repository, which is public. Only root
  # reads it: a runner container gets a registration for one job instead.
  # TODO: one token for every repository, so they all belong to one owner. A
  # repository of another owner needs a token file of its own.
  tokenFile = "${persist}/token.env";

  userOf = name: "runner-${name}";
  slotsOf = name: cfg: map (number: "github-runner-${name}-${toString number}") (lib.range 1 cfg.count);
  slotUnits = map (slot: "${slot}.service") (lib.concatLists (lib.mapAttrsToList slotsOf repositories));

  run = mode: "${pkgs.bash}/bin/bash ${./runner-server.sh} ${mode}";
  reportFailure = [ "runner-server-report@%N.service" ];

  # What every unit that runs runner-server.sh shares.
  serverService = {
    path = [
      config.virtualisation.docker.rootless.package
      pkgs.bash
      pkgs.curl
      pkgs.gh
      pkgs.jq
      pkgs.util-linux
    ];
    environment = {
      HOME = "/run/runner-server";
      OTLP_ENDPOINT = otlpEndpoint;
    };
    serviceConfig = {
      RuntimeDirectory = "runner-server";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
    };
  };

  # One runner. It ends with its job and starts again for the next one. A
  # changed definition is not applied under a running job: it takes effect when
  # the runner starts again.
  slotService =
    name: cfg: slot:
    lib.nameValuePair slot (
      lib.mkMerge [
        serverService
        {
          description = "GitHub Actions runner for ${cfg.repository}, one job per container";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          onFailure = reportFailure;
          restartIfChanged = false;
          startLimitIntervalSec = 0;
          unitConfig.RequiresMountsFor = persist;
          environment = {
            REPOSITORY = cfg.repository;
            RUNNER_USER = userOf name;
            RUNNER_NAME = slot;
            RUNNER_LABELS = lib.concatStringsSep "," cfg.labels;
            RUNNER_VOLUMES = lib.concatStringsSep " " cfg.volumes;
            RUNNER_IMAGE = runnerImage;
          };
          serviceConfig = {
            EnvironmentFile = tokenFile;
            ExecStart = run "slot";
            Restart = "on-success";
            RestartSec = 2;
          };
        }
      ]
    );
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  system.stateVersion = nixosRelease;
  networking.hostName = "github-runner";
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Hetzner's x86 types boot through BIOS (the 1M partition). The ESP is there
  # so the same layout also boots a type that uses UEFI.
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
        };
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # The volume gets a name that does not carry its Hetzner id, so a replaced
  # volume needs no change here. An empty one is formatted on its first mount.
  # Without the volume the machine still boots and takes SSH, and the runner
  # services refuse to start.
  # TODO: the rule matches any Hetzner volume, which is right while the server
  # has one. A second volume needs the match narrowed to this one's id
  # (ID_SCSI_SERIAL).
  services.udev.extraRules = ''
    SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_VENDOR}=="HC", ENV{ID_MODEL}=="Volume", SYMLINK+="persist-volume"
  '';
  fileSystems.${persist} = {
    device = "/dev/persist-volume";
    fsType = "ext4";
    autoFormat = true;
    options = [
      "nofail"
      "x-systemd.device-timeout=30s"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # A repository's jobs run as its own user and reach nothing of root's: not
  # the token, not another repository's containers. The user's manager starts
  # at boot (linger) and runs that user's Docker daemon.
  # TODO: one daemon per repository, so a job can leave a container behind that
  # reaches a later job of the same repository, until the night removes it. A
  # daemon per runner would close that, at the price of an image store each.
  users.groups = lib.mapAttrs' (name: _: lib.nameValuePair (userOf name) { }) repositories;
  users.users =
    lib.mapAttrs' (
      name: _:
      lib.nameValuePair (userOf name) {
        isSystemUser = true;
        group = userOf name;
        home = "/var/lib/${userOf name}";
        createHome = true;
        autoSubUidGidRange = true;
        linger = true;
      }
    ) repositories
    // {
      root.openssh.authorizedKeys.keyFiles = [ ./admin.pub ];
    };
  virtualisation.docker.rootless.enable = true;

  # What NixOS loads for a root Docker daemon. This machine has none, and a
  # daemon without root cannot be counted on to get them loaded itself.
  boot.kernelModules = [
    "bridge"
    "veth"
    "br_netfilter"
    "xt_nat"
  ];

  zramSwap.enable = true;

  # The night, 04:00 in Japan. First the newest system is built from this
  # repository's master on the newest commit of the NixOS release branch and
  # made the one to boot ("boot", so nothing changes under a running job). When
  # that worked, the maintenance lets the running jobs finish, removes every
  # container, image and volume, and reboots into the new system. A build that
  # fails leaves the machine as it was, with no reboot.
  system.autoUpgrade = {
    enable = true;
    operation = "boot";
    dates = "*-*-* 04:00:00 Asia/Tokyo";
    flake = "github:RobertvBraam/PersonalAutomation?dir=github-runners/nixos#github-runner";
    flags = [
      "--override-input"
      "nixpkgs"
      "github:NixOS/nixpkgs/nixos-${nixosRelease}"
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  systemd.services = lib.mkMerge [
    (lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (name: cfg: map (slotService name cfg) (slotsOf name cfg)) repositories
      )
    ))
    {
      nixos-upgrade = {
        onSuccess = [ "runner-server-maintenance.service" ];
        onFailure = reportFailure;
      };

      runner-server-check = lib.mkMerge [
        serverService
        {
          description = "Hourly check of the runners: start the failed ones, report a sign of life";
          startAt = "hourly";
          onFailure = reportFailure;
          environment.SLOT_UNITS = lib.concatStringsSep " " slotUnits;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = run "check";
          };
        }
      ];

      runner-server-maintenance = lib.mkMerge [
        serverService
        {
          description = "Nightly clean start of the runners: drain, wipe, reboot";
          onFailure = reportFailure;
          unitConfig = {
            RequiresMountsFor = persist;
            SuccessAction = "reboot";
          };
          environment = {
            SLOT_UNITS = lib.concatStringsSep " " slotUnits;
            RUNNER_USERS = lib.concatStringsSep " " (map userOf (lib.attrNames repositories));
            DRAIN_PATIENCE_MINUTES = toString drainPatienceMinutes;
          };
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = tokenFile;
            ExecStart = run "maintain";
          };
        }
      ];

      "runner-server-report@" = lib.mkMerge [
        serverService
        {
          description = "Reports the failed unit %i to SigNoz";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = run "report %i";
          };
        }
      ];
    }
  ];
}
