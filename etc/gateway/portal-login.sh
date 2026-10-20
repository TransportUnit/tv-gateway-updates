#!/bin/sh
# Site recipe for the portal login, called by gateway-check with the fetched portal page:
#   $1 = page file, $2 = page URL. Exit 0 once the login request was sent; the last output line is
#   reported in the log and in Telegram. gateway-check then checks whether the internet is reachable.
# Default: generic form login. Replace with a site-specific recipe once the real portal is known
# (helpers: portal_curl, portal_fetch in /usr/lib/gateway/lib.sh).

. /usr/lib/gateway/lib.sh

portal_generic_login "$1" "$2"
rc=$?
echo "generic: $LOGIN_INFO"
exit $rc
