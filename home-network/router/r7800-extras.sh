#!/bin/sh
set -eu

fail() {
	echo "$*" >&2
	exit 1
}

require_main_setup() {
	uci -q get network.nordvpn >/dev/null || fail "Run r7800-setup.sh first: the VPN is not configured."
	uci -q get firewall.dns_to_pihole >/dev/null || fail "Run r7800-setup.sh first: the Pi-hole redirect is missing."
}

install_server_list() {
	# TODO: a snapshot of NordVPN servers taken on 2026-11-24. A server NordVPN retires has to be replaced by hand; regenerating the list from the NordVPN API would keep it current.
	cat > /etc/vpn-servers <<'EOF'
jp1235.nordvpn.com rd9H/PbVpOe7I8AJqhJI8sclbVE2JLfvK6am5ITOu00=
jp1216.nordvpn.com 1Y32vdalForT9kNrRsi7qaI0TM4cX154LI9+EgorbHk=
jp1240.nordvpn.com GkcZpq6cht6x1mTaTUwjGnquHWeiwKRDLSpUXFvBcQk=
jp721.nordvpn.com 808LcKcbIJeUC4B/R4HWnVlbWpB5CgG1m4T94fdq5UE=
jp814.nordvpn.com Hh52ICXLUXxvYYQOWQfwbdqkLjixeoviIcJGuQ2+ZAs=
EOF
}

install_homenet() {
	cat > /usr/bin/homenet <<'EOF'
#!/bin/sh
set -eu

SERVERS='/etc/vpn-servers'
STALE_SECONDS=300
LAST_SWITCH='/tmp/homenet-last-switch'

usage() {
	cat >&2 <<'USAGE'
usage:
  homenet status
  homenet vpn on|off
  homenet pihole on|off
  homenet server <host from /etc/vpn-servers>
  homenet failover [now]
  homenet dns-bypass
USAGE
	exit 1
}

fail() {
	echo "$*" >&2
	exit 1
}

pihole_ip() {
	uci -q get firewall.dns_to_pihole.dest_ip || fail "No Pi-hole redirect rule found."
}

vpn_enabled() {
	[ "$(uci -q get network.vpn.auto)" != '0' ]
}

seconds_since_handshake() {
	last=$(wg show vpn latest-handshakes 2>/dev/null | awk 'NR == 1 { print $2 }')
	if [ -z "$last" ] || [ "$last" -eq 0 ]; then
		echo 999999
	else
		echo $(( $(date +%s) - last ))
	fi
}

show_status() {
	if vpn_enabled; then
		age=$(seconds_since_handshake)
		if [ "$age" -ge 999999 ]; then age='no handshake yet'; else age="last handshake ${age}s ago"; fi
		echo "VPN: on, server $(uci -q get network.nordvpn.endpoint_host), $age"
	else
		echo "VPN: off, traffic goes out directly"
	fi
	if [ "$(uci -q get firewall.dns_to_pihole.enabled)" = '0' ]; then
		echo "Pi-hole: off, the router answers DNS"
	else
		echo "Pi-hole: on, all DNS goes to $(pihole_ip)"
	fi
}

show_dns_bypass() {
	[ -r /proc/net/nf_conntrack ] || fail "The connection table is not available."
	ip=$(pihole_ip)
	ips=$(sed -n 's/^[^=]*src=\([0-9.]*\) dst=[0-9.]* sport=[0-9]* dport=53 .*/\1/p' /proc/net/nf_conntrack | awk -v lan="${ip%.*}." -v pihole="$ip" 'index($0, lan) == 1 && $0 != pihole' | sort -u)
	if [ -z "$ips" ]; then
		echo "No device is using its own DNS server right now. These lookups only last about half a minute, so try again a few times."
		return
	fi
	echo "These devices use their own DNS server (the router passes their lookups to the Pi-hole):"
	for device in $ips; do
		cat /tmp/dhcp.leases 2>/dev/null | awk -v ip="$device" '$3 == ip { print "  " $4 " " ip " " $2; found = 1 } END { if (!found) print "  (no name) " ip }'
	done
}

vpn_on() {
	uci -q delete network.vpn.auto || true
	uci -q delete firewall.lan_to_wan || true
	uci commit
	/etc/init.d/firewall reload
	ifup vpn
}

vpn_off() {
	uci set network.vpn.auto='0'
	uci set firewall.lan_to_wan=forwarding
	uci set firewall.lan_to_wan.src='lan'
	uci set firewall.lan_to_wan.dest='wan'
	uci commit
	ifdown vpn
	/etc/init.d/firewall reload
}

pihole_on() {
	ip=$(pihole_ip)
	uci -q delete firewall.dns_to_pihole.enabled || true
	uci -q delete firewall.dns_to_pihole_reply.enabled || true
	uci -q del_list dhcp.lan.dhcp_option="6,$ip" || true
	uci add_list dhcp.lan.dhcp_option="6,$ip"
	uci commit
	/etc/init.d/firewall reload
	/etc/init.d/dnsmasq restart
}

pihole_off() {
	# TODO: devices keep asking the Pi-hole until their DHCP lease renews (up to 12 hours). Reconnecting a device's Wi-Fi picks up the change at once; a shorter lease time would make it automatic.
	ip=$(pihole_ip)
	uci set firewall.dns_to_pihole.enabled='0'
	uci set firewall.dns_to_pihole_reply.enabled='0'
	uci -q del_list dhcp.lan.dhcp_option="6,$ip" || true
	uci commit
	/etc/init.d/firewall reload
	/etc/init.d/dnsmasq restart
}

switch_to() {
	host=$1
	key=$(awk -v host="$host" '$1 == host { print $2; exit }' "$SERVERS")
	[ -n "$key" ] || fail "$host is not in $SERVERS"
	uci set network.nordvpn.endpoint_host="$host"
	uci set network.nordvpn.public_key="$key"
	uci commit network
	date +%s > "$LAST_SWITCH"
	logger -t homenet "VPN server set to $host"
	if vpn_enabled; then ifup vpn; fi
}

next_server() {
	awk -v current="$(uci -q get network.nordvpn.endpoint_host)" '
		BEGIN { n = 0 }
		NF == 2 { host[n] = $1; if ($1 == current) { at = n; found = 1 }; n++ }
		END { if (n) print host[found ? (at + 1) % n : 0] }
	' "$SERVERS"
}

failover() {
	vpn_enabled || exit 0
	if [ "${1:-}" != 'now' ]; then
		[ "$(cut -d. -f1 /proc/uptime)" -lt "$STALE_SECONDS" ] && exit 0
		[ -f "$LAST_SWITCH" ] && [ $(( $(date +%s) - $(cat "$LAST_SWITCH") )) -lt "$STALE_SECONDS" ] && exit 0
		[ "$(seconds_since_handshake)" -lt "$STALE_SECONDS" ] && exit 0
	fi
	next=$(next_server)
	[ -n "$next" ] || fail "$SERVERS is empty."
	logger -t homenet "No VPN handshake for ${STALE_SECONDS}s, or a switch was forced"
	switch_to "$next"
}

case "${1:-}" in
	status) show_status ;;
	vpn)
		case "${2:-}" in on) vpn_on ;; off) vpn_off ;; *) usage ;; esac
		show_status
		;;
	pihole)
		case "${2:-}" in on) pihole_on ;; off) pihole_off ;; *) usage ;; esac
		show_status
		;;
	server)
		[ -n "${2:-}" ] || usage
		switch_to "$2"
		;;
	failover) failover "${2:-}" ;;
	dns-bypass) show_dns_bypass ;;
	*) usage ;;
esac
EOF
	chmod +x /usr/bin/homenet
}

schedule_failover() {
	touch /etc/crontabs/root
	grep -q 'homenet failover' /etc/crontabs/root || echo '* * * * * /usr/bin/homenet failover' >> /etc/crontabs/root
	uci set system.@system[0].cronloglevel='9'
	uci commit system
	/etc/init.d/cron enable
	/etc/init.d/cron restart
}

block_doh_to_known_resolvers() {
	# TODO: a hand-picked list of the big public resolvers. banIP with its DoH feed covers thousands more and keeps itself current.
	uci -q delete firewall.block_doh_ips || true
	uci set firewall.block_doh_ips=rule
	uci set firewall.block_doh_ips.name='Block-DoH-to-known-resolvers'
	uci set firewall.block_doh_ips.proto='tcp udp'
	uci set firewall.block_doh_ips.src='lan'
	uci set firewall.block_doh_ips.src_ip="!$(uci get firewall.dns_to_pihole.dest_ip)"
	uci set firewall.block_doh_ips.dest='*'
	uci set firewall.block_doh_ips.dest_port='443'
	for ip in 1.1.1.1 1.0.0.1 1.1.1.2 1.0.0.2 1.1.1.3 1.0.0.3 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 9.9.9.10 149.112.112.10 9.9.9.11 149.112.112.11 94.140.14.14 94.140.15.15 94.140.14.15 94.140.15.16 94.140.14.140 94.140.14.141 208.67.222.222 208.67.220.220 45.90.28.0/24 45.90.30.0/24 194.242.2.0/24 103.2.57.5 103.2.57.6; do
		uci add_list firewall.block_doh_ips.dest_ip="$ip"
	done
	uci set firewall.block_doh_ips.target='REJECT'
	uci commit firewall
	/etc/init.d/firewall reload
}

keep_on_upgrade() {
	for f in /usr/bin/homenet /etc/vpn-servers /etc/crontabs/root; do
		grep -qx "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
	done
}

require_main_setup
install_server_list
install_homenet
schedule_failover
block_doh_to_known_resolvers
keep_on_upgrade

echo "Done."
homenet status
