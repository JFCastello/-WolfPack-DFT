#!/usr/bin/env bash
#
# vasp_clean.sh   (invoked on PATH as: vasp-clean)
#               — Clean heavy intermediate files from VASP calculation folders.
#
# By default, removes large files that are not typically needed for
# post-processing while preserving every file essential for analysis
# (vasprun.xml, OUTCAR, CONTCAR, CHGCAR, DOSCAR, EIGENVAL, PROCAR, ...).
#
# Usage: vasp-clean [OPTIONS] [DIR...]
#

set -euo pipefail

VERSION="1.0"
PROGRAM="vasp-clean"

# ------------------------------------------------------------------
# Files lists
# ------------------------------------------------------------------

# Heavy files removed by DEFAULT (safe to delete after a calculation;
# none of these are required by standard post-processing tools).
DEFAULT_REMOVE=(
    "WAVECAR"      # wavefunctions — huge, almost never needed
    "CHG"          # intermediate charge density (CHGCAR is the keeper)
    "TMPCAR"       # temporary
    "vasprun.tmp"  # temporary
    "PCDAT"        # pair-correlation (MD), regenerable
    "WAVEDER"      # wavefunction derivatives (optics restart)
    "STOPCAR"      # stop flag, leftover
    "REPORT"       # MD report file, can be large
    "HILLSPOT"     # metadynamics restart
)

# Files removed ONLY with --aggressive
# (still safe to remove, but may be useful for some post-processing).
AGGRESSIVE_REMOVE=(
    "CHGCAR"       # full charge density (kept by default: Bader, NSCF...)
    "LOCPOT"       # local potential (workfunctions)
    "ELFCAR"       # electron localization function
    "PROCAR"       # projected bands (vasprun.xml usually has equivalent info)
    "DOSCAR"       # DOS (vasprun.xml has it)
    "EIGENVAL"     # eigenvalues (vasprun.xml has it)
    "XDATCAR"      # trajectory (MD/relax)
    "AECCAR0"      # all-electron charge density
    "AECCAR1"
    "AECCAR2"
)

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
DRY_RUN=0
RECURSIVE=0
AGGRESSIVE=0
FORCE=0
VERBOSE=0
DIRS=()

# Colors only if stdout is a terminal
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    RED=$'\033[31m'
    RESET=$'\033[0m'
else
    BOLD="" DIM="" GREEN="" YELLOW="" CYAN="" RED="" RESET=""
fi

# ------------------------------------------------------------------
# Help
# ------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}$PROGRAM v$VERSION${RESET} — Clean heavy files from VASP calculations

${BOLD}USAGE${RESET}
  $PROGRAM [OPTIONS] [DIR...]

  If no DIR is given, the current directory is used.

${BOLD}REMOVED BY DEFAULT${RESET}
  WAVECAR  CHG  TMPCAR  vasprun.tmp  PCDAT  WAVEDER  STOPCAR  REPORT  HILLSPOT

${BOLD}REMOVED WITH --aggressive${RESET}
  CHGCAR  LOCPOT  ELFCAR  PROCAR  DOSCAR  EIGENVAL  XDATCAR  AECCAR0/1/2

${BOLD}ALWAYS PRESERVED${RESET}
  INCAR  POSCAR  CONTCAR  KPOINTS  POTCAR  OUTCAR  OSZICAR  vasprun.xml
  IBZKPT  + anything not in the lists above

${BOLD}OPTIONS${RESET}
  -n, --dry-run       Show what would be deleted, don't delete anything
  -r, --recursive     Look for VASP folders recursively under DIR
  -a, --aggressive    Also remove CHGCAR, LOCPOT, ELFCAR, etc.
  -f, --force         Don't ask for confirmation (use with care)
  -v, --verbose       Print extra info
  -h, --help          This help
  -V, --version       Print version

${BOLD}EXAMPLES${RESET}
  $PROGRAM                     # clean current dir (asks for confirmation)
  $PROGRAM -n .                # dry-run on current dir
  $PROGRAM -r ./relax_runs     # clean all VASP folders under relax_runs/
  $PROGRAM -a -f calc1 calc2   # aggressive clean of two folders, no prompt

EOF
}

# ------------------------------------------------------------------
# Arg parsing
# ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)    DRY_RUN=1; shift ;;
        -r|--recursive)  RECURSIVE=1; shift ;;
        -a|--aggressive) AGGRESSIVE=1; shift ;;
        -f|--force)      FORCE=1; shift ;;
        -v|--verbose)    VERBOSE=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        -V|--version)    echo "$PROGRAM $VERSION"; exit 0 ;;
        --)              shift; while [[ $# -gt 0 ]]; do DIRS+=("$1"); shift; done ;;
        -*)              echo "${RED}Unknown option: $1${RESET}" >&2; usage; exit 1 ;;
        *)               DIRS+=("$1"); shift ;;
    esac
done

[[ ${#DIRS[@]} -eq 0 ]] && DIRS=(".")

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

# A directory is "VASP-like" if it contains at least one of the
# canonical input/output files.
is_vasp_dir() {
    local d="$1"
    [[ -f "$d/INCAR"       || -f "$d/POSCAR"     ||
       -f "$d/OUTCAR"      || -f "$d/vasprun.xml" ]]
}

human_size() {
    # human-readable size of a file; "-" if missing
    [[ -f "$1" ]] && du -h "$1" 2>/dev/null | awk '{print $1}' || echo "-"
}

human_total() {
    # human readable from a kB integer
    local kb="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B $((kb*1024))
    else
        echo "${kb}K"
    fi
}

# Print list of files (full paths) to remove in directory $1
gather_targets() {
    local d="$1"
    local targets=("${DEFAULT_REMOVE[@]}")
    if [[ $AGGRESSIVE -eq 1 ]]; then
        targets+=("${AGGRESSIVE_REMOVE[@]}")
    fi

    local f
    local found=()
    for f in "${targets[@]}"; do
        [[ -f "$d/$f" ]] && found+=("$d/$f")
    done

    # also catch gzipped versions e.g. WAVECAR.gz, CHGCAR.gz
    for f in "${targets[@]}"; do
        [[ -f "$d/$f.gz" ]] && found+=("$d/$f.gz")
    done

    if [[ ${#found[@]} -gt 0 ]]; then
        printf '%s\n' "${found[@]}"
    fi
}

# Clean a single VASP directory
clean_dir() {
    local d="$1"

    if ! is_vasp_dir "$d"; then
        [[ $VERBOSE -eq 1 ]] && echo "${DIM}skip (not VASP): $d${RESET}"
        return 0
    fi

    local files=()
    mapfile -t files < <(gather_targets "$d")

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "${GREEN}✓${RESET} ${BOLD}$d${RESET}: already clean"
        return 0
    fi

    echo ""
    echo "${BOLD}${CYAN}▸ $d${RESET}"

    local total_kb=0
    local f size kb
    for f in "${files[@]}"; do
        size=$(human_size "$f")
        printf "    %-8s  %s\n" "$size" "$(basename "$f")"
        kb=$(du -k "$f" 2>/dev/null | awk '{print $1}')
        total_kb=$((total_kb + ${kb:-0}))
    done
    echo "    ${DIM}---------------${RESET}"
    printf "    %-8s  %s\n" "$(human_total "$total_kb")" "${BOLD}total${RESET}"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "    ${YELLOW}(dry-run — nothing removed)${RESET}"
        return 0
    fi

    if [[ $FORCE -eq 0 ]]; then
        read -r -p "    Delete these files? [y/N] " ans
        case "$ans" in
            y|Y|yes|YES|Yes) ;;
            *) echo "    ${YELLOW}skipped${RESET}"; return 0 ;;
        esac
    fi

    for f in "${files[@]}"; do
        rm -f -- "$f"
        [[ $VERBOSE -eq 1 ]] && echo "    ${DIM}rm $f${RESET}"
    done
    echo "    ${GREEN}cleaned (~$(human_total "$total_kb") freed)${RESET}"
}

# Process one path (file/dir/recursive)
process_path() {
    local p="$1"
    if [[ ! -d "$p" ]]; then
        echo "${RED}not a directory: $p${RESET}" >&2
        return 1
    fi

    if [[ $RECURSIVE -eq 1 ]]; then
        # iterate every subdirectory; clean_dir will filter non-VASP ones
        while IFS= read -r -d '' sub; do
            clean_dir "$sub"
        done < <(find "$p" -type d -print0)
    else
        clean_dir "$p"
    fi
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
echo "${BOLD}$PROGRAM v$VERSION${RESET}"
[[ $DRY_RUN    -eq 1 ]] && echo "  mode: ${YELLOW}dry-run${RESET}"
[[ $AGGRESSIVE -eq 1 ]] && echo "  mode: ${YELLOW}aggressive${RESET} (also removing CHGCAR/LOCPOT/ELFCAR/...)"
[[ $FORCE      -eq 1 ]] && echo "  mode: ${YELLOW}force${RESET} (no prompts)"
[[ $RECURSIVE  -eq 1 ]] && echo "  mode: ${YELLOW}recursive${RESET}"

for d in "${DIRS[@]}"; do
    process_path "$d"
done

echo ""
echo "${GREEN}Done.${RESET}"
