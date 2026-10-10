# Mac purchase-spec summary + official spec-sheet lookup

Three pieces:

| file | role |
|---|---|
| `mac-spec.sh` | reads this Mac, prints the purchase-relevant specs + identity + spec-sheet URLs; `--spec` writes a Markdown report |
| `build-spec-map.sh` | harvests Apple's "Technical Specifications" KB articles into `data/apple-spec-articles.tsv` |
| `data/apple-spec-articles.tsv` | the map: `article-id <TAB> product title` (160 Mac rows, ids 107000-124500) |

## How the machine is tied to its official spec page

There is **no public Apple API** for `model identifier -> spec article`. Things that
look promising and do not work from the CLI:

- `https://cdsassets.apple.com/live/<key>/models` — the JSON that used to answer
  exactly this; 404 for every key tried (its sibling
  `.../SZLF0YNV/images/sp/111901_*.png` still serves, so only the models endpoint
  is gone).
- `support.apple.com/search-services/suggestions`, `apple.com/search-services/...`
  — XHR-gated, HTML 404 to curl.
- `support.apple.com/*/sitemap.xml` — absent.
- Brave/Bing/DDG `site:support.apple.com <identifier>` — the identifier is not in
  the article HTML at all, so search can't resolve it.

So the mapping is built from two facts that *are* authoritative:

1. **The join key comes from the machine, not the web.** IOKit's `product-name`
   on `IOPlatformDevice` is Apple's own marketing string:

   ```
   $ ioreg -rc IOPlatformDevice -d 1 | grep -m1 product-name
   "product-name" = <"MacBook Pro (16-inch, 2021)">
   ```

   which is byte-identical to the title of that model's spec article,
   `MacBook Pro (16-inch, 2021) - Technical Specifications - Apple Support`.
   `MacBookPro18,2 -> "MacBook Pro (16-inch, 2021)"` therefore needs no lookup
   table and no guessing.

2. **The title -> article-id table is harvested from the KB itself** by probing
   `support.apple.com/en-us/<id>` and reading `<meta property="og:title">`.
   Parallel, ~20 ids/s, polite by default (`--jobs`).

`identifier -> product-name (local) -> title (exact match) -> id -> URL`, with a
punctuation-insensitive pass as fallback and `apple.com/<product>/specs/` as the
last resort for models outside the scanned id band.

EveryMac's lookup accepts the raw identifier, so that URL is always constructed
dynamically — no table needed:
`https://everymac.com/ultimate-mac-lookup/?identify=MacBookPro18%2C2`

## Refreshing the map

```bash
./build-spec-map.sh                     # incremental: new ids past the last
                                        # scanned max, plus a --recheck tail
./build-spec-map.sh --range 111000 112000
./build-spec-map.sh --full              # re-sweep the default span
./build-spec-map.sh --target 125000     # how far forward to probe
./build-spec-map.sh --recheck 200       # re-verify last N ids (default 100)
./build-spec-map.sh --all               # keep iPhone/iPad rows too
```

`data/apple-spec-articles.state` holds `min <TAB> max <TAB> epoch` — the id span
ever covered — so a plain re-run scans `max+1 .. max+400` and re-checks the last
100 ids. Merge is `sort -u -k1,1n`, so re-scanning is idempotent.

Two caveats baked into that design:

- **Article ids are not chronological.** Apple bulk-migrated the old `HT??????`
  docs, so 112xxx holds iMac G5 while 111901 holds the 2021 MacBook Pro.
  Forward-only refresh catches *newly published* articles; historical gaps need
  `--range`.
- **Late articles can land in an already-scanned gap**, which is what `--recheck`
  exists for.

Coverage found so far: **160 Mac spec articles**, ids 107000-124500, from
`MacBook (original)` and iMac G5 up to `MacBook Pro (14-inch, 2023)` / `Mac Pro
(2023)`. No M4/M5-era per-model article exists anywhere in that span — a full
sweep of 107000-124500 found none — so for current-lineup machines
`mac-spec.sh` falls back to `apple.com/<family>/specs/`.

## The title-suffix trap

Apple renamed the article suffix around 2022:

| era | og:title |
|---|---|
| pre-2022 | `MacBook Pro (16-inch, 2021) - Technical Specifications - Apple Support` |
| 2022+    | `MacBook Air (15-inch, M2, 2023) - Tech Specs - Apple Support` |

Filtering the harvest on `Technical Specifications` alone silently drops the
entire modern lineup — that is exactly what happened on the first sweep, which
returned 106 rows and made it look like M2+ articles did not exist. They were at
111346 etc. all along. `probe()` now accepts both suffixes; if you ever change
the filter, re-run `--full` and compare the row count.

## Search-engine fallback (`--search`)

On a map miss, `mac-spec.sh --search` asks a search engine instead:

```
"<product-name>" Tech Specs site:support.apple.com
```

via DDG Lite then Brave. The engine is only a **proposer**: every candidate id is
fetched and its `og:title` must normalise to the same alphanumerics as
`product-name` before being accepted, and is then cached into the map. So a bad
search result cannot produce a wrong URL — it just fails to verify.

Treat it as best-effort. Both engines bot-throttle scripted queries hard: during
testing DDG Lite began serving `anomaly` pages (HTTP 202) and Brave returned 429
for many minutes after a handful of requests. Prefer `build-spec-map.sh --full`,
which talks only to Apple and is the reason the map exists.

## Example

```
$ ./mac-spec.sh --spec=MacBookPro18_2-specs.md --locale=en-hk
=== MacBook Pro (16-inch, 2021) (MacBookPro18,2) ===
Chip / SoC      Apple M1 Max
CPU             10 (8 Performance and 2 Efficiency)
GPU             32-core GPU · Metal 4
Memory          64 GB
Built-in SSD    1 TB (1,000,555,581,440 bytes)  (APPLE SSD AP1024R)
...
KB article      111901  (MacBook Pro (16-inch, 2021))
Official        https://support.apple.com/en-hk/111901
EveryMac        https://everymac.com/ultimate-mac-lookup/?identify=MacBookPro18%2C2
```

The generated Markdown starts with the `system_profiler` command line and its
raw output in a fenced block, then the converted Apple spec sheet (image
references preserved). `--locale` picks the support.apple.com region; it
defaults to `AppleLocale`.

`support.apple.com` 403s non-browser user agents including defuddle's built-in
fetcher, so the page is fetched with `curl --user-agent` first and defuddle
parses the local file.

---

## Disclaimer

This project was built by **Qwen3.8-Flash-Next-Q4.gguf**, served by
<https://github.com/antirez/ds4>.

Everything above is therefore plausibly wrong somewhere. The parts that touch
Apple's undocumented endpoints (id bands, `og:title` suffixes, bot-throttling
behaviour) are empirical observations from October 2026, not contracts — re-run
`./build-spec-map.sh --full` before trusting the map, and always sanity-check
the resolved `KB article` line against the printed product name.
