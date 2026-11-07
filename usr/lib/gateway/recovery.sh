# Recovery chain (sourced, after lib.sh, net.sh and diag.sh). gateway-check calls rec_step on every
# run that is not online and rec_online on every online run. One action per run at most:
#   R1 DHCP renew   no_lease / no_gw for REC_DHCP_AFTER s, at most 2, REC_DHCP_EVERY s apart
#   R2 reconnect    no_assoc / no_lease / no_gw / no_upstream for REC_RECONNECT_AFTER s: rejoin the
#                   primary network with MAC_ORIG through GL's repeater; at most 3, REC_RECONNECT_EVERY apart
#   R6 MAC change   the last stage: after a reboot did not help (REC_MAC_AFTER_REBOOT s later), the outage
#                   is REC_MAC_AFTER s old (no_upstream: REC_MAC_AFTER_UPSTREAM) and the diagnosis makes a
#                   MAC cause plausible (no_assoc, no_lease, no_gw, a portal login failing without a
#                   refusal); never after a refusal or with the portal server down; at most every
#                   REC_MAC_EVERY s. gateway-mac (not updatable) charges the budget and reverts by itself.
#   R5 reboot       not online after REC_REBOOT1 s, again after REC_REBOOT2 s, then every REC_REBOOT_EVERY s
#                   (through gateway-reboot, which enforces its own limits)
# After a successful MAC change the router stays on MAC_ALT: every later reconnect uses the active MAC.
# The portal itself (R3) is handled by gateway-check's login; a portal that refuses access (R3b,
# portal_state "denied") gets no reboot. Nothing happens in the first
# REC_BOOT_GRACE s after boot: GL's repeater service joins the network by itself then.
# The outage is kept on flash ($REC_DIR/outage), written only when it starts, on an action and when it
# ends; its duration survives reboots as a lower bound (time spent rebooting is not counted).

REC_BOOT_GRACE=${REC_BOOT_GRACE:-300}
REC_DHCP_AFTER=${REC_DHCP_AFTER:-180}
REC_DHCP_EVERY=${REC_DHCP_EVERY:-300}
REC_RECONNECT_AFTER=${REC_RECONNECT_AFTER:-600}
REC_RECONNECT_EVERY=${REC_RECONNECT_EVERY:-600}
REC_REBOOT1=${REC_REBOOT1:-1800}
REC_REBOOT2=${REC_REBOOT2:-7200}
REC_REBOOT_EVERY=${REC_REBOOT_EVERY:-43200}
REC_MAC_AFTER=${REC_MAC_AFTER:-10800}
REC_MAC_AFTER_UPSTREAM=${REC_MAC_AFTER_UPSTREAM:-21600}
REC_MAC_AFTER_REBOOT=${REC_MAC_AFTER_REBOOT:-1800}
REC_MAC_EVERY=${REC_MAC_EVERY:-43200}
MACSTATE="$REC_DIR/mac"
OUTAGE="$REC_DIR/outage"

rec_get() { kv_get "$OUTAGE" "$@"; }

# Seconds since the outage started: what was stored at the last write plus the uptime since then
# (since boot, if the last write was in an earlier boot).
rec_elapsed() {
	e=$(rec_get base_elapsed 0)
	if [ "$(rec_get base_boot)" = "$BOOT" ]; then
		echo $(( e + $(uptime_s) - $(rec_get base_uptime 0) ))
	else
		echo $(( e + $(uptime_s) ))
	fi
}

# Write the outage file with the current elapsed time and the given key/value pairs.
rec_save() {
	el=$(rec_elapsed)
	kv_set "$OUTAGE" base_boot "$BOOT" base_uptime "$(uptime_s)" base_elapsed "$el" "$@"
}

rec_open() { [ "$(rec_get open 0)" = 1 ]; }

rec_begin() {
	n=$(( $(rec_get id 0) + 1 ))
	last=$(tail -n 1 "$EVENTS" 2>/dev/null | cut -d'|' -f1)
	t=$(date '+%d.%m. %H:%M')
	[ -f "$STATE_DIR/time_ok" ] || t="~$t"
	kv_set "$OUTAGE" open 1 id "$n" start "$t" start_seq "${last:-0}" base_boot "$BOOT" \
		base_uptime "$(uptime_s)" base_elapsed 0 dhcp_n 0 dhcp_at -1 recon_n 0 recon_at -1 reboots 0 reboot_at -1
	event "outage $n start: $DIAG ($DIAG_INFO)"
}

rec_action() {
	event "recovery: $*"
}

rec_dhcp() {
	ubus call network.interface."$WWAN_IFACE" renew >/dev/null 2>&1
}

# The MAC in use: MAC_ALT after a successful change (or while it is tried), else MAC_ORIG.
rec_mac() {
	if [ "$(kv_get "$MACSTATE" active orig)" = alt ]; then echo "$MAC_ALT"; else echo "$MAC_ORIG"; fi
}

# Rejoin the primary network with the active MAC through GL's repeater service (it owns the WiFi config).
rec_reconnect() {
	repeater_connect "$UPSTREAM_SSID" "$(rec_mac)"
}

# Rescue hotspot: a phone hotspot (RESCUE_SSID, RESCUE_KEY) the user turns on when the router cannot get
# online. Only a way to report and to get commands: the outage stays open, nothing is confirmed, no MAC
# change while it is used; after RESCUE_MAX s or on /primary the router goes back (the TV uses the
# phone's mobile data meanwhile) and waits RESCUE_PAUSE s before it uses the hotspot again.
RESCUE_AFTER=${RESCUE_AFTER:-120}
RESCUE_MAX=${RESCUE_MAX:-1800}
RESCUE_PAUSE=${RESCUE_PAUSE:-1800}

rescue_visible() {
	if [ ! -f "$STATE_DIR/diag_scan" ] || [ "$(age diag_scan_time)" -ge 120 ]; then
		net_scan > "$STATE_DIR/diag_scan"
		state_set diag_scan_time "$(now)"
	fi
	awk -F '\t' -v p="$RESCUE_SSID" '$3 == p { found = 1 } END { exit !found }' "$STATE_DIR/diag_scan"
}

# Called by rec_step: switch to the rescue hotspot if it is due. Returns 0 when it switched.
rescue_step() {
	[ -n "$RESCUE_SSID" ] || return 1
	[ "$(age rescue_left)" -ge "$RESCUE_PAUSE" ] || return 1
	[ "$(rec_elapsed)" -ge "$RESCUE_AFTER" ] || return 1
	rescue_visible || return 1
	rec_action "rescue: switching to $RESCUE_SSID"
	state_set rescue_since "$(now)"
	repeater_connect "$RESCUE_SSID"
}

rescue_active() { [ -n "$RESCUE_SSID" ] && [ "$(net_current)" = "$RESCUE_SSID" ]; }

# Online over the rescue hotspot: report once per session, leave after RESCUE_MAX s.
rescue_online() {
	[ -n "$(state_get rescue_since)" ] || state_set rescue_since "$(now)"
	if [ ! -f "$STATE_DIR/rescue_reported" ]; then
		touch "$STATE_DIR/rescue_reported"
		last=$(grep '|diag ' "$EVENTS" 2>/dev/null | tail -n 1)
		why=""
		[ -n "$last" ] && why="$(echo "$last" | cut -d'|' -f5 | sed 's/^diag //') since $(echo "$last" | cut -d'|' -f4 | cut -c12-)"
		steps=""
		rec_open && steps=$(events_since "$(rec_get start_seq 0)" | cut -d'|' -f5 | grep -E '^(recovery|diag|boot|portal)' | tail -n 12)
		notify "RESCUE: online over your hotspot $RESCUE_SSID. Not online over $UPSTREAM_SSID: ${why:-no diagnosis stored}; portal: $(state_get portal_state -).
Steps so far:
${steps:-none}
Files follow (last portal capture, diagnosis bundle). Commands: /status /log /capture /diag /network /primary. Back to $UPSTREAM_SSID after $(( RESCUE_MAX / 60 )) min, on /primary or when the hotspot is off. The TV uses your mobile data meanwhile."
		c=$(ls -t "$CAPTURE_DIR"/capture-*.tar.gz 2>/dev/null | head -n 1)
		[ -n "$c" ] && notify_file "$c"
		b=$(diag_bundle now)
		[ -n "$b" ] && notify_file "$b"
	fi
	[ "$(age rescue_since)" -ge "$RESCUE_MAX" ] && rescue_leave "time limit"
}

rescue_leave() {
	rec_action "rescue: back to $UPSTREAM_SSID ($1)"
	state_set rescue_left "$(now)"
	rm -f "$STATE_DIR/rescue_reported" "$STATE_DIR/rescue_since"
	# GL must not keep the hotspot as a known network (it would join it again by itself).
	for sec in $(uci -q show repeater 2>/dev/null | grep -F ".ssid='$RESCUE_SSID'" | cut -d. -f2); do
		uci -q delete "repeater.$sec"
	done
	uci -q commit repeater
	repeater_connect "$UPSTREAM_SSID" "$(rec_mac)"
}

# Is the last stage due at elapsed time $1? Budget, lock and phase are checked again by gateway-mac.
rec_mac_due() {
	[ -n "$MAC_ALT" ] && [ -n "$MAC_ORIG" ] || return 1
	[ "$(rec_get reboots 0)" -ge 1 ] || return 1
	[ $(( $1 - $(rec_get reboot_at 0) )) -ge "$REC_MAC_AFTER_REBOOT" ] || return 1
	[ "$(rec_get denied_seen 0)" = 1 ] && return 1
	[ "$(rec_get unreachable_seen 0)" = 1 ] && return 1
	at=$(rec_get mac_at -1)
	[ "$at" -lt 0 ] || [ $(( $1 - at )) -ge "$REC_MAC_EVERY" ] || return 1
	case "$DIAG" in
	no_assoc | no_lease | no_gw | portal) [ "$1" -ge "$REC_MAC_AFTER" ] || return 1 ;;
	no_upstream) [ "$1" -ge "$REC_MAC_AFTER_UPSTREAM" ] || return 1 ;;
	*) return 1 ;;
	esac
	[ "$(kv_get "$MACSTATE" phase idle)" = idle ] || return 1
	[ "$(kv_get "$MACSTATE" lock 0)" = 1 ] && return 1
	[ "$(kv_get "$MACSTATE" unsupported 0)" = 1 ] && return 1
	if [ "$(kv_get "$MACSTATE" budget_used 0)" -ge "${MAC_BUDGET:-2}" ]; then
		if [ "$(rec_get budget_noted 0)" != 1 ]; then
			rec_save budget_noted 1
			rec_action "R6 due, but the MAC budget is used up (${MAC_BUDGET:-2}): no further changes"
		fi
		return 1
	fi
	return 0
}

# Called when not online. Opens the outage when it is a real one (offline, or a portal whose login
# failed) and runs at most one due action.
rec_step() {
	st=$(state_get status unknown)
	if ! rec_open; then
		[ "$st" = offline ] || [ "$(state_get login_attempts 0)" -gt 0 ] || return 0
		rec_begin
	fi
	ps=$(state_get portal_state)
	if [ -n "$ps" ] && [ "$(rec_get "${ps}_seen" 0)" != 1 ]; then
		rec_save "${ps}_seen" 1
	fi
	[ "$(uptime_s)" -ge "$REC_BOOT_GRACE" ] || return 0
	# A MAC change in its verification window: gateway-mac decides, nothing else interferes.
	case "$(kv_get "$MACSTATE" phase idle)" in charged | applied | reverting | trial_orig | reverting_alt) return 0 ;; esac
	rescue_step && return 0
	el=$(rec_elapsed)
	case "$DIAG" in
	no_lease | no_gw)
		n=$(rec_get dhcp_n 0)
		at=$(rec_get dhcp_at -1)
		if [ "$el" -ge "$REC_DHCP_AFTER" ] && [ "$n" -lt 2 ] && { [ "$at" -lt 0 ] || [ $(( el - at )) -ge "$REC_DHCP_EVERY" ]; }; then
			rec_save dhcp_n $(( n + 1 )) dhcp_at "$el"
			rec_action "R1 DHCP renew $(( n + 1 ))/2 ($DIAG)"
			rec_dhcp
			return 0
		fi ;;
	esac
	case "$DIAG" in
	no_assoc | no_lease | no_gw | no_upstream)
		n=$(rec_get recon_n 0)
		at=$(rec_get recon_at -1)
		if [ "$el" -ge "$REC_RECONNECT_AFTER" ] && [ "$n" -lt 3 ] && { [ "$at" -lt 0 ] || [ $(( el - at )) -ge "$REC_RECONNECT_EVERY" ]; }; then
			rec_save recon_n $(( n + 1 )) recon_at "$el"
			mac=$(rec_mac)
			rec_action "R2 reconnect $UPSTREAM_SSID with ${mac:-GL's MAC} $(( n + 1 ))/3 ($DIAG)"
			rec_reconnect
			return 0
		fi ;;
	esac
	# A reboot cannot change a portal's refusal.
	[ "$ps" = denied ] && return 0
	if rec_mac_due "$el"; then
		rec_save mac_at "$el"
		rec_action "R6 MAC change to $MAC_ALT: $DIAG after $(fmt_dur "$el"), $MAC_ORIG did not help"
		out=$(/usr/bin/gateway-mac apply-alt "$DIAG after $(fmt_dur "$el")")
		rc=$?
		[ $rc -eq 0 ] || rec_action "R6 not done: $out"
		return 0
	fi
	n=$(rec_get reboots 0)
	case "$n" in
	0) due=$REC_REBOOT1 ;;
	1) due=$REC_REBOOT2 ;;
	*) due=$(( $(rec_get reboot_at 0) + REC_REBOOT_EVERY )) ;;
	esac
	if [ "$el" -ge "$due" ]; then
		rec_save reboots $(( n + 1 )) reboot_at "$el"
		rec_action "R5 reboot $(( n + 1 )) after $(fmt_dur "$el") ($DIAG)"
		/usr/bin/gateway-reboot "outage $(rec_get id)" || rec_action "R5 reboot refused by gateway-reboot"
	fi
}

# Called on every online run: confirms a MAC change in its verification window and closes an open
# outage. If the recovery acted, it is reported, built from the event log on flash, so the report
# survives the reboots in between.
rec_online() {
	mp=$(kv_get "$MACSTATE" phase idle)
	case "$mp" in applied | trial_orig) ;; *) rec_open || return 0 ;; esac
	# Success needs more than the probe: an HTTPS request must get through as well.
	if ! curl -s -m 15 -o /dev/null "$TG_API"; then
		if [ "$(state_get https_noted 0)" != 1 ]; then
			state_set https_noted 1
			event "probe online, but HTTPS to $TG_API fails: outage stays open"
		fi
		return 0
	fi
	rm -f "$STATE_DIR/https_noted"
	macok=""
	case "$mp" in
	applied | trial_orig)
		event "$(/usr/bin/gateway-mac confirm)"
		[ "$mp" = applied ] && macok=1
		;;
	esac
	rec_open || return 0
	el=$(rec_elapsed)
	id=$(rec_get id)
	start=$(rec_get start)
	acted=$(( $(rec_get dhcp_n 0) + $(rec_get recon_n 0) + $(rec_get reboots 0) + $(rec_get mac_at -1) + 1 ))
	rec_save open 0 end_elapsed "$el"
	event "outage $id end after $(fmt_dur "$el")"
	[ "$acted" -gt 0 ] || return 0
	all=$(events_since "$(rec_get start_seq 0)" | cut -d'|' -f5)
	steps=$(echo "$all" | grep -E '^(recovery|diag|boot)' | tail -n 15)
	b=$(rec_get reboots 0)
	if [ -z "$macok" ]; then
		notify "recovered: outage $id since $start, at least $(fmt_dur "$el") ($b reboot(s)). Steps:
$steps"
		return 0
	fi
	login="not needed (no portal)"
	echo "$all" | sed -n '/R6 MAC change/,$p' | grep -q 'status portal -> online' && login="ok"
	notify "online again AFTER A MAC CHANGE (last recovery stage). Outage $id since $start, at least $(fmt_dur "$el").
With the original MAC $MAC_ORIG nothing helped:
$steps
Now with $MAC_ALT: associated, address, portal login $login, internet verified (probe 204 + HTTPS).
MAC budget: $(kv_get "$MACSTATE" budget_used 0) of ${MAC_BUDGET:-2} used; further automatic MAC changes are LOCKED.
The change restored access, so a MAC-related access problem is possible, but NOT proven (also possible: an AP or controller restart, its lease table, coincidence). If it happens again, ask the care home. /mac original tries the original MAC again."
}
