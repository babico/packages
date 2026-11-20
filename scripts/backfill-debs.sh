#!/usr/bin/env bash
# backfill-debs.sh — download as many historical .deb files as fit in a size
# budget, newest-first. Binaries are force-added to git by the caller (the pool
# is gitignored) so Pages can serve them; CI then rebuilds and signs the APT
# index from the complete pool on its next run.
#
# Env: BUDGET_MB (default 800), MAX_GH (30), MAX_RUSTDESK (15),
#      MAX_TIXATI (all), MAX_MATTERMOST (0 — ~98 MB/file, over Pages guidance),
#      MAX_APIDOG (0 — upstream only publishes "latest" URLs, no history).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/build-all.sh"   # helpers; main is guarded

BUDGET_MB="${BUDGET_MB:-800}"
BUDGET=$((BUDGET_MB * 1024 * 1024))
used=0
declare -A covered=( [gh]=0 [rustdesk]=0 [tixati]=0 [mattermost-desktop]=0 [apidog]=0 )
declare -A skipped=( [gh]=0 [rustdesk]=0 [tixati]=0 [mattermost-desktop]=0 [apidog]=0 )

note() { echo "    $*"; }

fetch_deb() {
  local product="$1" ver="$2" arch="$3" url="$4" dest="$5"
  local tmp http size

  [ -f "$dest" ] && { note "[skip] $(basename "$dest")"; return 0; }
  [ "$used" -ge "$BUDGET" ] && { skipped[$product]=$(( ${skipped[$product]} + 1 )); return 0; }

  tmp="${dest}.part"
  http=$(curl -sSL --max-time 240 -o "$tmp" -w '%{http_code}' "$url" || echo "000")
  if [ "$http" = "200" ] && [ -s "$tmp" ]; then
    size=$(stat -c%s "$tmp")
    mv "$tmp" "$dest"
    used=$((used + size))
    note "[ok]   $(basename "$dest")  ($((size / 1024 / 1024)) MB, toplam $((used / 1024 / 1024)) MB)"
  else
    rm -f "$tmp"
    note "[miss] $(basename "$dest") — HTTP $http"
  fi
}

backfill_product() {
  local product="$1" limit="$2"
  local config="$BUILD_DIR/$product/config.yml"
  local name pool_letter track_file
  name=$(yget "$config" name)
  pool_letter=$(yget "$config" pool_letter)
  track_file="$TRACK_DIR/${name}.json"
  [ -f "$track_file" ] || return 0

  local pool_path="$POOL_DIR/$pool_letter/$product"
  mkdir -p "$pool_path"

  local bf format arch suffix dl_tpl extract pattern url dest v n=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$n" -ge "$limit" ] && break
    local got=0
    for bf in "$BUILD_DIR/$product"/deb-*.yml; do
      [ -f "$bf" ] || continue
      format=$(yget "$bf" format)
      [ "$format" = "deb" ] || continue
      extract=$(yget "$bf" extract | tr '[:upper:]' '[:lower:]')
      [ "$extract" = "true" ] && continue     # "latest" zip: no versioned URL

      arch=$(yget "$bf" arch)
      suffix=$(yget "$bf" suffix)
      dl_tpl=$(yget "$bf" download_url)
      pattern=$(deb_glob "$(yget "$bf" pool_name)" "$v" || true)
      [ -z "$pattern" ] && pattern=$(deb_glob "$(yget "$bf" inner_pattern)" "$v" || true)
      [ -z "$pattern" ] && continue

      url=$(resolve_url "$dl_tpl" "$v" "$suffix")
      dest="$pool_path/$(basename "$pattern")"
      fetch_deb "$product" "$v" "$arch" "$url" "$dest" || true
      [ -f "$dest" ] && got=1
    done
    [ "$got" = "1" ] && covered[$name]=$(( ${covered[$name]} + 1 ))
    n=$((n + 1))
  done < <(jq -r '.[].version' "$track_file")
}

echo "==> Backfilling historical .deb files (budget: ${BUDGET_MB} MB)..."

backfill_product tixati "${MAX_TIXATI:-999}"
backfill_product gh "${MAX_GH:-30}"
backfill_product rustdesk "${MAX_RUSTDESK:-15}"
# mattermost-desktop and apidog are intentionally skipped (see env docs above).

echo "==> Refreshing .archs metadata from pool (union with upstream data)..."
for dir in "$BUILD_DIR"/*/; do
  product=$(basename "$dir")
  name=$(yget "$dir/config.yml" name)
  track_file="$TRACK_DIR/${name}.json"
  [ -f "$track_file" ] || continue

  pool_map=$(jq -r '.[].version' "$track_file" | while IFS= read -r v; do
    printf '%s\t%s\n' "$v" "$(detect_archs_in_pool "$product" "$v" | jq -c '.')"
  done | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("\t"))
                    | map({key: .[0], value: (.[1] | fromjson)}) | from_entries')

  tmp=$(mktemp)
  jq --argjson pool "$pool_map" \
    'map(.archs = (((.archs // []) + ($pool[.version] // [])) | unique))' \
    "$track_file" > "$tmp"
  mv "$tmp" "$track_file"
done

echo "==> Regenerating landing page..."
bash "$HERE/build-index.sh"

echo ""
echo "==> Summary"
for name in tixati gh rustdesk mattermost-desktop apidog; do
  echo "  $name: ${covered[$name]} version(s) with binaries, ${skipped[$name]} skipped"
done
echo "  downloaded: $((used / 1024 / 1024)) MB / ${BUDGET_MB} MB"
echo ""
echo "NOTE: pool/*.deb files are gitignored — force-add them:"
echo "  git add -f docs/pool/"
echo "CI will rebuild and re-sign docs/dists/ from the full pool on its next run."
