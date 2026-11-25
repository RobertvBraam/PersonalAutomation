#!/bin/sh
set -eu

NORD_PRIVATE_KEY=''
NORD_SERVER_PUBLIC_KEY='rd9H/PbVpOe7I8AJqhJI8sclbVE2JLfvK6am5ITOu00='
NORD_ENDPOINT_HOST='jp1235.nordvpn.com'

LAN_IP='192.168.0.1'
PIHOLE_IP='192.168.0.175'
PIHOLE_MAC='b8:27:eb:17:2a:56'
AFTR='dgw.xpass.jp'

fail() {
	echo "$*" >&2
	exit 1
}

require_packages() {
	[ -f /lib/netifd/proto/dslite.sh ] || fail "ds-lite is not installed: rebuild the image with ds-lite in the package list."
	[ -f /lib/netifd/proto/wireguard.sh ] || fail "WireGuard is not installed: rebuild the image with luci-proto-wireguard in the package list."
}

require_fresh_install() {
	uci -q get network.dslite >/dev/null && fail "This script has already run. Reset the router (firstboot) before running it again."
	[ "$(uci -q get firewall.@zone[1].name)" = 'wan' ] || fail "Expected firewall zone 1 to be wan. Is this a fresh install?"
	[ "$(uci -q get firewall.@forwarding[0].dest)" = 'wan' ] || fail "Expected forwarding 0 to be lan to wan. Is this a fresh install?"
}

require_nord_values() {
	: "${NORD_PRIVATE_KEY:?Fill in NORD_PRIVATE_KEY at the top of this script.}"
	: "${NORD_SERVER_PUBLIC_KEY:?Fill in NORD_SERVER_PUBLIC_KEY at the top of this script.}"
	: "${NORD_ENDPOINT_HOST:?Fill in NORD_ENDPOINT_HOST at the top of this script.}"
}

configure_dslite() {
	uci set network.dslite=interface
	uci set network.dslite.proto='dslite'
	uci set network.dslite.peeraddr="$AFTR"
	uci set network.dslite.tunlink='wan6'
	uci set network.dslite.mtu='1460'
	uci set network.dslite.encaplimit='ignore'
	uci add_list firewall.@zone[1].network='dslite'
}

configure_lan_without_ipv6() {
	# TODO: the LAN gets no IPv6 at all, so nothing can go around the VPN. Carrying IPv6 through the tunnel needs ULA plus NAT66 and a VPN that carries IPv6 (NordVPN WireGuard does not).
	uci set network.lan.ipaddr="$LAN_IP/24"
	uci -q delete network.lan.netmask || true
	uci -q delete network.lan.ip6assign || true
	uci -q delete network.globals.ula_prefix || true
	uci set dhcp.lan.ra='disabled'
	uci set dhcp.lan.dhcpv6='disabled'
	uci -q delete dhcp.lan.ndp || true
}

configure_pihole_dns() {
	uci set dhcp.pihole=host
	uci set dhcp.pihole.name='pihole'
	uci set dhcp.pihole.mac="$PIHOLE_MAC"
	uci set dhcp.pihole.ip="$PIHOLE_IP"
	uci add_list dhcp.lan.dhcp_option="6,$PIHOLE_IP"

	uci set firewall.dns_to_pihole=redirect
	uci set firewall.dns_to_pihole.name='DNS-to-Pi-hole'
	uci set firewall.dns_to_pihole.family='ipv4'
	uci set firewall.dns_to_pihole.proto='tcp udp'
	uci set firewall.dns_to_pihole.src='lan'
	uci set firewall.dns_to_pihole.src_ip="!$PIHOLE_IP"
	uci set firewall.dns_to_pihole.src_dport='53'
	uci set firewall.dns_to_pihole.dest_ip="$PIHOLE_IP"
	uci set firewall.dns_to_pihole.target='DNAT'

	# TODO: devices with a hardcoded DNS server show up in Pi-hole as the router, because their redirected queries are masqueraded. Moving the Pi-hole to its own subnet removes the need for this rule.
	uci set firewall.dns_to_pihole_reply=nat
	uci set firewall.dns_to_pihole_reply.name='DNS-to-Pi-hole-reply'
	uci set firewall.dns_to_pihole_reply.family='ipv4'
	uci set firewall.dns_to_pihole_reply.proto='tcp udp'
	uci set firewall.dns_to_pihole_reply.src='lan'
	uci set firewall.dns_to_pihole_reply.dest_ip="$PIHOLE_IP"
	uci set firewall.dns_to_pihole_reply.dest_port='53'
	uci set firewall.dns_to_pihole_reply.target='MASQUERADE'

	# TODO: DNS-over-HTTPS to a hardcoded IP still gets past the Pi-hole. banIP with its DoH feed would close that.
	uci set firewall.block_dot=rule
	uci set firewall.block_dot.name='Block-DNS-over-TLS'
	uci set firewall.block_dot.proto='tcp udp'
	uci set firewall.block_dot.src='lan'
	uci set firewall.block_dot.dest='*'
	uci set firewall.block_dot.dest_port='853'
	uci set firewall.block_dot.target='REJECT'
}

configure_vpn() {
	uci set network.vpn=interface
	uci set network.vpn.proto='wireguard'
	uci set network.vpn.private_key="$NORD_PRIVATE_KEY"
	uci add_list network.vpn.addresses='10.5.0.2/32'
	uci set network.vpn.mtu='1400'

	# TODO: pinned to one NordVPN server. If NordVPN retires it, the kill switch keeps the house offline until a new server is filled in. A daily job that re-picks from the recommendations API would fix that.
	uci set network.nordvpn=wireguard_vpn
	uci set network.nordvpn.description='NordVPN'
	uci set network.nordvpn.public_key="$NORD_SERVER_PUBLIC_KEY"
	uci set network.nordvpn.endpoint_host="$NORD_ENDPOINT_HOST"
	uci set network.nordvpn.endpoint_port='51820'
	uci set network.nordvpn.persistent_keepalive='25'
	uci set network.nordvpn.route_allowed_ips='1'
	uci add_list network.nordvpn.allowed_ips='0.0.0.0/1'
	uci add_list network.nordvpn.allowed_ips='128.0.0.0/1'
}

configure_kill_switch() {
	uci delete firewall.@forwarding[0]

	uci set firewall.vpn=zone
	uci set firewall.vpn.name='vpn'
	uci add_list firewall.vpn.network='vpn'
	uci set firewall.vpn.input='REJECT'
	uci set firewall.vpn.output='ACCEPT'
	uci set firewall.vpn.forward='REJECT'
	uci set firewall.vpn.masq='1'
	uci set firewall.vpn.mtu_fix='1'

	uci set firewall.lan_to_vpn=forwarding
	uci set firewall.lan_to_vpn.src='lan'
	uci set firewall.lan_to_vpn.dest='vpn'
}

require_packages
require_fresh_install
require_nord_values

configure_dslite
configure_lan_without_ipv6
configure_pihole_dns
configure_vpn
configure_kill_switch

uci commit
echo "Done. Rebooting. The router comes back on $LAN_IP."
reboot
