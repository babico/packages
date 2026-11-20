#!/usr/bin/env bash
# build-all.sh — Single orchestrator for all package builds.
# Walks .github/build/*/ to detect versions, download, and build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../.github/build"
TRACK_DIR="$SCRIPT_DIR/../tracked"
POOL_DIR="$SCRIPT_DIR/../docs/pool/main"
SCOOP_DIR="$SCRIPT_DIR/../bucket"
BREW_DIR="$SCRIPT_DIR/../Formula"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GH_TOKEN="${GH_TOKEN:-}"
GH_API_ARGS=(-H "Accept: application/vnd.github+json")
[ -n "$GH_TOKEN" ] && GH_API_ARGS+=(-H "Authorization: Bearer $GH_TOKEN")
FORCE="${1:-}"
PY="$SCRIPT_DIR/yaml-get.py"

yget() { python3 "$PY" "$@"; }

# Download a URL and print its SHA-256. Returns non-zero on HTTP/transport
# errors or an empty body — callers must never bake an empty hash into a
# manifest (sha256sum of an empty stream is the well-known e3b0c442... string).
sha256_url() {
  local url="$1" out hash
  [ -n "$url" ] || return 1
  out=$(set -o pipefail; curl -fsSL --max-time 180 "$url" | sha256sum) || return 1
  hash=$(printf '%s' "$out" | awk '{print $1}')
  [ -n "$hash" ] || return 1
  [ "$hash" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ] && return 1
  printf '%s' "$hash"
}

# Turn a pool_name / inner_pattern into a find(1) glob for a version.
deb_glob() {
  local pattern="$1" ver="$2"
  [ -n "$pattern" ] || return 1
  printf '%s' "$pattern" | sed "s|\${VERSION}|$ver|g"
}

resolve_url() {
  local url="$1" ver="$2" suffix="$3"
  echo "$url" | sed "s|\${VERSION}|$ver|g; s|\${SUFFIX}|$suffix|g"
}

get_tracked() {
  local f="$TRACK_DIR/$1.json"
  [ -f "$f" ] && jq -r '.[].version' "$f" 2>/dev/null || true
}

upsert_version() {
  local product="$1" name="$2" ver="$3" rel_date="${4:-$NOW}"
  local f="$TRACK_DIR/${name}.json"
  mkdir -p "$TRACK_DIR"
  [ -f "$f" ] || echo "[]" > "$f"
  local archs_json
  archs_json=$(detect_archs_in_pool "$product" "$ver")
  local entry
  entry=$(jq -n --arg v "$ver" --arg a "$NOW" --arg r "$rel_date" --argjson archs "$archs_json" \
    '{"version":$v,"released_at":$r,"added_at":$a,"archs":$archs}')
  local tmp
  tmp=$(mktemp)
  jq --argjson e "$entry" '
    def vk: (.version // "" | gsub("-"; ".") | split(".") | map(tonumber? // 0));
    map(select(.version != $e.version)) + [$e] | sort_by([vk, (.version // "")]) | reverse
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
  echo "    [track] $ver archs=$(echo "$archs_json" | jq -r 'join(",")')"
}

detect_archs_in_pool() {
  local product="$1" ver="$2"
  local config="$BUILD_DIR/$product/config.yml"
  local pool_letter
  pool_letter=$(yget "$config" pool_letter)
  local a_json="[]"
  local pool_path="$POOL_DIR/$pool_letter/$product"
  for bf in "$BUILD_DIR/$product"/deb-*.yml; do
    [ -f "$bf" ] || continue
    local arch pattern
    arch=$(yget "$bf" arch)
    pattern=$(deb_glob "$(yget "$bf" pool_name)" "$ver" 2>/dev/null || true)
    [ -z "$pattern" ] && pattern=$(deb_glob "$(yget "$bf" inner_pattern)" "$ver" 2>/dev/null || true)
    [ -z "$pattern" ] && pattern="*$(yget "$bf" suffix)"
    if compgen -G "$pool_path/$pattern" >/dev/null 2>&1; then
      a_json=$(echo "$a_json" | jq --arg a "$arch" '. + [$a]')
    fi
  done
  echo "$a_json"
}

get_release_date() {
  local product="$1" ver="$2"
  local config="$BUILD_DIR/$product/config.yml"
  local source repo prefix
  source=$(yget "$config" source)
  repo=$(yget "$config" repo)
  prefix=$(yget "$config" version_prefix)
  local rel=""
  if [ "$source" = "github" ] && [ -n "$repo" ]; then
    rel=$(curl -sSf "https://api.github.com/repos/${repo}/releases/tags/${prefix}${ver}" \
      2>/dev/null | jq -r '.published_at // empty' || true)
  fi
  if [ -z "$rel" ]; then
    local dl_url first_suffix
    first_suffix=""
    for bf in "$BUILD_DIR/$product"/deb-*.yml "$BUILD_DIR/$product"/dmg-*.yml "$BUILD_DIR/$product"/rpm*.yml; do
      [ -f "$bf" ] || continue
      first_suffix=$(yget "$bf" suffix)
      break
    done
    [ -z "$first_suffix" ] && { echo "$NOW"; return; }
    dl_url=$(for fb in "$BUILD_DIR/$product"/deb-*.yml "$BUILD_DIR/$product"/dmg-*.yml "$BUILD_DIR/$product"/rpm*.yml; do
    [ -f "$fb" ] && { yget "$fb" download_url; break; }
  done)
    [ -z "$dl_url" ] && { echo "$NOW"; return; }
    dl_url=$(resolve_url "$dl_url" "$ver" "$first_suffix")
    rel=$(curl -sSI "$dl_url" 2>/dev/null | grep -i '^Last-Modified:' | sed 's/Last-Modified: *//;s/\r//' || true)
    if [ -n "$rel" ]; then
      rel=$(date -u -d "$rel" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$NOW")
    fi
  fi
  echo "${rel:-$NOW}"
}

# ── Version detection ─────────────────────────────────────────────────

detect_version() {
  local product="$1"
  local config="$BUILD_DIR/$product/config.yml"
  local source name repo lurl vre prefix extract_re
  source=$(yget "$config" source)
  name=$(yget "$config" name)

  case "$source" in
    github)
      repo=$(yget "$config" repo)
      prefix=$(yget "$config" version_prefix)
      local tag
      tag=$(curl -sSf "${GH_API_ARGS[@]}" \
        "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
      echo "${tag#$prefix}"
      ;;
    http_listing)
      lurl=$(yget "$config" listing_url)
      local vre
      vre=$(yget "$config" version_match)
      # grep for matching lines, extract version with sed capture group
      local matches
      matches=$(curl -sSf "$lurl" | grep -oP "$vre" || true)
      # Extract the version from each match using the capture group
      echo "$matches" | sed -E 's/.*([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' | sort -V -u | tail -1
      ;;
    zip_download)
      local suf bf dl_url_tpl suffix_val durl zip_tmp ver extract_re
      bf=$(ls "$BUILD_DIR/$product"/deb-*.yml 2>/dev/null | head -1)
      [ -z "$bf" ] && { echo ""; return; }
      dl_url_tpl=$(yget "$bf" download_url)
      suffix_val=$(yget "$bf" suffix)
      durl=$(echo "$dl_url_tpl" | sed "s|\${SUFFIX}|$suffix_val|g")
      zip_tmp=$(mktemp --suffix=.zip)
      curl -sSf "$durl" -o "$zip_tmp" || true
      ver=$(unzip -l "$zip_tmp" 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
      rm -f "$zip_tmp"
      echo "$ver"
      ;;
    *)
      echo ""
      ;;
  esac
}

# ── Download ──────────────────────────────────────────────────────────

download() {
  local product="$1" version="$2"
  local config="$BUILD_DIR/$product/config.yml"
  local pool_letter publish_archs
  pool_letter=$(yget "$config" pool_letter)
  publish_archs=$(yget "$config" publish_archs)
  local pool_path="$POOL_DIR/$pool_letter/$product"
  mkdir -p "$pool_path"

  local ok=0
  for bf in "$BUILD_DIR/$product"/deb-*.yml "$BUILD_DIR/$product"/rpm*.yml; do
    [ -f "$bf" ] || continue
    local bf_arch
    bf_arch=$(yget "$bf" arch)
    if [ -n "$publish_archs" ] && ! echo " $publish_archs " | grep -q " $bf_arch "; then
      continue
    fi
    local format arch suffix dl_url_tpl
    format=$(yget "$bf" format)
    arch=$(yget "$bf" arch)
    suffix=$(yget "$bf" suffix)
    dl_url_tpl=$(yget "$bf" download_url)

    case "$format" in
      deb)
        local extract
        extract=$(yget "$bf" extract)
        extract=$(echo "$extract" | tr '[:upper:]' '[:lower:]')
        local dl_url
        dl_url=$(resolve_url "$dl_url_tpl" "$version" "$suffix")

        if [ "$extract" = "true" ]; then
          local inner_pattern expected_name zip_tmp
          inner_pattern=$(yget "$bf" inner_pattern)
          expected_name=$(deb_glob "$inner_pattern" "$version" || true)
          if [ -n "$expected_name" ] && [ -f "$pool_path/$expected_name" ]; then
            echo "    [skip]  $expected_name"
            ((ok++)) || true
            continue
          fi
          zip_tmp="$pool_path/${suffix}.zip.tmp"
          echo "    [fetch] $suffix ($arch) via zip"
          local http
          http=$(curl -sSL -w "%{http_code}" -o "$zip_tmp" "$dl_url")
          if [ "$http" = "200" ]; then
            local extract_dir inner_deb inner_name inner_glob
            extract_dir=$(mktemp -d)
            unzip -q "$zip_tmp" -d "$extract_dir"
            inner_glob=$(deb_glob "$inner_pattern" "$version" || true)
            [ -z "$inner_glob" ] && inner_glob='*.deb'
            inner_deb=$(find "$extract_dir" -name "$inner_glob" | head -1)
            [ -z "$inner_deb" ] && inner_deb=$(find "$extract_dir" -name '*.deb' | head -1)
            if [ -f "$inner_deb" ]; then
              inner_name=$(basename "$inner_deb")
              cp "$inner_deb" "$pool_path/$inner_name"
              echo "    [ok]    $inner_name ($(du -sh "$pool_path/$inner_name" | cut -f1))"
              ((ok++)) || true
            else
              echo "    [error] no .deb in zip (pattern: $inner_glob)"
            fi
            rm -rf "$extract_dir"
          else
            echo "    [miss]  $suffix — HTTP $http"
          fi
          rm -f "$zip_tmp"
        else
          local pool_name
          pool_name=$(echo "$(yget "$bf" pool_name)" | sed "s|\${VERSION}|$version|g")
          local dest="$pool_path/$pool_name"
          if [ -f "$dest" ]; then
            echo "    [skip]  $pool_name"
            ((ok++)) || true
            continue
          fi
          echo "    [fetch] $pool_name"
          local http
          http=$(curl -sSL -w "%{http_code}" -o "${dest}.tmp" "$dl_url")
          if [ "$http" = "200" ]; then
            mv "${dest}.tmp" "$dest"
            echo "    [ok]    $pool_name ($(du -sh "$dest" | cut -f1))"
            ((ok++)) || true
          else
            rm -f "${dest}.tmp"
            echo "    [miss]  $pool_name — HTTP $http"
          fi
        fi
        ;;

      rpm)
        if [ "$product" = "apidog" ]; then
          echo "    [rpm]  Building from tarball..."
          local rurl spec_tmpl
          rurl=$(resolve_url "$dl_url_tpl" "$version" "$suffix")
          spec_tmpl="$BUILD_DIR/$product/rpm.spec.tmpl"
          local rpm_root
          rpm_root=$(mktemp -d)
          mkdir -p "$rpm_root"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
          curl -sSf "$rurl" -o "$rpm_root/SOURCES/apidog-manual.tar.gz"
          local changelog
          changelog="* $(date -u +'%a %b %d %Y') Apidog Build - ${version}-1\n- Automated build from upstream tarball"
          sed -e "s/__VERSION__/$version/g" -e "s|__CHANGELOG__|$changelog|g" \
            "$spec_tmpl" > "$rpm_root/SPECS/apidog.spec"
          (cd "$rpm_root" && rpmbuild -ba --define "_topdir $PWD" SPECS/apidog.spec 2>&1 | tail -3) || true
          local rpm_file
          rpm_file=$(find "$rpm_root/RPMS" -name "*.rpm" 2>/dev/null | head -1)
          if [ -f "$rpm_file" ]; then
            cp "$rpm_file" "$pool_path/$(basename "$rpm_file")"
            echo "    [ok]    $(basename "$rpm_file") ($(du -sh "$rpm_file" | cut -f1))"
            ((ok++)) || true
          else
            echo "    [error] rpmbuild failed"
          fi
          rm -rf "$rpm_root"
        fi
        ;;
    esac
  done
  [ "$ok" -gt 0 ] && return 0 || return 1
}

# ── Scoop manifest builder ────────────────────────────────────────────

build_scoop() {
  local product="$1" version="$2"
  local tmpl="$BUILD_DIR/$product/scoop.json.tmpl"
  [ -f "$tmpl" ] || return 0

  local config="$BUILD_DIR/$product/config.yml"
  local source repo prefix lurl product_name sf asset_ext
  source=$(yget "$config" source)
  repo=$(yget "$config" repo)
  prefix=$(yget "$config" version_prefix)
  lurl=$(yget "$config" listing_url)
  product_name=$(yget "$config" name)
  sf="$BUILD_DIR/$product/scoop.yml"
  asset_ext=$(yget "$sf" asset_ext)

  local url64="" hash64="" url32="" hash32=""

  case "$source" in
    github)
      local assets win_name
      assets=$(curl -sSf "${GH_API_ARGS[@]}" \
        "https://api.github.com/repos/${repo}/releases/tags/${prefix}${version}")
      if [ -n "$asset_ext" ]; then
        win_name=$(echo "$assets" | jq -r --arg ext "$asset_ext" \
          '[.assets[] | select(.name | test("." + $ext + "$"; "i")) | select(.name | test("blockmap"; "i") | not) | select(.name | test("arm64|armv7|386|i686"; "i") | not) | select(.name | test("win|x86_64"; "i"))] | .[0].name // empty')
      else
        win_name=$(echo "$assets" | jq -r \
          '[.assets[] | select(.name | test("\\.(exe|msi|zip)$"; "i")) | select(.name | test("win|x86|x64|amd64|arm64"; "i")) | select(.name | test("blockmap"; "i") | not)] |
           (map(select(.name | endswith(".msi"))) | .[0].name // empty) //
           (map(select(.name | endswith(".exe"))) | .[0].name // empty) //
           (map(select(.name | endswith(".zip"))) | .[0].name // empty)')
      fi
      [ -n "$win_name" ] || { echo "    [error] scoop: no ${asset_ext:-windows} asset for $version"; return 1; }
      url64=$(echo "$assets" | jq -r --arg n "$win_name" '.assets[] | select(.name == $n) | .browser_download_url')
      hash64=$(sha256_url "$url64") || { echo "    [error] scoop: cannot hash $url64"; return 1; }
      ;;
    http_listing)
      local dl_tpl
      dl_tpl=$(yget "$sf" download_url 2>/dev/null || echo "")
      [ -z "$dl_tpl" ] && dl_tpl="https://download.tixati.com/tixati-\${VERSION}-1.win64-install.exe"
      url64=$(echo "$dl_tpl" | sed "s|\${VERSION}|$version|g; s|\${SUFFIX}|win64-install.exe|g")
      hash64=$(sha256_url "$url64") || { echo "    [error] scoop: cannot hash $url64"; return 1; }
      ;;
    zip_download)
      local suf64 suf32 dl_tpl
      dl_tpl=$(yget "$sf" download_url)
      suf64=$(yget "$sf" suffix_64)
      suf32=$(yget "$sf" suffix_32)
      url64=$(echo "$dl_tpl" | sed "s|\${SUFFIX}|$suf64|g")
      hash64=$(sha256_url "$url64") || { echo "    [error] scoop: cannot hash $url64"; return 1; }
      if [ -n "$suf32" ]; then
        url32=$(echo "$dl_tpl" | sed "s|\${SUFFIX}|$suf32|g")
        hash32=$(sha256_url "$url32") || { echo "    [error] scoop: cannot hash $url32"; return 1; }
      fi
      ;;
  esac

  if grep -q '\${SHA256_32}' "$tmpl" && [ -z "$hash32" ]; then
    echo "    [error] scoop: template needs SHA256_32 but no 32-bit source is configured"
    return 1
  fi

  mkdir -p "$SCOOP_DIR"
  local out
  out=$(cat "$tmpl")
  out=$(echo "$out" | sed "s|\${VERSION}|$version|g")
  out=$(echo "$out" | sed "s|\${SHA256_64}|$hash64|g")
  out=$(echo "$out" | sed "s|\${SHA256_32}|$hash32|g")
  out=$(echo "$out" | sed "s|\${SHA256}|$hash64|g")
  if echo "$out" | grep -q '\${[A-Z_]*}'; then
    echo "    [error] scoop: unresolved placeholder after substitution"
    return 1
  fi
  echo "$out" > "$SCOOP_DIR/${product_name}.json"
  echo "    [scoop] updated"
}

# ── Homebrew formula builder ──────────────────────────────────────────

build_brew() {
  local product="$1" version="$2"
  local tmpl="$BUILD_DIR/$product/brew.rb.tmpl"
  [ -f "$tmpl" ] || return 0

  local config="$BUILD_DIR/$product/config.yml"
  local product_name
  product_name=$(yget "$config" name)
  local mac_arm_url="" mac_arm_hash=""
  local mac_x86_url="" mac_x86_hash=""
  local lin_arm_url="" lin_arm_hash=""
  local lin_amd64_url="" lin_amd64_hash=""
  local lin_rpm_url="" lin_rpm_hash=""

  for bf in "$BUILD_DIR/$product"/*.yml; do
    [ -f "$bf" ] || continue
    [ "$(basename "$bf")" = "config.yml" ] && continue
    local fmt arch dl_tpl suffix
    fmt=$(yget "$bf" format)
    arch=$(yget "$bf" arch)
    dl_tpl=$(yget "$bf" download_url)
    suffix=$(yget "$bf" suffix)

    case "$fmt:$arch" in
      dmg:arm)
        mac_arm_url=$(resolve_url "$dl_tpl" "$version" "$suffix")
        mac_arm_hash=$(sha256_url "$mac_arm_url") || { echo "    [error] brew: cannot hash $mac_arm_url"; return 1; }
        ;;
      dmg:x86)
        mac_x86_url=$(resolve_url "$dl_tpl" "$version" "$suffix")
        mac_x86_hash=$(sha256_url "$mac_x86_url") || { echo "    [error] brew: cannot hash $mac_x86_url"; return 1; }
        ;;
      deb:arm64|deb:armhf)
        lin_arm_url=$(resolve_url "$dl_tpl" "$version" "$suffix")
        lin_arm_hash=$(sha256_url "$lin_arm_url") || { echo "    [error] brew: cannot hash $lin_arm_url"; return 1; }
        ;;
      deb:amd64)
        lin_amd64_url=$(resolve_url "$dl_tpl" "$version" "$suffix")
        lin_amd64_hash=$(sha256_url "$lin_amd64_url") || { echo "    [error] brew: cannot hash $lin_amd64_url"; return 1; }
        ;;
      rpm:x86)
        lin_rpm_url=$(resolve_url "$dl_tpl" "$version" "$suffix")
        lin_rpm_hash=$(sha256_url "$lin_rpm_url") || { echo "    [error] brew: cannot hash $lin_rpm_url"; return 1; }
        ;;
    esac
  done

  mkdir -p "$BREW_DIR"
  local out
  out=$(cat "$tmpl")
  out=$(echo "$out" | sed "s|\${VERSION}|$version|g")
  out=$(echo "$out" | sed "s|\${MAC_ARM_URL}|$mac_arm_url|g")
  out=$(echo "$out" | sed "s|\${MAC_ARM_SHA256}|$mac_arm_hash|g")
  out=$(echo "$out" | sed "s|\${MAC_X86_URL}|$mac_x86_url|g")
  out=$(echo "$out" | sed "s|\${MAC_X86_SHA256}|$mac_x86_hash|g")
  out=$(echo "$out" | sed "s|\${LINUX_ARM_URL}|$lin_arm_url|g")
  out=$(echo "$out" | sed "s|\${LINUX_ARM_SHA256}|$lin_arm_hash|g")
  out=$(echo "$out" | sed "s|\${LINUX_AMD64_URL}|$lin_amd64_url|g")
  out=$(echo "$out" | sed "s|\${LINUX_AMD64_SHA256}|$lin_amd64_hash|g")
  out=$(echo "$out" | sed "s|\${LINUX_RPM_URL}|$lin_rpm_url|g")
  out=$(echo "$out" | sed "s|\${LINUX_RPM_SHA256}|$lin_rpm_hash|g")
  if echo "$out" | grep -q '\${[A-Z_]*}'; then
    echo "    [error] brew: unresolved placeholder after substitution"
    return 1
  fi
  echo "$out" > "$BREW_DIR/${product_name}.rb"
  echo "    [brew]  updated"
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
  echo "==> Scanning build targets..."
  local any_update=false

  for dir in "$BUILD_DIR"/*/; do
    local product
    product=$(basename "$dir")
    local config="$dir/config.yml"
    [ -f "$config" ] || continue

    local name
    name=$(yget "$config" name)
    echo ""
    echo "--- $name ---"

    local latest
    latest=$(detect_version "$product")
    [ -z "$latest" ] && { echo "  [skip]  version detection failed"; continue; }
    echo "  upstream: $latest"

    local tracked ephemeral up_to_date=false
    tracked=$(get_tracked "$name")
    ephemeral=$(yget "$config" ephemeral_pool | tr '[:upper:]' '[:lower:]')
    if echo "$tracked" | grep -qx "$latest" && [ "$FORCE" != "force" ]; then
      up_to_date=true
    fi

    if [ "$up_to_date" = "true" ]; then
      if [ "$ephemeral" = "true" ]; then
        # Binaries are not committed for this product — refresh the pool on
        # every run so the APT index and Pages still have something installable.
        echo "  refreshing ephemeral pool: $latest"
        download "$product" "$latest" || echo "  [warn] artifact refresh failed"
      else
        echo "  already at $latest"
      fi
      continue
    fi

    echo "  => queued: $latest"
    any_update=true

    # Track only versions whose artifact actually landed in the pool.
    if ! download "$product" "$latest"; then
      echo "  [skip] no artifact downloaded — not tracking $latest"
      continue
    fi

    # Build Scoop manifest
    build_scoop "$product" "$latest"

    # Build Homebrew formula
    build_brew "$product" "$latest"

    # Track for APT
    local rel_date
    rel_date=$(get_release_date "$product" "$latest")
    upsert_version "$product" "$name" "$latest" "$rel_date"
  done

  if [ "$any_update" = "true" ] || [ "$FORCE" = "rebuild" ]; then
    echo ""
    echo "==> Rebuilding APT index..."
    bash "$SCRIPT_DIR/build-apt.sh" "${GPG_KEY_ID:-}" "${GPG_PASSPHRASE:-}"

    echo "==> Generating landing page..."
    bash "$SCRIPT_DIR/build-index.sh"

    echo "==> Committing..."
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git pull --rebase origin main || true
    git add -A tracked/
    git add -A docs/dists/ docs/index.html docs/apt-repo.gpg 2>/dev/null || true
    git add -A bucket/ Formula/
    git add -A .github/build/
    git commit -m "chore: update packages" || echo "Nothing to commit"
    git push
  else
    echo ""
    echo "No updates needed."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi