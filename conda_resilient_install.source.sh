# conda_resilient_install: install one or more packages into the *current* conda env,
# retrying on failure with exponential backoff and jitter.
#
# Usage:
#   conda_resilient_install <pkg> [pkg2 pkg3 ...]
#
# Environment variables (all optional):
#   CONDA_RETRY_DELAY       Initial delay between retries in seconds (default: 10)
#   CONDA_RETRY_MAX         Max attempts (0 = try forever; default: 0)
#   CONDA_RETRY_BACKOFF     Backoff multiplier (default: 1.5)
#   CONDA_RETRY_MAX_DELAY   Max delay cap in seconds (default: 120)
#   CONDA_RETRY_JITTER      Jitter fraction in [0,1] for +/- jitter (default: 0.2)
#   CONDA_RETRY_QUIET       If "1", pass --quiet to installer (default: 1)
#   CONDA_INSTALLER         "conda", "mamba", or "auto" (prefer mamba if found; default: conda)
#
# Notes:
#   - Respects your existing conda config/channels (no channel flags added).
#   - Logs attempts with timestamps; shows the active env for sanity.
#   - Exits immediately on success; otherwise retries until limits are hit.
conda_resilient_install() {
  # No args? be kind and explain.
  if [[ $# -eq 0 ]]; then
    echo "Usage: conda_resilient_install <pkg> [pkg2 pkg3 ...]" >&2
    echo "Installs into the CURRENT active conda env, retrying on failure." >&2
    return 1
  fi

  # Config (with sane defaults)
  local delay="${CONDA_RETRY_DELAY:-10}"
  local max_attempts="${CONDA_RETRY_MAX:-0}"            # 0 => infinite
  local backoff="${CONDA_RETRY_BACKOFF:-1.5}"
  local max_delay="${CONDA_RETRY_MAX_DELAY:-120}"
  local jitter="${CONDA_RETRY_JITTER:-0.2}"
  local quiet="${CONDA_RETRY_QUIET:-1}"
  local installer="${CONDA_INSTALLER:-conda}"           # conda|mamba|auto

  # Choose installer
  if [[ "$installer" == "auto" ]]; then
    if command -v mamba >/dev/null 2>&1; then
      installer="mamba"
    else
      installer="conda"
    fi
  fi
  if ! command -v "$installer" >/dev/null 2>&1; then
    echo "conda_resilient_install: '$installer' not found in PATH" >&2
    return 127
  fi

  # Active env name (prefer env vars, avoid parsing JSON unless needed)
  local env_name="${CONDA_DEFAULT_ENV:-}"
  if [[ -z "$env_name" && -n "${CONDA_PREFIX:-}" ]]; then
    env_name="${CONDA_PREFIX##*/}"
  fi
  [[ -z "$env_name" ]] && env_name="(base or unknown)"

  local attempt=1
  while :; do
    printf '[%s] %s install attempt %d%s into env "%s": %q' \
      "$(date -Is)" "$installer" "$attempt" \
      "$([[ $max_attempts -ne 0 ]] && printf '/%s' "$max_attempts")" \
      "$env_name" "$1" >&2
    # If more than one arg, show the rest compactly:
    if (( $# > 1 )); then
      printf ' ...\n' >&2
    else
      printf '\n' >&2
    fi

    # Build args (quiet by default)
    local -a args=(install --yes)
    [[ "$quiet" == "1" ]] && args+=(--quiet)
    if "$installer" "${args[@]}" "$@"; then
      echo "conda_resilient_install: success after ${attempt} attempt(s) ✨" >&2
      return 0
    fi

    local exit_code=$?
    echo "conda_resilient_install: install failed for [$*] (exit $exit_code)" >&2

    # Exceeded attempts?
    if [[ "$max_attempts" -ne 0 && "$attempt" -ge "$max_attempts" ]]; then
      echo "conda_resilient_install: giving up after ${attempt} attempts 😵" >&2
      return "$exit_code"
    fi

    # Compute sleep with +/- jitter
    # jittered = delay * (1 + u), where u ∈ [-jitter, +jitter]
    local sleep_for
    sleep_for="$(awk -v s="$delay" -v j="$jitter" -v r="$RANDOM" 'BEGIN{
      u = (r/32767.0)*2*j - j; d = s*(1+u); if (d < 0.1) d = 0.1; printf "%.3f", d
    }')"
    echo "Retrying in ${sleep_for}s..." >&2
    sleep "$sleep_for"

    # Next backoff step (cap at max_delay)
    delay="$(awk -v d="$delay" -v b="$backoff" -v m="$max_delay" 'BEGIN{
      x = d*b; if (x > m) x = m; printf "%.3f", x
    }')"

    attempt=$((attempt + 1))
  done
}

