#!/usr/bin/env bash
###############################################################################
# run_nscf_steps.sh
#
# Step 1 of 4 -- Cococcioni linear-response Hubbard U workflow
#
# Prepares and submits one SLURM job per alpha value for the NON-SELF-
# CONSISTENT (NSCF) response stage. All alpha jobs run in parallel.
#
# WORKFLOW (4 steps; run them in order)
#   Step 1: run_nscf_steps.sh   <-- THIS SCRIPT
#   Step 2: run_scf_steps.sh    (after all NSCF jobs finish)
#   Step 3: collect_u_data.sh   (after all SCF jobs finish)
#   Step 4: vasp_calculate_u.py        (linear fit -> U value)
#
# WHAT IT DOES
#   For each alpha in the grid, creates a subdirectory under
#   02_NonselfconsistentResponse/V_<alpha>/ with:
#     - CHGCAR, WAVECAR, POSCAR, POTCAR, KPOINTS  (symlinked from 01_Groundstate/)
#     - INCAR  (copied from INCAR.nscf.template, then the per-alpha LDAU block
#               -- LDAUU = LDAUU_TEMPLATE{alpha}, LDAUJ = LDAUJ_TEMPLATE{alpha}
#               -- is appended)
#     - job.slurm  (copy of model_job.sh with -J/-o/-e rewritten per alpha)
#   Then submits each job.slurm with sbatch. Already-complete runs are skipped.
#
# REQUIRED INPUTS (in the current directory)
#   01_Groundstate/      Converged DFT ground state (CHGCAR, WAVECAR, POSCAR,
#                        POTCAR, KPOINTS). The perturbed atom must be its own
#                        species in POSCAR/POTCAR (see VASP wiki: Calculate_U).
#   INCAR.nscf.template  Base INCAR for the NSCF runs. Must contain ICHARG=11.
#                        Must NOT set LDAUL, LDAUU, or LDAUJ (appended per-alpha).
#   model_job.sh         SLURM script template with #SBATCH -J, -o, -e lines
#                        (short-form only). The body (modules, srun command)
#                        is copied verbatim into every V_<alpha>/job.slurm.
#
# QUICK START
#   run_nscf_steps.sh --ldaul "2 -1 -1" \
#                     --ldauu-template "{alpha} 0 0" \
#                     --ldauj-template "{alpha} 0 0"
#   # use {alpha} as the placeholder for the perturbation value
#
# SEE ALSO: run_scf_steps.sh --help
###############################################################################

set -euo pipefail

# --- Defaults ---------------------------------------------------------------
GS_DIR="01_Groundstate"
NSCF_DIR="02_NonselfconsistentResponse"
NSCF_TEMPLATE="INCAR.nscf.template"
MODEL_JOB="model_job.sh"
ALPHAS="-0.20 -0.15 -0.10 -0.05 0.05 0.10 0.15 0.20"
JOB_PREFIX="U_nscf"

LDAUL=""
LDAUU_TEMPLATE=""
LDAUJ_TEMPLATE=""
DRY_RUN=0
# ----------------------------------------------------------------------------

print_help() {
    cat <<'EOF'
run_nscf_steps.sh -- Step 1 of 4: submit NSCF perturbation jobs for the
                     Cococcioni linear-response Hubbard U calculation.

WORKFLOW
  Step 1: run_nscf_steps.sh   <-- THIS SCRIPT
  Step 2: run_scf_steps.sh    (after all NSCF jobs finish)
  Step 3: collect_u_data.sh   (after all SCF jobs finish)
  Step 4: vasp_calculate_u.py        (python vasp_calculate_u.py -> prints U)

USAGE
  run_nscf_steps.sh --ldaul "VALS" \
                    --ldauu-template "VALS" --ldauj-template "VALS" \
                    [options]

REQUIRED
  --ldaul "VALS"           LDAUL line (one integer per species, e.g. "2 -1 -1").
                           Use the angular-momentum quantum number of the shell
                           you are computing U for (d=2, f=3); -1 = inactive.
  --ldauu-template "VALS"  LDAUU values, using {alpha} as the per-alpha
                           placeholder (e.g. "{alpha} 0 0").
  --ldauj-template "VALS"  LDAUJ values, same structure as --ldauu-template.
                           Both templates must place {alpha} on the same species.

OPTIONS
  --alphas "V1 V2 ..."     Alpha perturbation grid (eV).
                           Default: -0.20 -0.15 -0.10 -0.05 0.05 0.10 0.15 0.20
  --gs-dir DIR             Ground-state directory (default: 01_Groundstate).
  --nscf-dir DIR           Output directory (default: 02_NonselfconsistentResponse).
  --template FILE          NSCF INCAR template (default: INCAR.nscf.template).
                           Must contain ICHARG=11. Must NOT set LDAUL/LDAUU/LDAUJ.
  --model-job FILE         SLURM template (default: model_job.sh).
  --job-prefix NAME        SLURM job-name prefix (default: U_nscf).
                           Each alpha job is named <prefix>_V_<alpha>.
  --dry-run                Prepare directories and job.slurm files but do NOT
                           call sbatch. Useful for inspection before committing.
  -h, --help               Show this help.

REQUIREMENTS FOR model_job.sh
  Must contain (short-form #SBATCH flags only):
      #SBATCH -J <some-name>
      #SBATCH -o <some-pattern>
      #SBATCH -e <some-pattern>
  These three lines are rewritten per-alpha; everything else is copied verbatim.

NEXT STEP
  Monitor jobs:  squeue -u $USER
  When all finish, run:
    run_scf_steps.sh --ldaul "..." --ldauu-template "..." --ldauj-template "..."
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)         print_help; exit 0 ;;
        --alphas)          ALPHAS="$2";          shift 2 ;;
        --gs-dir)          GS_DIR="$2";          shift 2 ;;
        --nscf-dir)        NSCF_DIR="$2";        shift 2 ;;
        --template)        NSCF_TEMPLATE="$2";   shift 2 ;;
        --model-job)       MODEL_JOB="$2";       shift 2 ;;
        --job-prefix)      JOB_PREFIX="$2";      shift 2 ;;
        --ldaul)           LDAUL="$2";           shift 2 ;;
        --ldauu-template)  LDAUU_TEMPLATE="$2";  shift 2 ;;
        --ldauj-template)  LDAUJ_TEMPLATE="$2";  shift 2 ;;
        --dry-run)         DRY_RUN=1;            shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Validation -------------------------------------------------------------
echo "Pre-flight checks..."

[[ -n "$LDAUL" && -n "$LDAUU_TEMPLATE" && -n "$LDAUJ_TEMPLATE" ]] \
    || { echo "ERROR: --ldaul, --ldauu-template, --ldauj-template are required." >&2
         echo "Run with --help for usage." >&2; exit 1; }

[[ "$LDAUU_TEMPLATE" == *"{alpha}"* && "$LDAUJ_TEMPLATE" == *"{alpha}"* ]] \
    || { echo "ERROR: LDAUU/LDAUJ templates must contain {alpha} placeholder." >&2; exit 1; }

[[ -d "$GS_DIR" ]] || { echo "ERROR: $GS_DIR not found." >&2; exit 1; }
for f in CHGCAR WAVECAR POSCAR POTCAR KPOINTS; do
    [[ -s "$GS_DIR/$f" ]] || { echo "ERROR: $GS_DIR/$f missing or empty." >&2; exit 1; }
done

[[ -f "$NSCF_TEMPLATE" ]] || { echo "ERROR: $NSCF_TEMPLATE not found." >&2; exit 1; }
grep -qE '^[[:space:]]*ICHARG[[:space:]]*=[[:space:]]*11' "$NSCF_TEMPLATE" \
    || { echo "ERROR: $NSCF_TEMPLATE must contain ICHARG=11." >&2; exit 1; }

# --- model_job.sh validation ------------------------------------------------
[[ -f "$MODEL_JOB" ]] || { echo "ERROR: $MODEL_JOB not found in current directory." >&2
                          echo "Provide a SLURM template (or use --model-job FILE)." >&2; exit 1; }

# Require -J, -o, -e directives. Accept both short ("-J") and long ("--job-name")
# forms; we only rewrite the short forms, but warn if the user uses long forms.
missing_directives=()
grep -qE '^[[:space:]]*#SBATCH[[:space:]]+-J[[:space:]]'        "$MODEL_JOB" || missing_directives+=("-J")
grep -qE '^[[:space:]]*#SBATCH[[:space:]]+-o[[:space:]]'        "$MODEL_JOB" || missing_directives+=("-o")
grep -qE '^[[:space:]]*#SBATCH[[:space:]]+-e[[:space:]]'        "$MODEL_JOB" || missing_directives+=("-e")
if (( ${#missing_directives[@]} > 0 )); then
    echo "ERROR: $MODEL_JOB is missing required #SBATCH directive(s): ${missing_directives[*]}" >&2
    echo "       Each must use the short form (-J, -o, -e). Example:" >&2
    echo "         #SBATCH -J my_job" >&2
    echo "         #SBATCH -o my_job_%j.out" >&2
    echo "         #SBATCH -e my_job_%j.err" >&2
    exit 1
fi

command -v sbatch >/dev/null 2>&1 \
    || { echo "ERROR: sbatch not found in PATH." >&2; exit 1; }

echo "  All checks passed."

# --- Helpers ----------------------------------------------------------------

# Convert numeric alpha to a directory-safe label, e.g. -0.20 -> V_-0p20.
alpha_label() {
    LC_NUMERIC="C" printf "V_%+0.2f" "$1" | sed 's/\./p/'
}

# Generate a per-alpha job script by rewriting the -J/-o/-e directives in
# the model. Body of the model is preserved verbatim. Args:
#   $1 = path to model_job.sh
#   $2 = path to output job script
#   $3 = job name (e.g. U_nscf_V_-0p20)
write_job_script() {
    local model="$1" out="$2" jobname="$3"
    # awk substitutes the three directives. Only the FIRST occurrence of
    # each is replaced (defensive, in case the user duplicates a directive).
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
read -r -a ALPHA_ARRAY <<< "$ALPHAS"
mkdir -p "$NSCF_DIR"
gs_abs=$(readlink -f "$GS_DIR")

echo ""
echo "Submitting ${#ALPHA_ARRAY[@]} NSCF jobs (model: $MODEL_JOB)..."

for alpha in "${ALPHA_ARRAY[@]}"; do

    label=$(alpha_label "$alpha")
    sub_dir="$NSCF_DIR/$label"
    job_name="${JOB_PREFIX}_${label}"

    echo ""
    echo "  alpha = $alpha eV  ->  $sub_dir"

    # Skip already-completed runs so failures can be retried individually.
    if [[ -f "$sub_dir/OUTCAR" ]] && grep -q "General timing" "$sub_dir/OUTCAR" 2>/dev/null; then
        echo "    Already complete (General timing in OUTCAR). Skipping."
        continue
    fi

    if [[ ! -d "$sub_dir" ]]; then
        mkdir -p "$sub_dir"

        # Symlink large/read-only inputs to save disk. VASP rewrites these
        # files in-place using open(...,status='replace'), which deletes
        # the symlink first -- so the GS originals are not modified.
        ln -sf "$gs_abs/CHGCAR"  "$sub_dir/CHGCAR"
        ln -sf "$gs_abs/WAVECAR" "$sub_dir/WAVECAR"
        ln -sf "$gs_abs/POSCAR"  "$sub_dir/POSCAR"
        ln -sf "$gs_abs/POTCAR"  "$sub_dir/POTCAR"
        ln -sf "$gs_abs/KPOINTS" "$sub_dir/KPOINTS"

        # INCAR is a real file: we append the per-alpha LDAU block.
        cp "$NSCF_TEMPLATE" "$sub_dir/INCAR"
        ldauu_line="${LDAUU_TEMPLATE//\{alpha\}/$alpha}"
        ldauj_line="${LDAUJ_TEMPLATE//\{alpha\}/$alpha}"
        {
            echo ""
            echo "# Cococcioni linear-response perturbation (alpha = $alpha eV)"
            echo "LDAUL = $LDAUL"
            echo "LDAUU = $ldauu_line"
            echo "LDAUJ = $ldauj_line"
        } >> "$sub_dir/INCAR"

        # Per-alpha SLURM script derived from model_job.sh.
        write_job_script "$MODEL_JOB" "$sub_dir/job.slurm" "$job_name"

        echo "    Inputs and job.slurm prepared."
    else
        echo "    Directory exists; reusing existing inputs."
    fi

    if (( DRY_RUN )); then
        echo "    [dry-run] would submit: sbatch $sub_dir/job.slurm"
    else
        # cd into sub_dir so SLURM_SUBMIT_DIR is the calculation dir
        ( cd "$sub_dir" && sbatch job.slurm )
    fi
done

echo ""
echo "All NSCF jobs submitted (or prepared in --dry-run mode)."
echo "Monitor with:  squeue -u \$USER"
echo "Once all jobs finish, run:  run-scf-steps  (with the same arguments)"
