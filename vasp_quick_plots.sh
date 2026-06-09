#!/usr/bin/env bash
###############################################################################
# vasp_quick_plots.sh   (invoked on PATH as: vasp-quick-plots)
#
# One fat-band/DOS figure per plotting method, in a single command. For each
# method the most-important projections over the energy window are chosen
# automatically (by vasp-plot-fatbandsdos --auto-projections), so you get a
# quick, faithful overview without hand-picking orbitals:
#
#   plain        no projection: pale-grey backbone + black k-point dots
#   one_orbital  the single most-contributing (element, dominant-l), e.g. Cu-d
#   duo          the 2 most-contributing elements (e.g. Cu-d, S-p)
#   rgb          the 3 most-contributing elements
#   stacked      the N most-contributing elements (default 4)
#
# "Most-contributing" is measured by the projected DOS integrated over the
# energy window [--emin, --emax] (a proper states integral, summed over spin).
# If the cell has fewer distinct elements than a method needs, selection falls
# back to inequivalent Wyckoff sites of the same element (Pt1-d, Pt2-d, ...),
# always in descending order of contribution.
#
# OUTPUT (under <root>/Plots/):
#   plain.{png,pdf}  one_orbital.{png,pdf}  duo.{png,pdf}
#   rgb.{png,pdf}    stacked.{png,pdf}      (+ <name>.analysis_report.txt each)
#
# USAGE
#   conda activate wolfpack-dft         # needs pymatgen/numpy/matplotlib/scipy
#   cd <root with Scf/ Bands/ Dos/>
#   vasp-quick-plots                    # all methods, auto energy window
#   vasp-quick-plots --emin -6 --emax 6 --title "CuVS_3"
#   vasp-quick-plots --methods plain,one_orbital,rgb
#   vasp-quick-plots --root path/to/calc --stacked-n 5 --spin both
#   vasp-quick-plots --help
#
# OPTIONS
#   --root DIR        calculation root (default: .)
#   --emin/--emax EV  energy window (rel. E_F) for BOTH the view and the
#                     contribution ranking (default: auto-fit to the bands)
#   --title STR       figure title (TeX-ish, e.g. "CuVS_3 - G_0W_0")
#   --methods LIST    comma list from: plain,one_orbital,duo,rgb,stacked
#                     (default: all five)
#   --stacked-n N     how many units for the stacked plot (default: 4)
#   --spin {both,up,down}   spin channel(s) (default: both)
#   --formats LIST    output formats, e.g. png,pdf (default: png,pdf)
#   --group MODE      site grouping symmetry|formula|element (default: symmetry)
#   Any extra args after `--` are passed verbatim to vasp-plot-fatbandsdos.
###############################################################################
set -uo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,46p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
    exit 0
fi

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_rst} $*"; }
ok()   { printf '%s\n' "    ${c_grn}done${c_rst}  $*"; }
warn() { printf '%s\n' "    ${c_yel}WARN${c_rst} $*" >&2; }

# --------------------------------------------------------------------------- #
# Defaults + argument parsing
# --------------------------------------------------------------------------- #
ROOT="."
EMIN=""; EMAX=""; TITLE=""
METHODS="plain,one_orbital,duo,rgb,stacked"
STACKED_N=4
SPIN="both"
FORMATS="png,pdf"
GROUP="symmetry"
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)       ROOT="${2:?}"; shift 2 ;;
        --emin)       EMIN="${2:?}"; shift 2 ;;
        --emax)       EMAX="${2:?}"; shift 2 ;;
        --title)      TITLE="${2:?}"; shift 2 ;;
        --methods)    METHODS="${2:?}"; shift 2 ;;
        --stacked-n)  STACKED_N="${2:?}"; shift 2 ;;
        --spin)       SPIN="${2:?}"; shift 2 ;;
        --formats)    FORMATS="${2:?}"; shift 2 ;;
        --group)      GROUP="${2:?}"; shift 2 ;;
        --)           shift; EXTRA=("$@"); break ;;
        *) warn "Unknown option: $1"; echo "Try: vasp-quick-plots --help" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------- #
# Locate the plotter (the master command, or the package file next to us)
# --------------------------------------------------------------------------- #
PLOT_CMD=()
for cand in "${VASP_PLOT:-}" \
            "$(command -v vasp-plot-fatbandsdos 2>/dev/null || true)" \
            "$HOME/.local/bin/vasp-plot-fatbandsdos"; do
    if [[ -n "$cand" && -x "$cand" ]]; then PLOT_CMD=("$cand"); break; fi
done
if [[ ${#PLOT_CMD[@]} -eq 0 ]]; then
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    here="$(dirname "$self")"
    if [[ -f "$here/vasp_plot_fatbandsdos.py" ]]; then
        PY="$(command -v python3 || command -v python || true)"
        [[ -n "$PY" ]] && PLOT_CMD=("$PY" "$here/vasp_plot_fatbandsdos.py")
    fi
fi
if [[ ${#PLOT_CMD[@]} -eq 0 ]]; then
    echo "ERROR: could not find vasp-plot-fatbandsdos (install the toolkit, or "  >&2
    echo "       set VASP_PLOT=/path/to/vasp_plot_fatbandsdos.py)."               >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Sanity: the expected sub-folders
# --------------------------------------------------------------------------- #
for d in Scf Bands Dos; do
    [[ -d "$ROOT/$d" ]] || warn "$ROOT/$d not found — vasp-plot-fatbandsdos may fail."
done

# Common args shared by every invocation.
COMMON=(--root "$ROOT" --spin "$SPIN" --formats "$FORMATS" --group "$GROUP")
[[ -n "$EMIN" ]] && COMMON+=(--emin "$EMIN")
[[ -n "$EMAX" ]] && COMMON+=(--emax "$EMAX")
[[ -n "$TITLE" ]] && COMMON+=(--title "$TITLE")
[[ ${#EXTRA[@]} -gt 0 ]] && COMMON+=("${EXTRA[@]}")

# Units auto-picked per method (plain takes none).
declare -A NUNITS=( [plain]=0 [one_orbital]=1 [duo]=2 [rgb]=3 [stacked]="$STACKED_N" )

info "WolfPack-DFT quick plots"
echo "    root    : $ROOT"
echo "    window  : ${EMIN:-auto} .. ${EMAX:-auto} eV   (selection + view)"
echo "    methods : $METHODS"
echo "    plotter : ${PLOT_CMD[*]}"
echo

# --------------------------------------------------------------------------- #
# One plot per requested method
# --------------------------------------------------------------------------- #
n_ok=0; n_fail=0
IFS=',' read -r -a METHOD_LIST <<< "$METHODS"
for raw in "${METHOD_LIST[@]}"; do
    m="$(echo "$raw" | tr 'A-Z -' 'a-z__' | sed 's/^ *//;s/ *$//')"
    [[ -z "$m" ]] && continue
    if [[ -z "${NUNITS[$m]+x}" ]]; then
        warn "unknown method '$raw' — skipping (valid: ${!NUNITS[*]})."
        continue
    fi
    args=("${COMMON[@]}" --method "$m" --name "$m")
    if [[ "${NUNITS[$m]}" -gt 0 ]]; then
        args+=(--auto-projections "${NUNITS[$m]}")
    fi

    info "[$m] ${PLOT_CMD[*]##*/} --method $m $([[ ${NUNITS[$m]} -gt 0 ]] && echo "--auto-projections ${NUNITS[$m]}")"
    if "${PLOT_CMD[@]}" "${args[@]}"; then
        ok "$ROOT/Plots/$m.{${FORMATS}}"
        n_ok=$((n_ok + 1))
    else
        warn "$m plot failed (see message above) — continuing with the rest."
        n_fail=$((n_fail + 1))
    fi
    echo
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
info "Quick plots finished: ${c_grn}$n_ok ok${c_rst}, $([[ $n_fail -gt 0 ]] && echo "${c_red}$n_fail failed${c_rst}" || echo "0 failed")."
echo "    figures in: $ROOT/Plots/"
if [[ $n_fail -gt 0 ]]; then
    echo "    Tip: if everything failed with a ModuleNotFoundError, activate the env:"
    echo "         conda activate wolfpack-dft"
fi
[[ $n_ok -gt 0 ]]   # exit 0 if at least one plot succeeded
