#!/usr/bin/env bash
###############################################################################
# collect_u_data.sh
#
# Step 3 of 4 -- Cococcioni linear-response Hubbard U workflow
# Run AFTER all NSCF and SCF jobs from steps 1 and 2 have finished.
#
# WORKFLOW (4 steps; run them in order)
#   Step 1: run_nscf_steps.sh   (already done)
#   Step 2: run_scf_steps.sh    (already done)
#   Step 3: collect_u_data.sh   <-- THIS SCRIPT
#   Step 4: vasp_calculate_u.py        (python vasp_calculate_u.py -> prints U)
#
# WHAT IT DOES
#   1. Verifies that every NSCF and SCF OUTCAR is complete.
#      Default (strict):  OUTCAR must contain "General timing".
#      --lenient mode:    accepts OUTCARs that reached EDIFF (SCF converged)
#                         even if the job was killed before VASP exited.
#   2. Reads the d- or f-electron count on the perturbed atom from the
#      LORBIT=11 "total charge" block at the END of each OUTCAR (the last
#      occurrence = the converged result).
#   3. Reads the ground-state occupation from 01_Groundstate/OUTCAR (alpha=0).
#   4. Writes U_data.dat -- a whitespace-separated ASCII table with columns:
#         alpha(eV)  N_NSCF  N_SCF  dN_NSCF  dN_SCF
#      where dN = N(alpha) - N_GS. This table is the direct input to vasp_calculate_u.py.
#
# QUICK START
#   collect_u_data.sh                      # defaults (site=1, orbital=d)
#   collect_u_data.sh --site 2             # perturbed atom is POSCAR index 2
#   collect_u_data.sh --orbital f          # extract f-electron column instead
#   collect_u_data.sh --lenient            # accept OOM-killed but converged runs
#   collect_u_data.sh --help
###############################################################################

set -euo pipefail

# --- Defaults ---------------------------------------------------------------
GS_DIR="01_Groundstate"
NSCF_DIR="02_NonselfconsistentResponse"
SCF_DIR="03_SelfconsistentResponse"
ALPHAS="-0.20 -0.15 -0.10 -0.05 0.05 0.10 0.15 0.20"
SITE=1            # which atom index is the perturbed one (1-based, as in OUTCAR)
ORBITAL="d"       # "d" or "f"
OUTPUT="U_data.dat"
LENIENT=0         # if 1, accept OUTCARs that converged but were OOM-killed
                  # before VASP wrote "General timing"

print_help() {
    cat <<'EOF'
collect_u_data.sh -- Step 3 of 4: collect d/f-electron occupations from
                     VASP OUTCARs and write U_data.dat for linear fitting.

WORKFLOW
  Step 1: run_nscf_steps.sh   (already done)
  Step 2: run_scf_steps.sh    (already done)
  Step 3: collect_u_data.sh   <-- THIS SCRIPT
  Step 4: vasp_calculate_u.py        (python vasp_calculate_u.py -> prints U)

USAGE
  collect_u_data.sh [options]

REQUIREMENTS
  01_Groundstate/OUTCAR                          alpha=0 reference occupation
  02_NonselfconsistentResponse/V_<alpha>/OUTCAR  one per alpha value
  03_SelfconsistentResponse/V_<alpha>/OUTCAR     one per alpha value
  LORBIT=11 must have been set in every INCAR; otherwise the "total charge"
  block is absent and occupation extraction will fail.

OPTIONS
  --alphas "V1 V2 ..."   Alpha perturbation grid used in steps 1 and 2.
                         Default: -0.20 -0.15 -0.10 -0.05 0.05 0.10 0.15 0.20
  --gs-dir DIR           Ground-state directory (default: 01_Groundstate).
  --nscf-dir DIR         NSCF directory          (default: 02_NonselfconsistentResponse).
  --scf-dir DIR          SCF directory           (default: 03_SelfconsistentResponse).
  --site N               Index of the perturbed atom in POSCAR/OUTCAR
                         (1-based; default 1).
  --orbital {d|f}        Which orbital column to extract (default: d).
  --output FILE          Output table filename   (default: U_data.dat).
  --lenient              Accept an OUTCAR if the electronic SCF loop reached
                         EDIFF (line "aborting loop because EDIFF is reached")
                         even when "General timing" is missing. Use this when
                         VASP converged the physics but the job was killed
                         (e.g. OOM) before exiting cleanly.
  -h, --help             Show this help.

OUTPUT FORMAT (U_data.dat)
  Plain text, whitespace-separated, with a header line. Columns:
    alpha (eV)   N_NSCF   N_SCF   dN_NSCF   dN_SCF
  where dN = N(alpha) - N_GS. Suitable for gnuplot/numpy/pandas.

NEXT STEP
  python vasp_calculate_u.py
  Reads U_data.dat, fits chi_0 = d(dN_NSCF)/d(alpha) and
  chi = d(dN_SCF)/d(alpha), then prints  U = 1/chi - 1/chi_0.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)    print_help; exit 0 ;;
        --alphas)     ALPHAS="$2";    shift 2 ;;
        --gs-dir)     GS_DIR="$2";    shift 2 ;;
        --nscf-dir)   NSCF_DIR="$2";  shift 2 ;;
        --scf-dir)    SCF_DIR="$2";   shift 2 ;;
        --site)       SITE="$2";      shift 2 ;;
        --orbital)    ORBITAL="$2";   shift 2 ;;
        --output)     OUTPUT="$2";    shift 2 ;;
        --lenient)    LENIENT=1;      shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Validation -------------------------------------------------------------
[[ "$ORBITAL" == "d" || "$ORBITAL" == "f" ]] \
    || { echo "ERROR: --orbital must be 'd' or 'f'." >&2; exit 1; }
[[ "$SITE" =~ ^[0-9]+$ ]] && (( SITE >= 1 )) \
    || { echo "ERROR: --site must be a positive integer." >&2; exit 1; }

[[ -d "$GS_DIR"   ]] || { echo "ERROR: $GS_DIR not found."   >&2; exit 1; }
[[ -d "$NSCF_DIR" ]] || { echo "ERROR: $NSCF_DIR not found." >&2; exit 1; }
[[ -d "$SCF_DIR"  ]] || { echo "ERROR: $SCF_DIR not found."  >&2; exit 1; }

# Pick which awk column holds the requested orbital occupation. The OUTCAR
# "total charge" block has columns:  ion  s  p  d  tot     (for d-only PAWs)
# or:                                ion  s  p  d  f  tot  (for f PAWs)
# We use awk's column index. For d: column 4. For f: column 5.
if [[ "$ORBITAL" == "d" ]]; then
    OCC_COL=4
else
    OCC_COL=5
fi

# --- Helpers ----------------------------------------------------------------

# Verify a directory's OUTCAR is from a successful run.
# Strict mode (default): require "General timing" -- VASP's farewell line,
#                        only written if the job exits cleanly.
# Lenient mode (--lenient): accept the OUTCAR if the SCF actually converged
#                           (an F= line and "reached required accuracy"),
#                           even if the job was killed afterwards.
check_complete() {
    local outcar="$1"
    [[ -f "$outcar" ]] || return 1
    if (( LENIENT )); then
        # The actual SCF convergence marker. Printed when the electronic loop
        # hits EDIFF, regardless of whether it's a static (NSW=0) or relaxation
        # run, and regardless of what happens to the job afterwards.
        grep -q "aborting loop because EDIFF is reached" "$outcar" || return 1
    else
        grep -q "General timing" "$outcar" || return 1
    fi
    return 0
}

# Extract the orbital occupation on the requested site from an OUTCAR.
# Strategy:
#   * Find the LAST "total charge" block (the converged one).
#   * Skip the header lines until we hit the line for our atom index.
#   * Print column $OCC_COL.
# Implemented in a single awk pass for robustness.
extract_occ() {
    local outcar="$1"
    awk -v site="$SITE" -v col="$OCC_COL" '
        # Start of a "total charge" block.
        /^[[:space:]]*total charge[[:space:]]*$/ {
            in_block = 1
            next
        }
        # Inside a block: only data lines start with a pure integer (atom index).
        # Header lines (e.g. "# of ion ...") and dashed separators and blank
        # lines are simply skipped without leaving the block.
        in_block {
            if ($1 ~ /^[0-9]+$/) {
                if ($1+0 == site) {
                    last_value = $col
                }
                next
            }
            # The block ends when we hit a "total" / "tot" summary line
            # or an alphabetic word (e.g. start of the next OUTCAR section).
            if ($1 ~ /^(tot|total)$/ || $1 ~ /^[A-Za-z]/) {
                in_block = 0
            }
        }
        END {
            if (last_value == "") {
                exit 1
            }
            print last_value
        }
    ' "$outcar"
}

# --- Pre-flight: every OUTCAR must be complete ------------------------------
read -r -a ALPHA_ARRAY <<< "$ALPHAS"

echo "Verifying calculations..."
missing=0

# Ground state
gs_outcar="$GS_DIR/OUTCAR"
if ! check_complete "$gs_outcar"; then
    echo "  INCOMPLETE: $gs_outcar"
    missing=1
fi

# Per-alpha NSCF and SCF
for alpha in "${ALPHA_ARRAY[@]}"; do
    label=$(LC_NUMERIC="C" printf "V_%+0.2f" "$alpha" | sed 's/\./p/')
    for stage_dir in "$NSCF_DIR/$label" "$SCF_DIR/$label"; do
        if ! check_complete "$stage_dir/OUTCAR"; then
            echo "  INCOMPLETE: $stage_dir/OUTCAR"
            missing=1
        fi
    done
done

if (( missing )); then
    echo "" >&2
    echo "ERROR: One or more calculations are incomplete. Aborting." >&2
    echo "       Re-run the missing ones individually before collecting." >&2
    exit 1
fi
echo "  All calculations complete."

# --- Extract reference (ground-state) occupation ----------------------------
echo ""
echo "Extracting site-${SITE} ${ORBITAL}-electron count from ground state..."
N_GS=$(extract_occ "$gs_outcar") \
    || { echo "ERROR: could not parse '$ORBITAL' occupation on site $SITE in $gs_outcar." >&2; exit 1; }
echo "  N_GS = $N_GS"

# --- Walk through every alpha and collect the table -------------------------
echo ""
echo "Collecting per-alpha occupations..."

# Column widths: alpha (signed 2dp) | occ (4dp) | dN (signed 4dp).
# Header prefixed by '#' so gnuplot/numpy.loadtxt skip it.
{
    printf "# Linear-response Hubbard U data\n"
    printf "# Perturbed site: %d   Orbital: %s   N_GS: %s\n" "$SITE" "$ORBITAL" "$N_GS"
    printf "# %10s  %10s  %10s  %12s  %12s\n" "alpha(eV)" "N_NSCF" "N_SCF" "dN_NSCF" "dN_SCF"
} > "$OUTPUT"

for alpha in "${ALPHA_ARRAY[@]}"; do
    label=$(LC_NUMERIC="C" printf "V_%+0.2f" "$alpha" | sed 's/\./p/')

    nscf_outcar="$NSCF_DIR/$label/OUTCAR"
    scf_outcar="$SCF_DIR/$label/OUTCAR"

    n_nscf=$(extract_occ "$nscf_outcar") \
        || { echo "ERROR: could not parse $nscf_outcar." >&2; exit 1; }
    n_scf=$(extract_occ "$scf_outcar") \
        || { echo "ERROR: could not parse $scf_outcar." >&2; exit 1; }

    # Compute dN with awk (bash can't do floats). Use C locale for '.' decimal.
    dn_nscf=$(LC_NUMERIC="C" awk -v a="$n_nscf" -v g="$N_GS" 'BEGIN{printf "%.4f", a-g}')
    dn_scf=$(LC_NUMERIC="C" awk -v a="$n_scf"  -v g="$N_GS" 'BEGIN{printf "%.4f", a-g}')

    LC_NUMERIC="C" printf "  %+10.2f  %10s  %10s  %+12s  %+12s\n" \
        "$alpha" "$n_nscf" "$n_scf" "$dn_nscf" "$dn_scf" >> "$OUTPUT"

    echo "  alpha=$alpha   N_NSCF=$n_nscf   N_SCF=$n_scf   dN_NSCF=$dn_nscf   dN_SCF=$dn_scf"
done

# --- Echo the final table to stdout for convenience -------------------------
echo ""
echo "Wrote $OUTPUT:"
echo "----------------------------------------------------------------------"
cat "$OUTPUT"
echo "----------------------------------------------------------------------"
echo ""
echo "Next: linear-fit dN_NSCF and dN_SCF vs alpha, then"
echo "      U = 1/slope_SCF - 1/slope_NSCF"
