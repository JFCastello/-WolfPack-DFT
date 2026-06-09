#!/usr/bin/env bash
###############################################################################
# run_scf_steps.sh
#
# Step 2 of 4 -- Cococcioni linear-response Hubbard U workflow
# Run AFTER all NSCF jobs from run_nscf_steps.sh have finished.
#
# WORKFLOW (4 steps; run them in order)
#   Step 1: run_nscf_steps.sh   (already done)
#   Step 2: run_scf_steps.sh    <-- THIS SCRIPT
#   Step 3: collect_u_data.sh   (after all SCF jobs finish)
#   Step 4: vasp_calculate_u.py        (linear fit -> U value)
#
# WHAT IT DOES
#   1. Verifies every NSCF run in 02_NonselfconsistentResponse/V_*/ is usable.
#      Default (strict): OUTCAR must contain "General timing" (clean exit).
#      --lenient mode:   accepts an OUTCAR whose SCF converged (EDIFF reached)
#                        and whose LDA+U occupation table was written, even if
#                        the job was killed afterwards (e.g. OOM or walltime).
#   2. Sanity-checks that the NSCF LORBIT=11 charge tables vary across alphas.
#      If every alpha shows identical occupations the perturbation never took
#      effect and the script aborts before wasting SCF compute.
#   3. For each alpha, creates 03_SelfconsistentResponse/V_<alpha>/ with:
#        - CHGCAR, POSCAR, POTCAR, KPOINTS  (symlinked from 01_Groundstate/)
#        - WAVECAR  (symlinked from the matching NSCF run for faster restart)
#        - INCAR    (INCAR.scf.template + per-alpha LDAU block appended)
#        - job.slurm  (model_job.sh with -J/-o/-e rewritten per alpha)
#   4. Submits each job with sbatch. Already-complete runs are skipped.
#
# REQUIRED INPUTS (in the current directory)
#   01_Groundstate/      Converged ground state (CHGCAR, POSCAR, POTCAR, KPOINTS).
#   02_NonselfconsistentResponse/   All NSCF runs from step 1, complete or usable.
#   INCAR.scf.template   Base INCAR for the SCF runs. Must NOT contain ICHARG=11
#                        and must NOT set LDAUL, LDAUU, or LDAUJ.
#   model_job.sh         SLURM template with #SBATCH -J, -o, -e (short form).
#
# QUICK START
#   run_scf_steps.sh --ldaul "2 -1 -1" \
#                    --ldauu-template "{alpha} 0 0" \
#                    --ldauj-template "{alpha} 0 0"
#
# SEE ALSO: collect_u_data.sh --help
###############################################################################

set -euo pipefail

# --- Defaults ---------------------------------------------------------------
GS_DIR="01_Groundstate"
NSCF_DIR="02_NonselfconsistentResponse"
SCF_DIR="03_SelfconsistentResponse"
SCF_TEMPLATE="INCAR.scf.template"
MODEL_JOB="model_job.sh"
ALPHAS="-0.20 -0.15 -0.10 -0.05 0.05 0.10 0.15 0.20"
JOB_PREFIX="U_scf"
LDAUTYPE="3"

LDAUL=""
LDAUU_TEMPLATE=""
LDAUJ_TEMPLATE=""
DRY_RUN=0
LENIENT=0
# ----------------------------------------------------------------------------

print_help() {
    cat <<'EOF'
run_scf_steps.sh -- Step 2 of 4: submit SCF response jobs for the
                    Cococcioni linear-response Hubbard U calculation.
                    Run AFTER all NSCF jobs from run_nscf_steps.sh finish.

WORKFLOW
  Step 1: run_nscf_steps.sh   (already done)
  Step 2: run_scf_steps.sh    <-- THIS SCRIPT
  Step 3: collect_u_data.sh   (after all SCF jobs finish)
  Step 4: vasp_calculate_u.py        (python vasp_calculate_u.py -> prints U)

REQUIREMENT
  All NSCF jobs from Step 1 must be usable. Default (strict): OUTCAR must
  contain "General timing" (clean VASP exit). Use --lenient to accept OUTCARs
  that contain the LDA+U occupation table and a converged SCF loop (EDIFF
  reached) but were killed before VASP wrote the timing footer (e.g. OOM,
  walltime expiry after the physics was done).

USAGE
  run_scf_steps.sh --ldaul "VALS" \
                   --ldauu-template "VALS" --ldauj-template "VALS" \
                   [options]

REQUIRED
  --ldaul "VALS"           LDAUL line (one integer per species, e.g. "2 -1 -1").
  --ldauu-template "VALS"  LDAUU values, using {alpha} as placeholder.
  --ldauj-template "VALS"  LDAUJ values, same structure as --ldauu-template.

OPTIONS
  --alphas "V1 V2 ..."     Alpha perturbation grid (eV).
                           Default: -0.20 -0.15 -0.10 -0.05 0.05 0.10 0.15 0.20
  --gs-dir DIR             Ground-state directory (default: 01_Groundstate).
  --nscf-dir DIR           NSCF results directory (default: 02_NonselfconsistentResponse).
  --scf-dir DIR            Output directory (default: 03_SelfconsistentResponse).
  --template FILE          SCF INCAR template (default: INCAR.scf.template).
                           Must NOT contain ICHARG=11. Must NOT set LDAUL/LDAUU/LDAUJ.
  --model-job FILE         SLURM template (default: model_job.sh).
  --job-prefix NAME        SLURM job-name prefix (default: U_scf).
  --lenient                Accept NSCF OUTCARs that are incomplete but usable:
                           must have converged the SCF loop (EDIFF reached) AND
                           written the LORBIT=11 occupation table. Use when NSCF
                           jobs were killed after the physics was done.
  --dry-run                Prepare directories and job.slurm files but do NOT
                           call sbatch.
  -h, --help               Show this help.

REQUIREMENTS FOR model_job.sh
  Must contain (short-form flags only):
      #SBATCH -J <some-name>
      #SBATCH -o <some-pattern>
      #SBATCH -e <some-pattern>
  These lines are rewritten per-alpha; everything else is copied verbatim.

NEXT STEP
  Monitor jobs:  squeue -u $USER
  When all finish, run:
    collect_u_data.sh --site N --orbital d    (or --lenient if needed)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)         print_help; exit 0 ;;
        --alphas)          ALPHAS="$2";          shift 2 ;;
        --ldautype)        LDAUTYPE="$2";        shift 2 ;;
        --gs-dir)          GS_DIR="$2";          shift 2 ;;
        --nscf-dir)        NSCF_DIR="$2";        shift 2 ;;
        --scf-dir)         SCF_DIR="$2";         shift 2 ;;
        --template)        SCF_TEMPLATE="$2";    shift 2 ;;
        --model-job)       MODEL_JOB="$2";       shift 2 ;;
        --job-prefix)      JOB_PREFIX="$2";      shift 2 ;;
        --ldaul)           LDAUL="$2";           shift 2 ;;
        --ldauu-template)  LDAUU_TEMPLATE="$2";  shift 2 ;;
        --ldauj-template)  LDAUJ_TEMPLATE="$2";  shift 2 ;;
        --lenient)         LENIENT=1;            shift ;;
        --dry-run)         DRY_RUN=1;            shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Validation -------------------------------------------------------------
echo "Pre-flight checks..."

[[ -n "$LDAUL" && -n "$LDAUU_TEMPLATE" && -n "$LDAUJ_TEMPLATE" ]] \
    || { echo "ERROR: --ldaul, --ldauu-template, --ldauj-template are required." >&2; exit 1; }

[[ "$LDAUU_TEMPLATE" == *"{alpha}"* && "$LDAUJ_TEMPLATE" == *"{alpha}"* ]] \
    || { echo "ERROR: LDAUU/LDAUJ templates must contain {alpha} placeholder." >&2; exit 1; }

[[ -d "$GS_DIR"   ]] || { echo "ERROR: $GS_DIR not found." >&2; exit 1; }
[[ -d "$NSCF_DIR" ]] || { echo "ERROR: $NSCF_DIR not found. Run run_nscf_steps.sh first." >&2; exit 1; }
for f in CHGCAR POSCAR POTCAR KPOINTS; do
    [[ -s "$GS_DIR/$f" ]] || { echo "ERROR: $GS_DIR/$f missing or empty." >&2; exit 1; }
done

[[ -f "$SCF_TEMPLATE" ]] || { echo "ERROR: $SCF_TEMPLATE not found." >&2; exit 1; }
if grep -qE '^[[:space:]]*ICHARG[[:space:]]*=[[:space:]]*11' "$SCF_TEMPLATE"; then
    echo "ERROR: $SCF_TEMPLATE contains ICHARG=11. The SCF stage needs the charge to relax." >&2
    exit 1
fi

# model_job.sh validation
[[ -f "$MODEL_JOB" ]] || { echo "ERROR: $MODEL_JOB not found in current directory." >&2; exit 1; }
missing_directives=()
grep -qE '^[[:space:]]*#SBATCH[[:space:]]+-J[[:space:]]' "$MODEL_JOB" || missing_directives+=("-J")
grep -qE '^[[:space:]]*#SBATCH[[:space:]]+-o[[:space:]]' "$MODEL_JOB" || missing_directives+=("-o")
grep -qE '^[[:space:]]*#SBATCH[[:space:]]+-e[[:space:]]' "$MODEL_JOB" || missing_directives+=("-e")
if (( ${#missing_directives[@]} > 0 )); then
    echo "ERROR: $MODEL_JOB is missing #SBATCH directive(s): ${missing_directives[*]}" >&2
    echo "       Each must use the short form (-J, -o, -e)." >&2
    exit 1
fi

command -v sbatch >/dev/null 2>&1 \
    || { echo "ERROR: sbatch not found in PATH." >&2; exit 1; }

# --- Helpers (defined before they are used) ---------------------------------

# Does this NSCF OUTCAR contain LDA+U occupation data that is physically
# meaningful for U? Three markers must all be present:
#   - "LDAUTYPE"  -> confirms LDA+U is actually active for this run
#   - "aborting loop because EDIFF is reached"
#                -> the electronic loop CONVERGED under +alpha*Vext. This
#                   is the critical correctness check: if the loop did not
#                   converge, the occupations do not represent the perturbed
#                   state, and the Cococcioni response chi_0 from them is
#                   meaningless.
#   - "# of ion" -> the LORBIT=11 per-atom "total charge" table (s, p, d,
#                   [f], tot) was written. This block follows the EDIFF
#                   marker and contains the d-occupations we need.
# All three are printed BEFORE "writing wavefunctions", so they survive
# OOMs that hit during the wrap-up I/O phase.
has_ldau_occupation_info() {
    local outcar="$1"
    [[ -f "$outcar" ]] || return 1
    grep -q "LDAUTYPE"                                 "$outcar" 2>/dev/null || return 1
    grep -q "aborting loop because EDIFF is reached"   "$outcar" 2>/dev/null || return 1
    grep -qE '^[[:space:]]*#[[:space:]]*of[[:space:]]+ion' "$outcar" 2>/dev/null || return 1
    return 0
}

# --- Critical check: every NSCF run must be usable --------------------------
read -r -a ALPHA_ARRAY <<< "$ALPHAS"

if (( LENIENT )); then
    echo "  Verifying NSCF runs (--lenient: accept OUTCARs with occupation data)..."
else
    echo "  Verifying NSCF runs are complete..."
fi

missing=0
lenient_accepted=0
for alpha in "${ALPHA_ARRAY[@]}"; do
    label=$(LC_NUMERIC="C" printf "V_%+0.2f" "$alpha" | sed 's/\./p/')
    nscf_sub="$NSCF_DIR/$label"

    # OUTCAR must at least exist
    if [[ ! -f "$nscf_sub/OUTCAR" ]]; then
        echo "    MISSING OUTCAR: $nscf_sub"
        missing=1
    elif grep -q "General timing" "$nscf_sub/OUTCAR" 2>/dev/null; then
        : # cleanly finished, OK
    elif (( LENIENT )) && has_ldau_occupation_info "$nscf_sub/OUTCAR"; then
        echo "    LENIENT OK:     $nscf_sub (no 'General timing' but LDA+U occupation data present)"
        lenient_accepted=1
    else
        if (( LENIENT )); then
            echo "    UNUSABLE:       $nscf_sub (no 'General timing' AND no LDA+U occupation data)"
        else
            echo "    INCOMPLETE:     $nscf_sub (no 'General timing' in OUTCAR)"
        fi
        missing=1
    fi

    # WAVECAR must be non-empty (OOM'd runs typically still leave a usable
    # partial WAVECAR from the last completed electronic step).
    if [[ ! -s "$nscf_sub/WAVECAR" ]]; then
        echo "    MISSING:        $nscf_sub/WAVECAR"
        missing=1
    fi
done

if (( missing )); then
    echo "" >&2
    echo "ERROR: One or more NSCF calculations are not usable." >&2
    if (( ! LENIENT )); then
        echo "       If your OUTCARs contain the LDA+U occupation data already" >&2
        echo "       (e.g. jobs were killed late by OOM/walltime), retry with --lenient." >&2
    fi
    echo "       To re-run an incomplete alpha:" >&2
    echo "         cd $NSCF_DIR/V_<alpha> && sbatch job.slurm" >&2
    exit 1
fi

if (( lenient_accepted )); then
    echo "  All NSCF runs usable (some accepted via --lenient)."
    echo "  NOTE: WAVECARs from those runs are partial; SCF may need extra"
    echo "        electronic steps to converge but the result is unaffected."
else
    echo "  All NSCF runs complete."
fi

# --- Sanity check: occupations must differ across alphas --------------------
# The Cococcioni response chi_0 = dn/dalpha is *only* meaningful if VASP
# actually computed the perturbed occupations. We hash the LAST LORBIT=11
# "total charge" table from each NSCF OUTCAR; if those hashes are all
# identical, no atom's d-occupation changed across alphas, so the
# +alpha*Vext perturbation never took effect (e.g. jobs died before any
# electronic step under the perturbed potential finished).
echo ""
echo "  Sanity check: LORBIT=11 'total charge' table digest per alpha"
declare -a occ_values=()
for alpha in "${ALPHA_ARRAY[@]}"; do
    label=$(LC_NUMERIC="C" printf "V_%+0.2f" "$alpha" | sed 's/\./p/')
    outcar="$NSCF_DIR/$label/OUTCAR"

    # Extract the LORBIT=11 "total charge" table from the CONVERGED
    # electronic loop. Strategy: arm only after seeing
    #     aborting loop because EDIFF is reached
    # then capture the next "total charge" block (data rows only) until
    # the following "magnetization" header. Disarm after capture so any
    # later prints don't override. If the file has multiple ionic steps
    # (it shouldn't for an NSCF, but be safe) we keep the LAST converged
    # block. If the EDIFF marker never appears, the loop didn't converge
    # and we deliberately emit nothing -- the uniqueness check below will
    # then flag this run.
    table=$(awk '
        /aborting loop because EDIFF is reached/ { armed = 1; next }
        armed && /^[[:space:]]*total charge[[:space:]]*$/ {
            collecting = 1; buf = ""; next
        }
        collecting && /magnetization/ {
            last_buf = buf; collecting = 0; armed = 0; next
        }
        collecting && /^[[:space:]]*[0-9]+[[:space:]]+[0-9]/ {
            buf = buf $0 "\n"
        }
        END {
            if (collecting && buf != "") last_buf = buf
            printf "%s", last_buf
        }
    ' "$outcar" 2>/dev/null || true)

    if [[ -z "$table" ]]; then
        digest=""
        printf "    alpha = %+5.2f eV  ->  <no converged LORBIT=11 table>\n" "$alpha"
    else
        digest=$(printf '%s' "$table" | md5sum | awk '{print $1}')
        # 8-char prefix is plenty to spot duplicates by eye.
        printf "    alpha = %+5.2f eV  ->  table digest: %s\n" \
               "$alpha" "${digest:0:8}"
    fi
    occ_values+=("$digest")
done

# Catch the unconverged case explicitly: any empty digest means that run's
# electronic loop never converged under +alpha*Vext, so its occupations
# don't represent the perturbed state.
empty_count=0
for v in "${occ_values[@]}"; do
    [[ -z "$v" ]] && (( ++empty_count )) || true
done
if (( empty_count > 0 )); then
    echo "" >&2
    echo "ERROR: $empty_count NSCF run(s) lack a converged LORBIT=11 table." >&2
    echo "       VASP never printed 'aborting loop because EDIFF is reached'" >&2
    echo "       for those alphas, so the electronic loop didn't converge" >&2
    echo "       under the perturbed potential. Their occupations are NOT" >&2
    echo "       physically meaningful for the U calculation." >&2
    echo "       Rerun the affected alphas (more NELM, looser EDIFF, or" >&2
    echo "       investigate why convergence failed)." >&2
    exit 1
fi

unique=$(printf '%s\n' "${occ_values[@]}" | grep -v '^$' | sort -u | wc -l)
if (( unique <= 1 )); then
    echo "" >&2
    echo "ERROR: All NSCF LORBIT=11 charge tables are identical." >&2
    echo "       The +alpha*Vext perturbation never took effect -- jobs likely" >&2
    echo "       died before any electronic step under the perturbed potential" >&2
    echo "       finished, so the OUTCARs only contain the unperturbed GS" >&2
    echo "       occupation. Rerun the NSCF stage with more memory/walltime." >&2
    exit 1
fi
echo "  OK: per-atom occupations vary across alphas."

# --- Helpers ----------------------------------------------------------------

alpha_label() {
    LC_NUMERIC="C" printf "V_%+0.2f" "$1" | sed 's/\./p/'
}

write_job_script() {
    local model="$1" out="$2" jobname="$3"
    awk -v jn="$jobname" '
        BEGIN { didJ=0; didO=0; didE=0 }
        /^[[:space:]]*#SBATCH[[:space:]]+-J[[:space:]]/ && !didJ {
            print "#SBATCH -J " jn; didJ=1; next
        }
        /^[[:space:]]*#SBATCH[[:space:]]+-o[[:space:]]/ && !didO {
            print "#SBATCH -o " jn "_%j.out"; didO=1; next
        }
        /^[[:space:]]*#SBATCH[[:space:]]+-e[[:space:]]/ && !didE {
            print "#SBATCH -e " jn "_%j.err"; didE=1; next
        }
        { print }
    ' "$model" > "$out"
    chmod +x "$out"
}

# --- Main loop --------------------------------------------------------------
mkdir -p "$SCF_DIR"
gs_abs=$(readlink -f "$GS_DIR")

echo ""
echo "Submitting ${#ALPHA_ARRAY[@]} SCF jobs (model: $MODEL_JOB)..."

for alpha in "${ALPHA_ARRAY[@]}"; do

    label=$(alpha_label "$alpha")
    sub_dir="$SCF_DIR/$label"
    nscf_sub="$NSCF_DIR/$label"
    nscf_abs=$(readlink -f "$nscf_sub")
    job_name="${JOB_PREFIX}_${label}"

    echo ""
    echo "  alpha = $alpha eV  ->  $sub_dir"

    if [[ -f "$sub_dir/OUTCAR" ]] && grep -q "General timing" "$sub_dir/OUTCAR" 2>/dev/null; then
        echo "    Already complete (General timing in OUTCAR). Skipping."
        continue
    fi

    if [[ ! -d "$sub_dir" ]]; then
        mkdir -p "$sub_dir"

        # Symlink large/read-only inputs to save disk.
        ln -sf "$gs_abs/CHGCAR"     "$sub_dir/CHGCAR"
        ln -sf "$gs_abs/POSCAR"     "$sub_dir/POSCAR"
        ln -sf "$gs_abs/POTCAR"     "$sub_dir/POTCAR"
        ln -sf "$gs_abs/KPOINTS"    "$sub_dir/KPOINTS"
        # WAVECAR comes from the matching NSCF run (faster restart).
        ln -sf "$nscf_abs/WAVECAR"  "$sub_dir/WAVECAR"

        cp "$SCF_TEMPLATE" "$sub_dir/INCAR"
        ldauu_line="${LDAUU_TEMPLATE//\{alpha\}/$alpha}"
        ldauj_line="${LDAUJ_TEMPLATE//\{alpha\}/$alpha}"
        {
            echo ""
            echo "# Cococcioni linear-response perturbation (alpha = $alpha eV)"
            echo "LDAUL = $LDAUL"
            echo "LDAUU = $ldauu_line"
            echo "LDAUJ = $ldauj_line"
        } >> "$sub_dir/INCAR"

        write_job_script "$MODEL_JOB" "$sub_dir/job.slurm" "$job_name"

        echo "    Inputs and job.slurm prepared."
    else
        echo "    Directory exists; reusing existing inputs."
    fi

    if (( DRY_RUN )); then
        echo "    [dry-run] would submit: sbatch $sub_dir/job.slurm"
    else
        ( cd "$sub_dir" && sbatch job.slurm )
    fi
done

echo ""
echo "All SCF jobs submitted (or prepared in --dry-run mode)."
echo "Monitor with:  squeue -u \$USER"
echo "Once all jobs finish, run:  collect-u-data --lenient"
