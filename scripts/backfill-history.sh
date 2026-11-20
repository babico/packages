#!/usr/bin/env bash
# backfill-history.sh — extend tracked/*.json with every upstream release we can
# discover, going as far back as the source allows. Metadata only: no binaries.
#
#   github       -> paginate /releases, derive version/date and .deb archs from assets
#   http_listing -> scrape the directory listing for versioned .deb filenames
#   zip_download -> only "latest" URLs; versions come from the download pipeline
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/build-all.sh"   # yget, GH_API_ARGS, helpers (main is guarded)
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

VERBOSE="${VERBOSE:-0}"
note() { echo "    $*"; }

# JSON targets for a product: [{arch, pattern}] using exact upstream filenames.
deb_targets() {
  local product="$1" targets="[]" bf p
  for bf in "$BUILD_DIR/$product"/deb-*.yml; do
    [ -f "$bf" ] || continue
    p=$(yget "$bf" pool_name)
    [ -z "$p" ] && p=$(yget "$bf" inner_pattern)
    [ -z "$p" ] && p="*$(yget "$bf" suffix)"
    targets=$(jq -c --arg a "$(yget "$bf" arch)" --arg p "$p" \
      '. + [{arch:$a, pattern:$p}]' <<<"$targets")
  done
  printf '%s' "$targets"
}

github_history() {
  local product="$1" config="$BUILD_DIR/$product/config.yml"
  local repo prefix targets page=1 resp count tmp
  repo=$(yget "$config" repo)
  prefix=$(yget "$config" version_prefix)
  targets=$(deb_targets "$product")
  tmp=$(mktemp)

  while :; do
    resp=$(curl -sSf "${GH_API_ARGS[@]}" \
      "https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}")
    count=$(jq 'length' <<<"$resp")
    jq -c --argjson targets "$targets" --arg prefix "$prefix" '
      def cpu($n):
        if ($n | test("aarch64|arm64"; "i")) then "arm64"
        elif ($n | test("armv[0-9]|armhf|arm"; "i")) then "armhf"
        elif ($n | test("x86_64|amd64|x64"; "i")) then "amd64"
        elif ($n | test("i386|i686|386|x86"; "i")) then "i386"
        else null end;
      def classify($n; $url):
        if ($n | test("\\.deb$"; "i")) then {os: "linux", cpu: cpu($n), url: $url, name: $n}
        elif (($n | test("\\.(exe|msi)$"; "i")) or (($n | test("\\.zip$"; "i")) and ($n | test("win"; "i"))))
          then {os: "windows", cpu: cpu($n), url: $url, name: $n}
        elif (($n | test("\\.(dmg|pkg)$"; "i")) or (($n | test("\\.zip$"; "i")) and ($n | test("mac|darwin|osx"; "i"))))
          then {os: "macos", cpu: cpu($n), url: $url, name: $n}
        else null end;
      [ .[]
        | select(.draft == false)
        | (.tag_name | ltrimstr($prefix)) as $v
        | select($v | test("^[0-9]"))
        | . as $r
        | [ ($r.assets // [])[] | classify(.name; .browser_download_url) | select(. != null and .cpu != null) ] as $assets
        | { version: $v,
            released_at: ($r.published_at // $r.created_at // ""),
            archs: ([ $assets[].cpu ] | unique),
            assets: $assets }
      ]' <<<"$resp" >> "$tmp"
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
    [ "$page" -gt 10 ] && break
  done
  jq -s 'add' "$tmp"
}

listing_history() {
  local url config="$1" html
  url=$(yget "$config" listing_url)
  html=$(curl -sSf "$url")
  printf '%s' "$html" \
    | grep -oE 'tixati_[0-9.]+-1_(amd64|i686)\.deb|tixati-[0-9.]+-1\.win(32|64)-install\.exe' \
    | sort -u \
    | jq -R -s '
        split("\n") | map(select(length > 0))
        | reduce .[] as $f ({};
            if ($f | startswith("tixati_")) then
              ($f | capture("tixati_(?<v>[0-9.]+)-1_(?<a>amd64|i686)\\.deb")) as $m
              | (if $m.a == "i686" then "i386" else $m.a end) as $cpu
              | .[$m.v] = ((.[$m.v] // {archs: [], assets: []})
                  | .archs += [$cpu]
                  | .assets += [{os: "linux", cpu: $cpu,
                                 url: ("https://download.tixati.com/" + $f), name: $f}])
            else
              ($f | capture("tixati-(?<v>[0-9.]+)-1\\.win(?<b>32|64)-install\\.exe")) as $m
              | (if $m.b == "32" then "i386" else "amd64" end) as $cpu
              | .[$m.v] = ((.[$m.v] // {archs: [], assets: []})
                  | .archs += [$cpu]
                  | .assets += [{os: "windows", cpu: $cpu,
                                 url: ("https://download.tixati.com/" + $f), name: $f}])
            end)
        | to_entries
        | map({version: .key, released_at: "", archs: (.value.archs | unique), assets: .value.assets})'
}

merge_history() {
  local name="$1" incoming="$2" f="$TRACK_DIR/${name}.json" tmp before after incf
  [ -f "$f" ] || echo "[]" > "$f"
  before=$(jq 'length' "$f")
  incf=$(mktemp)
  jq -c '[.[] | select((.archs // []) | length > 0)]' <<<"$incoming" > "$incf"
  [ "$(jq 'length' "$incf")" -eq 0 ] && { note "no installable versions discovered"; return 0; }
  tmp=$(mktemp)
  jq --slurpfile inc "$incf" --arg now "$NOW" '
    def vk: (.version // "" | gsub("-"; ".") | split(".") | map(tonumber? // 0));
    reduce $inc[0][] as $e (.;
      if any(.[]; .version == $e.version) then
        map(if .version == $e.version then
              .archs = (((.archs // []) + ($e.archs // [])) | unique)
              | .assets = (((.assets // []) + ($e.assets // [])) | unique_by(.url))
              | .released_at = (if ($e.released_at // "") != "" then $e.released_at
                                else (.released_at // "") end)
            else . end)
      else
        . + [{ version: $e.version,
               released_at: ($e.released_at // ""),
               added_at: $now,
               archs: ($e.archs // []),
               assets: ($e.assets // []) }]
      end)
    | sort_by([vk, (.version // "")]) | reverse
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
  after=$(jq 'length' "$f")
  note "$name: $before -> $after version(s) (+$((after - before)))"
}

echo "==> Backfilling version history from upstream sources..."

for dir in "$BUILD_DIR"/*/; do
  product=$(basename "$dir")
  config="$dir/config.yml"
  [ -f "$config" ] || continue
  name=$(yget "$config" name)
  source=$(yget "$config" source)
  echo "--- $name ($source) ---"

  case "$source" in
    github)
      history=$(github_history "$product")
      ;;
    http_listing)
      history=$(listing_history "$config")
      ;;
    zip_download)
      # Only "latest" URLs exist upstream. Versions are recorded by the main
      # pipeline, after the artifact is actually downloaded into the pool.
      note "versioned history is driven by the deb download pipeline"
      continue
      ;;
    *)
      note "unknown source '$source' — skipped"
      continue
      ;;
  esac

  count=$(jq 'length' <<<"$history")
  note "discovered $count upstream version(s)"
  [ "$VERBOSE" = "1" ] && jq -r '.[] | "      \(.version)  \(.archs | join(","))  \(.released_at)"' <<<"$history"
  merge_history "$name" "$history"
done

echo "==> Done. Run 'bash scripts/backfill-debs.sh' for binaries, then rebuild the index."
