#!/bin/bash
# mac-tech-specs.sh — summarize the "buying decision" specs of a Mac in one shot.
#
# Everything here comes from system_profiler / ioreg / sysctl, i.e. the exact
# knobs Apple lets you choose at purchase: chip, CPU core split, GPU cores,
# memory, built-in SSD size — plus the identity fields (serial, model id,
# model number) and the official spec-sheet URL.
#
# Usage:
#   ./mac-tech-specs.sh                    # human-readable summary
#   ./mac-tech-specs.sh --tsv              # TSV instead (for spreadsheets)
#   ./mac-tech-specs.sh --spec             # also fetch official spec sheet -> Markdown
#   ./mac-tech-specs.sh --spec=FILE.md     # ... to an explicit path
#   ./mac-tech-specs.sh --url=URL          # override the spec-sheet URL
#   ./mac-tech-specs.sh --locale=en-hk     # support.apple.com region (default: AppleLocale)
#   ./mac-tech-specs.sh --map=FILE.tsv     # override the KB map path
#   ./mac-tech-specs.sh --search           # on map miss: resolve via search engine,
#                                    # verify og:title, cache into the map
#
# --spec uses `npx defuddle` (HTML -> Markdown); image references are kept.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TSV=0
SEARCH=0         # --search: on map miss, resolve via search engine + verify
FETCH=0          # --spec
SPEC_OUT=""      # explicit output path, else derived
SPEC_URL=""      # --url override

while (( $# )); do
  case $1 in
    --tsv)             TSV=1 ;;
    --spec)            FETCH=1 ;;
    --spec=*)          FETCH=1; SPEC_OUT="${1#--spec=}" ;;
    --url=*)           SPEC_URL="${1#--url=}"; FETCH=1 ;;
    --map=*)           MAP="${1#--map=}" ;;
    --search)          SEARCH=1 ;;
    --locale=*)        LOCALE="${1#--locale=}" ;;
    -h|--help)         sed -n '2,20p' "$0"; exit 0 ;;
    *)                 echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

sp() { system_profiler "$@" 2>/dev/null; }
grab() { grep -E "$1" | head -1 | sed -E 's/^[[:space:]]*//; s/^[^:]+:[[:space:]]*//'; }

HW=$(sp SPHardwareDataType)
GPU=$(sp SPDisplaysDataType)
NVME=$(sp SPNVMeDataType)
SW=$(sp SPSoftwareDataType)

# ---- identity -------------------------------------------------------------
model_name=$(   <<<"$HW" grab 'Model Name:')
model_id=$(     <<<"$HW" grab 'Model Identifier:')
model_number=$( <<<"$HW" grab 'Model Number:')
serial=$(       <<<"$HW" grab 'Serial Number \(system\):')
chip=$(         <<<"$HW" grab 'Chip:')
cores=$(        <<<"$HW" grab 'Total Number of Cores:')
ram=$(          <<<"$HW" grab 'Memory:')
osver=$(        <<<"$SW" grab 'System Version:')

# ---- GPU ------------------------------------------------------------------
gpu_cores=$(<<<"$GPU" grep -E "Total Number of Cores" | sed -n 1p | tr -dc 0-9)
metal=$(      <<<"$GPU" grab 'Metal Support:')

# ---- built-in SSD ---------------------------------------------------------
# SPNVMeDataType lists internal + any ePCIe dock/enclosure, so anchor on the
# Apple SSD (soldered, "Apple Fabric" protocol) rather than taking volume 1.
ssd_cap=$(<<<"$NVME" awk '/APPLE SSD|Apple SSD/{f=1} f && /Capacity:/{sub(/^[[:space:]]*Capacity:[[:space:]]*/,""); print; exit}')
[[ -z $ssd_cap ]] && ssd_cap=$(<<<"$NVME" grep -m1 -E "Capacity:" | sed -E 's/^[[:space:]]*Capacity:[[:space:]]*//')
ssd_model=$(<<<"$NVME" grep -m1 -E "^ *Model:" | sed -E 's/^ *Model:[[:space:]]*//')
[[ -z $ssd_model ]] && ssd_model=$(sp SPSerialATADataType | grep -m1 -E "^\s+Model:" | sed -E 's/.*Model:[[:space:]]*//')

# ---- display (also a purchase option) -------------------------------------
panel=$(<<<"$GPU" grab 'Display Type:')

# ---- battery cycle count (useful when buying used) ------------------------
cycles=$(ioreg -rc AppleSmartBattery 2>/dev/null \
  | grep -m1 -oE '"CycleCount"[[:space:]]*=[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
cycles=${cycles:-n/a}

# ---- identity: authoritative marketing name ------------------------------
# IOKit's product-name is Apple's own marketing string and is byte-identical to
# the title of that model's "... - Technical Specifications" support article.
# That is the join key from a machine to its official spec page.
product_name=$(ioreg -rc IOPlatformDevice -d 1 2>/dev/null \
  | grep -m1 -oE '"product-name" = .*' \
  | sed -E 's/^"product-name" = <?"(.*)">?$/\1/; s/^"product-name" = <([0-9a-fA-F]+)>$/\1/')
product_name=${product_name%%$'\n'*}   # defensive: single line only
# some firmwares report the name as a raw hex blob
[[ $product_name =~ ^[0-9a-fA-F]+$ ]] && product_name=$(<<<"$product_name" xxd -r -p 2>/dev/null)

# ---- official spec sheet --------------------------------------------------
# 1) exact title match in the harvested KB map  -> support.apple.com/<loc>/<id>
# 2) otherwise the generic apple.com specs page for the product family
MAP="${MAP:-$here/data/apple-spec-articles.tsv}"
LOCALE=${LOCALE:-$(defaults read -g AppleLocale 2>/dev/null | sed -E 's/@.*//; s/_/-/' | tr 'A-Z' 'a-z')}
LOCALE=${LOCALE:-en-us}
EVERYMAC="https://everymac.com/ultimate-mac-lookup/?identify=${model_id//,/%2C}"

kb_id=""; kb_title=""
if [[ -f $MAP && -n $product_name ]]; then
  kb_id=$(awk -F'\t' -v n="$product_name" 'tolower($2)==tolower(n){print $1; exit}' "$MAP")
  kb_title=$product_name
  if [[ -z $kb_id ]]; then   # tolerant pass: ignore punctuation/case
    kb_id=$(awk -F'\t' -v n="$product_name" '
      function norm(s){gsub(/[^A-Za-z0-9]/,"",s); return tolower(s)}
      BEGIN{n=norm(n)} norm($2)~n || n~norm($2){print $1; exit}' "$MAP")
    [[ -n $kb_id ]] && kb_title=$(awk -F'\t' -v i="$kb_id" '$1==i{print $2; exit}' "$MAP")
  fi
fi

# ---- map miss -> ask a web search engine, then *verify* the candidate ------
# Only used when the local map has no row, so it costs nothing in the common
# case. Search is a *proposer*, never an authority: every candidate id is
# fetched and its og:title must normalise to the same string as product-name
# before it is accepted, then it is cached into the map.
# DDG lite and Brave both answer plain curl but bot-throttle hard (429 /
# "anomaly" pages), so try them in order, stop at the first hit, and cache.
resolve_kb_by_search() {
  local ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
  local q cands id t
  q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' \
        "\"$product_name\" Tech Specs site:support.apple.com" 2>/dev/null) || return 1
  cands=$( {
      curl -fsSL -A "$ua" --max-time 15 "https://lite.duckduckgo.com/lite/?q=$q" 2>/dev/null
      sleep 2
      curl -fsSL -A "$ua" --max-time 20 -L "https://search.brave.com/search?q=$q" 2>/dev/null
    } | grep -oE 'support\.apple\.com/[a-z]{2}(-[a-z]{2})?/[0-9]{6}' \
        | grep -oE '[0-9]{6}$' | sort -u | head -8)
  [[ -z $cands ]] && { echo "search: no candidates (throttled?)" >&2; return 1; }
  for id in $cands; do
    t=$(curl -fsSL -A "$ua" --max-time 15 -L "https://support.apple.com/en-us/$id" 2>/dev/null \
          | grep -m1 -oE 'property="og:title" content="[^"]*"' | sed -E 's/.*content="//; s/"$//')
    t=${t%" - Technical Specifications - Apple Support"}
    t=${t%" - Tech Specs - Apple Support"}
    if [[ $(tr -dc '[:alnum:]' <<<"$t" | tr 'A-Z' 'a-z') == $(tr -dc '[:alnum:]' <<<"$product_name" | tr 'A-Z' 'a-z') ]]; then
      printf '%s\t%s\n' "$id" "$t" >> "$MAP"   # cache for next time
      kb_id=$id; kb_title=$t
      echo "search: verified $id -> $t (cached into $MAP)" >&2
      return 0
    fi
  done
  echo "search: candidates $(echo $cands) did not verify" >&2
  return 1
}
(( SEARCH )) && [[ -z $kb_id && -n $product_name ]] && resolve_kb_by_search

if [[ -z $SPEC_URL ]]; then
  if [[ -n $kb_id ]]; then
    SPEC_URL="https://support.apple.com/${LOCALE}/${kb_id}"
  else
    case "$model_id" in
      MacBookPro*)  SPEC_URL="https://www.apple.com/macbook-pro/specs/" ;;
      MacBookAir*)  SPEC_URL="https://www.apple.com/macbook-air/specs/" ;;
      iMac*)        SPEC_URL="https://www.apple.com/imac/specs/" ;;
      Macmini*)     SPEC_URL="https://www.apple.com/mac-mini/specs/" ;;
      MacStudio*)   SPEC_URL="https://www.apple.com/mac-studio/specs/" ;;
      *)            SPEC_URL="https://support.apple.com/${LOCALE}/102869" ;;
    esac
  fi
fi

fetch_spec() {
  local out="${SPEC_OUT:-${model_id//,/_}-specs.md}"
  local cmd="system_profiler SPHardwareDataType SPDisplaysDataType SPNVMeDataType SPSoftwareDataType"
  local ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
  {
    printf '# %s (%s)\n\n' "${product_name:-$model_name}" "$model_id"
    printf -- '- Model number: `%s`\n- Serial: `%s`\n- Official spec sheet: %s\n- EveryMac (unofficial, good for CTO configs): %s\n\n' \
      "$model_number" "$serial" "$SPEC_URL" "$EVERYMAC"
    printf '## Raw `system_profiler` output\n\n```text\n$ %s\n\n' "$cmd"
    $cmd 2>/dev/null
    printf '```\n\n---\n\n## Apple spec sheet\n\n'
  } > "$out"

  # support.apple.com 403s non-browser agents, and defuddle's own fetcher is
  # one of them: fetch with curl --user-agent, then parse the local file.
  local html; html=$(mktemp "${TMPDIR:-/tmp}/spec-XXXXXX.html")
  echo "fetching $SPEC_URL" >&2
  if curl -fsSL --max-time 40 -A "$ua" -L "$SPEC_URL" -o "$html"; then
    npx -y defuddle parse --markdown --property content --output "$out.tmp" "$html" >&2
  else
    echo "curl failed; letting defuddle fetch $SPEC_URL directly" >&2
    npx -y defuddle parse --markdown --property content --user-agent "$ua" \
      --output "$out.tmp" "$SPEC_URL" >&2
  fi
  if [[ -s $out.tmp ]]; then
    awk 'NF || !p {print; p=NF==0}' "$out.tmp" >> "$out"
    rm -f "$out.tmp"
  else
    echo "warning: spec sheet conversion produced nothing; kept local data only" >&2
  fi
  rm -f "$html"
  echo "wrote $out ($(wc -l < "$out" | tr -d ' ') lines, images kept)" >&2
}

if (( TSV )); then
  printf 'field\tvalue\n'
  printf 'chip\t%s\nproduct_name\t%s\nmodel_id\t%s\nmodel_number\t%s\nserial\t%s\ncpu_cores\t%s\ngpu_cores\t%s\nmemory\t%s\nssd\t%s\nssd_model\t%s\ndisplay\t%s\nmetal\t%s\nmacos\t%s\ncycle_count\t%s\nkb_article\t%s\nspec_url\t%s\neverymac_url\t%s\n' \
    "$chip" "$product_name" "$model_id" "$model_number" "$serial" "$cores" "$gpu_cores" "$ram" "$ssd_cap" "$ssd_model" "$panel" "$metal" "$osver" "$cycles" "${kb_id:-none}" "$SPEC_URL" "$EVERYMAC"
  (( FETCH )) && fetch_spec
  exit 0
fi

cat <<EOF
=== ${product_name:-$model_name} (${model_id}) ===
Chip / SoC      ${chip}
CPU             ${cores}
GPU             ${gpu_cores}-core GPU · ${metal}
Memory          ${ram}
Built-in SSD    ${ssd_cap}  (${ssd_model:-unknown})
Display         ${panel:-n/a}
macOS           ${osver}
--- identity / resale ---
Model Number    ${model_number}     <- order/CTO number: encodes the exact config
Serial Number   ${serial}
Battery cycles  ${cycles}
--- spec sheets ---
KB article      ${kb_id:-not in map}  ${kb_title:+($kb_title)}
Official        ${SPEC_URL}
EveryMac        ${EVERYMAC}
EOF

(( FETCH )) && fetch_spec

exit 0
