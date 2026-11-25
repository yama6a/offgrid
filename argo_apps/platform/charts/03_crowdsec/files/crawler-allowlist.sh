#!/usr/bin/env bash
# Loads the published IPs of the verified crawlers into the CrowdSec allowlist `crawlers`.
# It runs in the LAPI pod, because `cscli allowlists` writes to the SQLite file directly and LAPI has no API for it.
#   loop   the sidecar mode: wait for LAPI, refresh, sleep, repeat. A failed run logs and tries again sooner.
#   once   one refresh, for `make crowdsec-allowlist`. Exits non-zero when a source or cscli failed.
# Each entry's comment names its source. When a source fails, its entries from the last good run stay.
set -uo pipefail

# ---- knobs ----
ALLOWLIST="crawlers"
INTERVAL_SECONDS=86400 # time between two refreshes in loop mode
RETRY_SECONDS=3600     # time before the next try after a failed refresh in loop mode
LAPI_HEALTH="http://127.0.0.1:8080/health"
GOOGLE="https://developers.google.com/static/search/apis/ipranges"
AMAZON="https://developer.amazon.com/amazonbot"
# One source per line: <name> <url>. The URLs come from each operator's own crawler docs.
# Amazon publishes HTML pages with the JSON inside. Meta publishes no list, so its network AS32934 stands in.
SOURCES="
google-common ${GOOGLE}/googlebot.json
google-special ${GOOGLE}/special-crawlers.json
google-user-triggered ${GOOGLE}/user-triggered-fetchers.json
google-user-triggered-google ${GOOGLE}/user-triggered-fetchers-google.json
bing https://www.bing.com/toolbox/bingbot.json
apple https://search.developer.apple.com/applebot.json
duckduckgo https://duckduckgo.com/duckduckbot.json
openai-gptbot https://openai.com/gptbot.json
openai-searchbot https://openai.com/searchbot.json
openai-chatgpt-user https://openai.com/chatgpt-user.json
anthropic https://claude.com/crawling/bots.json
perplexity-bot https://www.perplexity.ai/perplexitybot.json
perplexity-user https://www.perplexity.ai/perplexity-user.json
commoncrawl https://index.commoncrawl.org/ccbot.json
amazon-amazonbot ${AMAZON}/ip-addresses/
amazon-searchbot ${AMAZON}/searchbot-ip-addresses/
amazon-live ${AMAZON}/live-ip-addresses/
meta https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS32934
"
# The JSON keys that hold a prefix: Google's format, Amazon's searchbot page and RIPEstat.
PREFIX_KEYS="ipv4Prefix|ipv6Prefix|ip_prefix|prefix"

# ---- state ----
WORK=""  # scratch dir of one refresh
FAILED=0 # sources or cscli steps that failed in this refresh

log() { printf '%s crawler-allowlist: %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() {
  FAILED=$((FAILED + 1))
  log "$*"
}

# Prints one IP or CIDR per line. A prefix shorter than /8 (IPv4) or /16 (IPv6) is dropped, so a broken or
# hijacked source cannot allowlist a large part of the internet.
extract_prefixes() {
  grep -oE "\"(${PREFIX_KEYS})\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$1" \
    | sed -E 's/.*"([^"]+)"$/\1/' \
    | awk -F/ '
        $1 ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/ && (NF == 1 || ($2 ~ /^[0-9]+$/ && $2 >= 8 && $2 <= 32)) { print; next }
        $1 ~ /^[0-9a-fA-F:]+$/ && $1 ~ /:/ && (NF == 1 || ($2 ~ /^[0-9]+$/ && $2 >= 16 && $2 <= 128)) { print }
      ' \
    | sort -u
}

# Each cscli or yq process takes about 75 MB, so no step pipes one into the other.
ensure_allowlist() {
  cscli allowlists list -o json > "$WORK/lists.json" || return 1
  yq -p json -e ".[] | select(.name == \"${ALLOWLIST}\")" "$WORK/lists.json" > /dev/null 2>&1 \
    || cscli allowlists create "$ALLOWLIST" -d "verified crawler IPs, refreshed daily by the crawler-allowlist sidecar" > /dev/null
}

# Writes <value>,<source> lines to $WORK/current.csv from the live allowlist.
read_current() {
  : > "$WORK/current.csv"
  cscli allowlists inspect "$ALLOWLIST" -o json > "$WORK/current.json" || return 1
  yq -p json -o csv '(.items // [])[] | [.value, .description]' "$WORK/current.json" > "$WORK/current.csv"
}

fetch_sources() {
  local name url count
  : > "$WORK/wanted.csv"
  while read -r name url; do
    [ -n "$name" ] || continue
    count=0
    if wget -q -T 30 -O "$WORK/$name.raw" "$url"; then
      extract_prefixes "$WORK/$name.raw" | sed "s/\$/,${name}/" > "$WORK/$name.csv"
      count="$(wc -l < "$WORK/$name.csv")"
    fi
    if [ "$count" -gt 0 ]; then
      cat "$WORK/$name.csv" >> "$WORK/wanted.csv"
      log "${name}: ${count} prefixes"
    else
      grep ",${name}\$" "$WORK/current.csv" >> "$WORK/wanted.csv"
      fail "${name}: download failed or empty, keeping its $(grep -c ",${name}\$" "$WORK/current.csv") entries from the last run"
    fi
  done <<< "$SOURCES"
}

# Removes the values no source lists any more, then imports the new ones. Import skips values already present.
apply() {
  local stale added
  cut -d, -f1 "$WORK/current.csv" | sort -u > "$WORK/current.values"
  # The first source that lists a value names it.
  awk -F, '!seen[$1]++' "$WORK/wanted.csv" > "$WORK/wanted.dedup.csv"
  cut -d, -f1 "$WORK/wanted.dedup.csv" | sort -u > "$WORK/wanted.values"
  comm -23 "$WORK/current.values" "$WORK/wanted.values" > "$WORK/stale.values"
  comm -13 "$WORK/current.values" "$WORK/wanted.values" > "$WORK/new.values"
  stale="$(wc -l < "$WORK/stale.values")"
  added="$(wc -l < "$WORK/new.values")"
  if [ "$stale" -gt 0 ]; then
    xargs -r cscli allowlists remove "$ALLOWLIST" < "$WORK/stale.values" > /dev/null \
      || fail "cscli allowlists remove failed"
  fi
  if [ "$added" -gt 0 ]; then
    {
      echo "value,comment"
      awk -F, 'NR == FNR { n[$1]; next } $1 in n' "$WORK/new.values" "$WORK/wanted.dedup.csv"
    } > "$WORK/import.csv"
    cscli allowlists import "$ALLOWLIST" -i "$WORK/import.csv" > /dev/null \
      || fail "cscli allowlists import failed"
  fi
  log "done: $(wc -l < "$WORK/wanted.values") entries, ${added} added, ${stale} removed, ${FAILED} failures"
}

refresh() {
  FAILED=0
  WORK="$(mktemp -d)"
  if ensure_allowlist && read_current; then
    fetch_sources
    apply
  else
    fail "cannot create or read allowlist ${ALLOWLIST}, skipping this run"
  fi
  rm -rf "$WORK"
  [ "$FAILED" -eq 0 ]
}

wait_for_lapi() {
  until [ -f /etc/crowdsec/config.yaml ] && wget -q -T 5 -O /dev/null "$LAPI_HEALTH"; do sleep 10; done
}

case "${1:-}" in
  loop)
    wait_for_lapi
    while true; do
      if refresh; then sleep "$INTERVAL_SECONDS"; else sleep "$RETRY_SECONDS"; fi
    done
    ;;
  once) refresh ;;
  *)
    echo "usage: $0 loop|once" >&2
    exit 2
    ;;
esac
