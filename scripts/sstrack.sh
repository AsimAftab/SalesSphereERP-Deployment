#!/usr/bin/env bash
#
# sstrack — read-only view of live tracking and raw GPS pings, from the server.
#
#   sstrack live [--org NAME]                 everyone being tracked now (refreshes, Ctrl+C)
#   sstrack follow EMAIL                      one user's pings as they arrive (Ctrl+C)
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
                                     Ctrl+C to stop.
  sstrack user EMAIL [DAY]           One user's tracking, start to end: each session,
                                     then every GPS ping. Prints and stops.
  sstrack users [DAY]                Every tracked user, one line each.
        --pings                      ...plus each user's GPS pings under their name.
  sstrack session SESSION_ID         Every GPS ping of one session.
  sstrack find TEXT                  Find a user's email by name or email.

  DAY        (nothing) = today · yesterday · 3d = last 3 days (up to 15d) · 2026-10-30
  --org NAME limit live/users to organizations whose name contains NAME
  --csv      CSV instead of a table (user, users, session):  ... --csv > file.csv

Each ping shows the address the phone saved; "~" marks the last known address
carried forward (the phone only looks one up now and then). "map" is a Google
Maps link to the exact point. "#" numbers each ping within its session, and
"mark" shows the session's first ping (▶ START) and its newest (● LATEST).
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

# A ping's place in its session (1 = its first, by phone time).
PING_NO_SQL='(SELECT count(*) FROM "TrackingPing" q
  WHERE q."sessionId" = p."sessionId"
    AND (q."recordedAt", q."createdAt") <= (p."recordedAt", p."createdAt"))'

# Columns of one ping row, shared by the user/session/users reports.
# "#" numbers the pings within their session (1 = its first, by phone time);
# "mark" flags the session's first ping (START) and its newest (LATEST). Both
# look at the whole session, not just the rows the day filter kept, so a
# session that began yesterday is not marked START on today's first row.
ping_columns() {
  cat <<SQL
$PING_NO_SQL AS "#",
CASE
  WHEN NOT EXISTS (SELECT 1 FROM "TrackingPing" q
                   WHERE q."sessionId" = p."sessionId"
                     AND (q."recordedAt", q."createdAt") < (p."recordedAt", p."createdAt"))
    THEN '▶ START'
  WHEN NOT EXISTS (SELECT 1 FROM "TrackingPing" q
                   WHERE q."sessionId" = p."sessionId"
                     AND (q."recordedAt", q."createdAt") > (p."recordedAt", p."createdAt"))
    THEN '● LATEST'
END AS mark,
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
SELECT u.name, o.name AS org, bp.name AS beat_plan, s.status,
       round(s."currentLatitude"::numeric, 6) AS lat,
       round(s."currentLongitude"::numeric, 6) AS lng,
       s."currentAddress" AS address,
       round(s."currentAccuracy"::numeric) AS acc_m,
       s."currentBatteryLevel" AS batt,
       (SELECT count(*) FROM "TrackingPing" q WHERE q."sessionId" = s.id) AS pings,
       $(npt 's."lastPingAt"' 'HH24:MI:SS') AS last_ping,
       round(extract(epoch FROM ($NOW_UTC - s."lastPingAt")) / 60) AS mins_ago,
       u.email,
       $(map_link 's."currentLatitude"' 's."currentLongitude"') AS map
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
  [ $# -eq 1 ] || bad "usage: sstrack follow EMAIL"
  local email="$1" uid name
  local row
  row="$(resolve_user "$email")"
  uid="${row%%$'\t'*}"; name="${row#*$'\t'}"

  run_sql -v uid="$uid" <<SQL
\\echo
SELECT s.id AS session, o.name AS org, bp.name AS beat_plan, s.status,
       $(npt 's."sessionStartedAt"') AS started, $(npt 's."lastPingAt"') AS last_ping
FROM "TrackingSession" s
JOIN "Organization" o ON o.id = s."organizationId"
JOIN "BeatPlan" bp ON bp.id = s."beatPlanId"
WHERE s."userId" = :'uid'
ORDER BY s."sessionStartedAt" DESC
LIMIT 1;
SQL
  echo "Following $name <$email> — new GPS pings appear below (Ctrl+C to stop)"
  echo "ACCURACY = how close the GPS fix is likely to be (±m; smaller is better)."
  echo
  # Same widths as the format() in line_sql below.
  printf '%5s  %-7s  %-8s  %-10s  %-10s  %-32s  %8s  %9s  %7s  %-22s  %s\n' \
    '#' MARK TIME LAT LNG ADDRESS ACCURACY SPEED BATTERY 'NEAREST STOP' MAP
  printf '%5s  %-7s  %-8s  %-10s  %-10s  %-32s  %8s  %9s  %7s  %-22s  %s\n' \
    ----- ------- -------- ---------- ---------- -------------------------------- -------- --------- ------- \
    ---------------------- ---

  # Each row: received-at (exact, to resume from) <TAB> the line to print.
  local line_sql
  line_sql="$(cat <<SQL
to_char(p."createdAt", 'YYYY-MM-DD"T"HH24:MI:SS.US') AS c,
format('%5s  %-7s  %-8s  %-10s  %-10s  %-32s  %8s  %9s  %7s  %-22s  %s%s',
  $PING_NO_SQL,
  CASE WHEN $PING_NO_SQL = 1 THEN '▶ START' ELSE '' END,
  $(npt 'p."recordedAt"' 'HH24:MI:SS'),
  round(p.latitude::numeric, 6), round(p.longitude::numeric, 6),
  coalesce($ADDRESS_SQL, '-'),
  coalesce('±' || round(p.accuracy::numeric) || ' m', '-'),
  coalesce(round((p.speed * 3.6)::numeric, 1) || ' km/h', '-'),
  coalesce(p."batteryLevel"::text || '%', '-'),
  coalesce(p."nearestName" || ' (' || round((p."nearestDistanceKm" * 1000)::numeric) || ' m)', '-'),
  $(map_link 'p.latitude' 'p.longitude'),
  CASE WHEN p."createdAt" - p."recordedAt" > interval '2 minutes'
       THEN '  [sent ' || round(extract(epoch FROM p."createdAt" - p."recordedAt") / 60) || ' min late]'
       ELSE '' END) AS line
FROM "TrackingPing" p
JOIN "TrackingSession" s ON s.id = p."sessionId"
WHERE s."userId" = :'uid'
SQL
)"
  # Start with the last 10 pings for context, then everything newer.
  SSTRACK_SQL_INIT="SELECT c, line FROM (SELECT $line_sql ORDER BY p.\"createdAt\" DESC LIMIT 10) t ORDER BY c;"
  SSTRACK_SQL="SELECT $line_sql AND p.\"createdAt\" > :'since'::timestamp ORDER BY p.\"createdAt\";"
  SSTRACK_SQL_NOW="SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US');"
  export SSTRACK_SQL SSTRACK_SQL_INIT SSTRACK_SQL_NOW

  # shellcheck disable=SC2016  # expanded inside the container
  run_watch '
    trap "exit 0" INT TERM HUP
    tab="$(printf "\t")"
    psql_q() { psql "$SSTRACK_DB" -X -q -At -F "$tab" -v uid="$1" -v since="$since"; }
    show() {
      while IFS="$tab" read -r c line; do
        [ -n "$c" ] || continue
        printf "%s\n" "$line"; since="$c"
      done < /tmp/rows
    }
    since=""
    printf "%s\n" "$SSTRACK_SQL_INIT" | psql_q "$1" > /tmp/rows && show
    if [ -z "$since" ]; then
      since="$(printf "%s\n" "$SSTRACK_SQL_NOW" | psql "$SSTRACK_DB" -X -q -At)"
      echo "(no pings yet — waiting)"
    fi
    while :; do
      sleep 5
      printf "%s\n" "$SSTRACK_SQL" | psql_q "$1" > /tmp/rows 2>/dev/null && show
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
SELECT $(ping_columns), bp.name AS beat_plan, s.id AS session
FROM "TrackingPing" p
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
SELECT s.id AS session, o.name AS org, bp.name AS beat_plan, s.status,
       $(npt 's."sessionStartedAt"') AS started,
       $(npt 's."sessionEndedAt"') AS ended,
       round(s."totalDistanceKm"::numeric, 2) AS km,
       round(s."totalDurationMin"::numeric) AS mins,
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
\\echo 'GPS pings (kmh = speed from the phone; received = when the server got it)'
$pings;
SQL
}

cmd_session() {
  local csv="$1"; shift
  [ $# -eq 1 ] || bad "usage: sstrack session SESSION_ID"
  local pings
  pings="$(cat <<SQL
SELECT $(ping_columns)
FROM "TrackingPing" p
WHERE p."sessionId" = :'sid'
ORDER BY p."recordedAt", p."createdAt"
SQL
)"
  if [ "$csv" = 1 ]; then
    printf '%s;\n' "$pings" | run_sql --csv -P null= -v sid="$1"
    return
  fi
  run_sql -v sid="$1" <<SQL
SELECT s.id AS session, u.name, u.email, o.name AS org, bp.name AS beat_plan, s.status,
       $(npt 's."sessionStartedAt"') AS started, $(npt 's."sessionEndedAt"') AS ended,
       round(s."totalDistanceKm"::numeric, 2) AS km
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
FROM "TrackingPing" p
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
       round(sum(ps."totalDistanceKm")::numeric, 2) AS km,
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
SELECT o.name AS org, u.name, u.email, $(ping_columns), bp.name AS beat_plan
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
  printf '%s;\n' "$summary" | run_sql "${vars[@]}"
  [ "$with_pings" = 1 ] || return 0

  # One heading per user, then their pings.
  printf '%s;\n' "$pings" | run_sql -At -F $'\t' "${vars[@]}" | awk -F '\t' '
    {
      key = $1 FS $3
      if (key != last) {
        printf "\n== %s <%s> — %s ==\n", $2, $3, $1
        printf "%5s  %-8s  %-19s  %-10s %-10s  %-32s %6s %6s %5s  %-8s  %s\n", "#", "mark", "time_npt", "lat", "lng", "address", "acc_m", "kmh", "batt", "received", "nearest stop · map"
        last = key
      }
      stop = ($13 == "" || $13 == "-") ? "" : $13 " (" $14 " m) · "
      printf "%5s  %-8s  %-19s  %-10s %-10s  %-32s %6s %6s %5s  %-8s  %s%s\n", $4, $5, $6, $7, $8, $9, $10, $11, $12, $15, stop, $16
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
  local csv=0 org="" with_pings=0 args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --csv) csv=1 ;;
      --pings) with_pings=1 ;;
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
    follow) cmd_follow "${args[@]}" ;;
    user) cmd_user "$csv" "${args[@]}" ;;
    users) cmd_users "$csv" "$org" "$with_pings" "${args[@]}" ;;
    session) cmd_session "$csv" "${args[@]}" ;;
    find) cmd_find "${args[@]}" ;;
    *) bad "unknown command: $cmd" ;;
  esac
}

main "$@"
