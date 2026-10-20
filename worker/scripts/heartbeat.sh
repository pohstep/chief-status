#!/bin/sh
# Keep a working bot's last post fresh without moving the job clock,
# and without turning an idle bot back to working.
#
#   export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
#   export CHIEF_STATUS_TOKEN="the password you gave the worker"
#   ./heartbeat.sh start Agent1
#   ./heartbeat.sh stop Agent1
#
# post-status.sh starts this with a working post and stops it with idle.
# The first post goes out immediately, then every 3 minutes
# (CHIEF_STATUS_HEARTBEAT_SECONDS). The body is status working with
# "heartbeat": true and no task, so the feed refreshes last_posted_at,
# keeps the stored task, and refuses the beat (409) unless that row is
# already working. A task on the command line is ignored, so an old
# command cannot relight a bot by sending one.
# The process id is stored under
# ${CHIEF_STATUS_HEARTBEAT_DIR:-${TMPDIR:-/tmp}/chief-status-heartbeats}/<bot>.pid
# This script never prints the token.

set -eu

SCRIPT=$0

usage() {
	echo "Usage: heartbeat.sh start BOT" >&2
	echo "       heartbeat.sh stop BOT" >&2
	echo "  A task after the bot name is ignored." >&2
	echo "  Set CHIEF_STATUS_URL and CHIEF_STATUS_TOKEN first." >&2
	exit 1
}

heartbeat_dir() {
	if [ -n "${CHIEF_STATUS_HEARTBEAT_DIR:-}" ]; then
		printf '%s\n' "$CHIEF_STATUS_HEARTBEAT_DIR"
		return
	fi
	base=${TMPDIR:-/tmp}
	base=${base%/}
	printf '%s/chief-status-heartbeats\n' "$base"
}

pid_path() {
	safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
	printf '%s/%s.pid\n' "$(heartbeat_dir)" "$safe"
}

interval() {
	raw=${CHIEF_STATUS_HEARTBEAT_SECONDS:-180}
	case "$raw" in
	*[!0-9]* | "")
		printf '180\n'
		;;
	*)
		if [ "$raw" -lt 1 ]; then
			printf '180\n'
		else
			printf '%s\n' "$raw"
		fi
		;;
	esac
}

end_bot() {
	file=$(pid_path "$1")
	if [ ! -f "$file" ]; then
		return 0
	fi
	pid=$(tr -cd '0-9' < "$file" || true)
	rm -f "$file"
	if [ -z "$pid" ]; then
		return 0
	fi
	if kill -0 "$pid" 2>/dev/null; then
		cmd=$(ps -p "$pid" -o args= 2>/dev/null || true)
		case "$cmd" in
		*heartbeat.sh* | "")
			# The loop spends most of its time in sleep. Collect children first,
			# then signal the loop. A plain TERM is caught so the loop can exit.
			kids=$(pgrep -P "$pid" 2>/dev/null || true)
			kill -TERM "$pid" 2>/dev/null || true
			for kid in $kids; do
				kill -TERM "$kid" 2>/dev/null || true
			done
			;;
		esac
	fi
	return 0
}

escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

post_once() {
	BASE=${CHIEF_STATUS_URL%/}
	case "$BASE" in
	*/status) URL=$BASE ;;
	*) URL="$BASE/status" ;;
	esac
	# No task. The feed keeps the stored working task, and rejects the beat if the bot is idle.
	BODY=$(printf '{"bot":"%s","status":"working","heartbeat":true}' "$(escape "$BOT")")
	curl -sS -o /dev/null -X POST "$URL" \
		-H "Authorization: Bearer ${CHIEF_STATUS_TOKEN}" \
		-H "Content-Type: application/json" \
		--data "$BODY" || true
}

run_loop() {
	file=$(pid_path "$BOT")
	printf '%s\n' "$$" > "$file"
	# exit 0 only. A trap that can fail under set -e lets dash resume the sleep.
	trap 'exit 0' TERM
	every=$(interval)
	while true; do
		post_once
		sleep "$every"
	done
}

require_env() {
	if [ -z "${CHIEF_STATUS_URL:-}" ]; then
		echo "Set CHIEF_STATUS_URL to your worker address." >&2
		exit 1
	fi
	if [ -z "${CHIEF_STATUS_TOKEN:-}" ]; then
		echo "Set CHIEF_STATUS_TOKEN to the worker password." >&2
		exit 1
	fi
}

if [ "${1:-}" = "--loop" ]; then
	shift
	if [ "$#" -lt 1 ]; then
		exit 1
	fi
	require_env
	BOT=$1
	run_loop
	exit 0
fi

if [ "${1:-}" = "stop" ]; then
	if [ "$#" -ne 2 ]; then
		usage
	fi
	end_bot "$2"
	exit 0
fi

if [ "${1:-}" = "start" ]; then
	shift
fi

if [ "$#" -lt 1 ]; then
	usage
fi

require_env
BOT=$1
end_bot "$BOT"
mkdir -p "$(heartbeat_dir)"
file=$(pid_path "$BOT")
nohup "$SCRIPT" --loop "$BOT" >/dev/null 2>&1 &
printf '%s\n' "$!" > "$file"
exit 0
