#!/bin/sh
set -eu

SET='vpn_bypass'
MARK='0x10/0x10'
TABLE='100'

fail() {
	echo "$*" >&2
	exit 1
}

dnsmasq_fills_sets() {
	dnsmasq --version | grep -qE '(^| )nftset( |$)'
}

require_prerequisites() {
	uci -q get network.dslite >/dev/null || fail "Run r7800-setup.sh first: there is no dslite interface."
	dnsmasq_fills_sets || fail "This dnsmasq cannot fill firewall sets. Install dnsmasq-full first."
}

configure_firewall() {
	# TODO: routing is by address. Sites behind a shared delivery network (Reddit uses Fastly) share addresses with other sites, so some unrelated sites also go direct. Routing by site name would mean inspecting every TLS handshake, which this router cannot do at speed.
	# TODO: a firewall reload (also from homenet vpn on|off) empties the set, so a direct site goes through the VPN until it is looked up again, minutes at most. fw4's ipset loadfile option could restore it.
	uci -q delete firewall.$SET || true
	uci set firewall.$SET=ipset
	uci set firewall.$SET.name="$SET"
	uci set firewall.$SET.family='ipv4'
	uci add_list firewall.$SET.match='dest_ip'

	uci -q delete firewall.direct_sites_mark || true
	uci set firewall.direct_sites_mark=rule
	uci set firewall.direct_sites_mark.name='Mark-direct-sites'
	uci set firewall.direct_sites_mark.src='lan'
	uci set firewall.direct_sites_mark.dest='*'
	uci set firewall.direct_sites_mark.proto='all'
	uci set firewall.direct_sites_mark.ipset="$SET"
	uci set firewall.direct_sites_mark.target='MARK'
	uci set firewall.direct_sites_mark.set_mark="$MARK"

	uci -q delete firewall.direct_sites_allow || true
	uci set firewall.direct_sites_allow=rule
	uci set firewall.direct_sites_allow.name='Allow-direct-sites-outside-VPN'
	uci set firewall.direct_sites_allow.src='lan'
	uci set firewall.direct_sites_allow.dest='wan'
	uci set firewall.direct_sites_allow.proto='all'
	uci set firewall.direct_sites_allow.ipset="$SET"
	uci set firewall.direct_sites_allow.target='ACCEPT'
}

configure_routing() {
	uci -q delete network.direct_sites_rule || true
	uci set network.direct_sites_rule=rule
	uci set network.direct_sites_rule.mark="$MARK"
	uci set network.direct_sites_rule.lookup="$TABLE"
	uci set network.direct_sites_rule.priority='100'

	uci -q delete network.direct_sites_route || true
	uci set network.direct_sites_route=route
	uci set network.direct_sites_route.interface='dslite'
	uci set network.direct_sites_route.target='0.0.0.0/0'
	uci set network.direct_sites_route.table="$TABLE"
}

configure_dns() {
	# TODO: the router records every name it looks up, so its own lookups (time servers, VPN server names) also go direct. A separate dnsmasq instance that only the Pi-hole forwards to would limit the set to the chosen sites.
	uci -q delete dhcp.$SET || true
	uci set dhcp.$SET=ipset
	uci add_list dhcp.$SET.name="$SET"
	uci add_list dhcp.$SET.domain='#'
	uci set dhcp.$SET.family='4'
}

apply() {
	uci commit
	/etc/init.d/network reload
	/etc/init.d/firewall reload
	/etc/init.d/dnsmasq restart
	sleep 3
}

verify() {
	nft list set inet fw4 "$SET" >/dev/null 2>&1 || fail "The firewall set $SET was not created."
	nft list chain inet fw4 mangle_prerouting | grep -q "@$SET" || fail "The rule that marks direct sites is not in mangle_prerouting."
	nft list chain inet fw4 forward_lan | grep -q "@$SET" || fail "The rule that lets direct sites out past the kill switch is not in forward_lan."
	ip rule | grep -q "lookup $TABLE" || fail "The routing rule for table $TABLE is missing."
	ip route show table "$TABLE" | grep -q 'ds-dslite' || fail "Table $TABLE has no route through DS-Lite."
	grep -qs "^nftset=/#/.*fw4#$SET" /var/etc/dnsmasq.conf.* || fail "dnsmasq is not set up to fill $SET. Check: grep nftset /var/etc/dnsmasq.conf.*"
	nslookup www.reddit.com 127.0.0.1 >/dev/null 2>&1 || fail "The router could not look up www.reddit.com."
	nft list set inet fw4 "$SET" | grep -q 'elements' || fail "dnsmasq answered but did not add the address to $SET."
}

require_prerequisites
configure_firewall
configure_routing
configure_dns
apply
verify

echo "Done. Addresses that currently go direct:"
nft list set inet fw4 "$SET" | sed -n '/elements/,/}/p'
