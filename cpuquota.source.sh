# cpuquota: run a command with a CPU cap via systemd (cgroups v2)
# Default: PERCENT is of the *entire machine* (cores * 100).
#
# Usage:
#   cpuquota [-c] [-b] [-n UNIT] [-P PERIOD] PERCENT COMMAND...
#
# Options:
#   -c        interpret PERCENT as % of a single CPU (per-core semantics)
#   -b        run as a transient background *service* (not an interactive scope)
#   -n UNIT   unit name (auto-generated if -b and omitted)
#   -P PERIOD set CPUQuotaPeriodSec (e.g., 500ms, 1s) to smooth bursts
#
# Quick examples:
#   cpuquota 50 make -j8
#       # 50% of the whole machine
#   cpuquota -c 70 ffmpeg -i in -c:v libx264 out.mp4
#       # 70% of one CPU
#   cpuquota -b -n nightly-build 35 bash build.sh
#       # background service at 35% of the whole machine
#   cpuquota -P 1s 25 ./cpu-hungry-test
#       # smoother throttling with a 1s quota period
#
# Notes:
#   • Tries the user manager first, then falls back to the system manager (with sudo).
#   • Inspect with: systemd-cgtop  |  systemctl status <UNIT>
cpuquota() {
  command -v systemd-run >/dev/null 2>&1 || { echo "cpuquota: systemd-run not found"; return 127; }

  local per_cpu=0 background=0 unit="" period=""
  while getopts ":cbn:P:h" opt; do
    case "$opt" in
      c) per_cpu=1 ;;
      b) background=1 ;;
      n) unit="$OPTARG" ;;
      P) period="$OPTARG" ;;
      h)
        cat <<'USAGE'
Usage: cpuquota [-c] [-b] [-n UNIT] [-P PERIOD] PERCENT COMMAND...
  -c        interpret PERCENT as % of a single CPU (per-core)
  -b        run as background service (not an interactive scope)
  -n UNIT   unit name (auto if -b and omitted)
  -P PERIOD CPUQuotaPeriodSec (e.g., 500ms, 1s)
USAGE
        return 0
        ;;
      \?) echo "cpuquota: invalid option -- '$OPTARG'" >&2; return 2 ;;
    esac
  done
  shift $((OPTIND-1))

  if [[ $# -lt 2 ]]; then
    echo "cpuquota: need PERCENT and COMMAND" >&2
    return 2
  fi

  # Parse percent (allow integer or decimal, optional % sign)
  local pct="${1%%%}"; shift
  [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "cpuquota: PERCENT must be a number"; return 2; }

  # Core count (robust fallbacks)
  local cores
  cores="$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || awk '/^processor/{c++} END{print c?c:1}' /proc/cpuinfo 2>/dev/null || echo 1)"

  # Compute CPUQuota value to pass to systemd:
  #  - default: pct of whole machine → pct * cores
  #  - -c: pct of one CPU → pct * 1
  local factor="1"
  (( per_cpu )) || factor="$cores"

  # Multiply (supports decimals) and round to nearest integer
  local quota
  quota="$(awk -v p="$pct" -v f="$factor" 'BEGIN{q=p*f; printf "%.0f", q}')"

  local -a props run_user run_sys
  props=(-p CPUAccounting=yes -p "CPUQuota=${quota}%")
  [[ -n "$period" ]] && props+=( -p "CPUQuotaPeriodSec=$period" )

  # Build run args (user first, then system, then sudo system)
  local -a base
  if (( background )); then
    [[ -z "$unit" ]] && unit="cpuquota-$(date +%s%N)"
    base=(--unit="$unit" --collect)
  else
    [[ -n "$unit" ]] && base=(--unit="$unit")
    base+=("--scope")
  fi
  run_user=(--user "${base[@]}")
  run_sys=("${base[@]}")

  if systemd-run "${run_user[@]}" "${props[@]}" -- "$@"; then
    :
  elif systemd-run "${run_sys[@]}" "${props[@]}" -- "$@"; then
    :
  else
    echo "cpuquota: elevating with sudo for system manager..." >&2
    if ! sudo systemd-run "${run_sys[@]}" "${props[@]}" -- "$@"; then
      echo "cpuquota: failed to start unit (CPU controller may be unavailable for user.slice; try with sudo or check cgroup v2 settings)" >&2
      return 1
    fi
  fi

  (( background )) && echo "cpuquota: started unit ${unit}. See: systemctl status ${unit}"
}

