#!/usr/bin/env bash
# build-index.sh — Generate the package index landing page.
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../.github/build"
TRACK_DIR="$SCRIPT_DIR/../tracked"
PY="$SCRIPT_DIR/yaml-get.py"
yget() { python3 "$PY" "$@"; }

deb_pattern() {
  local bf="$1" ver="$2" pattern
  pattern=$(yget "$bf" pool_name)
  [ -z "$pattern" ] && pattern=$(yget "$bf" inner_pattern)
  if [ -n "$pattern" ]; then
    printf '%s' "$pattern" | sed "s|\${VERSION}|$ver|g"
  else
    printf '*%s' "$(yget "$bf" suffix)"
  fi
}

OWNER="${GITHUB_REPOSITORY_OWNER:-babico}"
SLUG="${GITHUB_REPOSITORY:-babico/packages}"
NAME="${SLUG##*/}"
URL="https://${OWNER}.github.io/${NAME}"
GH_URL="https://github.com/${SLUG}"
UPDATED=$(date -u '+%Y-%m-%d %H:%M UTC')
mkdir -p docs

APP_COUNT=0; TOTAL_VERSIONS=0
APP_NAV=""; APP_PANELS=""

for dir in "$BUILD_DIR"/*/; do
  config="$dir/config.yml"
  [ -f "$config" ] || continue
  APP_COUNT=$((APP_COUNT + 1))

  app_name=$(yget "$config" name)
  display=$(yget "$config" display)
  desc=$(yget "$config" description)
  homepage=$(yget "$config" homepage)
  pool_letter=$(yget "$config" pool_letter)
  git_repo=$(yget "$config" repo)
  prefix=$(yget "$config" version_prefix)
  changelog_url=$(yget "$config" changelog_url)

  TRACKING="$TRACK_DIR/${app_name}.json"
  TOTAL=0; LATEST=""; ROWS=""

  if [ -f "$TRACKING" ]; then
    TOTAL=$(jq -r 'length // 0' "$TRACKING")
    TOTAL_VERSIONS=$((TOTAL_VERSIONS + TOTAL))
    LATEST=$(jq -r 'if length == 0 then "" else max_by([(.released_at // .added_at // ""), ((.version // "") | split(".") | map(tonumber? // 0))]) | .version // "" end' "$TRACKING")
    POOL_LIST=$(find "docs/pool/main/${pool_letter}/${app_name}/" -maxdepth 1 -name '*.deb' -printf '%f\n' 2>/dev/null || true)
    declare -A DEB_TPL=() POOL_FILES=()
    for bf in "$dir"deb-*.yml; do
      [ -f "$bf" ] || continue
      a=$(yget "$bf" arch)
      p=$(yget "$bf" pool_name)
      [ -z "$p" ] && p=$(yget "$bf" inner_pattern)
      [ -z "$p" ] && p="*$(yget "$bf" suffix)"
      DEB_TPL["$a"]="$p"
    done
    while IFS= read -r f; do [ -n "$f" ] && POOL_FILES["$f"]=1; done <<< "$POOL_LIST"

    while IFS=$'\t' read -r V REL ARCH_STR ASSETS_JSON; do
      REL=${REL:0:10}
      latest_class=""; [ "$V" = "$LATEST" ] && latest_class=" latest"
      badge=""; [ "$V" = "$LATEST" ] && badge='<span class="badge">latest</span>'

      SEEN=""; LCHIPS=""; WCHIPS=""; MCHIPS=""

      # Mirrored .deb files first — these are served from this site.
      for ARCH in $ARCH_STR; do
        pat="${DEB_TPL[$ARCH]:-}"
        [ -z "$pat" ] && continue
        pat="${pat//\$\{VERSION\}/$V}"
        if [ -n "${POOL_FILES[$pat]:-}" ]; then
          LCHIPS="${LCHIPS}<a class=\"chip local\" href=\"${URL}/pool/main/${pool_letter}/${app_name}/${pat}\" aria-label=\"${display} ${V} Linux ${ARCH} deb\">${ARCH}</a>"
          SEEN="${SEEN} ${ARCH} "
        fi
      done

      # Upstream installers for every platform/CPU we discovered.
      while IFS=$'\t' read -r os cpu aurl; do
        [ -n "$aurl" ] || continue
        case "$os" in
          linux)
            case " $SEEN " in *" $cpu "*) continue ;; esac
            LCHIPS="${LCHIPS}<a class=\"chip\" href=\"${aurl}\" rel=\"noopener\" aria-label=\"${display} ${V} Linux ${cpu}\">${cpu}</a>"
            ;;
          windows)
            WCHIPS="${WCHIPS}<a class=\"chip\" href=\"${aurl}\" rel=\"noopener\" aria-label=\"${display} ${V} Windows ${cpu}\">${cpu}</a>"
            ;;
          macos)
            MCHIPS="${MCHIPS}<a class=\"chip\" href=\"${aurl}\" rel=\"noopener\" aria-label=\"${display} ${V} macOS ${cpu}\">${cpu}</a>"
            ;;
        esac
      done < <(printf '%s' "$ASSETS_JSON" | jq -r '.[]? | [.os, .cpu, .url] | @tsv' 2>/dev/null || true)

      HAS=""
      [ -n "$LCHIPS" ] && HAS="${HAS}linux"
      [ -n "$WCHIPS" ] && HAS="${HAS:+$HAS }win"
      [ -n "$MCHIPS" ] && HAS="${HAS:+$HAS }mac"

      PLATFORM_GROUPS=""
      [ -n "$LCHIPS" ] && PLATFORM_GROUPS="${PLATFORM_GROUPS}<div class=\"grp\" data-os=\"linux\"><span class=\"oslabel\">Linux</span><span class=\"chips\">${LCHIPS}</span></div>"
      [ -n "$WCHIPS" ] && PLATFORM_GROUPS="${PLATFORM_GROUPS}<div class=\"grp\" data-os=\"win\"><span class=\"oslabel\">Windows</span><span class=\"chips\">${WCHIPS}</span></div>"
      [ -n "$MCHIPS" ] && PLATFORM_GROUPS="${PLATFORM_GROUPS}<div class=\"grp\" data-os=\"mac\"><span class=\"oslabel\">macOS</span><span class=\"chips\">${MCHIPS}</span></div>"

      APT_CMD="apt install ${app_name}=${V}"
      SCOOP_CMD="scoop install ${app_name}@${V}"
      BREW_CMD="brew install ${app_name}"
      ACTIONS=""
      [ -n "$LCHIPS" ] && ACTIONS="${ACTIONS}<button class=\"cp\" data-cmd=\"${APT_CMD}\" onclick=\"copyCmd(this)\" aria-label=\"Copy ${APT_CMD}\">apt</button>"
      [ -n "$WCHIPS" ] && ACTIONS="${ACTIONS}<button class=\"cp\" data-cmd=\"${SCOOP_CMD}\" onclick=\"copyCmd(this)\" aria-label=\"Copy ${SCOOP_CMD}\">scoop</button>"
      ACTIONS="${ACTIONS}<button class=\"cp\" data-cmd=\"${BREW_CMD}\" onclick=\"copyCmd(this)\" aria-label=\"Copy ${BREW_CMD}\">brew</button>"

      tag="${prefix}${V}"
      if [ -n "$changelog_url" ]; then
        C_LINK="<a class=\"notes\" href=\"${changelog_url}\" aria-label=\"${display} ${V} release notes\">notes</a>"
      elif [ -n "$git_repo" ]; then
        C_LINK="<a class=\"notes\" href=\"https://github.com/${git_repo}/releases/tag/${tag}\" aria-label=\"${display} ${V} release notes\">notes</a>"
      else
        C_LINK="<a class=\"notes\" href=\"${homepage}\" aria-label=\"${display} homepage\">site</a>"
      fi

      ROWS="${ROWS}
        <tr class=\"vrow${latest_class}\" data-has=\"${HAS}\">
          <td class=\"vcell\"><span class=\"vnum\">${V}</span>${badge}</td>
          <td class=\"dcell\">${REL}</td>
          <td class=\"icell\">${PLATFORM_GROUPS}</td>
          <td class=\"acell\">${ACTIONS}</td>
          <td class=\"lcell\">${C_LINK}</td>
        </tr>"
    done < <(jq -r '.[] | [.version, (.released_at // .added_at // ""), ((.archs // []) | join(" ")), ((.assets // []) | tojson)] | @tsv' "$TRACKING")
  fi

  if [ -n "$changelog_url" ]; then
    link_line="<a href=\"${changelog_url}\">Changelog</a>"
  elif [ -n "$git_repo" ]; then
    link_line="<a href=\"https://github.com/${git_repo}/releases\">Releases</a>"
  else
    link_line="<a href=\"${homepage}\">Website</a>"
  fi

  APP_NAV="${APP_NAV}<button class=\"rail-btn\" data-app=\"${app_name}\" onclick=\"selectApp('${app_name}')\" aria-label=\"Show ${display} versions\"><span class=\"rail-name\">${display}</span><span class=\"rail-meta\">${LATEST} <em>${TOTAL}</em></span></button>"

  APP_PANELS="${APP_PANELS}
  <section class=\"detail\" id=\"app-${app_name}\" data-app=\"${app_name}\" aria-labelledby=\"title-${app_name}\">
    <div class=\"detail-head\">
      <div>
        <p class=\"eyebrow\">package registry / ${app_name}</p>
        <h2 id=\"title-${app_name}\">${display}<span class=\"latest-inline\">${LATEST}</span></h2>
        <p class=\"detail-desc\">${desc} <span class=\"sep\">/</span> ${link_line}</p>
      </div>
      <div class=\"head-stat\"><strong>${TOTAL}</strong><span>versions indexed</span></div>
    </div>
    <div class=\"install-strip\" aria-label=\"Install commands\">
      <div class=\"icmd\"><span class=\"iprompt\">apt</span><code>apt install ${app_name}</code><button class=\"cp\" data-cmd=\"apt install ${app_name}\" onclick=\"copyCmd(this)\" aria-label=\"Copy apt install command\">copy</button></div>
      <div class=\"icmd\"><span class=\"iprompt\">scoop</span><code>scoop install ${app_name}</code><button class=\"cp\" data-cmd=\"scoop install ${app_name}\" onclick=\"copyCmd(this)\" aria-label=\"Copy scoop install command\">copy</button></div>
      <div class=\"icmd\"><span class=\"iprompt\">brew</span><code>brew install ${app_name}</code><button class=\"cp\" data-cmd=\"brew install ${app_name}\" onclick=\"copyCmd(this)\" aria-label=\"Copy brew install command\">copy</button></div>
    </div>
    <div class=\"panel-tools\">
      <label class=\"vsearch\"><span>Filter this package</span><input type=\"search\" placeholder=\"2.8. or 2025\" oninput=\"filterRows()\" aria-label=\"Filter versions of ${display}\"></label>
      <span class=\"count\" aria-live=\"polite\">${TOTAL} versions</span>
    </div>
    <div class=\"tablewrap\">
      <table>
        <caption class=\"sr-only\">${display} release history with platform installers</caption>
        <thead><tr><th scope=\"col\">Version</th><th scope=\"col\">Released</th><th scope=\"col\">Installers by platform</th><th scope=\"col\">Copy</th><th scope=\"col\">Info</th></tr></thead>
        <tbody id=\"tbody-${app_name}\">${ROWS}</tbody>
      </table>
    </div>
    <p class=\"empty\" hidden>No versions match this filter.</p>
  </section>"
done

# ── HTML ──────────────────────────────────────────────────────────────
cat > docs/index.html <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>packages — release index</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=Space+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#0a1014; --bg-alt:#0d151b; --surface:#111c24; --surface-2:#16232d;
  --line:#22323e; --line-soft:#1a2832;
  --text:#e7eef2; --muted:#9aadb9; --faint:#607785;
  --amber:#ffb454; --cyan:#6ad3c6; --green:#8bd77f; --violet:#b39ddb;
  --mono:'IBM Plex Mono',ui-monospace,SFMono-Regular,monospace;
  --sans:'Space Grotesk',system-ui,sans-serif;
}
*,*::before,*::after{box-sizing:border-box}
html{scroll-behavior:smooth}
body{
  margin:0;background:var(--bg);color:var(--text);font-family:var(--sans);
  font-size:15px;line-height:1.5;
  background-image:linear-gradient(var(--line-soft) 1px,transparent 1px),linear-gradient(90deg,var(--line-soft) 1px,transparent 1px);
  background-size:44px 44px;background-position:-1px -1px;
}
a{color:var(--cyan);text-decoration:none;border-bottom:1px solid transparent}
a:hover,a:focus-visible{border-bottom-color:currentColor}
code,mono{font-family:var(--mono)}
button,input{font:inherit;color:inherit}
button{cursor:pointer}
:focus-visible{outline:2px solid var(--amber);outline-offset:2px}
[hidden]{display:none!important}
.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}

.topbar{border-bottom:1px solid var(--line);background:rgba(10,16,20,.92);position:sticky;top:0;z-index:20;backdrop-filter:blur(12px)}
.topbar-in{max-width:1460px;margin:0 auto;padding:13px 26px;display:flex;align-items:center;gap:18px}
.brand{font-weight:700;font-size:19px;letter-spacing:-.03em;color:var(--text)}
.brand i{font-style:normal;color:var(--amber)}
.topmeta{font-family:var(--mono);font-size:11px;color:var(--muted);display:flex;gap:14px;align-items:center;flex-wrap:wrap}
.topmeta b{color:var(--text);font-weight:500}
.topspacer{flex:1}
.ghost-btn{background:transparent;border:1px solid var(--line);border-radius:4px;padding:6px 11px;font-size:12px;color:var(--muted);transition:border-color .15s,color .15s}
.ghost-btn:hover{border-color:var(--amber);color:var(--amber)}

.intro{max-width:1460px;margin:0 auto;padding:34px 26px 18px;display:grid;grid-template-columns:1fr auto;gap:24px;align-items:end}
.intro h1{font-size:clamp(26px,4vw,42px);line-height:1.05;letter-spacing:-.045em;margin:0;font-weight:700}
.intro h1 span{color:var(--amber)}
.intro p{color:var(--muted);max-width:62ch;margin:10px 0 0;font-size:14px}
.intro .stamp{font-family:var(--mono);font-size:11px;color:var(--faint);text-align:right;line-height:1.7}

.cmdbar{max-width:1460px;margin:0 auto;padding:0 26px 22px;display:flex;gap:12px;flex-wrap:wrap;align-items:center}
.searchbox{display:flex;align-items:center;gap:10px;background:var(--surface);border:1px solid var(--line);border-radius:5px;padding:0 12px;flex:1;min-width:260px;transition:border-color .15s}
.searchbox:focus-within{border-color:var(--amber)}
.searchbox .lead{font-family:var(--mono);color:var(--amber);font-size:14px}
.searchbox input{background:transparent;border:0;outline:0;padding:11px 0;width:100%;font-size:14px}
.searchbox input::placeholder{color:var(--faint)}
.kbd{font-family:var(--mono);font-size:10px;border:1px solid var(--line);border-radius:3px;padding:2px 5px;color:var(--faint)}
.seg{display:flex;border:1px solid var(--line);border-radius:5px;overflow:hidden;background:var(--surface)}
.seg button{border:0;border-right:1px solid var(--line);background:transparent;padding:11px 15px;font-size:12px;color:var(--muted);transition:background .15s,color .15s}
.seg button:last-child{border-right:0}
.seg button:hover{color:var(--text)}
.seg button[aria-pressed="true"]{background:var(--amber);color:#1a1206;font-weight:600}

.shell{max-width:1460px;margin:0 auto;padding:0 26px 80px;display:grid;grid-template-columns:230px minmax(0,1fr);gap:28px;align-items:start}
.rail{position:sticky;top:70px;display:flex;flex-direction:column;gap:4px}
.rail-head{font-family:var(--mono);font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--faint);padding:0 10px 8px}
.rail-btn{display:block;width:100%;text-align:left;background:transparent;border:1px solid transparent;border-left:2px solid transparent;border-radius:0 4px 4px 0;padding:9px 10px;transition:background .15s,border-color .15s}
.rail-btn:hover{background:var(--surface)}
.rail-btn[aria-pressed="true"]{background:var(--surface-2);border-left-color:var(--amber)}
.rail-name{display:block;font-size:13px;font-weight:500}
.rail-meta{display:block;font-family:var(--mono);font-size:10px;color:var(--faint);margin-top:2px}
.rail-meta em{font-style:normal;color:var(--muted)}

.details{display:flex;flex-direction:column;gap:18px;min-width:0}
.detail{background:linear-gradient(180deg,var(--surface) 0%,var(--bg-alt) 120px);border:1px solid var(--line);border-radius:6px;overflow:hidden}
.detail-head{padding:22px 22px 16px;display:flex;gap:20px;justify-content:space-between;align-items:flex-start;border-bottom:1px solid var(--line-soft)}
.eyebrow{font-family:var(--mono);font-size:10px;letter-spacing:.12em;text-transform:uppercase;color:var(--faint);margin:0 0 7px}
.detail h2{font-size:23px;letter-spacing:-.03em;margin:0;display:flex;align-items:baseline;gap:11px;flex-wrap:wrap}
.latest-inline{font-family:var(--mono);font-size:11px;font-weight:500;color:var(--green);border:1px solid #294a35;border-radius:3px;padding:2px 7px;background:#10251a}
.detail-desc{margin:7px 0 0;color:var(--muted);font-size:13px}
.detail-desc .sep{color:var(--line);padding:0 6px}
.head-stat{text-align:right;flex:0 0 auto}
.head-stat strong{display:block;font-family:var(--mono);font-size:25px;color:var(--amber);line-height:1}
.head-stat span{font-family:var(--mono);font-size:9px;color:var(--faint);letter-spacing:.08em;text-transform:uppercase}

.install-strip{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1px;background:var(--line-soft);border-bottom:1px solid var(--line-soft)}
.icmd{background:var(--bg-alt);padding:11px 14px;display:flex;align-items:center;gap:9px;min-width:0}
.iprompt{font-family:var(--mono);font-size:9px;text-transform:uppercase;letter-spacing:.08em;color:var(--amber);min-width:38px}
.icmd code{font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
.cp{background:transparent;border:1px solid var(--line);border-radius:3px;padding:3px 7px;font-family:var(--mono);font-size:10px;color:var(--muted);transition:color .15s,border-color .15s,background .15s}
.cp:hover{color:var(--amber);border-color:var(--amber)}
.cp.done{color:var(--green);border-color:var(--green);background:#10251a}

.panel-tools{padding:12px 20px;display:flex;justify-content:space-between;align-items:center;gap:12px;border-bottom:1px solid var(--line-soft)}
.vsearch{display:flex;align-items:center;gap:10px;color:var(--faint);font-size:11px;font-family:var(--mono)}
.vsearch input{background:var(--bg);border:1px solid var(--line);border-radius:4px;padding:6px 9px;font-family:var(--mono);font-size:11px;width:170px;outline:0}
.vsearch input:focus{border-color:var(--amber)}
.count{font-family:var(--mono);font-size:10px;color:var(--faint)}

.tablewrap{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;font-family:var(--mono);font-size:9px;letter-spacing:.1em;text-transform:uppercase;color:var(--faint);font-weight:500;padding:9px 14px;border-bottom:1px solid var(--line);white-space:nowrap;background:var(--bg-alt);position:sticky;top:56px;z-index:2}
td{padding:8px 14px;border-bottom:1px solid var(--line-soft);vertical-align:top}
tr.vrow:hover td{background:rgba(255,180,84,.035)}
tr.latest td{background:rgba(139,215,127,.045)}
tr.latest:hover td{background:rgba(255,180,84,.06)}
.vcell{white-space:nowrap}
.vnum{font-family:var(--mono);font-size:12px;color:var(--text)}
.badge{font-family:var(--mono);font-size:8px;text-transform:uppercase;letter-spacing:.06em;margin-left:7px;padding:2px 5px;border-radius:2px;background:#16301f;color:var(--green)}
.dcell{font-family:var(--mono);font-size:10px;color:var(--faint);white-space:nowrap}
.icell{min-width:280px}
.grp{display:flex;align-items:center;gap:8px;margin:2px 0}
.oslabel{font-family:var(--mono);font-size:9px;letter-spacing:.06em;color:var(--faint);min-width:46px;text-transform:uppercase}
.chips{display:flex;flex-wrap:wrap;gap:4px}
.chip{font-family:var(--mono);font-size:9px;line-height:1.4;padding:2px 6px;border:1px solid var(--line);border-radius:3px;color:var(--muted);background:var(--bg-alt);white-space:nowrap}
.chip:hover{border-color:var(--cyan);color:var(--cyan)}
.chip.local{border-color:#3a3320;color:var(--amber);background:#1e1a10}
.chip.local:hover{border-color:var(--amber)}
.acell{white-space:nowrap}
.lcell{white-space:nowrap}
.notes{font-family:var(--mono);font-size:10px;color:var(--faint)}
.notes:hover{color:var(--cyan)}
.empty{padding:26px;text-align:center;color:var(--faint);font-family:var(--mono);font-size:12px}

.guide{border:1px solid var(--line);background:var(--surface);border-radius:6px;margin:0 26px 26px;padding:0;max-width:1460px}
.guide>button{width:100%;text-align:left;background:transparent;border:0;padding:14px 18px;font-size:13px;color:var(--muted)}
.guide>button span{font-family:var(--mono);font-size:10px;color:var(--amber);margin-left:8px}
.guide-body{border-top:1px solid var(--line);padding:18px;display:grid;grid-template-columns:repeat(3,1fr);gap:16px}
.guide-body h3{font-family:var(--mono);font-size:10px;text-transform:uppercase;letter-spacing:.1em;color:var(--faint);margin:0 0 7px}
.guide-body pre{margin:0;padding:11px;background:var(--bg);border:1px solid var(--line);border-radius:4px;overflow-x:auto;font-size:10px;line-height:1.65;color:var(--muted)}

footer{max-width:1460px;margin:0 auto;padding:22px 26px 50px;border-top:1px solid var(--line-soft);font-family:var(--mono);font-size:10px;color:var(--faint);display:flex;justify-content:space-between;gap:14px;flex-wrap:wrap}

@media(max-width:1000px){
  .shell{grid-template-columns:1fr}
  .rail{position:static;flex-direction:row;flex-wrap:wrap}
  .rail-head{width:100%}
  .rail-btn{width:auto;border-left:0;border-bottom:2px solid transparent;border-radius:4px 4px 0 0}
  .rail-btn[aria-pressed="true"]{border-left:0;border-bottom-color:var(--amber)}
  .install-strip{grid-template-columns:1fr}
  .guide-body{grid-template-columns:1fr}
  .intro{grid-template-columns:1fr}
  .intro .stamp{text-align:left}
}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}
</style>
</head>
<body>
<header class="topbar">
  <div class="topbar-in">
    <div class="brand">packages<i>/</i></div>
    <div class="topmeta">
      <span><b>${APP_COUNT}</b> packages</span>
      <span><b>${TOTAL_VERSIONS}</b> releases indexed</span>
      <span>updated <b>${UPDATED}</b></span>
    </div>
    <div class="topspacer"></div>
    <button class="ghost-btn" onclick="toggleGuide()" aria-expanded="false" aria-controls="guide">Setup guide</button>
    <a class="ghost-btn" href="${GH_URL}" rel="noopener">Source</a>
  </div>
</header>

<div class="intro">
  <div>
    <h1>Every release,<br><span>one index.</span></h1>
    <p>Versioned installers for desktop tools across Linux, Windows and macOS. Pick a package, find a version, copy the command. The files are mirrored here or linked straight to upstream.</p>
  </div>
  <div class="stamp">APT · SCOOP · BREW<br>DEB · EXE · MSI · DMG</div>
</div>

<div class="cmdbar">
  <label class="searchbox">
    <span class="lead">/</span>
    <input id="q" type="search" placeholder="Search versions, dates, platforms…" oninput="applyFilters()" aria-label="Search all packages">
    <span class="kbd">/</span>
  </label>
  <div class="seg" role="group" aria-label="Filter installers by platform">
    <button aria-pressed="true" onclick="setPlatform('all')">All</button>
    <button aria-pressed="false" onclick="setPlatform('linux')">Linux</button>
    <button aria-pressed="false" onclick="setPlatform('win')">Windows</button>
    <button aria-pressed="false" onclick="setPlatform('mac')">macOS</button>
  </div>
</div>

<div class="shell">
  <aside class="rail" aria-label="Packages">
    <p class="rail-head">Packages</p>
    <button class="rail-btn" data-app="all" aria-pressed="true" onclick="selectApp('all')"><span class="rail-name">All packages</span><span class="rail-meta">combined index</span></button>
    ${APP_NAV}
  </aside>
  <main class="details" id="details">${APP_PANELS}</main>
</div>

<section class="guide" id="guide" hidden>
  <button onclick="toggleGuide()" aria-expanded="true">Setup commands <span>Linux · Windows · macOS</span></button>
  <div class="guide-body">
    <div><h3>Debian / Ubuntu</h3><pre>curl -fsSL ${URL}/apt-repo.gpg | sudo gpg --dearmor -o /usr/share/keyrings/packages.gpg
echo "deb [signed-by=/usr/share/keyrings/packages.gpg] ${URL} stable main" | sudo tee /etc/apt/sources.list.d/packages.list
sudo apt update &amp;&amp; sudo apt install &lt;package&gt;</pre></div>
    <div><h3>Windows</h3><pre>scoop bucket add personal ${GH_URL}
scoop install &lt;package&gt;</pre></div>
    <div><h3>macOS / Linux</h3><pre>brew tap babico/packages
brew install &lt;package&gt;</pre></div>
  </div>
</section>

<footer>
  <span>Unofficial mirror — upstream projects keep their own licenses.</span>
  <span><a href="${GH_URL}">Repository</a> · generated ${UPDATED}</span>
</footer>

<script>
var platform='all', currentApp='all';
function selectApp(name){
  currentApp=name;
  var btns=document.querySelectorAll('.rail-btn');
  for(var i=0;i<btns.length;i++) btns[i].setAttribute('aria-pressed', btns[i].getAttribute('data-app')===name?'true':'false');
  var panels=document.querySelectorAll('.detail');
  for(var j=0;j<panels.length;j++) panels[j].hidden = name!=='all' && panels[j].getAttribute('data-app')!==name;
  applyFilters();
}
function setPlatform(os){
  platform=os;
  var segs=document.querySelectorAll('.seg button');
  var names=['all','linux','win','mac'];
  for(var i=0;i<segs.length;i++) segs[i].setAttribute('aria-pressed', names[i]===os?'true':'false');
  var groups=document.querySelectorAll('.grp');
  for(var j=0;j<groups.length;j++) groups[j].hidden = os!=='all' && groups[j].getAttribute('data-os')!==os;
  applyFilters();
}
function applyFilters(){
  var q=(document.getElementById('q').value||'').toLowerCase().trim();
  var rows=document.querySelectorAll('.vrow'), shown=0;
  for(var i=0;i<rows.length;i++){
    var r=rows[i];
    var hasPlatform = platform==='all' || (' '+r.getAttribute('data-has')+' ').indexOf(' '+platform+' ')!==-1;
    var matches = !q || r.textContent.toLowerCase().indexOf(q)!==-1;
    r.hidden = !(hasPlatform && matches);
    if(!r.hidden) shown++;
  }
  var panels=document.querySelectorAll('.detail');
  for(var k=0;k<panels.length;k++){
    var visible=0, trs=panels[k].querySelectorAll('.vrow');
    for(var m=0;m<trs.length;m++) if(!trs[m].hidden) visible++;
    panels[k].hidden = (currentApp!=='all' && panels[k].getAttribute('data-app')!==currentApp) || visible===0;
    var count=panels[k].querySelector('.count');
    if(count) count.textContent=visible+' shown';
    var empty=panels[k].querySelector('.empty');
    if(empty) empty.hidden=visible!==0;
  }
}
function copyCmd(btn){
  var text=btn.getAttribute('data-cmd');
  function done(){ btn.classList.add('done'); var old=btn.textContent; btn.textContent='copied'; setTimeout(function(){btn.textContent=old;btn.classList.remove('done')},1400); }
  if(navigator.clipboard && navigator.clipboard.writeText){ navigator.clipboard.writeText(text).then(done,done); }
  else { var ta=document.createElement('textarea'); ta.value=text; document.body.appendChild(ta); ta.select(); try{document.execCommand('copy')}catch(e){} document.body.removeChild(ta); done(); }
}
function toggleGuide(){
  var g=document.getElementById('guide'), open=g.hidden;
  g.hidden=!open;
  var b=document.querySelector('.topbar .ghost-btn');
  if(b) b.setAttribute('aria-expanded', open?'true':'false');
}
document.addEventListener('keydown',function(e){
  if(e.key==='/' && document.activeElement.tagName!=='INPUT'){ e.preventDefault(); document.getElementById('q').focus(); }
  if(e.key==='Escape'){ document.getElementById('q').value=''; applyFilters(); if(document.activeElement) document.activeElement.blur(); }
});
applyFilters();
</script>
</body>
</html>
HTMLEOF

echo "==> docs/index.html written (${APP_COUNT} apps, ${TOTAL_VERSIONS} versions)"
