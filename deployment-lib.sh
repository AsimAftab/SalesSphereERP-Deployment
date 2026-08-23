#!/usr/bin/env bash

DEPLOYMENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_SUFFIX_LIST="${PUBLIC_SUFFIX_LIST:-${DEPLOYMENT_LIB_DIR}/data/public_suffix_list.dat}"

validate_domain() {
  local domain="${1:-}"
  # The official PSL stores IDN rules in Unicode. Until this installer has a
  # guaranteed IDNA implementation, reject A-labels rather than applying the
  # default "*" rule and potentially accepting an IDN public suffix.
  [[ "${domain,,}" != xn--* && "${domain,,}" != *.xn--* ]] || return 1
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

require_public_suffix_list() {
  if [ ! -f "$PUBLIC_SUFFIX_LIST" ] || [ ! -r "$PUBLIC_SUFFIX_LIST" ] \
     || [ ! -s "$PUBLIC_SUFFIX_LIST" ]; then
    printf 'Public Suffix List is missing or unreadable: %s\n' "$PUBLIC_SUFFIX_LIST" >&2
    return 1
  fi
  if ! grep -q 'Mozilla Public' "$PUBLIC_SUFFIX_LIST" \
     || ! grep -q '^// ===BEGIN ICANN DOMAINS===\r\?$' "$PUBLIC_SUFFIX_LIST" \
     || ! grep -q '^// ===END ICANN DOMAINS===\r\?$' "$PUBLIC_SUFFIX_LIST" \
     || ! grep -q '^// ===BEGIN PRIVATE DOMAINS===\r\?$' "$PUBLIC_SUFFIX_LIST" \
     || ! grep -q '^// ===END PRIVATE DOMAINS===\r\?$' "$PUBLIC_SUFFIX_LIST" \
     || [ "$(wc -l < "$PUBLIC_SUFFIX_LIST")" -lt 10000 ]; then
    printf 'Public Suffix List is incomplete or invalid: %s\n' "$PUBLIC_SUFFIX_LIST" >&2
    return 1
  fi
}

public_suffix() {
  local domain="${1,,}"
  validate_domain "$domain" || return 1
  require_public_suffix_list || return 1

  awk -v domain="$domain" '
    BEGIN {
      count = split(domain, labels, ".")
    }
    {
      sub(/\r$/, "")
      if ($0 == "" || substr($0, 1, 2) == "//") next
      rule = tolower($0)
      if (substr(rule, 1, 1) == "!") {
        exceptions[substr(rule, 2)] = 1
      } else if (substr(rule, 1, 2) == "*.") {
        wildcards[substr(rule, 3)] = 1
      } else {
        exact[rule] = 1
      }
    }
    END {
      best = 1
      result = labels[count]
      for (i = 1; i <= count; i++) {
        suffix = labels[i]
        for (j = i + 1; j <= count; j++) suffix = suffix "." labels[j]

        if (exceptions[suffix]) {
          sub(/^[^.]+\./, "", suffix)
          print suffix
          exit
        }

        labels_in_suffix = count - i + 1
        if (exact[suffix] && labels_in_suffix > best) {
          best = labels_in_suffix
          result = suffix
        }
        if (i > 1 && wildcards[suffix] && labels_in_suffix + 1 > best) {
          best = labels_in_suffix + 1
          result = labels[i - 1] "." suffix
        }
      }
      print result
    }
  ' "$PUBLIC_SUFFIX_LIST"
}

registrable_domain() {
  local domain="${1,,}" suffix prefix
  suffix="$(public_suffix "$domain")" || return 1
  [ "$domain" != "$suffix" ] || return 1
  prefix="${domain%."$suffix"}"
  printf '%s.%s' "${prefix##*.}" "$suffix"
}

auth_site_is_registrable() {
  local domain="${1,,}" registrable
  registrable="$(registrable_domain "$domain")" || return 1
  [ "$domain" = "$registrable" ]
}

domain_is_at_or_below() {
  local domain="${1,,}" parent="${2,,}"
  validate_domain "$domain" || return 1
  validate_domain "$parent" || return 1
  [ "$domain" = "$parent" ] || [[ "$domain" == *."$parent" ]]
}

derive_auth_site_domain() {
  local api="${1,,}" frontend="${2,,}"
  validate_domain "$api" || return 1
  validate_domain "$frontend" || return 1
  [ "$api" != "$frontend" ] || return 1

  if domain_is_at_or_below "$frontend" "$api"; then
    printf '%s' "$api"
  elif domain_is_at_or_below "$api" "$frontend"; then
    printf '%s' "$frontend"
  else
    return 1
  fi
}

validate_auth_site_domains() {
  local api="${1,,}" frontend="${2,,}" auth_site="${3,,}"
  require_public_suffix_list || return 1
  validate_domain "$api" || return 1
  validate_domain "$frontend" || return 1
  validate_domain "$auth_site" || return 1
  auth_site_is_registrable "$auth_site" || return 1
  [ "$api" != "$frontend" ] || return 1
  domain_is_at_or_below "$api" "$auth_site" || return 1
  domain_is_at_or_below "$frontend" "$auth_site" || return 1
}

domain_from_url() {
  printf '%s' "${1:-}" \
    | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|/.*$||; s|:[0-9]+$||'
}

render_caddy_template() {
  local api_domain="$1" frontend_domain="$2" auth_site_domain="$3"
  local template="$4" output="$5"
  validate_auth_site_domains "$api_domain" "$frontend_domain" "$auth_site_domain" || return 1
  [ -f "$template" ] || return 1

  sed \
    -e "s|{{API_DOMAIN}}|${api_domain}|g" \
    -e "s|{{FRONTEND_DOMAIN}}|${frontend_domain}|g" \
    "$template" > "$output"

  ! grep -qE '\{\{(API_DOMAIN|FRONTEND_DOMAIN)\}\}' "$output"
}

validate_caddy_file() {
  local file="$1" absolute
  absolute="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  docker run --rm \
    -v "${absolute}:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
}

install_caddy_config() {
  local api_domain="$1" frontend_domain="$2" auth_site_domain="$3"
  local template="${4:-Caddyfile.template}" destination="${5:-Caddyfile}"
  local candidate
  candidate="$(mktemp "${PWD}/.Caddyfile.tmp.XXXXXX")"

  if ! render_caddy_template "$api_domain" "$frontend_domain" "$auth_site_domain" "$template" "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  if ! validate_caddy_file "$candidate"; then
    rm -f "$candidate"
    return 1
  fi

  [ ! -f "$destination" ] || cp "$destination" "${destination}.rollback"
  chmod 644 "$candidate"
  mv -f "$candidate" "$destination"
}
