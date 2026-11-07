# Diagnosis when the probe does not say "online" (sourced, after lib.sh and net.sh). diag_run sets
# DIAG to the first layer that fails and DIAG_INFO to the facts behind it:
#   no_ssid      primary network not visible, or weaker than UPSTREAM_MIN_SIGNAL
#   no_assoc     visible, but the repeater is not associated
#   no_lease     associated, no IPv4 address on the repeater interface
#   no_gw        address, but the gateway answers neither ping nor arping
#   no_dns       gateway fine, the probe host does not resolve
#   no_upstream  gateway and DNS fine, but no HTTP answer and no portal
#   portal       an HTTP answer other than 204 (the portal)
#   online       the probe got its 204
# GL's repeater status contains the upstream WiFi key: it is only read field by field, never stored.

WWAN_IFACE=${WWAN_IFACE:-wwan}
DIAG_SCAN_EVERY=${DIAG_SCAN_EVERY:-300}

# Associated? Sets DIAG_SSID and DIAG_SIGNAL. GL's repeater service first, iwinfo without it.
diag_assoc() {
	DIAG_SSID=""
	DIAG_SIGNAL=""
	rs=$(ubus call repeater status 2>/dev/null)
	if [ -n "$rs" ]; then
		DIAG_SSID=$(echo "$rs" | jsonfilter -e @.ssid)
		DIAG_SIGNAL=$(echo "$rs" | jsonfilter -e @.signal)
		st=$(echo "$rs" | jsonfilter -e @.state_s)
		rs=""
		[ "$st" = connected ]
		return
	fi
	info=$(iwinfo "$STA_IFACE" info 2>/dev/null)
	DIAG_SSID=$(echo "$info" | sed -n 's/.*ESSID: "\(.*\)"/\1/p')
	DIAG_SIGNAL=$(echo "$info" | sed -n 's/.*Signal: \(-*[0-9]*\) dBm.*/\1/p')
	[ -n "$DIAG_SSID" ]
}

# Primary network visible with enough signal? The scan is cached for DIAG_SCAN_EVERY seconds.
diag_visible() {
	if [ ! -f "$STATE_DIR/diag_scan" ] || [ "$(age diag_scan_time)" -ge "$DIAG_SCAN_EVERY" ]; then
		net_scan > "$STATE_DIR/diag_scan"
		state_set diag_scan_time "$(now)"
	fi
	awk -F '\t' -v p="$UPSTREAM_SSID" -v m="$UPSTREAM_MIN_SIGNAL" \
		'$3 == p && $1 >= m { found = 1 } END { exit !found }' "$STATE_DIR/diag_scan"
}

# Address, gateway and DNS server of the repeater interface: DIAG_IP, DIAG_GW, DIAG_DNS.
diag_wwan() {
	ws=$(ubus call network.interface."$WWAN_IFACE" status 2>/dev/null)
	if [ -n "$ws" ]; then
		DIAG_IP=$(echo "$ws" | jsonfilter -e '@["ipv4-address"][0].address')
		DIAG_GW=$(echo "$ws" | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' | head -n 1)
		DIAG_DNS=$(echo "$ws" | jsonfilter -e '@["dns-server"][0]')
		return
	fi
	DIAG_IP=$(ip -4 addr show dev "$STA_IFACE" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)
	DIAG_GW=$(ip route show default 2>/dev/null | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -n 1)
	DIAG_DNS=$(sed -n 's/^nameserver //p' /tmp/resolv.conf.auto 2>/dev/null | head -n 1)
}

diag_gw() {
	[ -n "$DIAG_GW" ] || return 1
	ping -c 1 -W 2 "$DIAG_GW" >/dev/null 2>&1 || arping -q -c 1 -w 2 -I "$STA_IFACE" "$DIAG_GW" >/dev/null 2>&1
}

diag_dns() {
	h=${CHECK_URL#*://}
	h=${h%%/*}
	h=${h%%:*}
	# BusyBox nslookup returns 0 for unknown names too: an address after "Name:" is the answer.
	t=""
	command -v timeout >/dev/null && t="timeout 10"
	$t nslookup "$h" $DIAG_DNS 2>/dev/null | sed -n '/^Name:/,$p' | grep -q 'Address'
}

diag_run() {
	DIAG_IP=""
	DIAG_GW=""
	DIAG_DNS=""
	case "$PROBE" in
	online) DIAG=online ;;
	portal) DIAG=portal ;;
	*)
		if ! diag_assoc; then
			if diag_visible; then DIAG=no_assoc; else DIAG=no_ssid; fi
		else
			diag_wwan
			if [ -z "$DIAG_IP" ]; then DIAG=no_lease
			elif ! diag_gw; then DIAG=no_gw
			elif ! diag_dns; then DIAG=no_dns
			else DIAG=no_upstream
			fi
		fi ;;
	esac
	DIAG_INFO="ssid=${DIAG_SSID:-?} signal=${DIAG_SIGNAL:-?} ip=${DIAG_IP:--} gw=${DIAG_GW:--} dns=${DIAG_DNS:--}"
}
