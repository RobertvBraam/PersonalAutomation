# PersonalAutomation
## Chocolatey
- Install Chocolatey by running the following command in Powershell: `Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))`
- Download the Chocolatey.config file
- To install all packages run: `cinst CONFIGFILELOCATION -y`
- For listing all Chocolatey installed programs: `clist --local-only`
## Cmder
Contains the following:
- Preferred console settings
- Git aliases
- Chocolatey aliases
- Some other handy personal aliases
