#!/usr/bin/env bash
#
# sslogs — readable server logs and a health snapshot (read-only).
#
#   sslogs status                              containers, CPU/memory, disk, API + site health
#   sslogs errors [--since 1h]                 warnings and errors from the API
#   sslogs slow [--since 2h] [--top 25]        the slowest API requests
#   sslogs api [--since 30m] [-f]              API requests and events (-f: keep streaming)
#   sslogs user EMAIL [--since 24h]            log lines about one user (tracking, sockets, jobs)
#   sslogs web [--since 1h] [--errors]         website + API access log from Caddy
#
# Reads `docker logs` of the running containers and turns their JSON into one
# readable line each: Nepal time, no request ids, IPs or process noise, and
# tokens in URLs masked. Changes nothing, restarts nothing.
#
# One-time, to type `sslogs` from anywhere:  sudo ./scripts/sslogs.sh install

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
ENV_FILE="${SSLOGS_ENV_FILE:-$REPO_DIR/.env}"
DOCKER="${SSLOGS_DOCKER:-docker}"
APP="${SSLOGS_APP:-salessphere-app}"
CADDY="${SSLOGS_CADDY:-salessphere-caddy}"

usage() {
  cat <<'EOF'
sslogs — readable server logs and a health snapshot (read-only)

  sslogs status                      Containers, CPU/memory, server load, disk,
                                     and how fast the API and website answer.
  sslogs errors [--since 1h]         Warnings and errors from the API.
  sslogs slow [--since 2h]           The slowest API requests, slowest first.
        --top N                      ...how many to list (default 25).
  sslogs api [--since 30m]           API requests and events, one line each.
        -f                           ...keep streaming new lines (Ctrl+C to stop).
  sslogs user EMAIL [--since 24h]    Log lines about one user: tracking, sockets,
                                     jobs. (Plain API requests carry no user, so
                                     they are not in here — use api.)
  sslogs web [--since 1h]            Website + API access log from Caddy.
        --errors                     ...only 4xx/5xx responses.

  --since    how far back: 30m, 2h, 1d (up to what the container still holds)

Times are Nepal time. Request ids, IP addresses and process details are left
out, and tokens in URLs are masked.
EOF
}

die() { echo "sslogs: $*" >&2; exit 1; }
bad() { echo "sslogs: $*" >&2; echo >&2; usage >&2; exit 1; }

# 30m / 2h / 1d -> what `docker logs --since` takes (it has no "d").
since_arg() {
  case "$1" in
    [0-9]*m|[0-9]*h) [[ "$1" =~ ^[0-9]+[mh]$ ]] || bad "use 30m, 2h or 1d: $1"; echo "$1" ;;
    [0-9]*d) [[ "$1" =~ ^[0-9]+d$ ]] || bad "use 30m, 2h or 1d: $1"; echo "$(( ${1%d} * 24 ))h" ;;
    *) bad "use 30m, 2h or 1d: $1" ;;
  esac
}

container_up() {
  [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = true ] \
    || die "container $1 is not running (sslogs status shows what is)"
}

# --- the formatter ------------------------------------------------------------
# One JSON log line in, one readable line out. Modes: api, errors, slow, user,
# web. Lines that are not JSON (a crash trace, a startup message) are passed
# through in api mode, and in errors mode when they look like an error.
FORMATTER="$(cat <<'PY'
import json, re, sys
from datetime import datetime, timedelta, timezone

NPT = timezone(timedelta(hours=5, minutes=45))
LEVELS = {10: 'TRACE', 20: 'DEBUG', 30: 'INFO', 40: 'WARN', 50: 'ERROR', 60: 'FATAL'}
# Never shown: request ids, IPs, process details, and what the line already says.
NOISE = {'level', 'time', 'msg', 'pid', 'hostname', 'env', 'v', 'id', 'reqId', 'ip',
         'remoteAddress', 'socketId', 'method', 'url', 'status', 'durationMs', 'err'}
SECRET = re.compile(r'([?&](?:token|code|key|secret|signature|sig|password|otp)=)[^&\s"]+', re.I)
mode = sys.argv[1]
arg = sys.argv[2] if len(sys.argv) > 2 else ''


def when(ms):
    return datetime.fromtimestamp(ms / 1000, NPT).strftime('%m-%d %H:%M:%S')


def mask(text):
    return SECRET.sub(r'\1***', str(text))


def extras(obj):
    parts = []
    for k, v in obj.items():
        if k in NOISE or v is None:
            continue
        if isinstance(v, bool):
            v = 'true' if v else 'false'
        elif not isinstance(v, (str, int, float)):
            v = json.dumps(v, separators=(',', ':'))
        parts.append(f'{k}={mask(v)}')
    line = ' '.join(parts)
    return line if len(line) <= 240 else line[:237] + '...'


def app_line(obj):
    level = LEVELS.get(obj.get('level'), str(obj.get('level', '')))
    t = when(obj['time']) if isinstance(obj.get('time'), (int, float)) else '--'
    if 'method' in obj and 'url' in obj and 'status' in obj:
        return f"{t}  {level:5}  {obj['method']:6} {obj['status']}  {obj.get('durationMs', '?'):>6} ms  {mask(obj['url'])}"
    text = f"{t}  {level:5}  {mask(obj.get('msg', ''))}"
    err = obj.get('err')
    if isinstance(err, dict):
        text += f"  — {err.get('type', 'Error')}: {mask(err.get('message', ''))}"
        stack = (err.get('stack') or '').splitlines()
        if len(stack) > 1:
            text += f"  @ {stack[1].strip()}"
    rest = extras(obj)
    return f'{text}  {rest}' if rest else text


def out(line):
    sys.stdout.write(line + '\n')
    sys.stdout.flush()


slow = []
try:
    for raw in sys.stdin:
        raw = raw.rstrip('\n')
        if not raw.strip():
            continue
        try:
            obj = json.loads(raw)
            if not isinstance(obj, dict):
                raise ValueError
        except ValueError:
            if mode == 'api' or (mode == 'errors' and re.search(r'error|exception|fatal|unhandled', raw, re.I)):
                out(f'{"":14}  {"RAW":5}  {mask(raw)}')
            continue

        if mode == 'web':
            req = obj.get('request')
            if not isinstance(req, dict):
                if arg == 'errors' and obj.get('level') in ('error', 'fatal'):
                    out(f"{datetime.fromtimestamp(obj.get('ts', 0), NPT).strftime('%m-%d %H:%M:%S')}  CADDY  {mask(obj.get('msg', ''))}")
                continue
            status = obj.get('status', 0)
            if arg == 'errors' and status < 400:
                continue
            ms = round(obj.get('duration', 0) * 1000)
            t = datetime.fromtimestamp(obj.get('ts', 0), NPT).strftime('%m-%d %H:%M:%S')
            out(f"{t}  {status}  {ms:>6} ms  {req.get('method', ''):6} {req.get('host', '')}{mask(req.get('uri', ''))}")
            continue

        if mode == 'errors':
            level = obj.get('level')
            if isinstance(level, (int, float)) and level >= 40:
                out(app_line(obj))
        elif mode == 'slow':
            if 'durationMs' in obj and 'url' in obj:
                slow.append(obj)
        elif mode == 'user':
            if obj.get('userId') == arg or arg in raw:
                out(app_line(obj))
        else:
            out(app_line(obj))
except (BrokenPipeError, KeyboardInterrupt):
    sys.exit(0)

if mode == 'slow':
    top = int(arg or 25)
    slow.sort(key=lambda o: o.get('durationMs', 0), reverse=True)
    print(f'{len(slow)} requests in the window; slowest {min(top, len(slow))}:')
    for o in slow[:top]:
        t = when(o['time']) if isinstance(o.get('time'), (int, float)) else '--'
        print(f"{o['durationMs']:>7} ms  {o.get('status', '')}  {o.get('method', ''):6} {mask(o['url'])}  ({t})")
PY
)"

fmt() { python3 -c "$FORMATTER" "$@"; }

# --- commands -----------------------------------------------------------------

env_value() { grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'"'" || true; }

# Status code and how long a URL takes to answer, from this server.
probe() {
  curl -s -o /dev/null --max-time 20 \
    -w "%{http_code}  connect %{time_connect}s  first byte %{time_starttransfer}s  total %{time_total}s" "$1" \
    || echo "no answer within 20 s"
}

cmd_status() {
  echo "== Containers"
  "$DOCKER" ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo
  echo "== CPU / memory"
  timeout 20 "$DOCKER" stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' \
    || echo "(docker stats did not answer within 20 s)"
  echo
  echo "== Server"
  # Each on its own, so one missing tool does not hide the health check below.
  uptime || true
  free -h || true
  df -h / || true
  echo
  echo "== Health (from this server)"
  local api site
  api="$(env_value API_DOMAIN)"; site="$(env_value FRONTEND_DOMAIN)"
  if [ -n "$api" ]; then
    echo "API   https://$api/health/ready   $(probe "https://$api/health/ready")"
    echo "      $(curl -s --max-time 20 "https://$api/health/ready" || echo 'no answer')"
  fi
  [ -n "$site" ] && echo "Site  https://$site/   $(probe "https://$site/")"
  [ -n "$api$site" ] || echo "(API_DOMAIN / FRONTEND_DOMAIN not found in $ENV_FILE)"
}

app_logs() {
  local since="$1"; shift
  container_up "$APP"
  "$DOCKER" logs --since "$since" "$@" "$APP" 2>&1
}

cmd_install() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $SELF install"
  chmod +x "$SELF"
  ln -sf "$SELF" /usr/local/bin/sslogs
  echo "Installed: type 'sslogs' from anywhere (links to $SELF)."
}

# --- main ---------------------------------------------------------------------

main() {
  local cmd="${1:-help}"; [ $# -gt 0 ] && shift
  local since="" follow=0 top=25 errors_only=0 args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || bad "--since needs a value (30m, 2h, 1d)"; since="$(since_arg "$2")"; shift ;;
      --since=*) since="$(since_arg "${1#--since=}")" ;;
      --top) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || bad "--top needs a number"; top="$2"; shift ;;
      -f|--follow) follow=1 ;;
      --errors) errors_only=1 ;;
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

  command -v "$DOCKER" >/dev/null || die "docker is not installed"
  case "$cmd" in
    status|api|errors|slow|user|web) ;;
    *) bad "unknown command: $cmd" ;;
  esac
  [ "$cmd" = status ] || command -v python3 >/dev/null || die "python3 is needed to read the logs"

  case "$cmd" in
    status)
      [ ${#args[@]} -eq 0 ] || bad "usage: sslogs status"
      cmd_status ;;
    errors)
      [ ${#args[@]} -eq 0 ] || bad "usage: sslogs errors [--since 1h]"
      app_logs "${since:-1h}" | fmt errors ;;
    slow)
      [ ${#args[@]} -eq 0 ] || bad "usage: sslogs slow [--since 2h] [--top 25]"
      app_logs "${since:-2h}" | fmt slow "$top" ;;
    api)
      [ ${#args[@]} -eq 0 ] || bad "usage: sslogs api [--since 30m] [-f]"
      if [ "$follow" = 1 ]; then
        trap 'exit 0' INT
        app_logs "${since:-30m}" -f | fmt api
      else
        app_logs "${since:-30m}" | fmt api
      fi ;;
    user)
      [ ${#args[@]} -eq 1 ] || bad "usage: sslogs user EMAIL [--since 24h]"
      local uid
      uid="$("$REPO_DIR/scripts/sstrack.sh" _userid "${args[0]}")" || exit 1
      app_logs "${since:-24h}" | fmt user "$uid" ;;
    web)
      [ ${#args[@]} -eq 0 ] || bad "usage: sslogs web [--since 1h] [--errors]"
      container_up "$CADDY"
      "$DOCKER" logs --since "${since:-1h}" "$CADDY" 2>&1 \
        | fmt web "$([ "$errors_only" = 1 ] && echo errors)" ;;
  esac
}

main "$@"
