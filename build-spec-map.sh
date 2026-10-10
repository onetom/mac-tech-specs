#!/bin/bash
# build-spec-map.sh — build/refresh the map of Apple Support "Technical
# Specifications" KB articles, keyed by the article's own title.
#
#   Output: data/apple-spec-articles.tsv   id <TAB> title (Mac rows only)
#   State:  data/apple-spec-articles.state  "min max epoch" of what we scanned
#
# WHY A SCAN AND NOT AN API
# ------------------------
# Apple exposes no public, supported endpoint that maps a Mac model identifier
# (MacBookPro18,2) to its spec article (111901). The old
#   https://cdsassets.apple.com/live/<key>/models      (JSON, model -> specs)
# used to answer this and now 404s for every key we can find. apple.com
# search and the /search-services/suggestions endpoint are both XHR-gated and
# return HTML 404s to curl. Support sitemaps are absent. So the article list
# itself has to be harvested from the KB by probing IDs.
#
# The *join* to a specific machine does NOT rely on scraping though: macOS
# reports the authoritative marketing name in IOKit,
#   ioreg -l -n product  ->  "product-name" = "MacBook Pro (16-inch, 2021)"
# which is byte-identical to the KB article title prefix. So:
#   identifier -> product-name (local, authoritative) -> title (exact match) -> id
#
# ID SPACES ARE NOT CHRONOLOGICAL
# ------------------------------
# Apple bulk-migrated the old HT?????? articles to numeric ids, so 112xxx holds
# iMac G5 while 111901 holds the 2021 MacBook Pro. Forward-only incremental
# refresh therefore only catches *newly published* articles; use --range or
# --full to re-sweep historical bands, and --recheck to catch articles
# published later into an already-scanned gap.
#
# Usage:
#   ./build-spec-map.sh                      # incremental: new ids + recheck
#   ./build-spec-map.sh --range 111000 112000
#   ./build-spec-map.sh --full               # re-sweep the whole known span
#   ./build-spec-map.sh --target 125000      # how far forward to probe
#   ./build-spec-map.sh --recheck 200        # re-verify last N ids (default 100)
#   ./build-spec-map.sh --all                # keep non-Mac products too
#   ./build-spec-map.sh --filter 'MacBook|iMac'
#   ./build-spec-map.sh --out /path.tsv --state /path.state --jobs 12

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
OUT="$here/data/apple-spec-articles.tsv"
STATE="$here/data/apple-spec-articles.state"
JOBS=12
RECHECK=100
TARGET_STEP=400        # how far past the last scanned id to probe each run
FULL=0; ALL=0
FILTER='MacBook|iMac|Mac mini|Mac Pro|Mac Studio|XServe|Xserve'
RANGE_LO="" RANGE_HI="" TARGET=""

while (( $# )); do
  case $1 in
    --range)    RANGE_LO=${2:-}; RANGE_HI=${3:-}; shift 3 ;;
    --full)     FULL=1 ;;
    --target)   TARGET=${2:-}; shift 2 ;;
    --recheck)  RECHECK=${2:-}; shift 2 ;;
    --jobs)     JOBS=${2:-}; shift 2 ;;
    --filter)   FILTER=${2:-}; shift 2 ;;
    --all)      ALL=1; FILTER='.*' ;;
    --out)      OUT=${2:-}; shift 2 ;;
    --state)    STATE=${2:-}; shift 2 ;;
    -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$OUT")"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

# ---- one id -> one line, if it is a spec-sheet article --------------------
# Apple uses two title suffixes: the pre-2022 corpus says
#   "<Product> - Technical Specifications - Apple Support"
# and everything from ~2022 on says
#   "<Product> - Tech Specs - Apple Support"
# Filtering on only the first silently drops the entire modern lineup.
probe() {
  local id=$1 t
  t=$(curl -sS -A "$UA" --max-time 20 --retry 2 --retry-delay 2 -L "https://support.apple.com/en-us/$id" 2>/dev/null \
        | grep -m1 -oE 'property="og:title" content="[^"]*"' \
        | sed -E 's/.*content="//; s/"$//')
  case $t in
    *" - Technical Specifications - Apple Support") t=${t%" - Technical Specifications - Apple Support"} ;;
    *" - Tech Specs - Apple Support")                t=${t%" - Tech Specs - Apple Support"} ;;
    *) return 0 ;;
  esac
  [[ $ALL -eq 1 || $t =~ $FILTER ]] || return 0
  printf '%s\t%s\n' "$id" "$t"
}
export -f probe
export UA FILTER ALL

# ---- decide what to scan --------------------------------------------------
DEFAULT_LO=107000
DEFAULT_HI=124500

if [[ -n $RANGE_LO ]]; then
  LO=$RANGE_LO; HI=$RANGE_HI
elif (( FULL )); then
  # re-sweep everything we believe we have covered (state), else the defaults
  if [[ -f $STATE ]]; then read -r LO HI _ < "$STATE"; else LO=$DEFAULT_LO; HI=${TARGET:-$DEFAULT_HI}; fi
  [[ -n $TARGET ]] && HI=$TARGET
elif [[ ! -f $STATE ]]; then
  LO=$DEFAULT_LO; HI=${TARGET:-$DEFAULT_HI}
  [[ -f $OUT ]] && echo "no state file; assuming first sweep $LO..$HI" >&2
else
  read -r s_min s_max _ <<<"$(cat "$STATE")"
  LO=$(( s_max + 1 ))
  HI=${TARGET:-$(( s_max + TARGET_STEP ))}
  # re-sweep the tail so late-published articles in scanned gaps get picked up
  if (( RECHECK > 0 )); then
    echo "incremental: $LO..$HI  (+recheck $(( s_max - RECHECK + 1 ))..$s_max)" >&2
    seq $(( s_max - RECHECK + 1 )) "$s_max" > /tmp/specmap.recheck.$$
  fi
  (( HI >= LO )) || { echo "nothing new to scan ($LO > $HI)" >&2; }
fi

TMP=$(mktemp)
: > "$TMP"
if [[ -n ${LO:-} ]] && (( HI >= LO )); then
  echo "scanning $LO..$HI ($(( HI - LO + 1 )) ids, $JOBS jobs)" >&2
  seq "$LO" "$HI" | xargs -P "$JOBS" -n1 -I{} bash -c 'probe "$@"' _ {} >> "$TMP"
fi
if [[ -s /tmp/specmap.recheck.$$ ]]; then
  echo "rechecking $(wc -l < /tmp/specmap.recheck.$$ | tr -d ' ') ids" >&2
  xargs -P "$JOBS" -n1 -I{} bash -c 'probe "$@"' _ {} < /tmp/specmap.recheck.$$ >> "$TMP"
  rm -f /tmp/specmap.recheck.$$
fi

# ---- merge, dedupe, sort --------------------------------------------------
[[ -f $OUT ]] && cat "$OUT" >> "$TMP"
sort -u -k1,1n "$TMP" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

# state = the id span we have ever covered, widened by this run
prev_min=0 prev_max=0
[[ -f $STATE ]] && read -r prev_min prev_max _ < "$STATE"
new_min=${LO:-$prev_min}; new_max=${HI:-$prev_max}
(( prev_min < new_min )) && new_min=$prev_min
(( prev_max > new_max )) && new_max=$prev_max
printf '%s\t%s\t%s\n' "$new_min" "$new_max" "$(date +%s)" > "$STATE.tmp"
mv "$STATE.tmp" "$STATE"
echo "wrote $OUT: $(wc -l < "$OUT" | tr -d ' ') rows   scanned span: $new_min-$new_max" >&2
