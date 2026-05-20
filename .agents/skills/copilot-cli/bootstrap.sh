#!/usr/bin/env bash
# Shared bootstrap for /copilot-cli, /copilot-acp, /copilot-sdk.
# Installs `copilot` (if missing) via the official tarball installer and
# reports version + auth. Auth is normally via GH_TOKEN (pre-set), so no
# `copilot login` flow is needed.
#
# Usage:
#   bootstrap.sh        # run all checks
#   source bootstrap.sh # expose install_copilot / bootstrap_copilot as functions

install_copilot() {
  local fetcher=""
  if command -v curl >/dev/null 2>&1; then
    fetcher="curl -fsSL"
  elif command -v wget >/dev/null 2>&1; then
    fetcher="wget -qO-"
  else
    echo "error: neither curl nor wget available; cannot run installer."
    return 1
  fi

  echo "installing copilot via https://gh.io/copilot-install ..."
  if ! $fetcher https://gh.io/copilot-install | bash; then
    echo "installer exited non-zero"
    return 1
  fi

  if [ -x "$HOME/.local/bin/copilot" ]; then
    export PATH="$HOME/.local/bin:$PATH"
    if ! grep -qs '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
      printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
    fi
  fi
}

bootstrap_copilot() {
  local missing=0

  if ! command -v copilot >/dev/null 2>&1; then
    echo "copilot: NOT INSTALLED — auto-installing..."
    if install_copilot; then
      hash -r 2>/dev/null || true
      if command -v copilot >/dev/null 2>&1; then
        echo "copilot: installed ($(command -v copilot))"
      else
        echo "copilot: install ran but binary still not on PATH"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        return 1
      fi
    else
      echo "copilot: install failed"
      return 1
    fi
  else
    echo "copilot: installed ($(command -v copilot))"
  fi

  if copilot --version >/dev/null 2>&1; then
    echo "copilot version: $(copilot --version 2>&1 | head -1)"
  else
    echo "copilot --version failed; binary may be stale"
    missing=1
  fi

  if [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
    echo "copilot auth: ok (COPILOT_GITHUB_TOKEN set)"
  elif [ -n "${GH_TOKEN:-}" ]; then
    echo "copilot auth: ok (GH_TOKEN set)"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "copilot auth: ok (GITHUB_TOKEN set)"
  elif [ -d "$HOME/.copilot" ]; then
    echo "copilot auth: ok (stored credentials at ~/.copilot)"
  else
    echo "copilot auth: NOT CONFIGURED"
    echo "  set GH_TOKEN in the env, or run: copilot login"
    missing=1
  fi

  return $missing
}

# When executed (not sourced) run the bootstrap end-to-end.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  bootstrap_copilot
fi
