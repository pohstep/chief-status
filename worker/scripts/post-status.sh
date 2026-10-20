#!/bin/sh
# Post one bot status line to the Chief Status feed.
#
#   export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
#   export CHIEF_STATUS_TOKEN="the password you gave the worker"
#   export CHIEF_STATUS_BOT_URL="https://example.com/agent1"   # optional chat link
#   export CHIEF_STATUS_BOT_COLOR="#3B82F6"                    # optional #RRGGBB
#   ./post-status.sh Agent1 working "drafting the homepage"
#   ./post-status.sh Agent1 needs_input "approve the homepage copy" --approval
#   ./post-status.sh Agent1 heartbeat            # still on the current working task
#
# Working is the first step of a turn, including a voice turn. It posts working
# and starts heartbeat.sh for this bot. Idle is the last step, including a voice
# turn. Idle stops the heartbeat and posts idle only when this bot has no other
# live turn. The count lives in the heartbeat folder, one file per turn.
#
# started_at is sent for "working" and "needs_input". It is the job clock.
# The feed records last_posted_at itself, and the 404 uses that, so a long job
# that keeps posting does not go black. done, failed and idle let the feed keep
# the job clock, which is what today's durations are based on.
#
# heartbeat: one ping during a long job. It sends no task, refreshes
# last_posted_at, and keeps the job clock. The feed refuses it (409) unless the
# bot is already working, so a late beat cannot light an idle bot. heartbeat.sh
# repeats this every 3 minutes. A working post starts that loop. Idle stops it
# when the last turn ends. Give heartbeat a TASK only to change the task text
# on a bot that is already working.
#
# STATUS is one of: idle, working, failed, done, needs_input, heartbeat
#   needs_input means the bot is waiting on you.
#   Add --approval, or set CHIEF_STATUS_APPROVAL=1, when it needs an approval
#   rather than an answer. The task text must say exactly what is needed:
#   the question, or the thing to approve. Do not leave it vague.
# The address can be the worker root or the full /status address.
# This script never prints the token.

set -eu

usage() {
	echo "Usage: post-status.sh BOT STATUS TASK [--approval]" >&2
	echo "       post-status.sh BOT heartbeat [TASK]" >&2
	echo "  STATUS is idle, working, failed, done, or needs_input" >&2
	echo "  needs_input: the task must say exactly what is needed." >&2
	echo "  --approval (or CHIEF_STATUS_APPROVAL=1) is only for needs_input." >&2
	echo "  working starts heartbeat.sh. idle stops it when the last turn ends." >&2
	echo "  heartbeat keeps the current working task fresh without moving its clock." >&2
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

turn_dir() {
	safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
	printf '%s/%s.turns\n' "$(heartbeat_dir)" "$safe"
}

turn_ttl() {
	raw=${CHIEF_STATUS_TURN_TTL_SECONDS:-1200}
	case "$raw" in
	*[!0-9]* | "")
		printf '1200\n'
		;;
	*)
		if [ "$raw" -lt 1 ]; then
			printf '1200\n'
		else
			printf '%s\n' "$raw"
		fi
		;;
	esac
}

lock_turns() {
	dir=$(turn_dir "$1")
	mkdir -p "$(dirname "$dir")"
	lock="${dir}.lock"
	i=0
	while ! mkdir "$lock" 2>/dev/null; do
		i=$((i + 1))
		if [ "$i" -gt 100 ]; then
			echo "Could not lock live turns." >&2
			exit 1
		fi
		sleep 0.05
	done
}

unlock_turns() {
	rmdir "$(turn_dir "$1").lock" 2>/dev/null || true
}

# A crashed turn stops counting after the ttl, so a later idle can still go grey.
expire_turns() {
	dir=$(turn_dir "$1")
	[ -d "$dir" ] || return 0
	now=$(date +%s)
	ttl=$(turn_ttl)
	for file in "$dir"/turn.*; do
		[ -f "$file" ] || continue
		IFS= read -r stamp < "$file" || stamp=""
		case "$stamp" in
		"" | *[!0-9]*)
			rm -f "$file"
			continue
			;;
		esac
		if [ $((now - stamp)) -ge "$ttl" ]; then
			rm -f "$file"
		fi
	done
}

add_turn() {
	dir=$(turn_dir "$1")
	mkdir -p "$dir"
	file=$(mktemp "${dir}/turn.XXXXXX")
	printf '%s\n' "$(date +%s)" > "$file"
}

drop_turn() {
	dir=$(turn_dir "$1")
	[ -d "$dir" ] || return 0
	for file in "$dir"/turn.*; do
		if [ -f "$file" ]; then
			rm -f "$file"
			return 0
		fi
	done
	return 0
}

count_turns() {
	dir=$(turn_dir "$1")
	n=0
	if [ -d "$dir" ]; then
		for file in "$dir"/turn.*; do
			if [ -f "$file" ]; then
				n=$((n + 1))
			fi
		done
	fi
	printf '%s\n' "$n"
}

if [ "$#" -lt 2 ]; then
	usage
fi
if [ "$#" -lt 3 ] && [ "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" != "heartbeat" ]; then
	usage
fi

BOT=$1
STATUS=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
shift 2

# The env var only applies to a needs_input post. --approval on any other status is a mistake.
ENV_APPROVAL=0
case "$(printf '%s' "${CHIEF_STATUS_APPROVAL:-}" | tr '[:upper:]' '[:lower:]')" in
1 | true | yes | on) ENV_APPROVAL=1 ;;
esac
FLAG_APPROVAL=0

TASK=""
for arg in "$@"; do
	if [ "$arg" = "--approval" ]; then
		FLAG_APPROVAL=1
	else
		if [ -n "$TASK" ]; then
			TASK="$TASK $arg"
		else
			TASK=$arg
		fi
	fi
done

case "$STATUS" in
idle | working | failed | done | needs_input | heartbeat) ;;
*)
	echo "Status must be idle, working, failed, done, needs_input, or heartbeat." >&2
	exit 1
	;;
esac

if [ "$FLAG_APPROVAL" -eq 1 ] && [ "$STATUS" != "needs_input" ]; then
	echo "--approval is only for needs_input. The task must say exactly what is needed." >&2
	exit 1
fi

APPROVAL=0
if [ "$STATUS" = "needs_input" ]; then
	if [ "$FLAG_APPROVAL" -eq 1 ] || [ "$ENV_APPROVAL" -eq 1 ]; then
		APPROVAL=1
	fi
fi

if [ -z "${CHIEF_STATUS_URL:-}" ]; then
	echo "Set CHIEF_STATUS_URL to your worker address." >&2
	exit 1
fi
if [ -z "${CHIEF_STATUS_TOKEN:-}" ]; then
	echo "Set CHIEF_STATUS_TOKEN to the worker password." >&2
	exit 1
fi

BASE=${CHIEF_STATUS_URL%/}
case "$BASE" in
*/status) URL=$BASE ;;
*) URL="$BASE/status" ;;
esac

# Overlapping turns share one feed row. Idle, done and failed wait until the last turn.
case "$STATUS" in
working)
	lock_turns "$BOT"
	expire_turns "$BOT"
	add_turn "$BOT"
	unlock_turns "$BOT"
	;;
idle)
	lock_turns "$BOT"
	expire_turns "$BOT"
	drop_turn "$BOT"
	left=$(count_turns "$BOT")
	unlock_turns "$BOT"
	if [ "$left" -gt 0 ]; then
		printf '{"ok":true,"skipped":"idle","live_turns":%s}\n' "$left"
		exit 0
	fi
	"$(dirname "$0")/heartbeat.sh" stop "$BOT" >/dev/null 2>&1 || true
	;;
done | failed)
	lock_turns "$BOT"
	expire_turns "$BOT"
	left=$(count_turns "$BOT")
	unlock_turns "$BOT"
	if [ "$left" -gt 1 ]; then
		printf '{"ok":true,"skipped":"%s","live_turns":%s}\n' "$STATUS" "$left"
		exit 0
	fi
	"$(dirname "$0")/heartbeat.sh" stop "$BOT" >/dev/null 2>&1 || true
	;;
esac

STARTED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

started_field=""
if [ "$STATUS" = "working" ] || [ "$STATUS" = "needs_input" ]; then
	started_field=$(printf ',"started_at":"%s"' "$STARTED")
fi
url_field=""
if [ -n "${CHIEF_STATUS_BOT_URL:-}" ]; then
	url_field=$(printf ',"url":"%s"' "$(escape "$CHIEF_STATUS_BOT_URL")")
fi
color_field=""
if [ -n "${CHIEF_STATUS_BOT_COLOR:-}" ]; then
	color_field=$(printf ',"color":"%s"' "$(escape "$CHIEF_STATUS_BOT_COLOR")")
fi
approval_field=""
if [ "$APPROVAL" -eq 1 ]; then
	approval_field=',"approval":true'
fi
BODY=$(printf '{"bot":"%s","status":"%s","task":"%s"%s%s%s%s}' \
	"$(escape "$BOT")" \
	"$(escape "$STATUS")" \
	"$(escape "$TASK")" \
	"$started_field" \
	"$url_field" \
	"$color_field" \
	"$approval_field")
if [ "$STATUS" = "heartbeat" ]; then
	# No task unless one was passed. A task is only a text change, and only while working.
	task_field=""
	if [ -n "$TASK" ]; then
		task_field=$(printf ',"task":"%s"' "$(escape "$TASK")")
	fi
	BODY=$(printf '{"bot":"%s","status":"working","heartbeat":true%s}' "$(escape "$BOT")" "$task_field")
fi

tmp=$(mktemp)
code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$URL" \
	-H "Authorization: Bearer ${CHIEF_STATUS_TOKEN}" \
	-H "Content-Type: application/json" \
	--data "$BODY") || {
	rm -f "$tmp"
	if [ "$STATUS" = "working" ]; then
		lock_turns "$BOT"
		drop_turn "$BOT"
		unlock_turns "$BOT"
	fi
	echo "Couldn't reach the feed." >&2
	exit 1
}

cat "$tmp"
printf '\n'
rm -f "$tmp"

if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
	if [ "$STATUS" = "working" ]; then
		lock_turns "$BOT"
		drop_turn "$BOT"
		unlock_turns "$BOT"
	fi
	exit 1
fi

if [ "$STATUS" = "working" ]; then
	"$(dirname "$0")/heartbeat.sh" start "$BOT" >/dev/null 2>&1 || true
fi
