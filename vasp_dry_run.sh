#!/bin/bash
###############################################################################
# vasp_dry_run.sh   (invoked on PATH as: vasp-dry-run)
#
# Submit a one-rank VASP dry run to your cluster's DEBUG partition. The
# resulting OUTCAR feeds vasp_recommend_slurm.py (vasp-recommend-slurm), which
# uses it to predict memory and suggest the best parallelization setup.
#
# CLUSTER PROFILE
#   Partition, notification email and the VASP module(s) to load all come from
#   the profile written by `vasp-configure` (~/.config/wolfpack-dft/cluster.conf).
#   If no profile exists, built-in NLHPC defaults are used.
#
# WHAT IT DOES
#   Runs "vasp_std --dry-run" on 1 MPI rank: VASP initialises all arrays, writes
#   its full memory table to OUTCAR, then exits without electronic iterations.
#
# USAGE
#   cd <dir with INCAR / POSCAR / POTCAR / KPOINTS>
#   vasp-dry-run            # self-submits to the configured debug partition
#   # (sbatch vasp-dry-run also works, but uses the cluster's default partition)
#
# PART OF: dry-run / parallelization workflow
#   Step 1: vasp-dry-run                   <-- THIS SCRIPT
#   Step 2: vasp-recommend-slurm OUTCAR
###############################################################################
#SBATCH --job-name=vasp_dryrun
#SBATCH -n 1
#SBATCH --ntasks-per-node=1
#SBATCH -c 1
#SBATCH --mem-per-cpu=8000
#SBATCH -t 00:30:00
#SBATCH -o vasp_dryrun_%j.out
#SBATCH -e vasp_dryrun_%j.err
# (partition and --mail-user are added at submit time from the cluster profile)

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,29p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
    exit 0
fi

set -uo pipefail

# --- Load the cluster profile (if present) --------------------------------- #
_wp_conf="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
# shellcheck source=/dev/null
[[ -f "$_wp_conf" ]] && source "$_wp_conf"

# --- Submit side: not yet under SLURM -> resubmit self with profile flags --- #
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    part="${WP_DEBUG_PARTITION:-debug}"
    sb=(-p "$part")
    [[ -n "${WP_EMAIL:-}" ]] && sb+=(--mail-user="$WP_EMAIL" --mail-type=ALL)
    if ! command -v sbatch >/dev/null 2>&1; then
        echo "ERROR: sbatch not found. Run this on a cluster login node." >&2
        exit 1
    fi
    echo "Submitting 1-rank VASP dry run to partition '$part' ..." >&2
    exec sbatch "${sb[@]}" "$0" "$@"
fi

# --- Job side: load modules and run the dry run ---------------------------- #
cd "$SLURM_SUBMIT_DIR" || exit 1

_wp_load_modules() {
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        local cmd="${WP_MODULE_CMD:-ml}"
        if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
            { [[ "$cmd" == "module" ]] && module purge || ml purge; } 2>/dev/null || true
        fi
        # word-split WP_VASP_MODULES into individual module args on purpose
        # shellcheck disable=SC2086
        if [[ "$cmd" == "module" ]]; then module load $WP_VASP_MODULES
        else ml $WP_VASP_MODULES; fi
    else                                   # built-in NLHPC default
        ml purge 2>/dev/null || true
        ml gcc/14.2.0-zen4-y 2>/dev/null || true
        ml vasp/6.4.3-mpi-openmp-h5-zen4-c 2>/dev/null || true
    fi
}
_wp_load_modules

EXE="${WP_VASP_STD:-vasp_std}"
srun -n 1 "$EXE" --dry-run
