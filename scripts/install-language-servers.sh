#!/bin/zsh
# Installs the language servers Vet uses for code navigation into
# ~/Library/Application Support/Vet/servers:
#   node/        typescript-language-server, typescript 6 and pyright (from npm). TypeScript 7 is
#                the native Go compiler and ships no tsserver.js, which typescript-language-server
#                needs, so the fallback TypeScript stays on 6 (projects' own TypeScript wins anyway).
#   kotlin-lsp/  JetBrains kotlin-lsp, the macOS aarch64 standalone build of the latest
#                GitHub release (github.com/Kotlin/kotlin-lsp). That release has no attached
#                assets; its notes link the archive and its SHA-256 on download.jetbrains.com,
#                and the checksum is verified before unpacking. The archive bundles its own Java
#                runtime (JBR 25, which kotlin-lsp requires); if a build ever comes without one,
#                WebStorm's runtime is linked in its place.
# Safe to run again: npm reuses what's there, and kotlin-lsp is skipped when the latest
# release is already installed.
set -euo pipefail

DEST="$HOME/Library/Application Support/Vet/servers"
JBR=/Applications/WebStorm.app/Contents/jbr/Contents/Home
mkdir -p "$DEST"
summary=()

# MARK: node servers

# Node comes from the user's login shell (nvm sets it up in .zshrc), the way Vet resolves it.
resolve_node() {
  local line
  line=$(/bin/zsh -ilc 'printf "\n__VET_NODE__%s\n" "$(command -v node)"' </dev/null 2>/dev/null | grep '^__VET_NODE__' | tail -n 1) || true
  local node=${line#__VET_NODE__}
  if [[ -n "$node" && -x "$node" ]]; then print -r -- "$node"; return; fi
  # Fallback: nvm's default alias, then the newest installed nvm node.
  local nvm="${NVM_DIR:-$HOME/.nvm}"
  if [[ -r "$nvm/alias/default" ]]; then
    local v; v=$(<"$nvm/alias/default")
    local candidate=("$nvm"/versions/node/v${v#v}*/bin/node(N))
    (( ${#candidate} )) && [[ -x "${candidate[-1]}" ]] && { print -r -- "${candidate[-1]}"; return; }
  fi
  local all=("$nvm"/versions/node/*/bin/node(Nn))
  (( ${#all} )) && { print -r -- "${all[-1]}"; return; }
  command -v node || true
}

NODE=$(resolve_node)
if [[ -z "$NODE" || ! -x "$NODE" ]]; then
  echo "error: node not found in the login shell (nvm?); TypeScript and Python navigation need it" >&2
  summary+=("node servers: NOT installed (no node)")
else
  NODE_DIR=${NODE:h}
  echo "==> node $("$NODE" --version) at $NODE"
  mkdir -p "$DEST/node"
  # npm's own shebang is `env node`, so the resolved node goes first on PATH.
  PATH="$NODE_DIR:$PATH" "$NODE_DIR/npm" install --prefix "$DEST/node" --no-fund --no-audit --loglevel=error \
    typescript-language-server typescript@6 pyright
  for pkg in typescript-language-server typescript pyright; do
    v=$("$NODE" -p "require(process.argv[1]).version" "$DEST/node/node_modules/$pkg/package.json")
    summary+=("$pkg $v")
  done
fi

# MARK: kotlin-lsp

install_kotlin() {
  local api=https://api.github.com/repos/Kotlin/kotlin-lsp/releases/latest
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/vet-kotlin-lsp.XXXXXX")
  trap "rm -rf '$tmp'" EXIT
  curl -fsSL -H "Accept: application/vnd.github+json" "$api" -o "$tmp/release.json"
  local tag; tag=$(plutil -extract tag_name raw -o - "$tmp/release.json")
  local body; body=$(plutil -extract body raw -o - "$tmp/release.json")
  # The standalone macOS arm64 archive, not the VS Code .vsix.
  local url; url=$(print -r -- "$body" | grep -oE 'https://download\.jetbrains\.com/[^) ]*/kotlin-server-[0-9.]+-aarch64\.sit' | head -n 1) || true
  if [[ -z "$url" ]]; then
    echo "error: no macOS aarch64 standalone archive linked from kotlin-lsp release $tag" >&2
    summary+=("kotlin-lsp: NOT installed (no macOS aarch64 archive in $tag)")
    return
  fi
  local version=${${url:t}#kotlin-server-}; version=${version%-aarch64.sit}
  local dir="$DEST/kotlin-lsp"
  if [[ -x "$dir/$version/kotlin-lsp.sh" && "$(readlink "$dir/current" 2>/dev/null)" == "$version" ]]; then
    echo "==> kotlin-lsp $version already installed"
  else
    echo "==> downloading kotlin-lsp $version ($tag) from $url"
    curl -fL --progress-bar "$url" -o "$tmp/kotlin-lsp.sit"
    local expected; expected=$(curl -fsSL "$url.sha256" | awk '{print $1}')
    local actual; actual=$(shasum -a 256 "$tmp/kotlin-lsp.sit" | awk '{print $1}')
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
      echo "error: kotlin-lsp checksum mismatch (expected '$expected', got '$actual')" >&2
      summary+=("kotlin-lsp: NOT installed (checksum mismatch)")
      return
    fi
    rm -rf "$tmp/unpacked"; mkdir -p "$tmp/unpacked"
    ditto -x -k "$tmp/kotlin-lsp.sit" "$tmp/unpacked"
    # The archive holds kotlin-lsp.sh either at its top or inside one folder.
    local script; script=$(find "$tmp/unpacked" -maxdepth 2 -name kotlin-lsp.sh -type f | head -n 1)
    if [[ -z "$script" ]]; then
      echo "error: kotlin-lsp.sh not found in the archive" >&2
      summary+=("kotlin-lsp: NOT installed (unexpected archive layout)")
      return
    fi
    mkdir -p "$dir"
    rm -rf "$dir/$version"
    mv "${script:h}" "$dir/$version"
    chmod +x "$dir/$version/kotlin-lsp.sh"
    ln -sfn "$version" "$dir/current"
    # Older versions are ~700 MB each.
    for old in "$dir"/*(N/); do
      [[ "${old:t}" == "$version" || "${old:t}" == current ]] || rm -rf "$old"
    done
  fi
  summary+=("kotlin-lsp $version ($dir/current)")
}
install_kotlin

# kotlin-lsp's launcher (bin/intellij-server) runs the runtime in its own jbr/ folder.
KOTLIN="$DEST/kotlin-lsp/current"
if [[ -d "$KOTLIN" ]]; then
  if [[ ! -x "$KOTLIN/jbr/Contents/Home/bin/java" ]]; then
    if [[ -x "$JBR/bin/java" ]]; then
      rm -rf "$KOTLIN/jbr"
      ln -s "${JBR:h:h}" "$KOTLIN/jbr"
      echo "==> kotlin-lsp has no bundled runtime; linked WebStorm's ($JBR)"
    else
      echo "warning: kotlin-lsp has no bundled runtime and WebStorm's is missing at $JBR; Kotlin navigation won't start" >&2
    fi
  fi
  if [[ -x "$KOTLIN/jbr/Contents/Home/bin/java" ]]; then
    summary+=("java for kotlin-lsp: $("$KOTLIN/jbr/Contents/Home/bin/java" -version 2>&1 | head -n 1) ($(readlink "$KOTLIN/jbr" || echo bundled))")
  else
    summary+=("java for kotlin-lsp: MISSING")
  fi
fi

echo
echo "Installed in $DEST:"
for line in "${summary[@]}"; do echo "  $line"; done
