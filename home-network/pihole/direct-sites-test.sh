#!/bin/sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
STUBS=$(mktemp -d)
trap 'rm -rf "$STUBS"' EXIT
export STORE="$STUBS/dnsmasq_lines"

cat > "$STUBS/pihole-FTL" <<'EOF'
#!/bin/sh
if [ $# -ge 3 ]; then printf '%s' "$3" > "$STORE"; fi
sed 's/^\["/[ /; s/"\]$/ ]/' "$STORE"
EOF
cat > "$STUBS/ip" <<'EOF'
#!/bin/sh
echo "default via 192.168.0.1 dev eth0 proto dhcp src 192.168.0.175 metric 100"
EOF
cat > "$STUBS/id" <<'EOF'
#!/bin/sh
echo 0
EOF
chmod +x "$STUBS"/*
PATH="$STUBS:$PATH"

passed=0
failed=0
check() {
	if [ "$2" = "$3" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $1"; echo "  expected: $3"; echo "  actual:   $2"; fi
}
run() {
	sh "$HERE/direct-sites" "$@" >/dev/null 2>&1
}
stored() {
	cat "$STORE"
}

printf '%s' '["server=/reddit.com/redd.it/redditmedia.com/redditstatic.com/192.168.0.1"]' > "$STORE"
check "list reads the line set by hand" "$(sh "$HERE/direct-sites" list | tail -n +2 | tr -d ' ' | tr '\n' ',')" "reddit.com,redd.it,redditmedia.com,redditstatic.com,"

run add example.com
check "add keeps the old sites and adds the new one" "$(stored)" '["server=/example.com/redd.it/reddit.com/redditmedia.com/redditstatic.com/192.168.0.1"]'

run add 'https://WWW.Example.org/some/path'
check "add accepts a pasted URL" "$(stored)" '["server=/example.com/redd.it/reddit.com/redditmedia.com/redditstatic.com/www.example.org/192.168.0.1"]'

run add reddit.com
check "add does not duplicate" "$(stored)" '["server=/example.com/redd.it/reddit.com/redditmedia.com/redditstatic.com/www.example.org/192.168.0.1"]'

before=$(stored)
run add 'evil.com"],"x'; status=$?
check "add rejects a non-domain and keeps the list" "$status $(stored)" "1 $before"
run add localhost; status=$?
check "add rejects a single label" "$status" "1"
run add; status=$?
check "add without a domain shows usage" "$status" "1"

run remove www.example.org example.com
check "remove takes several sites" "$(stored)" '["server=/redd.it/reddit.com/redditmedia.com/redditstatic.com/192.168.0.1"]'

run remove notthere.com; status=$?
check "remove fails for a site not in the list" "$status $(stored)" '1 ["server=/redd.it/reddit.com/redditmedia.com/redditstatic.com/192.168.0.1"]'

run remove reddit.com redd.it redditmedia.com redditstatic.com
check "removing every site empties the setting" "$(stored)" '[]'
check "list says when nothing is set" "$(sh "$HERE/direct-sites" list)" "No sites skip the VPN."

run add reddit.com
check "add works from an empty setting" "$(stored)" '["server=/reddit.com/192.168.0.1"]'

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
