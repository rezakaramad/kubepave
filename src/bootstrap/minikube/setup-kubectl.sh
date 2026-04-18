#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"


# ----------------------------------------------------------------------------
# Install kubectl plugins
# ----------------------------------------------------------------------------
install_kubectl_plugins() {
  local github_repo="${GITHUB_REPO:-rezakaramad/kubepave}"
  local release_ref="${KUBECTL_PLUGIN_RELEASE_REF:-latest}"

  local os arch
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$arch" in
    x86_64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo "❌ Unsupported architecture: $arch"
      return 1
      ;;
  esac

  if [[ ! -d "$KUBECTL_PLUGIN_DIR" ]]; then
    echo "❌ Plugin source directory not found: $KUBECTL_PLUGIN_DIR"
    return 1
  fi

  echo "🚀 Installing kubectl plugins from GitHub Releases"
  echo "🔎 Repo: $github_repo"
  echo "🖥️  Platform: $os/$arch"

  # ------------------------------------------------------------
  # Resolve version (avoid flaky /latest redirects)
  # ------------------------------------------------------------
  local version
  if [[ "$release_ref" == "latest" ]]; then
    echo "🔎 Resolving latest release version..."
    version="$(curl -fsSL "https://api.github.com/repos/${github_repo}/releases/latest" | jq -r .tag_name)"

    if [[ -z "$version" || "$version" == "null" ]]; then
      echo "❌ Failed to resolve latest release version"
      return 1
    fi
  else
    version="$release_ref"
  fi

  echo "📌 Using release: $version"

  local found_any=0

  for dir in "$KUBECTL_PLUGIN_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "$dir/go.mod" ]] || continue

    found_any=1

    local name binary asset url tmp installed_path
    name="$(basename "$dir")"
    binary="kubectl-$name"
    asset="${binary}-${os}-${arch}"
    url="https://github.com/${github_repo}/releases/download/${version}/${asset}"

    tmp="$(mktemp)"

    echo ""
    echo "⬇️  Processing plugin: $name"
    echo "   Asset: $asset"
    echo "   URL:   $url"

    # ------------------------------------------------------------
    # Download with retry
    # ------------------------------------------------------------
    if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
      echo "⚠️  Skipping $name (asset not found in release)"
      rm -f "$tmp"
      continue
    fi

    # ------------------------------------------------------------
    # Validate download (protect against "Not Found")
    # ------------------------------------------------------------
    if [[ ! -s "$tmp" ]]; then
      echo "❌ Downloaded file is empty"
      rm -f "$tmp"
      continue
    fi

    if ! file "$tmp" | grep -qi 'executable'; then
      echo "❌ Downloaded file is not a valid binary (likely 404 page)"
      rm -f "$tmp"
      continue
    fi

    chmod 0755 "$tmp"

    installed_path="$(command -v "$binary" 2>/dev/null || true)"

    if [[ -n "$installed_path" ]] && cmp -s "$tmp" "$installed_path"; then
      echo "✅ $binary is already up to date at $installed_path"
      rm -f "$tmp"
      continue
    fi

    echo "📦 Installing $binary → /usr/local/bin/$binary"
    sudo install -m 0755 "$tmp" "/usr/local/bin/$binary"

    echo "✅ Installed kubectl $name"

    rm -f "$tmp"
  done

  if [[ "$found_any" -eq 0 ]]; then
    echo "⚠️  No plugin directories found under $KUBECTL_PLUGIN_DIR"
    return 0
  fi

  echo ""
  echo "🎉 All kubectl plugins processed."
  echo "🔍 Available plugins:"
  kubectl plugin list || true
}


# ----------------------------------------------------------------------------
# Install shell completion for kubectl plugins
# ----------------------------------------------------------------------------
install_plugin_completion() {
  set -euo pipefail

  if [[ ! -d "$KUBECTL_PLUGIN_DIR" ]]; then
    echo "⚠️  Plugin directory not found: $KUBECTL_PLUGIN_DIR"
    return 0
  fi

  # Detect current shell
  local shell
  shell="$(ps -p $$ -o comm=)"

  echo "🔎 Detected shell: $shell"

  for dir in "$KUBECTL_PLUGIN_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "$dir/go.mod" ]] || continue

    local name binary
    name="$(basename "$dir")"
    binary="kubectl-$name"

    echo ""
    echo "⚙️  Setting up completion for $binary"

    case "$shell" in
      fish)
        local fish_dir="$HOME/.config/fish/completions"
        local completion_file="$fish_dir/${binary}.fish"

        mkdir -p "$fish_dir"

        tmp_file="$(mktemp)"

        if kubectl "$name" completion fish > "$tmp_file" 2>/dev/null; then
          if [[ -f "$completion_file" ]] && cmp -s "$tmp_file" "$completion_file"; then
            echo "✅ Fish completion already up-to-date"
            rm -f "$tmp_file"
          else
            mv "$tmp_file" "$completion_file"
            echo "🐟 Installed Fish completion → $completion_file"
          fi
        else
          echo "⚠️  Failed to generate Fish completion for $binary"
          rm -f "$tmp_file"
        fi
        ;;

      zsh)
        local zsh_dir="${ZSH_COMPLETION_DIR:-$HOME/.zsh/completions}"
        local completion_file="$zsh_dir/_${binary}"

        mkdir -p "$zsh_dir"

        tmp_file="$(mktemp)"

        if kubectl "$name" completion zsh > "$tmp_file" 2>/dev/null; then
          if [[ -f "$completion_file" ]] && cmp -s "$tmp_file" "$completion_file"; then
            echo "✅ Zsh completion already up-to-date"
            rm -f "$tmp_file"
          else
            mv "$tmp_file" "$completion_file"
            echo "🐚 Installed Zsh completion → $completion_file"
          fi
        else
          echo "⚠️  Failed to generate Zsh completion for $binary"
          rm -f "$tmp_file"
        fi
        ;;

      bash)
        local completion_file="$HOME/.${binary}-completion.sh"

        tmp_file="$(mktemp)"

        if kubectl "$name" completion bash > "$tmp_file" 2>/dev/null; then
          if [[ -f "$completion_file" ]] && cmp -s "$tmp_file" "$completion_file"; then
            echo "✅ Bash completion already up-to-date"
            rm -f "$tmp_file"
          else
            mv "$tmp_file" "$completion_file"
            echo "🐚 Installed Bash completion → $completion_file"
            echo "💡 Add to ~/.bashrc:"
            echo "   source $completion_file"
          fi
        else
          echo "⚠️  Failed to generate Bash completion for $binary"
          rm -f "$tmp_file"
        fi
        ;;

      *)
        echo "⚠️  Unknown shell ($shell), skipping completion for $binary"
        ;;
    esac
  done

  echo ""
  echo "🎉 Completion setup complete"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  install_kubectl_plugins
  install_plugin_completion

  echo "✅ Kubectl plugin setup complete!"
}

main "$@"
