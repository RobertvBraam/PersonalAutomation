{ modulesPath, pkgs, ... }:

let
  repository = "RobertvBraam/table-tab";

  # Jobs that run at the same time. The CX33 has 4 vCPUs and 8 GB, and one PR
  # gate alone starts a backend, a dev server and four browsers.
  runnerCount = 2;

  nixosRelease = "26.05";
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

  # Every night (03:00 in Japan) the machine rebuilds itself from this
  # repository's master on the newest commit of the NixOS release branch, so a
  # merged change and security patches both arrive without anyone logging in.
  # TODO: a new kernel only takes effect after a reboot, and nothing reboots the
  # machine because that would abandon running jobs. Reboot by hand when it is
  # idle; allowReboot with a window would do it once jobs can be drained first.
  system.autoUpgrade = {
    enable = true;
    dates = "18:00";
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

  # The token file holds one line, RUNNER_ACCESS_TOKEN=<token>, and is copied to
  # the machine by hand (../README.md): this repository is public.
  # TODO: a token in a root-only file is the whole secret handling. sops-nix or
  # agenix would keep it encrypted in the repository and survive a reinstall.
  systemd.services.tabletab-runners = {
    description = "TableTab GitHub Actions runners, from table-tab's own compose file";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    startAt = "hourly";
    path = with pkgs; [
      bash
      coreutils
      docker
      findutils
      gh
      git
      gnugrep
      gnused
    ];
    environment = {
      HOME = "/var/lib/tabletab-runners";
      REPOSITORY = repository;
      RUNNER_COUNT = toString runnerCount;
      RUNNER_AUTO_LABEL = "false";
      GIT_CONFIG_COUNT = "1";
      GIT_CONFIG_KEY_0 = "credential.helper";
      GIT_CONFIG_VALUE_0 = "!gh auth git-credential";
    };
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "tabletab-runners";
      StateDirectoryMode = "0700";
      EnvironmentFile = "/var/lib/tabletab-runners/token.env";
      ExecStart = "${pkgs.bash}/bin/bash ${./tabletab-runners.sh}";
    };
  };
}
