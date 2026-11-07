# Front LED (sourced, after recovery.sh): the state for the first LED_WINDOW s after power-on, or while
# the toggle switch is in the LED_SWITCH_ON position; dark otherwise (it stands in a bedroom). The Opal's
# LED knows blue and white, solid, blinking and breathing; it is written over I2C by GL's gl_i2c_led
# (GL's own LED daemon is switched off by install.sh). Written when the pattern changes and every
# LED_REFRESH s; the LED chip (ET6326) is never read: a read hangs the I2C bus until a reboot.
#   connecting (first minutes)       blue_breath
#   portal login running             blue_flash normal
#   no usable network / recovery     blue_flash fast
#   needs a person (refused, failing) white_flash fast
#   online                           white

LED_CMD=${LED_CMD:-gl_i2c_led}
LED_WINDOW=${LED_WINDOW:-1800}
LED_REFRESH=${LED_REFRESH:-600}
LED_SWITCH_GPIO=${LED_SWITCH_GPIO:-gpio-1}
LED_SWITCH_ON=${LED_SWITCH_ON:-}
GPIO_FILE=${GPIO_FILE:-/sys/kernel/debug/gpio}

led_pattern() {
	shown=""
	[ "$(uptime_s)" -lt "$LED_WINDOW" ] && shown=1
	if [ -n "$LED_SWITCH_ON" ] &&
		grep -E "^ *$LED_SWITCH_GPIO .* in +$LED_SWITCH_ON" "$GPIO_FILE" >/dev/null 2>&1; then
		shown=1
	fi
	[ -n "$shown" ] || { echo off; return; }
	st=$(state_get status unknown)
	if [ "$st" = online ]; then
		echo white
	elif [ "$(state_get portal_state)" = denied ] || { [ "$st" = portal ] && [ "$(state_get login_attempts 0)" -ge 2 ]; }; then
		echo "white_flash fast"
	elif [ "$st" = portal ]; then
		echo "blue_flash normal"
	elif [ "$(uptime_s)" -lt "${REC_BOOT_GRACE:-300}" ] || [ "$st" = unknown ]; then
		echo blue_breath
	else
		echo "blue_flash fast"
	fi
}

led_update() {
	p=$(led_pattern)
	# Also every LED_REFRESH s: something else (GL's scripts, install.sh) may have changed the LED.
	[ "$p" = "$(state_get led)" ] && [ "$(age led_time)" -lt "$LED_REFRESH" ] && return
	state_set led "$p"
	state_set led_time "$(now)"
	command -v "${LED_CMD%% *}" >/dev/null 2>&1 || return 0
	$LED_CMD $p >/dev/null 2>&1
}
