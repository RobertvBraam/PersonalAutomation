# Home network

A Netgear R7800 on OpenWrt is the only router, plugged straight into the NTT GE-ONU (FLET'S Hikari, Xpass DS-Lite). Every device goes through NordVPN, with a kill switch: if the tunnel is down, nothing gets out. Every DNS lookup goes through the Pi-hole, including devices with their own DNS server set. Chosen sites (Reddit) skip the VPN.

| Part | Address | Login |
|---|---|---|
| Router (OpenWrt) | `192.168.0.1`, or `http://router.lan` | `ssh root@192.168.0.1` |
| Pi-hole | `192.168.0.175`, admin on `http://raspberrypi/admin` | `ssh user@raspberrypi` |

## Daily use

### On the router: `homenet`

Run from the laptop with `ssh root@192.168.0.1 "homenet status"`, or log in first.

| Command | What it does |
|---|---|
| `homenet status` | VPN server and last handshake, and whether the Pi-hole is in use |
| `homenet vpn off` / `on` | Turns the VPN off (traffic goes out directly) or back on |
| `homenet pihole off` / `on` | Lets the router answer DNS itself, or sends it back to the Pi-hole. Devices pick up the change when their DHCP lease renews or they reconnect |
| `homenet server jp1216.nordvpn.com` | Switches to another server from `/etc/vpn-servers` |
| `homenet failover now` | Moves to the next server in the list right away. Cron does this by itself after 5 minutes without a handshake |
| `homenet dns-bypass` | Lists devices that use their own DNS server (the router still sends their lookups to the Pi-hole) |

When the internet is down, start with `homenet status`.

### On the Pi-hole: `direct-sites`

Sites in this list skip the VPN. A domain covers its subdomains. Run from the laptop with `ssh -t user@raspberrypi direct-sites list`.

| Command | What it does |
|---|---|
| `direct-sites list` | Shows the sites that skip the VPN |
| `direct-sites add a.com b.com` | Adds sites. A pasted URL works: only the domain is kept |
| `direct-sites remove a.com` | Removes sites |

A site that still fails after adding it usually loads from other domains too (Reddit needs `reddit.com`, `redd.it`, `redditmedia.com` and `redditstatic.com`). The browser's developer tools, Network tab, show which domains a page uses. A browser may keep the old address for a minute.

## Setting it up again

Run the PowerShell commands from the root of this repository. PowerShell has no `<` redirect, so scripts go to the router through `cmd /c "ssh ... sh -s < file"`.

### 1. Gather

- **NordVPN WireGuard config** for one server, from Nord Account (manual setup). Take the private key from it, and use the per-server name (`jp1235.nordvpn.com`) with that server's public key. Ignore the `*.wg.nordhold.net` name in the file: it rotates between servers with different keys. Fallback servers and keys are in `r7800-extras.sh`.
- **OpenWrt factory image** for the R7800 from [firmware-selector.openwrt.org](https://firmware-selector.openwrt.org/?target=ipq806x%2Fgeneric&id=netgear_r7800), 25.12 or newer. Under "Customize installed packages", add `ds-lite luci-proto-wireguard`. Replacing `dnsmasq` with `dnsmasq-full` there as well saves step 5's install (untested; step 5 is the tested route).
- A copy of `router/r7800-setup.sh` **outside this repository**, with `NORD_PRIVATE_KEY` filled in. Check the other values at the top. Never commit the key.

### 2. Flash and reach the router

1. In the stock Netgear page, Advanced > Administration > Firmware Update, upload the factory image. After about 10 minutes the Netgear Wi-Fi and page are gone: that means it worked. OpenWrt starts on `192.168.1.1` with Wi-Fi off.
2. The laptop has no Ethernet port, so reach the R7800 through another router: R7800 **LAN** port to a LAN port of the router that serves your internet. Never the R7800 Internet port: OpenWrt closes its admin page there. Power-cycle the R7800.
3. In an admin PowerShell, give the laptop's Wi-Fi a second address next to its normal one:
   ```powershell
   netsh interface ipv4 set address name="Wi-Fi" static 192.168.0.215 255.255.255.0 192.168.0.1
   ```
   ```powershell
   netsh interface ipv4 add address name="Wi-Fi" 192.168.1.50 255.255.255.0
   ```
   ```powershell
   netsh interface ipv4 set dnsservers name="Wi-Fi" static 192.168.0.1 primary
   ```
4. Set a root password: `ssh root@192.168.1.1`, then `passwd`. After a reset, clear the old host key first with `ssh-keygen -R 192.168.1.1`.

### 3. Run the setup

```powershell
cmd /c "ssh root@192.168.1.1 sh -s < C:\path\to\your\r7800-setup.sh"
```

The router reboots onto `192.168.0.1`. **Unplug the cable between the two routers at once**: both now use `192.168.0.1`. Then put the laptop back on DHCP:

```powershell
netsh interface ipv4 set address name="Wi-Fi" dhcp
```
```powershell
netsh interface ipv4 set dnsservers name="Wi-Fi" dhcp
```

Delete your filled-in copy of the script.

### 4. Cut over

1. Switch the old router to access point mode with its DHCP server **off**, and plug it into an R7800 LAN port. The laptop stays on its Wi-Fi for now.
2. ONU into the R7800 Internet port. Pi-hole into an R7800 LAN port, then restart the Pi-hole.
3. In LuCI (`http://192.168.0.1`), Network > Wireless, on both radios: the same SSID and password as before, WPA2-PSK, country code `JP` (Advanced Settings), Enable, Save & Apply.
4. Unplug the old router. Devices reconnect to the same network name.

### 5. Extras and split tunnel

```powershell
cmd /c "ssh root@192.168.0.1 sh -s < home-network\router\r7800-extras.sh"
```
```powershell
ssh root@192.168.0.1 "apk -U add dnsmasq-full"
```
```powershell
cmd /c "ssh root@192.168.0.1 sh -s < home-network\router\r7800-direct-sites.sh"
```

### 6. Pi-hole

1. Install `direct-sites` and add Reddit:
   ```powershell
   scp home-network\pihole\direct-sites user@raspberrypi:/tmp/direct-sites
   ```
   ```powershell
   ssh -t user@raspberrypi "sudo install -m 755 /tmp/direct-sites /usr/local/bin/direct-sites && direct-sites add reddit.com redd.it redditmedia.com redditstatic.com"
   ```
2. Settings > DNS: upstream servers. NordVPN's `103.86.96.100` and `103.86.99.100` were the suggestion; the Pi-hole's own traffic goes through the VPN either way.
3. Settings > Local DNS Records: `router.lan` to `192.168.0.1`.
4. Optional, Lists: add `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/doh.txt` and update gravity, to block DNS-over-HTTPS by name.

The Pi-hole's DHCP stays off: the router hands out addresses and always gives the Pi `192.168.0.175` (fixed lease by MAC, set in `r7800-setup.sh`).

### 7. Check

| Check | Expected |
|---|---|
| `ssh root@192.168.0.1 "homenet status"` | VPN on, a recent handshake, Pi-hole on |
| `curl.exe -s https://ipinfo.io/org` | A NordVPN network (PacketHub), not ARTERIA or NTT |
| `ssh root@192.168.0.1 "ifdown vpn"`, open any site, then `ifup vpn` | Nothing loads while the VPN is down |
| `tracert -d -h 2 www.reddit.com` | Hop 2 is `192.0.0.1` (direct), not `10.5.0.1` (VPN) |

## Lessons from the first setup

| Symptom | Cause | Fix |
|---|---|---|
| Netgear firmware update "did nothing", Wi-Fi gone | It worked: OpenWrt starts with Wi-Fi off | Connect by cable through a LAN port (step 2) |
| R7800 page unreachable | Cable in its Internet port | Use a LAN port |
| LAN at `/32`, no DHCP | OpenWrt 25.12 stores the LAN address as CIDR | Fixed in `r7800-setup.sh` |
| No VPN handshake | NordVPN's `*.wg.nordhold.net` name rotates between servers with different keys | Use `jpNNNN.nordvpn.com` with its own key |
| Old router seemed to lose IPv4 | Two routers on `192.168.0.1` | Never connect them while both are routers |
| A direct site still goes through the VPN | fw4 puts a MARK rule without `dest` in `mangle_input` | Fixed in `r7800-direct-sites.sh` (`dest='*'`), which now checks the chain |
| Pi-hole rejects the new password, or says `app_sudo is false` | `pihole setpassword` did not take; not a full password login | On the Pi: `sudo pihole-FTL --config webserver.api.password 'temporary'`, log in, set a real one |
| Pi-hole web page cannot change `misc.dnsmasq_lines` | Only `pihole.toml` or `pihole-FTL --config` can | Use `direct-sites` |
| `pihole-FTL: not found` | Typed on the router | Pi-hole commands go on the Pi |
| Script fails with odd syntax errors | Windows line endings; BusyBox needs LF | `.gitattributes` pins LF for these folders |
| `scp` to the router fails | OpenWrt has no SFTP server | `scp -O`, or the `sh -s` form above |
| 130 Mbps through the VPN, 280/380 without | The R7800 CPU | Expected |

A firmware upgrade keeps the settings, `homenet` and the server list, but not added packages. Build the new image with `dnsmasq-full`: the stock dnsmasq cannot fill the split tunnel set and may refuse to start, taking DHCP down with it. After a factory reset, run everything from step 2 again.

Every known shortcut is marked in the scripts: `git grep -n "TODO: " -- home-network`.
