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
	curl -sf -m 20 "$TG_API/bot$TG_TOKEN/$m" "$@"
}

tg_reply() { tg_api sendMessage --data-urlencode "chat_id=$1" --data-urlencode "text=$2" -o /dev/null; }

is_admin() { [ "$1" = "$TG_CHAT" ]; }
is_user() { is_admin "$1" || grep -q "^$1 " "$USERS_FILE" 2>/dev/null; }

bot_name() {
	n=$(state_get bot_name "")
	if [ -z "$n" ]; then
		n=$(tg_api getMe | jsonfilter -e '@.result.username')
		[ -n "$n" ] && state_set bot_name "$n"
	fi
	echo "$n"
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
	up=$(net_current 2>/dev/null)
	echo "upstream: ${up:-unknown}"
	leases=0
	[ -f /tmp/dhcp.leases ] && leases=$(wc -l < /tmp/dhcp.leases)
	echo "TV side: $leases DHCP client(s)"
	echo "update version: $(cat /etc/gateway/version 2>/dev/null || echo 0)"
	echo "uptime: $(uptime | sed 's/^ *//')"
}

HELP="/status, /log, /capture (last portal capture), /update, /network
admin: /invite, /users, /remove <id>, /reboot"

bot_handle() {
	chat=$1
	text=$2
	name=$(echo "$3" | tr -cd '[:alnum:] ._-' | cut -c1-32)
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
	/update)
		state_set update_last "$(now)"
		/usr/bin/gateway-update
		tg_reply "$chat" "$(tail -n 1 "$STATE_DIR/log")"
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
	*) tg_reply "$chat" "unknown command. $HELP" ;;
	esac
}

# Fetch and handle new messages. The offset is stored before each command runs.
bot_poll() {
	tg_ok || return 0
	offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
	json=$(tg_api getUpdates --data "offset=$offset" --data "timeout=0") || return 1
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
