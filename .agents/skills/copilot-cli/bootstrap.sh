#!/usr/bin/env bash
# Shared bootstrap for /copilot-cli, /copilot-acp, /copilot-sdk.
# Installs `copilot` (if missing) via the official tarball installer and
# reports version + auth.
#
# The auth check probes the credential instead of testing whether some
# variable is non-empty. A hosted agent sandbox always sets GH_TOKEN to its
# own repo-scoped session credential, which carries no Copilot entitlement:
# a presence test calls that "ok" and the run then dies with a 403 deep
# inside Copilot's own startup validation, far from where it is cheap to
# read. So we make the same call Copilot makes at startup — fetch the
# authenticated user from the GitHub API — and report the actual state.
#
# What that probe can and cannot settle: it reliably rejects the credential the
# sandbox supplies (401 for junk, 403 for a GitHub App installation token), which
# is the failure this exists to catch. It cannot confirm the "Copilot Requests"
# permission, because no endpoint reports it, so "ready" means "no known blocker"
# and not "proven entitled". Say so rather than repeating the original sin one
# level down.
#
# Exactly one of these lines is printed, machine-greppable prefix first:
#   copilot auth: ready
#   copilot auth: missing-tool                      (rc 2)
#   copilot auth: missing-credential                (rc 3)
#   copilot auth: credential-present-but-unusable   (rc 4)
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

# Resolve the credential Copilot would actually use, mirroring run.sh's
# precedence. Sets _copilot_token / _copilot_token_src in the caller's scope.
copilot_resolve_token() {
  _copilot_token=""
  _copilot_token_src=""
  local token_file=""

  if [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
    _copilot_token="$COPILOT_GITHUB_TOKEN"
    _copilot_token_src="COPILOT_GITHUB_TOKEN"
  elif [ -n "${GH_TOKEN:-}" ]; then
    _copilot_token="$GH_TOKEN"
    _copilot_token_src="GH_TOKEN"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    _copilot_token="$GITHUB_TOKEN"
    _copilot_token_src="GITHUB_TOKEN"
  else
    token_file="${COPILOT_TOKEN_FILE:-$HOME/.config/copilot-token}"
    if [ -r "$token_file" ]; then
      _copilot_token="$(tr -d '\r\n' < "$token_file" 2>/dev/null)"
      [ -n "$_copilot_token" ] && _copilot_token_src="token file $token_file"
    fi
  fi

  [ -n "$_copilot_token" ]
}

# Make the same call Copilot makes when it validates a token at startup:
# fetch the authenticated user. This is the discriminator — a fine-grained PAT
# carrying "Copilot Requests" answers 200, a repo-scoped sandbox session token
# answers 401/403. Echoes the HTTP status ("000" if the request never
# completed, "no-curl" if we cannot probe at all) and returns 0 only on 2xx,
# so no-network fails closed rather than claiming readiness.
copilot_probe_token() {
  local token="$1" code=""

  if ! command -v curl >/dev/null 2>&1; then
    echo "no-curl"
    return 1
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: copilot-cli-bootstrap" \
    https://api.github.com/user 2>/dev/null)" || code=""
  [ -n "$code" ] || code="000"

  echo "$code"
  case "$code" in
    2??) return 0 ;;
    *)   return 1 ;;
  esac
}

# Print exactly one of the four auth states, with a non-zero rc for anything
# that is not "ready".
copilot_auth_state() {
  local _copilot_token="" _copilot_token_src="" code=""

  if ! copilot_resolve_token; then
    echo "copilot auth: missing-credential — no token in COPILOT_GITHUB_TOKEN, GH_TOKEN or GITHUB_TOKEN, and no readable ${COPILOT_TOKEN_FILE:-$HOME/.config/copilot-token}."
    echo "  fix: export COPILOT_GITHUB_TOKEN=<fine-grained PAT with the \"Copilot Requests\" permission>"
    echo "  (preferred over GH_TOKEN: gh ignores it, so a Copilot-only token here cannot widen gh's access)"
    if [ -d "$HOME/.copilot" ]; then
      echo "  note: ~/.copilot exists, so a prior \`copilot login\` may still work, but this preflight cannot verify it."
    fi
    return 3
  fi

  code="$(copilot_probe_token "$_copilot_token")"
  if [ "$code" = "000" ] || [ "$code" = "no-curl" ]; then
    echo "copilot auth: credential-present-but-unusable — token from $_copilot_token_src could not be verified (probe of https://api.github.com/user did not complete: $code)."
    echo "  the preflight fails closed rather than claim an unverified readiness; re-run with network access."
    return 4
  fi

  case "$code" in
    2??)
      echo "copilot auth: ready — token from $_copilot_token_src accepted by https://api.github.com/user (HTTP $code)."
      echo "  scope of that claim: the credential is a valid GitHub token that is not the"
      echo "  repo-scoped sandbox kind. It is NOT proof that it carries \"Copilot Requests\";"
      echo "  GitHub exposes no cheap probe for that, so a token can reach here and still 403"
      echo "  inside Copilot, which means exactly that permission is missing."
      return 0
      ;;
    *)
      echo "copilot auth: credential-present-but-unusable — token from $_copilot_token_src was rejected by https://api.github.com/user (HTTP $code)."
      echo "  this is the hosted-sandbox trap: GH_TOKEN is always set there, but it is the session's own"
      echo "  repo-scoped credential and carries no Copilot entitlement, so Copilot itself 403s at startup."
      echo "  fix: export COPILOT_GITHUB_TOKEN=<fine-grained PAT with the \"Copilot Requests\" permission>"
      echo "  (or write it to ${COPILOT_TOKEN_FILE:-$HOME/.config/copilot-token}, which run.sh reads)"
      return 4
      ;;
  esac
}

bootstrap_copilot() {
  if ! command -v copilot >/dev/null 2>&1; then
    echo "copilot: NOT INSTALLED — auto-installing..."
    if install_copilot; then
      hash -r 2>/dev/null || true
      if command -v copilot >/dev/null 2>&1; then
        echo "copilot: installed ($(command -v copilot))"
      else
        echo "copilot: install ran but binary still not on PATH"
        echo "copilot auth: missing-tool — installer finished but \`copilot\` is not on PATH."
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        return 2
      fi
    else
      echo "copilot auth: missing-tool — install failed; nothing to authenticate."
      return 2
    fi
  else
    echo "copilot: installed ($(command -v copilot))"
  fi

  if copilot --version >/dev/null 2>&1; then
    echo "copilot version: $(copilot --version 2>&1 | head -1)"
  else
    echo "copilot auth: missing-tool — \`copilot --version\` failed; the binary is unusable (stale or wrong arch)."
    echo "  reinstall: curl -fsSL https://gh.io/copilot-install | bash"
    return 2
  fi

  copilot_auth_state
}

# When executed (not sourced) run the bootstrap end-to-end.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  bootstrap_copilot
fi
