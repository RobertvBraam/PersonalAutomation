# PersonalAutomation
## Chocolatey
- Install Chocolatey by running the following command in Powershell: `Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))`
- Download the `Chocolatey.config` file
- To install all packages run: `choco install CONFIGFILELOCATION -y`
- For listing all installed packages: `choco list`
- For finding a new package: `choco find YOURPACKAGENAME`
- For getting more details about a single package: `choco find YOURPACKAGENAME -e --detail`
## Cmder
The `CmderConfig.xml` file can be imported into the Cmder application and contains the following:
- Preferred console settings
- Git aliases
- Chocolatey aliases
- Some other handy personal aliases
## GitHub runners
A Hetzner Cloud server on NixOS that runs the GitHub Actions runners for TableTab (Terraform for the server, a Nix flake for the system). See [github-runners/README.md](github-runners/README.md) for daily use and how to set it up again.
## Home network
Scripts for the home router (Netgear R7800 on OpenWrt: NordVPN with a kill switch, DNS forced through the Pi-hole) and the Pi-hole. See [home-network/README.md](home-network/README.md) for daily use and how to set it up again.
