# env_audit.source.sh
# Source this file, then run:
#   env_audit [-o OUTDIR] [-p PYBIN] [-h]
# Produces a read-only snapshot of a mixed conda/pip environment.

env_audit() (
  # run in a subshell to avoid polluting the caller's shell
  set -u  # (intentionally not -e; we want best-effort completion)
  IFS=$' \t\n'

  # ---------- args ----------
  OUTDIR="env_audit_$(date +%Y%m%d_%H%M%S)"
  PYBIN="${PYTHON:-$(command -v python 2>/dev/null || true)}"
  while getopts ":o:p:h" opt; do
    case "$opt" in
      o) OUTDIR="$OPTARG" ;;
      p) PYBIN="$OPTARG" ;;
      h)
        cat <<'USAGE'
env_audit [-o OUTDIR] [-p PYBIN]
  -o OUTDIR   Output directory (default: env_audit_YYYYmmdd_HHMMSS)
  -p PYBIN    Python binary to use (default: detected "python")
USAGE
        exit 0
        ;;
      \?) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
      :)  echo "Option -$OPTARG requires an argument." >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND-1))
  mkdir -p "$OUTDIR"

  # ---------- helpers ----------
  sec() { printf '\n=== %s ===\n' "$*"; }
  die() { echo "fatal: $*" >&2; exit 1; }
  have() { command -v "$1" >/dev/null 2>&1; }
  save_cmd() {  # usage: save_cmd file -- cmd args...
    local file="$1"; shift
    [[ "$1" == "--" ]] && shift
    { "$@" ; } >"$OUTDIR/$file" 2>&1 || printf '[exit %d]\n' "$?" >>"$OUTDIR/$file"
  }
  save_py() {  # usage: save_py file <<'PY' ... PY
    local file="$1"; shift
    "$PYBIN" - "$@" >"$OUTDIR/$file" 2>&1 || printf '[exit %d]\n' "$?" >>"$OUTDIR/$file"
  }

  # ---------- sanity ----------
  [[ -n "${PYBIN:-}" ]] || die "No python found (set -p PYBIN or export PYTHON=/path/to/python)"
  PYVER="$("$PYBIN" -V 2>&1 || echo n/a)"

  # ---------- 0) Environment snapshot ----------
  sec "Environment"
  {
    echo "python: $PYVER"
    echo "python exe: $PYBIN"
    echo "which pip: $(command -v pip 2>/dev/null || echo '(missing)')"
    "$PYBIN" -m pip -V 2>/dev/null || echo "pip: (unavailable)"
    echo "CONDA_PREFIX: ${CONDA_PREFIX:-'(unset)'}"
    echo "CONDA_DEFAULT_ENV: ${CONDA_DEFAULT_ENV:-'(unset)'}"
    echo "CUPY_ACCELERATORS: ${CUPY_ACCELERATORS:-'(unset)'}"
    echo
    if have conda; then
      echo "[conda envs]"
      conda info --envs 2>/dev/null || true
    else
      echo "conda: (not found in PATH)"
    fi
  } | tee "$OUTDIR/00_env.txt" >/dev/null
  echo "snapshot → $OUTDIR/00_env.txt"

  # ---------- 1) Conda package state ----------
  if have conda; then
    sec "Conda packages (channels)"
    save_cmd 10_conda_list.txt -- conda list --show-channel-urls
    head -n 12 "$OUTDIR/10_conda_list.txt" || true
    [[ -s "$OUTDIR/10_conda_list.txt" ]] && echo "... (full: $OUTDIR/10_conda_list.txt)"

    sec "Conda revisions (history)"
    save_cmd 11_conda_revisions.txt -- conda list --revisions
    head -n 12 "$OUTDIR/11_conda_revisions.txt" || true
    [[ -s "$OUTDIR/11_conda_revisions.txt" ]] && echo "... (full: $OUTDIR/11_conda_revisions.txt)"

    save_cmd _conda_list.json -- conda list --json
  else
    printf '[]\n' >"$OUTDIR/_conda_list.json"
    sec "Conda not found — skipping conda sections"
  fi

  # ---------- 2) Pip package state ----------
  sec "Pip packages"
  save_cmd 20_pip_list.txt -- "$PYBIN" -m pip list --format=columns
  head -n 20 "$OUTDIR/20_pip_list.txt" || true
  [[ -s "$OUTDIR/20_pip_list.txt" ]] && echo "... (full: $OUTDIR/20_pip_list.txt)"

  save_cmd 21_pip_freeze.txt -- "$PYBIN" -m pip freeze
  echo "freeze → $OUTDIR/21_pip_freeze.txt"

  # ---------- 3) Pip-installed via conda (channel=pypi) ----------
  if have conda; then
    sec "Conda entries with channel=pypi"
    save_py 30_conda_pypi_entries.txt <<'PY'
import json, sys, pathlib
p = pathlib.Path("_conda_list.json")
try:
    data = json.loads(p.read_text())
except Exception:
    data = []
rows = [f"{d.get('name',''):<30} {d.get('version','')}" for d in data if d.get('channel') == 'pypi']
print("\n".join(rows) if rows else "(none)")
PY
    head -n 12 "$OUTDIR/30_conda_pypi_entries.txt" || true
    [[ -s "$OUTDIR/30_conda_pypi_entries.txt" ]] && echo "... (full: $OUTDIR/30_conda_pypi_entries.txt)"
  fi

  # ---------- 4) Overlaps: conda ∩ pip ----------
  sec "Overlaps (present in BOTH conda and pip)"
  save_py 40_overlaps.txt "$OUTDIR/_conda_list.json" <<'PY'
import json, sys, importlib.metadata as m, pathlib
conda_pkgs = json.loads(pathlib.Path(sys.argv[1]).read_text()) if len(sys.argv)>1 else []
conda_names = { (p.get('name') or '').lower() for p in conda_pkgs }
pip_names = { (d.metadata.get('Name') or '').lower() for d in m.distributions() }
both = sorted(n for n in (conda_names & pip_names) if n)
print("\n".join(both) if both else "(none)")
PY
  cat "$OUTDIR/40_overlaps.txt"

  # ---------- 5) Import locations ----------
  sec "Import locations (module → file)"
  save_py 50_import_paths.txt <<'PY'
import importlib, importlib.metadata as m
def where(modname):
    try:
        spec = importlib.util.find_spec(modname)
        if spec is None: return None
        return getattr(spec, 'origin', None) or str(getattr(spec, 'loader', ''))
    except Exception:
        return None
dists = sorted({ (dist.metadata.get('Name') or '') for dist in m.distributions() if dist.metadata.get('Name') })
for name in dists:
    mod = name.replace('-', '_')
    loc = where(mod)
    if loc:
        print(f"{name:30s} -> {loc}")
PY
  head -n 15 "$OUTDIR/50_import_paths.txt" || true
  [[ -s "$OUTDIR/50_import_paths.txt" ]] && echo "... (full: $OUTDIR/50_import_paths.txt)"

  # ---------- 6) Duplicate installs ----------
  sec "Duplicate install locations"
  save_py 60_duplicates.txt <<'PY'
import os, importlib.metadata as m
from collections import defaultdict
paths = defaultdict(set)
for d in m.distributions():
    try:
        base = os.path.dirname(d.locate_file(''))
        name = (d.metadata.get('Name') or '').lower()
        if name: paths[name].add(base)
    except Exception:
        pass
found = False
for name, locs in sorted(paths.items()):
    if len(locs) > 1:
        found = True
        print(f"{name}:")
        for L in sorted(locs): print("  -", L)
if not found:
    print("(none)")
PY
  cat "$OUTDIR/60_duplicates.txt"

  # ---------- 7) Health checks ----------
  sec "pip check"
  save_cmd 70_pip_check.txt -- "$PYBIN" -m pip check
  cat "$OUTDIR/70_pip_check.txt"

  # ---------- 8) Exports ----------
  if have conda; then
    sec "conda env export (full)"
    save_cmd 80_conda_env_full.yml -- conda env export ${CONDA_DEFAULT_ENV:+-n "$CONDA_DEFAULT_ENV"}
    sec "conda env export (from-history)"
    save_cmd 81_conda_env_from_history.yml -- conda env export --from-history ${CONDA_DEFAULT_ENV:+-n "$CONDA_DEFAULT_ENV"}
  else
    printf "conda not found — skipping exports\n" | tee "$OUTDIR/80_conda_env_full.yml" >/dev/null
    cp "$OUTDIR/80_conda_env_full.yml" "$OUTDIR/81_conda_env_from_history.yml" 2>/dev/null || true
  fi
  save_cmd 82_requirements-pip.txt -- "$PYBIN" -m pip freeze

  # ---------- 9) One-file audit bundle ----------
  sec "pkg_audit.txt (combined snapshot)"
  save_py 90_pkg_audit.txt <<'PY'
import json, subprocess, importlib.metadata as m, sys, shutil
print("python:", sys.version.split()[0]); print("exe:", sys.executable)
print("\n[conda list --show-channel-urls]")
if shutil.which("conda"):
    try:
        print(subprocess.check_output(["conda","list","--show-channel-urls"], text=True))
    except Exception as e:
        print("conda list failed:", e)
else:
    print("(conda not found)")
print("\n[pip list]")
try:
    print(subprocess.check_output([sys.executable,"-m","pip","list","--format=columns"], text=True))
except Exception as e:
    print("pip list failed:", e)
print("\n[overlaps conda ∩ pip]")
try:
    conda_pkgs = json.loads(subprocess.check_output(["conda","list","--json"], text=True)) if shutil.which("conda") else []
except Exception:
    conda_pkgs = []
conda_names = { (p.get("name") or "").lower() for p in conda_pkgs }
pip_names = { (d.metadata.get("Name") or "").lower() for d in m.distributions() }
print("\n".join(sorted(conda_names & pip_names)) or "(none)")
PY
  echo "bundle → $OUTDIR/90_pkg_audit.txt"

  # ---------- summary ----------
  sec "Done"
  echo "Artifacts written to: $OUTDIR"
  ls -1 "$OUTDIR" | sed 's/^/  - /'
)

