#!/usr/bin/env bash
# verify.sh — Offline self-check for the package build tooling and its artifacts.
# No network required. Exits non-zero on the first failure with a clear message.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "  [FAIL] $*" >&2; exit 1; }
ok()   { echo "  [ok]   $*"; }

echo "==> 1. syntax"
for f in scripts/*.sh; do
  bash -n "$f" || fail "bash syntax: $f"
done
python3 - <<'PY' || fail "python syntax: scripts/yaml-get.py"
compile(open("scripts/yaml-get.py").read(), "scripts/yaml-get.py", "exec")
PY
ok "all scripts parse"

echo "==> 2. yaml-get.py (PyYAML and fallback paths)"
[ "$(python3 scripts/yaml-get.py .github/build/gh/config.yml name)" = "gh" ] \
  || fail "yaml-get normal path"
[ "$(python3 scripts/yaml-get.py --no-yaml .github/build/gh/config.yml name)" = "gh" ] \
  || fail "yaml-get fallback path"
[ "$(python3 scripts/yaml-get.py --no-yaml .github/build/gh/config.yml missing KEY)" = "KEY" ] \
  || fail "yaml-get fallback default"
[ "$(python3 scripts/yaml-get.py --no-yaml .github/build/rustdesk/config.yml version_prefix X)" = "" ] \
  || fail "yaml-get fallback empty value"
ok "yaml-get works with and without PyYAML"

echo "==> 3. tracked versions are semver-sorted (newest first)"
SORT='sort_by([(.version // "" | gsub("-"; ".") | split(".") | map(tonumber? // 0)), (.version // "")]) | reverse | map(.version)'
for f in tracked/*.json; do
  jq empty "$f" || fail "invalid JSON: $f"
  actual=$(jq -c '[.[].version]' "$f")
  expected=$(jq -c "$SORT" "$f")
  [ "$actual" = "$expected" ] || fail "version order in $f is not semver-desc"
done
ok "version ordering"

echo "==> 4. generated manifests contain no placeholders or empty hashes"
EMPTY_HASH='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
for f in bucket/*.json Formula/*.rb; do
  [ -f "$f" ] || continue
  jq empty "$f" 2>/dev/null || true
  grep -q '\${[A-Z_]*}' "$f" && fail "unresolved placeholder in $f"
  grep -q "$EMPTY_HASH" "$f" && fail "empty-download hash in $f"
  grep -qE '(url|sha256) ""' "$f" && fail "empty url/sha in $f"
done
ok "manifest hashes and URLs"

echo "==> 5. APT Release checksums match files on disk"
REL="docs/dists/stable/Release"
[ -f "$REL" ] || fail "missing $REL"
for ALGO in MD5Sum SHA1 SHA256 SHA512; do
  case "$ALGO" in
    MD5Sum) BIN=md5sum ;; SHA1) BIN=sha1sum ;; SHA256) BIN=sha256sum ;; SHA512) BIN=sha512sum ;;
  esac
  while read -r sum size path; do
    [ -n "${sum:-}" ] || continue
    [ -f "docs/dists/stable/$path" ] || fail "$path listed in $ALGO but missing"
    actual=$($BIN "docs/dists/stable/$path" | awk '{print $1}')
    [ "$actual" = "$sum" ] || fail "$ALGO mismatch for $path"
  done < <(awk -v a="$ALGO:" '$0==a{f=1;next} /^[A-Za-z0-9]+:$/{f=0} f' "$REL")
done
ok "Release checksums"

echo "==> 6. landing page sanity"
[ -s docs/index.html ] || fail "empty docs/index.html"
grep -q 'id="card-gh"' docs/index.html || fail "gh card missing from index"
grep -q 'id="card-apidog"' docs/index.html || fail "apidog card missing from index"
ok "index.html"

echo "==> ALL CHECKS PASSED"
