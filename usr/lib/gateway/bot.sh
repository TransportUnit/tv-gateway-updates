# Telegram commands (sourced by gateway-check, runs only while online). Polls getUpdates once per run.
# Only the owner (TG_CHAT, admin) and users in $USERS_FILE are answered; other chats are ignored,
# except "/start <code>" with a valid invite code.

OFFSET_FILE=${OFFSET_FILE:-/etc/gateway/tg_offset}
INVITE_TTL=${INVITE_TTL:-1800}
# Commands older than this are ignored, so a reboot can never replay itself.
CMD_MAX_AGE=${CMD_MAX_AGE:-300}

tg_api() {
	m=$1
	shift
	curl -sf -m "${TG_MAX_TIME:-20}" "$TG_API/bot$TG_TOKEN/$m" "$@"
}

tg_reply() { tg_api sendMessage --data-urlencode "chat_id=$1" --data-urlencode "text=$2" -o /dev/null; }

is_admin() { [ "$1" = "$TG_CHAT" ]; }
is_user() { is_admin "$1" || grep -q "^$1 " "$USERS_FILE" 2>/dev/null; }

bot_name() {
	bn=$(state_get bot_name "")
	if [ -z "$bn" ]; then
		bn=$(tg_api getMe | jsonfilter -e '@.result.username')
		[ -n "$bn" ] && state_set bot_name "$bn"
	fi
	echo "$bn"
}

invite_new() {
	code=$(head -c 8 /dev/urandom | hexdump -e '8/1 "%02x"')
	mkdir -p "$STATE_DIR/invites"
	echo $(( $(now) + INVITE_TTL )) > "$STATE_DIR/invites/$code"
	echo "$code"
}

# invite_use CODE CHAT NAME: add CHAT as user if CODE is valid; codes work once.
invite_use() {
	case "$1" in *[!0-9a-f]* | "") return 1 ;; esac
	f="$STATE_DIR/invites/$1"
	[ -f "$f" ] || return 1
	exp=$(cat "$f")
	rm -f "$f"
	[ "$(now)" -le "$exp" ] || return 1
	echo "$2 $3" >> "$USERS_FILE"
}

status_text() {
	since=$(date -d @"$(state_get status_since 0)" '+%d.%m. %H:%M' 2>/dev/null)
	echo "status: $(state_get status unknown) since $since"
	echo "diagnosis: $(state_get diag -)"
	up=$(net_current 2>/dev/null)
	echo "upstream: ${up:-unknown}"
	leases=0
	[ -f /tmp/dhcp.leases ] && leases=$(wc -l < /tmp/dhcp.leases)
	echo "TV side: $leases DHCP client(s)"
	echo "update version: $(cat /etc/gateway/version 2>/dev/null || echo 0)"
	echo "uptime: $(uptime | sed 's/^ *//')"
}

# Console over Telegram (owner and invited users, user decision 07.11.2026): "/shell", then "/shell yes"
# within 2 minutes. While open, every message of that chat that is not a bot command runs as root on the
# router (sh, non-interactive; the directory is kept between commands); the reply is the output and the
# exit code, a long output also as a file. One console at a time. Closed by /exit, after SHELL_IDLE s
# without a command or SHELL_MAX s after opening (RAM state: a reboot closes it too). A command is killed
# after SHELL_CMD_TIMEOUT s. Opening and closing are events on flash; commands go to the RAM log.
SHELL_DIR="$STATE_DIR/shell"
SHELL_IDLE=${SHELL_IDLE:-600}
SHELL_MAX=${SHELL_MAX:-3600}
SHELL_CMD_TIMEOUT=${SHELL_CMD_TIMEOUT:-60}
SHELL_TEXT_MAX=${SHELL_TEXT_MAX:-3500}

shell_get() { cat "$SHELL_DIR/$1" 2>/dev/null; }

# shell_close REASON: close the console and tell its chat (and the owner, if someone else opened it).
shell_close() {
	schat=$(shell_get chat)
	[ -n "$schat" ] || return 0
	sname=$(shell_get name)
	rm -rf "$SHELL_DIR"
	tg_reply "$schat" "console closed: $1"
	is_admin "$schat" || tg_reply "$TG_CHAT" "console of $sname ($schat) closed: $1"
	event "shell closed for $sname ($schat): $1"
}

# Close a console that was idle too long or open too long. Returns 0 while one is open.
shell_check() {
	[ -f "$SHELL_DIR/chat" ] || return 1
	tnow=$(now)
	if [ $(( tnow - $(shell_get last) )) -ge "$SHELL_IDLE" ]; then
		shell_close "no command for $(( SHELL_IDLE / 60 )) min"
		return 1
	fi
	if [ $(( tnow - $(shell_get start) )) -ge "$SHELL_MAX" ]; then
		shell_close "open for $(( SHELL_MAX / 60 )) min (maximum)"
		return 1
	fi
	return 0
}

shell_open_for() { shell_check && [ "$(shell_get chat)" = "$1" ]; }

# A process that still runs (a finished child stays a zombie until waited for).
alive() {
	st=$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)
	[ -n "$st" ] && [ "$st" != Z ]
}

# kill_tree PID: kill a process and all its descendants (BusyBox has no pkill, maybe no timeout).
kill_tree() {
	for k in $(grep -l "^PPid:[[:space:]]*$1\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3); do
		kill_tree "$k"
	done
	kill -9 "$1" 2>/dev/null
}

# shell_run CHAT TEXT: run TEXT in the console's directory, reply with output and exit code.
shell_run() {
	echo "$(now)" > "$SHELL_DIR/last"
	log "shell: $(shell_get name) ($1): $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-200)"
	cwd=$(shell_get cwd)
	{
		printf "cd '%s' 2>/dev/null || cd /root\n" "$(printf '%s' "${cwd:-/root}" | sed "s/'/'\\\\''/g")"
		printf '%s\n' "$2"
		printf 'rc=$?\npwd > "%s/cwd"\nexit $rc\n' "$SHELL_DIR"
	} > "$SHELL_DIR/cmd.sh"
	sh "$SHELL_DIR/cmd.sh" > "$SHELL_DIR/out" 2>&1 < /dev/null &
	pid=$!
	waited=0
	while alive $pid && [ $waited -lt "$SHELL_CMD_TIMEOUT" ]; do
		sleep 1
		waited=$(( waited + 1 ))
	done
	if alive $pid; then
		kill_tree $pid
		wait $pid 2>/dev/null
		rc="killed after ${SHELL_CMD_TIMEOUT} s"
	else
		wait $pid
		rc="rc $?"
	fi
	echo "$(now)" > "$SHELL_DIR/last"
	size=$(wc -c < "$SHELL_DIR/out")
	if [ "$size" -eq 0 ]; then
		tg_reply "$1" "[$rc, no output]"
	elif [ "$size" -le "$SHELL_TEXT_MAX" ]; then
		tg_reply "$1" "$(cat "$SHELL_DIR/out")
[$rc]"
	else
		tg_reply "$1" "$(head -c "$SHELL_TEXT_MAX" "$SHELL_DIR/out")
... [$rc, $size bytes, full output as file]"
		cp "$SHELL_DIR/out" "$SHELL_DIR/output.txt"
		tg_api sendDocument -F "chat_id=$1" -F "document=@$SHELL_DIR/output.txt" -o /dev/null
	fi
}

# /shell [yes]
shell_cmd() {
	if shell_check; then
		if [ "$(shell_get chat)" = "$1" ]; then
			tg_reply "$1" "console already open; /exit closes it"
		else
			tg_reply "$1" "console is open for $(shell_get name); only one at a time"
		fi
		return
	fi
	if [ "$2" != yes ]; then
		state_set shell_asked "$(now) $1"
		tg_reply "$1" "Console: send '/shell yes' within 2 minutes. Then every message that is not a bot command runs as root on the router (no interactive programs; each stopped after $SHELL_CMD_TIMEOUT s). /exit closes it; it closes itself after $(( SHELL_IDLE / 60 )) min without a command, at most after $(( SHELL_MAX / 60 )) min."
		return
	fi
	asked=$(state_get shell_asked 0)
	if [ "${asked#* }" != "$1" ] || [ $(( $(now) - ${asked%% *} )) -gt 120 ]; then
		tg_reply "$1" "send '/shell' first"
		return
	fi
	state_set shell_asked 0
	mkdir -p "$SHELL_DIR"
	echo "$name" > "$SHELL_DIR/name"
	echo "$(now)" > "$SHELL_DIR/start"
	echo "$(now)" > "$SHELL_DIR/last"
	echo /root > "$SHELL_DIR/cwd"
	echo "$1" > "$SHELL_DIR/chat"
	tg_reply "$1" "console open (root, /root). /exit closes it."
	is_admin "$1" || tg_reply "$TG_CHAT" "console opened by $name ($1)"
	event "shell opened by $name ($1)"
}

HELP="/status, /log, /capture (last portal capture), /diag (diagnosis bundle), /update, /network, /mac, /primary (leave the rescue hotspot), /shell (console on the router), /exit
admin: /invite, /users, /remove <id>, /reboot, /mac original, /mac reset"

bot_handle() {
	chat=$1
	text=$2
	name=$(echo "$3" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-32)
	cmd=${text%% *}
	cmd=${cmd%@*}
	arg=${text#"${text%% *}"}
	arg=${arg# }
	if ! is_user "$chat"; then
		if [ "$cmd" = /start ] && invite_use "$arg" "$chat" "$name"; then
			log "bot: $name ($chat) joined with an invite"
			tg_reply "$chat" "Welcome $name. You will get the gateway's messages. $HELP"
			tg_reply "$TG_CHAT" "$name ($chat) joined with an invite"
		else
			log "bot: ignored message from unknown chat $chat"
		fi
		return
	fi
	log "bot: $chat $cmd"
	case "$cmd" in
	/start | /help) tg_reply "$chat" "$HELP" ;;
	/status) tg_reply "$chat" "$(status_text)" ;;
	/log) tg_reply "$chat" "$(tail -n 20 "$STATE_DIR/log")" ;;
	/network) tg_reply "$chat" "$(net_report 2>&1)" ;;
	/capture)
		f=$(ls -t "$CAPTURE_DIR"/capture-*.tar.gz 2>/dev/null | head -n 1)
		if [ -n "$f" ]; then
			tg_api sendDocument -F "chat_id=$chat" -F "caption=$(basename "$f")" -F "document=@$f" -o /dev/null
		else
			tg_reply "$chat" "no capture yet"
		fi
		;;
	/primary)
		if rescue_active; then
			tg_reply "going back to $UPSTREAM_SSID"
			rescue_leave "/primary by $chat"
		else
			tg_reply "not on the rescue hotspot"
		fi
		;;
	/diag)
		f=$(diag_bundle now)
		tg_api sendDocument -F "chat_id=$chat" -F "caption=$(basename "$f")" -F "document=@$f" -o /dev/null
		;;
	/mac)
		if [ -z "$arg" ]; then
			tg_reply "$chat" "$(/usr/bin/gateway-mac status 2>&1)"
			return
		fi
		if ! is_admin "$chat"; then
			tg_reply "$chat" "admin only"
			return
		fi
		case "$arg" in
		original | reset)
			state_set mac_asked "$(now) $arg"
			tg_reply "$chat" "send '/mac $arg yes' within 2 minutes"
			;;
		"original yes" | "reset yes")
			a=${arg% yes}
			if [ "$(state_get mac_asked | cut -d' ' -f2)" != "$a" ] ||
				[ $(( $(now) - $(state_get mac_asked 0 | cut -d' ' -f1) )) -gt 120 ]; then
				tg_reply "$chat" "send '/mac $a' first"
				return
			fi
			state_set mac_asked 0
			event "bot: /mac $a by $chat"
			[ "$a" = original ] && tg_reply "$chat" "trying the original MAC; back to the alternative one if not online within $(( ${MAC_VERIFY:-1200} / 60 )) min"
			out=$(/usr/bin/gateway-mac "$a" 2>&1)
			event "$out"
			[ "$a" = reset ] && tg_reply "$chat" "$out"
			;;
		*) tg_reply "$chat" "usage: /mac, /mac original, /mac reset" ;;
		esac
		;;
	/update)
		state_set update_last "$(now)"
		/usr/bin/gateway-update
		# An installed update is announced as a message anyway; otherwise say what happened.
		last=$(tail -n 1 "$STATE_DIR/log" | cut -c21-)
		case "$last" in notify:*) ;; *) tg_reply "$chat" "$last" ;; esac
		;;
	/invite | /users | /remove | /reboot)
		if ! is_admin "$chat"; then
			tg_reply "$chat" "admin only"
			return
		fi
		case "$cmd" in
		/invite)
			tg_reply "$chat" "Forward this link (valid $(( INVITE_TTL / 60 )) min, works once): https://t.me/$(bot_name)?start=$(invite_new)"
			;;
		/users)
			tg_reply "$chat" "$(echo "$TG_CHAT owner"; cat "$USERS_FILE" 2>/dev/null)"
			;;
		/remove)
			case "$arg" in "" | *[!0-9-]*) tg_reply "$chat" "usage: /remove <id>"; return ;; esac
			if grep -q "^$arg " "$USERS_FILE" 2>/dev/null; then
				grep -v "^$arg " "$USERS_FILE" > "$USERS_FILE.new"
				mv "$USERS_FILE.new" "$USERS_FILE"
				tg_reply "$chat" "removed $arg"
			else
				tg_reply "$chat" "no user $arg"
			fi
			;;
		/reboot)
			if [ "$arg" = yes ] && [ "$(age reboot_asked)" -le 120 ]; then
				tg_reply "$chat" "rebooting"
				log "bot: reboot by $chat"
				state_set reboot_asked 0
				REBOOT_NOW=1
			else
				state_set reboot_asked "$(now)"
				tg_reply "$chat" "send '/reboot yes' within 2 minutes to reboot"
			fi
			;;
		esac
		;;
	/shell) shell_cmd "$chat" "$arg" ;;
	/exit)
		if shell_open_for "$chat"; then
			shell_close "/exit"
		else
			tg_reply "$chat" "no console open"
		fi
		;;
	*)
		if shell_open_for "$chat"; then
			shell_run "$chat" "$text"
		else
			tg_reply "$chat" "unknown command. $HELP"
		fi
		;;
	esac
}

# Fetch and handle new messages. The offset is stored before each command runs.
bot_poll() {
	tg_ok || return 0
	shell_check
	offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
	# $1: long polling, Telegram answers as soon as a message arrives or after $1 seconds.
	TG_MAX_TIME=$(( ${1:-0} + 5 ))
	json=$(tg_api getUpdates --data "offset=$offset" --data "timeout=${1:-0}")
	rc=$?
	TG_MAX_TIME=20
	[ $rc -eq 0 ] || return 1
	n=$(echo "$json" | jsonfilter -e '@.result[*].update_id' | wc -l)
	i=0
	while [ $i -lt "$n" ]; do
		u=$(echo "$json" | jsonfilter -e "@.result[$i]")
		i=$(( i + 1 ))
		echo $(( $(echo "$u" | jsonfilter -e '@.update_id') + 1 )) > "$OFFSET_FILE"
		chat=$(echo "$u" | jsonfilter -e '@.message.chat.id')
		text=$(echo "$u" | jsonfilter -e '@.message.text')
		date=$(echo "$u" | jsonfilter -e '@.message.date')
		[ -n "$chat" ] && [ -n "$text" ] || continue
		if [ $(( $(now) - ${date:-0} )) -gt "$CMD_MAX_AGE" ]; then
			log "bot: ignored old message from $chat"
			continue
		fi
		bot_handle "$chat" "$text" "$(echo "$u" | jsonfilter -e '@.message.from.first_name')"
	done
	[ "${REBOOT_NOW:-0}" = 1 ] && ${REBOOT_CMD:-reboot}
	return 0
}
