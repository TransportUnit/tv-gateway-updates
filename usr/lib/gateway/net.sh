# Upstream network choice (sourced). Only networks the user allows in gateway.conf are used:
#   UPSTREAM_SSID        primary network, always tried first (it may only be down)
#   UPSTREAM_PATTERNS    case-insensitive shell patterns for other open networks, e.g. "*gast* *guest*"
#   UPSTREAM_MIN_SIGNAL  minimum signal in dBm for pattern matches
# Repeater interface and uci section are device specific and set in gateway.conf (STA_IFACE,
# STA_SECTION). Without STA_SECTION the router never switches networks.

UPSTREAM_SSID=${UPSTREAM_SSID:-Korian_Gast}
UPSTREAM_MIN_SIGNAL=${UPSTREAM_MIN_SIGNAL:--75}
NET_SWITCH_AFTER=${NET_SWITCH_AFTER:-600}

# One line per network: "signal<TAB>encryption<TAB>ssid" (hidden networks skipped).
net_scan() {
	if [ -n "$NET_SCAN_CMD" ]; then $NET_SCAN_CMD; else iwinfo "$STA_IFACE" scan; fi 2>/dev/null | awk '
		/ESSID: "/ { s = $0; sub(/.*ESSID: "/, "", s); sub(/"[ \t]*$/, "", s) }
		/ESSID: unknown/ { s = "" }
		/Signal:/ { sig = $2 }
		/Encryption:/ { e = $0; sub(/.*Encryption: */, "", e); if (s != "") print sig "\t" e "\t" s; s = "" }'
}

net_current() {
	if [ -n "$STA_SECTION" ]; then
		uci -q get "$STA_SECTION.ssid"
	else
		iwinfo "$STA_IFACE" info 2>/dev/null | sed -n 's/.*ESSID: "\(.*\)"/\1/p'
	fi
}

# Allowed networks visible now, in order: primary, then open pattern matches by signal (strongest first).
net_candidates() {
	net_scan > "$STATE_DIR/scan"
	awk -F '\t' -v p="$UPSTREAM_SSID" '$3 == p { print $3; exit }' "$STATE_DIR/scan"
	set -f
	sort -t "	" -k1,1nr "$STATE_DIR/scan" | while IFS="	" read -r sig enc ssid; do
		[ "$ssid" = "$UPSTREAM_SSID" ] && continue
		[ "$enc" = none ] || continue
		[ "$sig" -ge "$UPSTREAM_MIN_SIGNAL" ] 2>/dev/null || continue
		lc=$(echo "$ssid" | tr 'A-Z' 'a-z')
		for p in $UPSTREAM_PATTERNS; do
			case "$lc" in $p) echo "$ssid"; break ;; esac
		done
	done | awk '!seen[$0]++'
	set +f
}

net_report() {
	echo "upstream: $(net_current) (primary $UPSTREAM_SSID)"
	echo "allowed and visible:"
	net_candidates | sed 's/^/  /'
	echo "strongest seen:"
	sort -t "	" -k1,1nr "$STATE_DIR/scan" | head -n 8 | awk -F '\t' '{ print "  " $1 " dBm  " $2 "  " $3 }'
}

net_apply() {
	uci set "$STA_SECTION.ssid=$1" && uci set "$STA_SECTION.encryption=none" || return 1
	uci -q delete "$STA_SECTION.key"
	uci set "$STA_SECTION.disabled=0"
	uci commit "${STA_SECTION%%.*}"
	command -v wifi >/dev/null && wifi reload
	return 0
}

# Switch to the next allowed network not yet tried in this outage. "force" skips the waiting time
# (used when the portal of a non-primary network cannot be passed).
net_next() {
	[ -n "$STA_SECTION" ] || return 0
	if [ "$1" != force ]; then
		[ "$(age status_since)" -ge "$NET_SWITCH_AFTER" ] || return 0
		[ "$(age net_switched)" -ge "$NET_SWITCH_AFTER" ] || return 0
	fi
	tried="$STATE_DIR/net_tried"
	cur=$(net_current)
	grep -qxF "$cur" "$tried" 2>/dev/null || echo "$cur" >> "$tried"
	next=$(net_candidates | grep -vxF -f "$tried" | head -n 1)
	if [ -z "$next" ]; then
		log "net: all allowed networks tried, starting over"
		echo "$cur" > "$tried"
		next=$(net_candidates | grep -vxF "$cur" | head -n 1)
	fi
	[ -n "$next" ] || { log "net: no other allowed network visible"; return 0; }
	echo "$next" >> "$tried"
	state_set net_switched "$(now)"
	state_set net_announce 1
	log "net: switching upstream $cur -> $next"
	notify "no internet via $cur, switching to $next"
	net_apply "$next" || log "net: switching failed"
}
