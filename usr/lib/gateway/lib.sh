# Shared helpers for the gateway scripts (BusyBox ash). Sourced, not executed.

CONF=${GATEWAY_CONF:-/etc/gateway/gateway.conf}
[ -r "$CONF" ] && . "$CONF"

CHECK_URL=${CHECK_URL:-http://connectivitycheck.gstatic.com/generate_204}
TG_API=${TG_API:-https://api.telegram.org}
PORTAL_INSECURE=${PORTAL_INSECURE:-1}
FAIL_THRESHOLD=${FAIL_THRESHOLD:-2}
HEARTBEAT_EVERY=${HEARTBEAT_EVERY:-300}
UPDATE_EVERY=${UPDATE_EVERY:-86400}
NAME=${NAME:-TV gateway}
STATE_DIR=${STATE_DIR:-/tmp/gateway}
CAPTURE_DIR=${CAPTURE_DIR:-/root/gateway-captures}
LIB_DIR=${LIB_DIR:-/usr/lib/gateway}
USERS_FILE=${USERS_FILE:-/etc/gateway/users}
HINT_FILE=${HINT_FILE:-/etc/gateway/login_hint}
UA="Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36"

mkdir -p "$STATE_DIR/queue"

now() { date +%s; }

log() {
	logger -t gateway "$*" 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$STATE_DIR/log"
	# Keep the RAM log small.
	if [ "$(wc -c < "$STATE_DIR/log")" -gt 65536 ]; then
		tail -n 300 "$STATE_DIR/log" > "$STATE_DIR/log.tmp" && mv "$STATE_DIR/log.tmp" "$STATE_DIR/log"
	fi
}

state_get() { cat "$STATE_DIR/$1" 2>/dev/null || echo "$2"; }
state_set() { echo "$2" > "$STATE_DIR/$1"; }

# Seconds since the timestamp stored under $1 (large if never set).
age() { echo $(( $(now) - $(state_get "$1" 0) )); }

next_seq() {
	s=$(( $(state_get seq 0) + 1 ))
	state_set seq $s
	printf '%08d' $s
}

# Queue a Telegram message; queue_flush sends it once online. Queuing first means nothing is lost
# when the portal blocks the request.
notify() {
	log "notify: $*"
	printf '%s\n' "$*" > "$STATE_DIR/queue/$(next_seq).msg"
}

# Queue a file (portal capture) as a Telegram document.
notify_file() {
	cp "$1" "$STATE_DIR/queue/$(next_seq).doc-$(basename "$1")"
}

tg_ok() { [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; }

fmt_dur() { printf '%dh%02dm' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )); }

# Messages go to the owner and to every invited user.
recipients() {
	echo "$TG_CHAT"
	cut -d' ' -f1 "$USERS_FILE" 2>/dev/null
}

tg_send_item() {
	case "$2" in
	*.msg)
		curl -sf -m 15 -o /dev/null "$TG_API/bot$TG_TOKEN/sendMessage" \
			--data-urlencode "chat_id=$1" --data-urlencode "text=$NAME: $(cat "$3")" ;;
	*.doc-*)
		curl -sf -m 60 -o /dev/null "$TG_API/bot$TG_TOKEN/sendDocument" \
			-F "chat_id=$1" -F "caption=$NAME: ${2#*.doc-}" -F "document=@$3" ;;
	esac
}

# Send queued items in order; stop at the first failure for the owner and keep the rest. Other users
# get their copy best effort.
queue_flush() {
	tg_ok || { rm -f "$STATE_DIR"/queue/*; return 0; }
	for f in $(ls "$STATE_DIR/queue" 2>/dev/null | sort); do
		p="$STATE_DIR/queue/$f"
		tg_send_item "$TG_CHAT" "$f" "$p" || return 1
		for r in $(recipients | grep -vx "$TG_CHAT"); do
			tg_send_item "$r" "$f" "$p" || log "telegram: send to $r failed"
		done
		rm -f "$p"
	done
}

# PROBE=online (204, empty body), portal (any other HTTP answer) or offline (no answer).
probe() {
	out=$(curl -s -m 10 -o "$STATE_DIR/probe.body" -D "$STATE_DIR/probe.head" \
		-w '%{http_code} %{size_download}' "$CHECK_URL")
	code=${out% *}
	size=${out#* }
	if [ -z "$code" ] || [ "$code" = 000 ]; then
		PROBE=offline
	elif [ "$code" = 204 ] && [ "$size" = 0 ]; then
		PROBE=online
	else
		PROBE=portal
	fi
}

# healthchecks.io: plain ping when online; "/fail" with a reason when something is wrong but the
# router can still reach it (e.g. portal login failing is not visible otherwise).
heartbeat() {
	[ -n "$HC_URL" ] || return 0
	curl -sf -m 15 -o /dev/null --data-binary "${2:-}" "$HC_URL${1:+/$1}"
}

# Portal requests: browser-like, with a cookie jar per portal episode.
portal_curl() {
	k=""
	[ "$PORTAL_INSECURE" = 1 ] && k="-k"
	curl -s $k -m 20 -A "$UA" -b "$STATE_DIR/cookies" -c "$STATE_DIR/cookies" "$@"
}

# Fetch the portal page the probe gets redirected to. Sets PAGE (file), PAGE_URL and PAGE_HEADERS
# (headers of every step). Follows meta-refresh interstitials up to 3 times.
portal_fetch() {
	PAGE="$STATE_DIR/page.html"
	PAGE_HEADERS="$STATE_DIR/page.headers"
	PAGE_URL=$(portal_curl -L --max-redirs 10 --max-filesize 1048576 -D "$PAGE_HEADERS" -o "$PAGE" \
		-w '%{url_effective}' "${1:-$CHECK_URL}")
	for i in 1 2 3; do
		next=$(lua "$LIB_DIR/portal-generic.lua" refresh "$PAGE" "$PAGE_URL") || break
		PAGE_URL=$(portal_curl -L --max-redirs 10 --max-filesize 1048576 -e "$PAGE_URL" -D "$STATE_DIR/page.h" \
			-o "$PAGE" -w '%{url_effective}' "$next")
		cat "$STATE_DIR/page.h" >> "$PAGE_HEADERS"
	done
}

# portal_send CANDIDATE REFERER: send one candidate line from the parser. Sets RESP, RESP_URL, LABEL, SIG.
portal_send() {
	method=$(printf '%s\n' "$1" | cut -f1)
	target=$(printf '%s\n' "$1" | cut -f2)
	body=$(printf '%s\n' "$1" | cut -f3)
	LABEL=$(printf '%s\n' "$1" | cut -f4)
	SIG=$(printf '%s\n' "$1" | cut -f5)
	RESP="$STATE_DIR/resp.html"
	log "login try: $LABEL"
	if [ "$method" = POST ]; then
		RESP_URL=$(portal_curl -L -e "$2" -o "$RESP" -w '%{url_effective}' --data "$body" "$target")
	else
		case "$target" in *\?*) sep="&" ;; *) sep="?" ;; esac
		RESP_URL=$(portal_curl -L -e "$2" -o "$RESP" -w '%{url_effective}' "$target${body:+$sep$body}")
	fi
}

# Generic login: try the parser's candidates (best first) until the probe says online. The page is
# fetched again before each further first-step attempt (a failed attempt may invalidate its token).
# A reply with a different form (e.g. a confirmation page) is followed, up to 3 steps. The first-step
# variant that worked is remembered and tried first next time.
# Returns 0 when online, 1 when nothing worked, 2 when the page has no usable form (LOGIN_INFO says why).
portal_generic_login() {
	page=$1
	url=$2
	tries=0
	idx=1
	GATEWAY_HINT=$(cat "$HINT_FILE" 2>/dev/null)
	export GATEWAY_HINT
	while [ $tries -lt 8 ]; do
		if [ $idx -gt 1 ]; then
			portal_fetch
			page=$PAGE
			url=$PAGE_URL
		fi
		if ! lua "$LIB_DIR/portal-generic.lua" candidates "$page" "$url" > "$STATE_DIR/cands"; then
			LOGIN_INFO=$(cat "$STATE_DIR/cands")
			[ $idx -eq 1 ] && return 2
			break
		fi
		line=$(sed -n "${idx}p" "$STATE_DIR/cands")
		[ -n "$line" ] || break
		first=$(printf '%s\n' "$line" | cut -f4)
		step=1
		ref=$url
		while [ -n "$line" ] && [ $step -le 3 ]; do
			tries=$(( tries + 1 ))
			portal_send "$line" "$ref"
			sleep 2
			probe
			if [ "$PROBE" = online ]; then
				[ "$first" = "$GATEWAY_HINT" ] || echo "$first" > "$HINT_FILE"
				LOGIN_INFO="online with $first (step $step, $tries tries)"
				return 0
			fi
			# A different form in the reply is the next step; the same form again means "rejected".
			next=$(lua "$LIB_DIR/portal-generic.lua" candidates "$RESP" "$RESP_URL" 2>/dev/null | head -n 1)
			if [ -n "$next" ] && [ "$(printf '%s\n' "$next" | cut -f5)" != "$SIG" ]; then
				line=$next
				ref=$RESP_URL
				step=$(( step + 1 ))
			else
				line=""
			fi
		done
		idx=$(( idx + 1 ))
	done
	LOGIN_INFO="no variant worked ($tries tries)"
	return 1
}
