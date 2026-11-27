{ modulesPath, pkgs, ... }:

let
  repository = "RobertvBraam/table-tab";

  # Jobs that run at the same time. The CX33 has 4 vCPUs and 8 GB, and one PR
  # gate alone starts a backend, a dev server and four browsers.
  runnerCount = 2;

  # How long the nightly maintenance waits for running jobs before it gives up
  # for that night. Longer than a PR gate, shorter than the weekly mutation run.
  drainPatienceMinutes = 120;

  nixosRelease = "26.05";

  # The token file holds one line, RUNNER_ACCESS_TOKEN=<token>, and is copied to
  # the machine by hand (../README.md): this repository is public.
  # TODO: a token in a root-only file is the whole secret handling. sops-nix or
  # agenix would keep it encrypted in the repository and survive a reinstall.
  tokenFile = "/var/lib/tabletab-runners/token.env";

  # The two modes of tabletab-runners.sh share everything but their trigger.
  runnerService = mode: {
    requires = [ "docker.service" ];
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash
      docker
      gh
      git
      util-linux
    ];
    environment = {
      HOME = "/var/lib/tabletab-runners";
      REPOSITORY = repository;
      RUNNER_COUNT = toString runnerCount;
      DRAIN_PATIENCE_MINUTES = toString drainPatienceMinutes;
      GIT_CONFIG_COUNT = "1";
      GIT_CONFIG_KEY_0 = "credential.helper";
      GIT_CONFIG_VALUE_0 = "!gh auth git-credential";
    };
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "tabletab-runners";
      StateDirectoryMode = "0700";
      EnvironmentFile = tokenFile;
      ExecStart = "${pkgs.bash}/bin/bash ${./tabletab-runners.sh} ${mode}";
    };
  };
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

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [ ./admin.pub ];

  virtualisation.docker.enable = true;
  zramSwap.enable = true;

  # The night, 04:00 in Japan. First the newest system is built from this
  # repository's master on the newest commit of the NixOS release branch and
  # made the one to boot ("boot", so nothing changes under a running job). When
  # that worked, the maintenance lets the running jobs finish, removes every
  # container, image, volume and checkout, and reboots into the new system. A
  # build that fails leaves the machine as it was, with no reboot.
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
  systemd.services.nixos-upgrade.onSuccess = [ "tabletab-runners-maintenance.service" ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  systemd.services.tabletab-runners = runnerService "sync" // {
    description = "TableTab GitHub Actions runners, following table-tab's master";
    wantedBy = [ "multi-user.target" ];
    startAt = "hourly";
  };

  systemd.services.tabletab-runners-maintenance = runnerService "maintain" // {
    description = "Nightly clean start of the TableTab runners: drain, wipe, reboot";
    unitConfig.SuccessAction = "reboot";
  };
}
