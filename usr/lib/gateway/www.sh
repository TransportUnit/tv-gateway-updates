# Status page, diagnosis bundle and site report (sourced, after lib.sh, net.sh, diag.sh, recovery.sh).
# The page is static HTML in RAM ($STATE_DIR/www), rewritten on every run and served by GL's nginx
# (/etc/nginx/conf.d/tvgw.conf, PIN check in www-auth.lua). nginx has no directory listing, so every
# file is linked from the page. Nothing secret goes into the page or the bundle.

DIAG_DIR=${DIAG_DIR:-/root/gateway-diag}
DIAG_BUNDLE_EVERY=${DIAG_BUNDLE_EVERY:-1800}

html() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Lines without anything that looks like a secret.
no_secrets() { grep -viE "key|passw|token|secret|psk"; }

www_write() {
	w="$STATE_DIR/www"
	mkdir -p "$w"
	ln -sf "$STATE_DIR/log" "$w/log"
	ln -sf "$EVENTS" "$w/events"
	ln -sfn "$CAPTURE_DIR" "$w/captures"
	ln -sfn "$DIAG_DIR" "$w/diag"
	t=$(date '+%d.%m.%Y %H:%M')
	[ -f "$STATE_DIR/time_ok" ] || t="~$t (clock not checked yet)"
	since=$(date -d @"$(state_get status_since 0)" '+%d.%m. %H:%M' 2>/dev/null)
	{
		echo '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
		echo '<meta http-equiv="refresh" content="60"><title>TV gateway</title><style>'
		echo 'body{font-family:sans-serif;margin:12px;max-width:760px}pre{white-space:pre-wrap;font-size:12px;'
		echo 'background:#f2f2f2;padding:6px}h2{font-size:16px;margin:18px 0 4px}.s{font-size:20px;font-weight:bold}'
		echo '</style></head><body>'
		echo "<h1>$NAME</h1><p>$t, uptime $(fmt_dur "$(uptime_s)"), boot $(state_get boot ?), version $(cat /etc/gateway/version 2>/dev/null || echo 0)</p>"
		echo "<p class=\"s\">$(state_get status unknown | html) since $since</p>"
		echo "<p>diagnosis: <b>$(state_get diag - | html)</b> $(state_get diag_info "" | html)</p>"
		echo "<p>portal: $(state_get portal_state "-" | html); last login: $(tail -n 1 "$STATE_DIR/login.out" 2>/dev/null | html)</p>"
		if rec_open; then
			echo "<p>outage $(rec_get id) since $(rec_get start | html), at least $(fmt_dur "$(rec_elapsed)"):" \
				"DHCP $(rec_get dhcp_n 0)×, reconnect $(rec_get recon_n 0)×, reboots $(rec_get reboots 0)</p>"
		else
			echo "<p>no open outage</p>"
		fi
		echo "<p>MAC: $(/usr/bin/gateway-mac status 2>&1 | html)</p>"
		echo "<p>upstream: $(net_current 2>/dev/null | html); TV side: $(cat /tmp/dhcp.leases 2>/dev/null | grep -c '') DHCP client(s)</p>"
		echo '<h2>Networks seen (last scan)</h2><pre>'
		sort -t "	" -k1,1nr "$STATE_DIR/diag_scan" 2>/dev/null | head -n 10 | awk -F '\t' '{ print $1 " dBm  " $2 "  " $3 }' | html
		echo '</pre><h2>Last events</h2><pre>'
		tail -n 20 "$EVENTS" 2>/dev/null | cut -d'|' -f4- | html
		echo '</pre><h2>Log</h2><pre>'
		tail -n 25 "$STATE_DIR/log" | html
		echo '</pre><h2>Files</h2><p><a href="log">full log (RAM)</a> · <a href="events">event log (flash)</a></p><p>Portal captures: '
		for f in $(ls -t "$CAPTURE_DIR" 2>/dev/null); do echo "<a href=\"captures/$f\">$f</a> "; done
		echo '</p><p>Diagnosis bundles: '
		for f in $(ls -t "$DIAG_DIR" 2>/dev/null); do echo "<a href=\"diag/$f\">$f</a> "; done
		echo '</p></body></html>'
	} > "$w/index.html.tmp" && mv "$w/index.html.tmp" "$w/index.html"
}

# Everything needed to analyse a failure at home, as a tar.gz on flash (the last 3 kept). At most one
# per DIAG_BUNDLE_EVERY s unless $1 is "now". Prints the file name.
diag_bundle() {
	[ "$1" = now ] || [ "$(age diag_bundle_time)" -ge "$DIAG_BUNDLE_EVERY" ] || return 1
	state_set diag_bundle_time "$(now)"
	d="$STATE_DIR/bundle"
	rm -rf "$d"
	mkdir -p "$d" "$DIAG_DIR"
	www_write
	cp "$STATE_DIR/www/index.html" "$d/status.html"
	cp "$EVENTS" "$d/events.txt" 2>/dev/null
	cp "$STATE_DIR/log" "$d/gateway-log.txt" 2>/dev/null
	cp "$STATE_DIR/diag_scan" "$d/scan.txt" 2>/dev/null
	cat "$OUTAGE" "$REC_DIR/mac" "$REC_DIR/boots" "$REC_DIR/reboots" > "$d/recovery-state.txt" 2>/dev/null
	{
		date
		uptime
		ip -4 addr 2>/dev/null
		ip route 2>/dev/null
		cat /tmp/resolv.conf.auto 2>/dev/null
		iwinfo 2>/dev/null
		ubus call network.interface."$WWAN_IFACE" status 2>/dev/null
		uci -q show repeater 2>/dev/null | no_secrets
		cat /tmp/dhcp.leases 2>/dev/null
	} > "$d/network.txt" 2>&1
	logread 2>/dev/null | tail -n 400 | no_secrets > "$d/system-log.txt"
	f="$DIAG_DIR/diag-$(date +%Y%m%d-%H%M%S).tar.gz"
	tar -czf "$f" -C "$d" .
	rm -rf "$d"
	ls -t "$DIAG_DIR"/diag-*.tar.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
	echo "$f"
}

# Once per boot, on the first online run: where the router is and how it got online.
site_report() {
	[ -f "$STATE_DIR/site_reported" ] && return
	touch "$STATE_DIR/site_reported"
	rs=$(ubus call repeater status 2>/dev/null)
	band=$(echo "$rs" | jsonfilter -e @.band 2>/dev/null)
	ch=$(echo "$rs" | jsonfilter -e @.channel 2>/dev/null)
	sig=$(echo "$rs" | jsonfilter -e @.signal 2>/dev/null)
	rs=""
	ip=$(ubus call network.interface."$WWAN_IFACE" status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address')
	login=$(grep -E 'login ok|portal captured|login attempt' "$STATE_DIR/log" | tail -n 1 | cut -c21-)
	tv=$(awk '{ print $4 }' /tmp/dhcp.leases 2>/dev/null | tr '\n' ' ')
	notify "site report: $(net_current) ${band:-?} ch ${ch:-?} ${sig:-?} dBm, IP ${ip:-?}; portal: ${login:-none seen this boot}; TV side DHCP: ${tv:-none}; version $(cat /etc/gateway/version 2>/dev/null || echo 0); $(/usr/bin/gateway-mac status 2>&1 | cut -d' ' -f1-4); status page http://tv.internal/ or http://192.168.8.1:8088/"
}
