# PersonalAutomation
## Chocolatey
- Install Chocolatey by running the following command in Powershell: `Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))`
- Download the Chocolatey.config file
- To install all packages run: `cinst CONFIGFILELOCATION -y`
- For listing all Chocolatey installed programs: `clist --local-only`
## Cmder
The `CmderConfig.xml` file can be imported into the Cmder application and contains the following:
- Preferred console settings
- Git aliases
- Chocolatey aliases
- Some other handy personal aliases
