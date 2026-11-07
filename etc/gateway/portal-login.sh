#!/bin/sh
# Site recipe for the portal login, called by gateway-check with the fetched portal page:
#   $1 = page file, $2 = page URL. Exit 0 once the login request was sent; the last output line is
#   reported in the log and in Telegram. gateway-check then checks whether the internet is reachable.
#   Exit 3 when the portal clearly refuses access (the last line says why): reported as a refusal,
#   no automatic workaround.
# Helpers: portal_curl, portal_fetch in /usr/lib/gateway/lib.sh.
#
# Korian_Gast (BTD Service): Alcatel-Lucent OmniVista Cirrus UPAM portal (*.upam.ovcirrus.com),
# page .../portalpages/<id>/login.html?mac=<client MAC>&url=<original URL>. Login by "terms of use":
# the page's Angular script (login-controller.js, loginBuildIn) posts JSON with the built-in account
# and the MAC from the page URL to /portal/api/ham/login/buildin; errorCode 0 = allowed. Checked
# against the real portal on 07.11.2026 (the router went online with this request).
# Any other portal: generic form login.

. /usr/lib/gateway/lib.sh

# qparam QUERY NAME: value of NAME in a URL query string, decoded like the page's unescape().
qparam() {
	v=$(echo "&$1" | sed -n "s/.*&$2=\([^&#]*\).*/\1/p" | head -n 1)
	printf '%b' "$(echo "$v" | sed 's/\\/\\\\/g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

# Text for a JSON string: no quotes, backslashes or control characters.
jstr() {
	printf '%s' "$1" | tr -d '"\\\000-\037'
}

upam_login() {
	page_url=$1
	base=$(echo "$page_url" | sed -E 's#^(https?://[^/]*).*#\1#')
	dir=${page_url%%\?*}
	dir=${dir%/*}
	query=""
	case "$page_url" in *\?*) query=${page_url#*\?} ;; esac
	mac=$(qparam "$query" mac)
	url=$(qparam "$query" url)
	ip=$(qparam "$query" ip)
	[ -n "$mac" ] || { echo "upam: no mac in the portal URL"; return 2; }
	# The portal's settings (login type, strategy name) live in portal-param.js next to the page.
	strategy=Gast
	portal_curl -e "$page_url" --max-filesize 65536 -o "$STATE_DIR/upam-param.js" "$dir/js/user-custom/portal-param.js"
	if [ -s "$STATE_DIR/upam-param.js" ]; then
		by=$(sed -n 's/^[ \t]*var[ \t]*loginBy[ \t]*=[ \t]*"\([^"]*\)".*/\1/p' "$STATE_DIR/upam-param.js" | tail -n 1)
		s=$(sed -n 's/^[ \t]*var[ \t]*strategyInfo[ \t]*=[ \t]*"\([^"]*\)".*/\1/p' "$STATE_DIR/upam-param.js" | tail -n 1)
		[ -n "$s" ] && strategy=$s
		if [ -n "$by" ] && [ "$by" != termsOfUse ]; then
			echo "upam: portal wants loginBy=$by, the recipe only does termsOfUse"
			return 2
		fi
	fi
	json="{\"userIp\":\"$(jstr "$ip")\",\"strategyName\":\"$(jstr "$strategy")\",\"useFor\":\"Guest\",\"serviceLevel\":\"\",\"mac\":\"$(jstr "$mac")\",\"url\":\"$(jstr "$url")\",\"username\":\"BuiltInAccount\",\"loginCustomAttrList\":null}"
	portal_curl -e "$page_url" -H "Origin: $base" -H 'Content-Type: application/json;charset=utf-8' \
		-H 'Accept: application/json, text/plain, */*' -o "$STATE_DIR/resp.html" --data "$json" \
		"$base/portal/api/ham/login/buildin"
	[ -s "$STATE_DIR/resp.html" ] || { echo "upam: no answer from $base/portal/api/ham/login/buildin"; return 2; }
	code=$(sed -n 's/.*"errorCode"[ \t]*:[ \t]*\(-\{0,1\}[0-9]*\).*/\1/p' "$STATE_DIR/resp.html" | head -n 1)
	msg=$(sed -n 's/.*"errorMessage"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p' "$STATE_DIR/resp.html" | head -n 1)
	if [ "$code" = 0 ]; then
		# The cloud tells the access point; give that up to 20 s before gateway-check probes.
		i=0
		while [ $i -lt 10 ]; do
			probe
			[ "$PROBE" = online ] && break
			sleep 2
			i=$(( i + 1 ))
		done
		echo "upam: login accepted (strategy $strategy, mac $mac)"
		return 0
	fi
	case "$msg" in
	upam.alreadyPermissionAccessnetwork)
		echo "upam: portal says already allowed (mac $mac)"
		return 0
		;;
	upam.DataQuotaIsZero)
		echo "upam: refused: data quota used up ($msg)"
		return 3
		;;
	esac
	echo "upam: login rejected: errorCode ${code:-?} ${msg:-$(head -c 200 "$STATE_DIR/resp.html")}"
	return 2
}

case "$2" in
*/portalpages/*/login.html*mac=*)
	upam_login "$2"
	exit $?
	;;
esac

portal_generic_login "$1" "$2"
rc=$?
echo "generic: $LOGIN_INFO"
exit $rc
