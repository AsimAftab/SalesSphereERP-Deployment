#!/usr/bin/env bash
#
# sstrack — read-only view of live tracking and raw GPS pings, from the server.
#
#   sstrack live [--org NAME]                 everyone being tracked now (refreshes, Ctrl+C)
#   sstrack follow EMAIL [--keep]             one user's pings as they arrive; stops when
#                                             the session ends (--keep: wait for the next)
#   sstrack user EMAIL [DAY] [--csv]          one user's sessions + every ping
#   sstrack users [DAY] [--org NAME] [--pings] [--csv]
#   sstrack session SESSION_ID [--csv]
#   sstrack find TEXT                         look up a user's email
#
# Runs psql in a throwaway postgres container against DATABASE_URL from this
# repo's .env. The session is read-only (default_transaction_read_only), so no
# command here can change data, and nothing is installed on the host.
#
# One-time, to type `sstrack` from anywhere:  sudo ./scripts/sstrack.sh install

set -euo pipefail

TZ_NPT='Asia/Kathmandu'
IMAGE='postgres:16-alpine'
# Pings older than this are pruned (TRACKING_RETENTION_DAYS); asking for more
# would only return empty days.
MAX_DAYS=15

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
ENV_FILE="${SSTRACK_ENV_FILE:-$REPO_DIR/.env}"
READ_ONLY='-c default_transaction_read_only=on'

usage() {
  cat <<'EOF'
sstrack — live tracking and raw GPS pings (read-only)

  sstrack live [--org NAME]          Everyone being tracked right now. Refreshes every
                                     10 s; Ctrl+C to stop.
  sstrack follow EMAIL               One user's GPS pings as they arrive (like logs -f).
                                     Notes when tracking pauses or resumes, and stops
                                     when the session ends. Ctrl+C to stop sooner.
        --keep                       ...don't stop: wait for the user's next session.
  sstrack user EMAIL [DAY]           One user's tracking, start to end: each session,
                                     then every GPS ping. Prints and stops.
  sstrack users [DAY]                Every tracked user, one line each.
        --pings                      ...plus each user's GPS pings under their name.
  sstrack session SESSION_ID         Every GPS ping of one session.
  sstrack find TEXT                  Find a user's email by name or email.

  DAY        (nothing) = today · yesterday · 3d = last 3 days (up to 15d) · 2026-10-30
  --org NAME limit live/users to organizations whose name contains NAME
  --csv      CSV instead of a table (user, users, session):  ... --csv > file.csv

The screen shows what says whether pings are arriving and where the user is:
"#" (each ping's place in its session), "mark" (▶ START / ● LATEST), time,
address, accuracy (±m, smaller is better), battery, and "late" for a ping the
phone held with no signal. --csv adds everything else (lat/lng, speed,
nearest stop, map link, ...).
"~" marks the last known address carried forward (the phone only looks one up
now and then).
km is the session's cleaned distance, filled in when the session ends; an open
session shows "(open)" — the web shows its distance so far.
Times are Nepal time. Pings are kept for 15 days.
EOF
}

die() { echo "sstrack: $*" >&2; exit 1; }
bad() { echo "sstrack: $*" >&2; echo >&2; usage >&2; exit 1; }

# --- database ---------------------------------------------------------------

load_db() {
  [ -r "$ENV_FILE" ] || die "can't read $ENV_FILE (run this on the server, as the deploy user)"
  local url
  url="$(grep -m1 '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2- || true)"
  url="${url%\"}"; url="${url#\"}"; url="${url%\'}"; url="${url#\'}"
  [ -n "$url" ] || die "DATABASE_URL is not set in $ENV_FILE"
  # Prisma-only options (schema=, sslrootcert= paths inside the app image)
  # mean nothing to psql; Azure needs TLS. SSTRACK_SSLMODE is for local tests.
  SSTRACK_DB="${url%%\?*}?sslmode=${SSTRACK_SSLMODE:-require}"
  export SSTRACK_DB
}

# psql in a throwaway container. The URL travels by environment (-e NAME
# without a value), so it never shows in `ps` on the host. SQL comes on stdin.
run_sql() {
  docker run --rm -i --label sstrack -e SSTRACK_DB -e PGOPTIONS="$READ_ONLY" "$IMAGE" \
    sh -c 'exec psql "$SSTRACK_DB" -X -q -v ON_ERROR_STOP=1 -P pager=off -P null=- "$@"' sh "$@"
}

# A watch loop: one container for the whole watch, not one per refresh.
# --init + the trap make Ctrl+C (or a dropped SSH session) stop it cleanly; the
# label finds a stray one: docker ps --filter label=sstrack
run_watch() {
  local script="$1"; shift
  local tty=()
  if [ -t 0 ] && [ -t 1 ]; then tty=(-t); fi
  docker run --rm -i "${tty[@]}" --init --label sstrack \
    -e SSTRACK_DB -e PGOPTIONS="$READ_ONLY" -e SSTRACK_SQL -e SSTRACK_SQL_INIT -e SSTRACK_SQL_NOW \
    -e SSTRACK_SQL_SESSION -e SSTRACK_SQL_OPEN -e SSTRACK_KEEP \
    "$IMAGE" sh -c "$script" sh "$@"
}

# --- helpers ----------------------------------------------------------------

# A UTC timestamp column shown as Nepal time.
npt() { printf "to_char(%s AT TIME ZONE 'UTC' AT TIME ZONE '%s', '%s')" "$1" "$TZ_NPT" "${2:-YYYY-MM-DD HH24:MI:SS}"; }

# Start/end of the chosen Nepal days, as the UTC timestamps the columns hold.
FROM_UTC="((:'from')::date::timestamp AT TIME ZONE '$TZ_NPT' AT TIME ZONE 'UTC')"
TO_UTC="(((:'to')::date + 1)::timestamp AT TIME ZONE '$TZ_NPT' AT TIME ZONE 'UTC')"
NOW_UTC="(now() AT TIME ZONE 'UTC')"
ORG_MATCH="(:'org' = '' OR o.name ILIKE '%' || :'org' || '%')"

# The phone reverse-geocodes only now and then (the first accurate fix, then
# throttled), so most pings carry no address. Those show the session's last
# address before them, marked "~". Nothing here geocodes — that would cost
# money per lookup; it only reads what the phone saved.
ADDRESS_SQL='coalesce(p."formattedAddress", '"'~ '"' || (
  SELECT q."formattedAddress" FROM "TrackingPing" q
  WHERE q."sessionId" = p."sessionId" AND q."formattedAddress" IS NOT NULL
    AND q."recordedAt" <= p."recordedAt"
  ORDER BY q."recordedAt" DESC LIMIT 1))'
# A ping the phone held (no signal) and sent later: how late it arrived.
LATE_SQL="CASE WHEN p.\"createdAt\" - p.\"recordedAt\" > interval '2 minutes'
  THEN 'sent ' || round(extract(epoch FROM p.\"createdAt\" - p.\"recordedAt\") / 60) || ' min late' END"
# A Google Maps link for a point: free, opens the exact spot.
map_link() {
  printf "'https://maps.google.com/?q=' || round((%s)::numeric, 6) || ',' || round((%s)::numeric, 6)" "$1" "$2"
}

# Sets DAY_FROM / DAY_TO (YYYY-MM-DD, Nepal) and DAY_LABEL.
parse_day() {
  local arg="${1:-}" today n
  # Nepal is a fixed UTC+5:45 with no DST. Computed from UTC rather than
  # TZ=Asia/Kathmandu, which silently falls back to UTC on a host without
  # tzdata and would pick the wrong day around midnight.
  today="$(date -u -d '+5 hours 45 minutes' +%F)"
  case "$arg" in
    ''|today)
      DAY_FROM="$today"; DAY_TO="$today"; DAY_LABEL="today ($today)" ;;
    yesterday)
      DAY_FROM="$(date -u -d "$today -1 day" +%F)"; DAY_TO="$DAY_FROM"; DAY_LABEL="yesterday ($DAY_FROM)" ;;
    [0-9]d|[0-9][0-9]d)
      n=$((10#${arg%d}))
      [ "$n" -ge 1 ] && [ "$n" -le "$MAX_DAYS" ] || bad "use 1d to ${MAX_DAYS}d (pings are kept ${MAX_DAYS} days): $arg"
      DAY_FROM="$(date -u -d "$today -$((n - 1)) day" +%F)"; DAY_TO="$today"
      DAY_LABEL="last $n days ($DAY_FROM to $DAY_TO)" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      [ "$(date -u -d "$arg" +%F 2>/dev/null)" = "$arg" ] || bad "not a real date: $arg"
      DAY_FROM="$arg"; DAY_TO="$arg"; DAY_LABEL="$arg" ;;
    *)
      bad "unknown day '$arg' — use yesterday, 3d or YYYY-MM-DD" ;;
  esac
}

# Prints "<user id><TAB><name>" for an email, or dies.
resolve_user() {
  local email="$1" row
  row="$(run_sql -At -F $'\t' -v email="$email" <<'SQL'
SELECT id, name FROM "User" WHERE lower(email) = lower(:'email');
SQL
)"
  [ -n "$row" ] || die "no user with email $email (try: sstrack find <name>)"
  printf '%s\n' "$row"
}

# A ping's place in its session (1 = its first, by phone time). One count per
# row: used by follow, which only ever numbers a handful of new pings.
PING_NO_SQL='(SELECT count(*) FROM "TrackingPing" q
  WHERE q."sessionId" = p."sessionId"
    AND (q."recordedAt", q."createdAt") <= (p."recordedAt", p."createdAt"))'

# The pings of the sessions matching $1 (a condition on tp), as "p" with each
# ping's place in its session (seq) and the session's ping count (total). The
# reports number whole sessions this way: one pass, where a count per row grew
# with the square of the pings and would load the production database on a
# 15-day report.
session_pings() {
  cat <<SQL
(SELECT tp.*,
        row_number() OVER (PARTITION BY tp."sessionId"
                           ORDER BY tp."recordedAt", tp."createdAt") AS seq,
        count(*) OVER (PARTITION BY tp."sessionId") AS total
   FROM "TrackingPing" tp
  WHERE $1) p
SQL
}

# Columns of one ping row, shared by the user/session/users reports; "p"
# comes from session_pings. "#" numbers the pings within their session (1 =
# its first, by phone time); "mark" flags the session's first ping (START) and
# its newest (LATEST). Both count the whole session, not just the rows the day
# filter kept, so a session that began yesterday is not marked START on
# today's first row.
# On screen only what says "is the server getting pings, and where is the
# rep": number, mark, time, address, GPS accuracy, battery, and how late a
# held-back ping arrived. ping_columns 1 (for --csv) keeps every column.
ping_columns() {
  if [ "${1:-0}" != 1 ]; then
    cat <<SQL
p.seq AS "#",
CASE WHEN p.seq = 1 THEN '▶ START' WHEN p.seq = p.total THEN '● LATEST' END AS mark,
$(npt 'p."recordedAt"') AS time_npt,
$ADDRESS_SQL AS address,
round(p.accuracy::numeric) AS acc_m,
p."batteryLevel" AS batt,
$LATE_SQL AS late
SQL
    return
  fi
  cat <<SQL
p.seq AS "#",
CASE WHEN p.seq = 1 THEN '▶ START' WHEN p.seq = p.total THEN '● LATEST' END AS mark,
$(npt 'p."recordedAt"') AS time_npt,
round(p.latitude::numeric, 6) AS lat,
round(p.longitude::numeric, 6) AS lng,
$ADDRESS_SQL AS address,
round(p.accuracy::numeric) AS acc_m,
round((p.speed * 3.6)::numeric, 1) AS kmh,
p."batteryLevel" AS batt,
p."nearestName" AS nearest_stop,
round((p."nearestDistanceKm" * 1000)::numeric) AS stop_m,
$(npt 'p."createdAt"' 'HH24:MI:SS') AS received,
$(map_link 'p.latitude' 'p.longitude') AS map
SQL
}

# --- commands ---------------------------------------------------------------

cmd_find() {
  [ $# -eq 1 ] || bad "usage: sstrack find TEXT"
  run_sql -v q="$1" <<'SQL'
SELECT u.name, u.email,
       coalesce(string_agg(DISTINCT o.name, ', '), '-') AS organizations,
       coalesce(u."systemRole"::text, '') AS platform_role
FROM "User" u
LEFT JOIN "Membership" m ON m."userId" = u.id
LEFT JOIN "Organization" o ON o.id = m."organizationId"
WHERE u.name ILIKE '%' || :'q' || '%' OR u.email ILIKE '%' || :'q' || '%'
GROUP BY u.id, u.name, u.email, u."systemRole"
ORDER BY u.name
LIMIT 50;
SQL
}

cmd_live() {
  local org="$1"
  SSTRACK_SQL="$(cat <<SQL
\\pset tuples_only on
SELECT 'Live tracking  ' || $(npt "$NOW_UTC") || ' NPT   (refreshes every 10 s · Ctrl+C to stop)';
\\pset tuples_only off
SELECT u.name, bp.name AS beat_plan, s.status,
       $(npt 's."lastPingAt"' 'HH24:MI:SS') AS last_ping,
       round(extract(epoch FROM ($NOW_UTC - s."lastPingAt")) / 60) AS mins_ago,
       (SELECT count(*) FROM "TrackingPing" q WHERE q."sessionId" = s.id) AS pings,
       s."currentBatteryLevel" AS batt,
       round(s."currentAccuracy"::numeric) AS acc_m,
       s."currentAddress" AS now_at
FROM "TrackingSession" s
JOIN "User" u ON u.id = s."userId"
JOIN "Organization" o ON o.id = s."organizationId"
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
WHERE s.status IN ('ACTIVE', 'PAUSED') AND $ORG_MATCH
ORDER BY o.name, u.name;
SQL
)"
  export SSTRACK_SQL
  # shellcheck disable=SC2016  # expanded inside the container
  run_watch '
    trap "exit 0" INT TERM HUP
    while :; do
      out="$(printf "%s\n" "$SSTRACK_SQL" | psql "$SSTRACK_DB" -X -q -P pager=off -P null=- -v org="$1" 2>&1)"
      printf "\033[2J\033[H%s\n" "$out"
      sleep 10
    done' "$org"
}

cmd_follow() {
  local keep="$1"; shift
  [ $# -eq 1 ] || bad "usage: sstrack follow EMAIL [--keep]"
  local email="$1" uid name
  local row
  row="$(resolve_user "$email")"
  uid="${row%%$'\t'*}"; name="${row#*$'\t'}"

  run_sql -v uid="$uid" <<SQL
\\echo
SELECT s.id AS session, bp.name AS beat_plan, s.status,
       $(npt 's."sessionStartedAt"') AS started, $(npt 's."lastPingAt"') AS last_ping
FROM "TrackingSession" s
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
WHERE s."userId" = :'uid'
ORDER BY (s.status <> 'COMPLETED') DESC, s."sessionStartedAt" DESC
LIMIT 1;
SQL
  echo "Following $name <$email> — new GPS pings appear below (Ctrl+C to stop)"
  echo
  # Same widths as the format() in line_sql below.
  printf '%5s  %-7s  %-8s  %-45s  %8s  %7s\n' '#' MARK TIME ADDRESS ACCURACY BATTERY
  printf '%5s  %-7s  %-8s  %-45s  %8s  %7s\n' ----- ------- -------- \
    --------------------------------------------- -------- -------

  # Each row: received-at (exact, to resume from) <TAB> the line to print.
  local line_sql
  line_sql="$(cat <<SQL
to_char(p."createdAt", 'YYYY-MM-DD"T"HH24:MI:SS.US') AS c,
p.id AS pid,
format('%5s  %-7s  %-8s  %-45s  %8s  %7s%s',
  $PING_NO_SQL,
  CASE WHEN $PING_NO_SQL = 1 THEN '▶ START' ELSE '' END,
  $(npt 'p."recordedAt"' 'HH24:MI:SS'),
  coalesce($ADDRESS_SQL, '-'),
  coalesce('±' || round(p.accuracy::numeric) || ' m', '-'),
  coalesce(p."batteryLevel"::text || '%', '-'),
  coalesce('   ' || $LATE_SQL, '')) AS line
FROM "TrackingPing" p
JOIN "TrackingSession" s ON s.id = p."sessionId"
WHERE s."userId" = :'uid'
SQL
)"
  # Start with the last 10 pings for context, then everything newer.
  SSTRACK_SQL_INIT="SELECT c, pid, line FROM (SELECT $line_sql ORDER BY p.\"createdAt\" DESC LIMIT 10) t ORDER BY c;"
  # A minute back from the last ping shown: a ping written by a slower
  # transaction can land with an earlier receipt time than one already shown.
  # Ids already printed are skipped (see show).
  SSTRACK_SQL="SELECT $line_sql AND p.\"createdAt\" > :'since'::timestamp - interval '1 minute' ORDER BY p.\"createdAt\";"
  SSTRACK_SQL_NOW="SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US');"
  # The followed session, one tab-separated row: id, status, ended (or last
  # ping) time, duration, km, pings. km is the stored summary, written when
  # the session closes — which is the only time it is printed.
  local session_cols
  session_cols="$(cat <<SQL
s.id, s.status,
$(npt 'coalesce(s."sessionEndedAt", s."lastPingAt")' 'HH24:MI'),
(floor(extract(epoch FROM coalesce(s."sessionEndedAt", $NOW_UTC) - s."sessionStartedAt") / 3600)::int
   || 'h ' ||
 floor(mod(extract(epoch FROM coalesce(s."sessionEndedAt", $NOW_UTC) - s."sessionStartedAt") / 60, 60))::int
   || 'm'),
round(s."totalDistanceKm"::numeric, 1),
(SELECT count(*) FROM "TrackingPing" q WHERE q."sessionId" = s.id),
bp.name
FROM "TrackingSession" s
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
SQL
)"
  SSTRACK_SQL_SESSION="SELECT $session_cols WHERE s.id = :'sid';"
  SSTRACK_SQL_OPEN="SELECT $session_cols WHERE s.\"userId\" = :'uid' AND s.status IN ('ACTIVE', 'PAUSED') ORDER BY s.\"sessionStartedAt\" DESC LIMIT 1;"
  SSTRACK_KEEP="$keep"
  export SSTRACK_SQL SSTRACK_SQL_INIT SSTRACK_SQL_NOW SSTRACK_SQL_SESSION SSTRACK_SQL_OPEN SSTRACK_KEEP

  # shellcheck disable=SC2016  # expanded inside the container
  run_watch '
    trap "exit 0" INT TERM HUP
    tab="$(printf "\t")"
    psql_q() { psql "$SSTRACK_DB" -X -q -At -F "$tab" -v uid="$1" -v since="$since"; }
    show() {
      while IFS="$tab" read -r c pid line; do
        [ -n "$c" ] || continue
        since="$c"
        grep -qxF "$pid" /tmp/seen 2>/dev/null && continue
        printf "%s\n" "$pid" >> /tmp/seen
        printf "%s\n" "$line"
      done < /tmp/rows
      # Only the last minute is ever re-read.
      if [ "$(wc -l < /tmp/seen)" -gt 2000 ]; then
        tail -n 500 /tmp/seen > /tmp/seen.new && mv /tmp/seen.new /tmp/seen
      fi
    }
    # The followed session: its id, status and closing figures.
    session_row() {
      printf "%s\n" "$2" | psql "$SSTRACK_DB" -X -q -At -F "$tab" -v uid="$1" -v sid="$sid" 2>/dev/null
    }
    read_session() {
      row="$(session_row "$1" "$2")" || return 1
      [ -n "$row" ] || return 1
      IFS="$tab" read -r r_id r_status r_at r_dur r_km r_pings r_plan <<EOF
$row
EOF
    }
    adopt_open() {
      if read_session "$1" "$SSTRACK_SQL_OPEN"; then
        sid="$r_id"; status="$r_status"
        [ "$status" = PAUSED ] && echo "⏸ Paused since $r_at — the phone has stopped sending (no signal, or the app was closed)"
        return 0
      fi
      return 1
    }

    since=""; sid=""; status=""; fails=0; : > /tmp/seen
    printf "%s\n" "$SSTRACK_SQL_INIT" | psql_q "$1" > /tmp/rows && show
    if [ -z "$since" ]; then
      since="$(printf "%s\n" "$SSTRACK_SQL_NOW" | psql "$SSTRACK_DB" -X -q -At)"
      echo "(no pings yet — waiting)"
    fi
    adopt_open "$1" || echo "No open session — waiting for one to start (Ctrl+C to stop)"

    while :; do
      sleep 5
      # A new session is announced before its first ping is printed.
      if [ -z "$sid" ] && adopt_open "$1"; then
        echo "▶ Session started — $r_plan"
      fi
      if printf "%s\n" "$SSTRACK_SQL" | psql_q "$1" > /tmp/rows 2>/dev/null; then
        [ "$fails" -ge 3 ] && echo "✓ Reconnected to the database"
        fails=0
        show
      else
        fails=$((fails + 1))
        # A quiet screen would read as "no pings" when it means "cannot look".
        [ "$fails" -eq 3 ] && echo "⚠ Cannot reach the database — retrying every 5 s (Ctrl+C to stop)"
        continue
      fi
      [ -n "$sid" ] || continue
      read_session "$1" "$SSTRACK_SQL_SESSION" || continue
      [ "$r_status" = "$status" ] && continue
      status="$r_status"
      case "$status" in
        PAUSED) echo "⏸ Paused at $r_at — the phone has stopped sending (no signal, or the app was closed)" ;;
        ACTIVE) echo "▶ Resumed" ;;
        COMPLETED)
          [ "$r_pings" = 1 ] && word=ping || word=pings
          echo "■ Session ended $r_at (COMPLETED) — $r_dur, $r_km km, $r_pings $word"
          [ "$SSTRACK_KEEP" = 1 ] || exit 0
          echo "Waiting for the next session (Ctrl+C to stop)"
          sid="" ;;
      esac
    done' "$uid"
}

cmd_user() {
  local email="" day="" csv="$1"; shift
  [ $# -ge 1 ] || bad "usage: sstrack user EMAIL [DAY]"
  email="$1"; day="${2:-}"
  [ $# -le 2 ] || bad "too many arguments"
  parse_day "$day"
  local uid name
  local row
  row="$(resolve_user "$email")"
  uid="${row%%$'\t'*}"; name="${row#*$'\t'}"

  local pings
  pings="$(cat <<SQL
SELECT $(ping_columns "$csv")$([ "$csv" = 1 ] && echo ', bp.name AS beat_plan, s.id AS session')
FROM $(session_pings "tp.\"sessionId\" IN (
  SELECT us.id FROM \"TrackingSession\" us
   WHERE us.\"userId\" = :'uid' AND us.\"sessionStartedAt\" < $TO_UTC
     AND coalesce(us.\"sessionEndedAt\", $NOW_UTC) >= $FROM_UTC)")
JOIN "TrackingSession" s ON s.id = p."sessionId"
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
WHERE s."userId" = :'uid' AND p."recordedAt" >= $FROM_UTC AND p."recordedAt" < $TO_UTC
ORDER BY p."recordedAt", p."createdAt"
SQL
)"
  if [ "$csv" = 1 ]; then
    printf '%s;\n' "$pings" | run_sql --csv -P null= -v uid="$uid" -v from="$DAY_FROM" -v to="$DAY_TO"
    return
  fi

  echo "$name <$email> — $DAY_LABEL, Nepal time"
  echo
  run_sql -v uid="$uid" -v from="$DAY_FROM" -v to="$DAY_TO" <<SQL
\\echo 'Sessions'
SELECT s.id AS session, bp.name AS beat_plan, s.status,
       $(npt 's."sessionStartedAt"') AS started,
       $(npt 's."sessionEndedAt"') AS ended,
       CASE WHEN s.status = 'COMPLETED' THEN round(s."totalDistanceKm"::numeric, 2)::text ELSE '(open)' END AS km,
       round(CASE WHEN s.status = 'COMPLETED' THEN s."totalDurationMin"
                  ELSE extract(epoch FROM $NOW_UTC - s."sessionStartedAt") / 60 END::numeric) AS mins,
       (SELECT count(*) FROM "TrackingPing" p
         WHERE p."sessionId" = s.id
           AND p."recordedAt" >= $FROM_UTC AND p."recordedAt" < $TO_UTC) AS pings
FROM "TrackingSession" s
JOIN "Organization" o ON o.id = s."organizationId"
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
WHERE s."userId" = :'uid'
  AND s."sessionStartedAt" < $TO_UTC
  AND coalesce(s."sessionEndedAt", $NOW_UTC) >= $FROM_UTC
ORDER BY s."sessionStartedAt";
\\echo 'GPS pings (late = held by the phone with no signal, sent when it came back)'
$pings;
SQL
}

cmd_session() {
  local csv="$1"; shift
  [ $# -eq 1 ] || bad "usage: sstrack session SESSION_ID"
  local found
  found="$(run_sql -At -v sid="$1" <<'SQL'
SELECT count(*) FROM "TrackingSession" WHERE id = :'sid';
SQL
)"
  [ "$found" = 1 ] || die "no session with id $1 (sstrack user EMAIL lists a user's sessions)"
  local pings
  pings="$(cat <<SQL
SELECT $(ping_columns "$csv")
FROM $(session_pings "tp.\"sessionId\" = :'sid'")
ORDER BY p."recordedAt", p."createdAt"
SQL
)"
  if [ "$csv" = 1 ]; then
    printf '%s;\n' "$pings" | run_sql --csv -P null= -v sid="$1"
    return
  fi
  run_sql -v sid="$1" <<SQL
SELECT s.id AS session, u.name, bp.name AS beat_plan, s.status,
       $(npt 's."sessionStartedAt"') AS started, $(npt 's."sessionEndedAt"') AS ended,
       CASE WHEN s.status = 'COMPLETED' THEN round(s."totalDistanceKm"::numeric, 2)::text ELSE '(open)' END AS km
FROM "TrackingSession" s
JOIN "User" u ON u.id = s."userId"
JOIN "Organization" o ON o.id = s."organizationId"
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
WHERE s.id = :'sid';
$pings;
SQL
}

cmd_users() {
  local csv="$1" org="$2" with_pings="$3"; shift 3
  [ $# -le 1 ] || bad "usage: sstrack users [DAY] [--org NAME] [--pings]"
  parse_day "${1:-}"
  local vars=(-v from="$DAY_FROM" -v to="$DAY_TO" -v org="$org")

  # Sessions that overlap the range, so pings are read by (sessionId, recordedAt).
  local in_range
  in_range="$(cat <<SQL
FROM $(session_pings "tp.\"sessionId\" IN (
  SELECT rs.id FROM \"TrackingSession\" rs
   WHERE rs.\"sessionStartedAt\" < $TO_UTC
     AND coalesce(rs.\"sessionEndedAt\", $NOW_UTC) >= $FROM_UTC - interval '1 day')")
JOIN "TrackingSession" s ON s.id = p."sessionId"
JOIN "User" u ON u.id = s."userId"
JOIN "Organization" o ON o.id = s."organizationId"
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
WHERE s."sessionStartedAt" < $TO_UTC
  AND coalesce(s."sessionEndedAt", $NOW_UTC) >= $FROM_UTC - interval '1 day'
  AND p."recordedAt" >= $FROM_UTC AND p."recordedAt" < $TO_UTC
  AND $ORG_MATCH
SQL
)"
  local summary
  summary="$(cat <<SQL
WITH per_session AS (
  SELECT s.id, s."userId", s."organizationId", s.status, s."totalDistanceKm",
         min(p."recordedAt") AS first_at, max(p."recordedAt") AS last_at, count(*) AS n,
         (array_agg(p."batteryLevel" ORDER BY p."recordedAt" DESC))[1] AS batt
  $in_range
  GROUP BY s.id
)
SELECT u.name, o.name AS org, count(*) AS sessions,
       $(npt 'min(ps.first_at)' 'MM-DD HH24:MI') AS first_ping,
       $(npt 'max(ps.last_at)' 'MM-DD HH24:MI') AS last_ping,
       sum(ps.n) AS pings,
       CASE WHEN bool_and(ps.status IN ('ACTIVE', 'PAUSED')) THEN '(open)'
            WHEN bool_or(ps.status IN ('ACTIVE', 'PAUSED'))
              THEN round((sum(ps."totalDistanceKm") FILTER (WHERE ps.status = 'COMPLETED'))::numeric, 2) || ' + open'
            ELSE round(sum(ps."totalDistanceKm")::numeric, 2)::text END AS km,
       (array_agg(ps.batt ORDER BY ps.last_at DESC))[1] AS batt,
       CASE WHEN bool_or(ps.status IN ('ACTIVE', 'PAUSED')) THEN 'yes' ELSE '' END AS tracking_now,
       u.email
FROM per_session ps
JOIN "User" u ON u.id = ps."userId"
JOIN "Organization" o ON o.id = ps."organizationId"
GROUP BY u.id, u.name, u.email, o.id, o.name
ORDER BY o.name, u.name
SQL
)"
  local pings
  pings="$(cat <<SQL
SELECT o.name AS org, u.name, u.email, $(ping_columns "$csv")$([ "$csv" = 1 ] && echo ', bp.name AS beat_plan')
$in_range
ORDER BY o.name, u.name, u.email, p."recordedAt", p."createdAt"
SQL
)"

  if [ "$csv" = 1 ]; then
    if [ "$with_pings" = 1 ]; then
      printf '%s;\n' "$pings" | run_sql --csv -P null= "${vars[@]}"
    else
      printf '%s;\n' "$summary" | run_sql --csv -P null= "${vars[@]}"
    fi
    return
  fi

  echo "Tracked users — $DAY_LABEL, Nepal time${org:+ — organizations matching \"$org\"}"
  # On screen: who, how many pings, until when, and whether still tracking.
  printf '%s;\n' "SELECT name, sessions, first_ping, last_ping, pings, km, batt, tracking_now
FROM ($summary) t ORDER BY org, name" | run_sql "${vars[@]}"
  [ "$with_pings" = 1 ] || return 0

  # One heading per user, then their pings.
  printf '%s;\n' "$pings" | run_sql -At -F $'\t' "${vars[@]}" | awk -F '\t' '
    {
      key = $1 FS $3
      if (key != last) {
        printf "\n== %s — %s ==\n", $2, $1
        printf "%5s  %-8s  %-19s  %-45s %6s %5s  %s\n", "#", "mark", "time_npt", "address", "acc_m", "batt", "late"
        last = key
      }
      late = ($10 == "-") ? "" : $10
      printf "%5s  %-8s  %-19s  %-45s %6s %5s  %s\n", $4, ($5 == "-" ? "" : $5), $6, $7, $8, $9, late
    }'
}

cmd_install() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $SELF install"
  chmod +x "$SELF"
  ln -sf "$SELF" /usr/local/bin/sstrack
  echo "Installed: type 'sstrack' from anywhere (links to $SELF)."
}

# --- main -------------------------------------------------------------------

main() {
  local cmd="${1:-help}"; [ $# -gt 0 ] && shift
  local csv=0 org="" with_pings=0 keep=0 args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --csv) csv=1 ;;
      --pings) with_pings=1 ;;
      --keep) keep=1 ;;
      --org) [ $# -ge 2 ] || bad "--org needs a name"; org="$2"; shift ;;
      --org=*) org="${1#--org=}" ;;
      -h|--help) usage; exit 0 ;;
      -*) bad "unknown option $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  case "$cmd" in
    help|-h|--help) usage; return ;;
    install) cmd_install; return ;;
  esac

  command -v docker >/dev/null || die "docker is not installed"
  load_db
  case "$cmd" in
    live) [ ${#args[@]} -eq 0 ] || bad "usage: sstrack live [--org NAME]"; cmd_live "$org" ;;
    follow) cmd_follow "$keep" "${args[@]}" ;;
    user) cmd_user "$csv" "${args[@]}" ;;
    users) cmd_users "$csv" "$org" "$with_pings" "${args[@]}" ;;
    session) cmd_session "$csv" "${args[@]}" ;;
    find) cmd_find "${args[@]}" ;;
    # Internal, for sslogs: the user id of an email.
    _userid) [ ${#args[@]} -eq 1 ] || bad "usage: sstrack _userid EMAIL"
             row="$(resolve_user "${args[0]}")"; printf '%s\n' "${row%%$'\t'*}" ;;
    *) bad "unknown command: $cmd" ;;
  esac
}

main "$@"
