#!/usr/bin/env bash
###############################################################################
# vasp_test.sh   (invoked on PATH as: vasp-test)
#
# Short VASP RESOURCE BENCHMARK on your cluster's debug partition.
#
# CLUSTER PROFILE
#   The debug partition name, cores/node, memory/node, notification email and
#   the VASP module(s) to load all come from the profile written by
#   `vasp-configure` (~/.config/wolfpack-dft/cluster.conf). Built-in NLHPC
#   defaults are used if no profile exists.
#
# WHAT IT DOES
#   Submits a real (not dry-run) VASP calculation for a fixed, short wall time
#   (default 11 minutes) on ONE whole debug node (cores/memory from your cluster
#   profile). While it runs, the SLURM cgroup records the true peak memory per
#   rank and the CPU efficiency of YOUR current INCAR parallel settings. When
#   the budget is up the run is stopped and the script:
#
#     1. Reads the SLURM accounting metrics (MaxRSS, CPU efficiency), the
#        parallel layout the run used, and the OUTCAR memory breakdown.
#     2. Builds the production recommendation from those MEASURED numbers
#        (memory anchored to MaxRSS, KPAR/NCORE/NSIM from the run) -- it does
#        NOT re-run vasp-recommend's model.
#     3. Writes a ready-to-submit MAIN-partition SLURM script + an INCAR snippet
#        (KPAR / NCORE / NSIM), sized to your cluster's memory policies.
#
#   The benchmark runs inside a fresh sub-directory (vasp_test_<jobid>/) built
#   from copies of your inputs, so your existing OUTCAR/WAVECAR/etc. are never
#   touched.
#
#   The production recommendation is built FROM THE MEASUREMENT: per-rank memory
#   is anchored to the SLURM MaxRSS the job actually used (then scaled to the
#   production layout), KPAR/NCORE/NSIM come from the run, and the memory REQUEST
#   honours your cluster policies (>=80% utilisation; a per-node reserve kept
#   free on the debug/login node). It is NOT a re-run of vasp-recommend's model.
#
# USAGE
#   cd <dir with INCAR / POSCAR / POTCAR / KPOINTS>
#   vasp-test                        # 1 debug node; renders ./slurm_vasptest.sh
#                                    # (the exact job), submits it, then writes
#                                    # slurm_job.sh + INCAR.parallel from the run.
#   vasp-test --debug-nodes 2        # use BOTH debug nodes (96 ranks, 48/node)
#   vasp-test --prod-ranks 256       # size the production job for 256 ranks
#
# FLAGS
#   --debug-nodes N   debug nodes to reserve for the benchmark (default 1;
#                     2 -> 96 ranks across 2 nodes, 48 per node).
#   --prod-ranks N    total MPI ranks to size the production job for
#                     (default: auto = your account core cap).
#
#   Tunables (export before running):
#     VASP_TEST_MINUTES=11          # length of the timed run (<= ~25 on debug)
#     VASP_EXE=vasp_std             # vasp_std | vasp_gam | vasp_ncl
#     VASP_TEST_MEM_UTIL=0.80       # request memory so usage >= this fraction
#     VASP_TEST_DEBUG_MARGIN_MB=16384  # memory kept free per debug/login node
#     VASP_TEST_PROD_TIME=7-00:00:00   # --time of the production job
#
#   The advice is printed to the job's .out file (vasp_test-<jobid>.out) and
#   saved as slurm_job.sh + INCAR.parallel in your submit directory.
#
# REQUIREMENTS
#   - SLURM job accounting (sacct/MaxRSS) enabled -> the memory is anchored to
#     the measured peak. If it is off, it falls back to VASP's own memory table.
###############################################################################

# --- Allow `vasp-test --help` to work outside of SLURM (handled in the parser
#     below too; this early check keeps --help working before set -u) ---------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,63p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
    exit 0
fi

#----------------------- SBATCH fallback defaults -----------------------------
# These apply ONLY if you run `sbatch vasp-test` directly. The normal entry
# point `vasp-test` re-submits with cores/memory/partition/email taken from
# your cluster profile (vasp-configure) instead.
#SBATCH --job-name=vasp_test
#SBATCH --nodes=1
#SBATCH --time=00:18:00
#SBATCH --output=vasp_test-%j.out
#SBATCH --error=vasp_test-%j.err
#------------------------------------------------------------------------------

set -uo pipefail

# --- Load the cluster profile (vasp-configure) ----------------------------- #
_wp_conf="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
# shellcheck source=/dev/null
[[ -f "$_wp_conf" ]] && source "$_wp_conf"

TEST_MINUTES="${VASP_TEST_MINUTES:-11}"
DEBUG_MARGIN_MB="${VASP_TEST_DEBUG_MARGIN_MB:-16384}"   # keep free on debug node
MEM_UTIL="${VASP_TEST_MEM_UTIL:-0.80}"                  # request so use >= this frac
DEBUG_NODES="${VASP_TEST_DEBUG_NODES:-1}"               # how many debug nodes to use
PROD_RANKS="${VASP_TEST_PROD_RANKS:-0}"                 # 0 = auto (cap at max-cores)

# Submit-side flags (the rendered job re-enters with no args, so on the job side
# these stay at their env-provided values, which the wrapper exports).
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug-nodes) DEBUG_NODES="${2:?--debug-nodes needs a number}"; shift 2 ;;
        --prod-ranks)  PROD_RANKS="${2:?--prod-ranks needs a number}"; shift 2 ;;
        -h|--help)     sed -n '2,63p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "vasp-test: unknown option '$1' (try --help)" >&2; shift ;;
    esac
done

# Emit the resolved module-load command lines (baked into the rendered job
# script; the body skips its own loading when WP_MODULES_PRELOADED is set).
_wp_module_block() {
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        local cmd="${WP_MODULE_CMD:-ml}"
        if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
            [[ "$cmd" == "module" ]] && echo "module purge" || echo "ml purge"
        fi
        if [[ "$cmd" == "module" ]]; then echo "module load ${WP_VASP_MODULES}"
        else echo "ml ${WP_VASP_MODULES}"; fi
    else                                   # built-in NLHPC default
        echo "ml purge"
        echo "ml gcc/14.2.0-zen4-y"
        echo "ml vasp/6.4.3-mpi-openmp-h5-zen4-c"
    fi
}

# --- Submit side: render a self-contained job script and submit it --------- #
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    if ! command -v sbatch >/dev/null 2>&1; then
        echo "ERROR: sbatch not found. Run on a cluster login node." >&2; exit 1
    fi
    part="${WP_DEBUG_PARTITION:-debug}"
    cpn="${WP_DEBUG_CPUS_PER_NODE:-48}"
    nodes="$DEBUG_NODES"; (( nodes < 1 )) && nodes=1
    n=$(( cpn * nodes ))                                  # total ranks
    memnode="${WP_DEBUG_MEM_PER_NODE_MB:-360000}"
    # Leave a reserve free on each debug node (it doubles as the login node).
    usable=$(( memnode - DEBUG_MARGIN_MB )); (( usable < cpn )) && usable=$memnode
    mempc=$(( usable / cpn )); (( mempc < 100 )) && mempc=100
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    job="$PWD/slurm_vasptest.sh"
    {
        echo "#!/bin/bash"
        echo "#SBATCH --job-name=vasp_test"
        echo "#SBATCH --partition=${part}"
        echo "#SBATCH --nodes=${nodes}"
        echo "#SBATCH --ntasks=${n}"
        echo "#SBATCH --ntasks-per-node=${cpn}"
        echo "#SBATCH --cpus-per-task=1"
        echo "#SBATCH --mem-per-cpu=${mempc}"
        echo "#SBATCH --time=00:18:00"
        if [[ -n "${WP_EMAIL:-}" ]]; then
            echo "#SBATCH --mail-user=${WP_EMAIL}"
            echo "#SBATCH --mail-type=ALL"
        fi
        echo "#SBATCH --output=vasp_test-%j.out"
        echo "#SBATCH --error=vasp_test-%j.err"
        echo ""
        echo "# Generated by vasp-test on $(date -Iseconds) -- the exact job submitted."
        echo 'cd "$SLURM_SUBMIT_DIR"'
        echo ""
        echo "# --- modules (resolved from your cluster profile) ---"
        _wp_module_block
        echo ""
        echo "# Run the benchmark + analysis body of the installed vasp-test."
        echo "export VASP_TEST_MINUTES='${TEST_MINUTES}'"
        echo "export VASP_TEST_PROD_RANKS='${PROD_RANKS}'"
        echo "export VASP_TEST_DEBUG_NODES='${nodes}'"
        echo "export WP_MODULES_PRELOADED=1"
        echo "exec '${self}'"
    } > "$job"
    chmod +x "$job"
    echo "Wrote job script : $job" >&2
    echo "Submitting ${TEST_MINUTES}-min VASP benchmark: partition '${part}', ${nodes} node(s) x ${cpn} = ${n} ranks, ${mempc} MB/cpu (${DEBUG_MARGIN_MB} MB/node reserved) ..." >&2
    exec sbatch "$job"
fi

# --------------------------------------------------------------------------- #
# Job side: configuration (overridable via environment / cluster profile)
# --------------------------------------------------------------------------- #
VASP_EXE="${VASP_EXE:-${WP_VASP_STD:-vasp_std}}"
EMAIL="${VASP_TEST_EMAIL:-${WP_EMAIL:-}}"
JOBNAME="${VASP_TEST_JOBNAME:-VASP}"
NTASKS="${SLURM_NTASKS:-48}"
NTPN="${SLURM_NTASKS_PER_NODE:-$NTASKS}"
PARTITION="${SLURM_JOB_PARTITION:-${WP_DEBUG_PARTITION:-debug}}"
NODE_MEM_MB="${WP_DEBUG_MEM_PER_NODE_MB:-$(( NTPN * 7500 ))}"

SUBMIT_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
cd "$SUBMIT_DIR" || { echo "Cannot cd to submit dir $SUBMIT_DIR" >&2; exit 1; }

rule() { printf '%.0s-' {1..78}; echo; }
hdr()  { echo; rule; echo " $*"; rule; }
posq() { awk -v v="${1:-0}" 'BEGIN{exit !(v>0)}'; }   # true if $1 is a positive number

# --------------------------------------------------------------------------- #
# 1. Validate inputs and build an isolated run directory
# --------------------------------------------------------------------------- #
need=(INCAR POSCAR POTCAR KPOINTS)
missing=0
for f in "${need[@]}"; do
    [[ -s "$SUBMIT_DIR/$f" ]] || { echo "ERROR: missing or empty $f in $SUBMIT_DIR" >&2; missing=1; }
done
[[ $missing -eq 0 ]] || { echo "Aborting: provide INCAR/POSCAR/POTCAR/KPOINTS." >&2; exit 1; }

RUNDIR="$SUBMIT_DIR/vasp_test_${SLURM_JOB_ID}"
mkdir -p "$RUNDIR"
cp -f "$SUBMIT_DIR"/INCAR "$SUBMIT_DIR"/POSCAR "$SUBMIT_DIR"/POTCAR "$SUBMIT_DIR"/KPOINTS "$RUNDIR/"
cd "$RUNDIR" || { echo "Cannot enter run dir $RUNDIR" >&2; exit 1; }

# Make the test cheap on I/O: never write WAVECAR/CHGCAR during the benchmark.
# (Append-and-let-VASP-take-the-last-value; we do not alter your real INCAR.)
{
    echo ""
    echo "# ---- appended by vasp-test (benchmark only; harmless duplicates) ----"
    echo "LWAVE  = .FALSE."
    echo "LCHARG = .FALSE."
} >> INCAR

hdr "VASP RESOURCE BENCHMARK  (${PARTITION}, ${NTASKS} ranks, ${TEST_MINUTES} min)"
echo "  job id        : $SLURM_JOB_ID"
echo "  run directory : $RUNDIR"
echo "  executable    : $VASP_EXE"
echo "  inputs tested : your current INCAR parallel settings (KPAR/NCORE if set)"
echo "  start         : $(date)"

# --------------------------------------------------------------------------- #
# 2. Modules / environment (from the cluster profile; same build you will use
#    on the main partition, so the benchmark is representative). The rendered
#    slurm_vasptest.sh wrapper normally loads these already (WP_MODULES_PRELOADED).
# --------------------------------------------------------------------------- #
if [[ -z "${WP_MODULES_PRELOADED:-}" ]]; then
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        _wpcmd="${WP_MODULE_CMD:-ml}"
        if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
            { [[ "$_wpcmd" == "module" ]] && module purge || ml purge; } 2>/dev/null || true
        fi
        # shellcheck disable=SC2086
        if [[ "$_wpcmd" == "module" ]]; then module load $WP_VASP_MODULES
        else ml $WP_VASP_MODULES; fi
    else                                   # built-in NLHPC default
        ml purge                              2>/dev/null || true
        ml gcc/14.2.0-zen4-y                  2>/dev/null || true
        ml vasp/6.4.3-mpi-openmp-h5-zen4-c    2>/dev/null || true
    fi
fi
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
# extra environment exports from the cluster profile (e.g. OMPI/MKL pinning)
if [[ -n "${WP_EXTRA_ENV:-}" ]]; then
    IFS=';' read -r -a _wpenv <<< "$WP_EXTRA_ENV"
    for _e in "${_wpenv[@]}"; do [[ -n "${_e// }" ]] && eval "$_e" 2>/dev/null || true; done
fi

# --------------------------------------------------------------------------- #
# 3. Run VASP for at most TEST_MINUTES, then stop it
# --------------------------------------------------------------------------- #
hdr "RUNNING VASP (timed)"
run_start=$(date +%s)
# --signal=TERM lets VASP exit at the next safe point; --kill-after forces it.
timeout --signal=TERM --kill-after=30s "${TEST_MINUTES}m" \
    srun --cpu-bind=cores "$VASP_EXE"
rc=$?
run_end=$(date +%s)
wall=$(( run_end - run_start ))
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "  VASP reached the ${TEST_MINUTES}-minute benchmark limit and was stopped (expected)."
elif [[ $rc -eq 0 ]]; then
    echo "  VASP finished on its own before the limit (small system) -- metrics still valid."
else
    echo "  VASP exited with code $rc -- metrics below may be partial."
fi
echo "  measured wall time: ${wall}s"

OUTCAR="$RUNDIR/OUTCAR"
[[ -s "$OUTCAR" ]] || { echo "ERROR: no OUTCAR produced -- cannot analyse." >&2; exit 1; }

# --------------------------------------------------------------------------- #
# 4. Gather SLURM accounting metrics (poll: accounting can lag a few seconds)
# --------------------------------------------------------------------------- #
hdr "MEASURED RESOURCE USAGE"
RAW=""
if command -v sacct >/dev/null 2>&1; then
    for _ in $(seq 1 15); do
        RAW=$(sacct -j "$SLURM_JOB_ID" -n -P \
                -o JobID,State,Elapsed,TotalCPU,NCPUS,MaxRSS 2>/dev/null)
        if printf '%s\n' "$RAW" | awk -F'|' '$6!="" && $6!~/^0?$/{f=1} END{exit !f}'; then
            break
        fi
        sleep 3
    done
fi

# Parse: peak MaxRSS (MB) across all steps; CPU efficiency from the VASP step.
read -r maxrss_mb step_elapsed_s step_cpu_s step_ncpus <<<"$(
    printf '%s\n' "$RAW" | awk -F'|' '
    function to_mb(x,  u,n){ if(x==""||x=="0")return 0;
        u=substr(x,length(x),1);
        if(u ~ /[KMGT]/){ n=substr(x,1,length(x)-1)+0 } else { n=x+0; u="K" }
        if(u=="K")return n/1024.0; if(u=="M")return n;
        if(u=="G")return n*1024.0; if(u=="T")return n*1048576.0; return n/1024.0 }
    function to_s(t,  d,a,n,s){ if(t=="")return 0; s=0;
        n=split(t,d,"-"); if(n==2){ s+=d[1]*86400; t=d[2] }
        n=split(t,a,":"); if(n==3)s+=a[1]*3600+a[2]*60+a[3];
        else if(n==2)s+=a[1]*60+a[2]; else s+=a[1]+0; return s }
    { rss=to_mb($6); if(rss>maxrss)maxrss=rss
      jid=$1
      if(jid ~ /\.0$/){ el=to_s($3); cpu=to_s($4); nc=$5+0 }
      if(jid !~ /\./){ jel=to_s($3); jcpu=to_s($4); jnc=$5+0 } }
    END{ if(el==0||el==""){ el=jel; cpu=jcpu; nc=jnc }
         printf "%.1f %.1f %.1f %d", maxrss+0, el+0, cpu+0, nc+0 }'
)"
maxrss_mb="${maxrss_mb:-0}"; step_elapsed_s="${step_elapsed_s:-0}"
step_cpu_s="${step_cpu_s:-0}"; step_ncpus="${step_ncpus:-0}"

cpu_eff=$(awk -v c="$step_cpu_s" -v e="$step_elapsed_s" -v n="$step_ncpus" \
    'BEGIN{ if(e>0 && n>0) printf "%.1f", 100.0*c/(e*n); else printf "0" }')
peak_node_gb=$(awk -v r="$maxrss_mb" -v n="$NTPN" 'BEGIN{ printf "%.1f", r*n/1024.0 }')

# VASP's own per-rank memory table from the OUTCAR (independent cross-check).
vasp_tbl_mb=$(awk '/total amount of memory used by VASP MPI-rank0/{
        for(i=1;i<=NF;i++) if($i ~ /[kK][bB]ytes/){ printf "%.1f", $(i-1)/1024.0; exit } }' "$OUTCAR")
vasp_tbl_mb="${vasp_tbl_mb:-0}"

# Per-electronic-step wall time and step count from the OUTCAR.
# NB: `grep -c` prints "0" AND exits 1 on zero matches, so `|| echo 0` would
# append a second line ("0\n0"). Capture it plain and sanitise to one integer.
nscf=$(grep -c 'LOOP:' "$OUTCAR" 2>/dev/null); nscf="${nscf//[^0-9]/}"; nscf="${nscf:-0}"
avg_loop=$(awk '/LOOP:/{ k=split($0,a,"real time"); if(k>1){ s+=a[2]+0; c++ } }
                END{ if(c>0) printf "%.2f", s/c; else printf "0" }' "$OUTCAR")
avg_loop="${avg_loop:-0}"

if posq "$maxrss_mb" && [[ -n "$RAW" ]]; then
    node_avail_gb=$(awk -v m="$NODE_MEM_MB" 'BEGIN{printf "%.0f", m/1024.0}')
    printf "  peak RAM / rank (MaxRSS) : %s MB\n" "$maxrss_mb"
    printf "  peak RAM / node (%s rk)  : %s GB   (of ~%s GB available)\n" \
        "$NTPN" "$peak_node_gb" "$node_avail_gb"
else
    echo "  SLURM MaxRSS    : (unavailable -- job accounting may be off)"
    echo "                    Falling back to VASP's own memory table for sizing."
fi
printf "  VASP memory table / rank : %s MB   (rank-0, from OUTCAR)\n" "$vasp_tbl_mb"
if posq "$cpu_eff"; then
    printf "  CPU efficiency           : %s %%   (TotalCPU / (Elapsed x %s cores))\n" \
        "$cpu_eff" "$step_ncpus"
fi
printf "  SCF electronic steps     : %s in %ss\n" "$nscf" "$wall"
posq "$avg_loop" && printf "  avg wall / SCF step      : %s s\n" "$avg_loop"

# Quick human-readable verdict on the parallel efficiency.
echo
if posq "$cpu_eff"; then
    awk -v e="$cpu_eff" 'BEGIN{
        if(e>=85) print "  Verdict: parallel efficiency is GOOD (>=85%).";
        else if(e>=70) print "  Verdict: parallel efficiency is OK (70-85%); a different KPAR/NCORE may help.";
        else print "  Verdict: parallel efficiency is LOW (<70%); try the KPAR/NCORE below or fewer ranks." }'
fi

# --------------------------------------------------------------------------- #
# 5. Build the PRODUCTION recommendation FROM THE MEASUREMENT
#    (memory anchored to the measured MaxRSS, layout from the run, cluster
#    policies applied -- NOT a re-run of vasp-recommend's model.)
# --------------------------------------------------------------------------- #
PY="$(command -v python3 || command -v python || true)"
SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
HELPER=""
for cand in "${VASP_TEST_RECOMMEND:-}" \
            "$SELF_DIR/vasp_test_recommend.py" \
            "$HOME/.local/bin/vasp_test_recommend.py" \
            "$HOME/Useful_scripts/vasp_test_recommend.py"; do
    [[ -n "$cand" && -f "$cand" ]] && { HELPER="$cand"; break; }
done

if [[ -z "$PY" || -z "$HELPER" ]]; then
    hdr "NEXT STEP (could not auto-generate the recommendation)"
    echo "  python3 and/or the helper (vasp_test_recommend.py) were not found."
    echo "  Your MEASURED peak memory was ${maxrss_mb} MB/rank on ${NTASKS} ranks."
    echo "  Size production from that: request MaxRSS / ${MEM_UTIL} per rank."
    echo "  Benchmark outputs kept in: $RUNDIR"
    exit 0
fi

MAIN_PART="${WP_MAIN_PARTITION:-main}"
MAIN_CPN="${WP_MAIN_CPUS_PER_NODE:-256}"
MAIN_MEM="${WP_MAIN_MEM_PER_NODE_MB:-$(( MAIN_CPN * 2000 ))}"
MAXCORES="${WP_MAX_CORES:-$MAIN_CPN}"
PROD_TIME="${VASP_TEST_PROD_TIME:-7-00:00:00}"
MODS="$(_wp_module_block)"

# Sanitise the numeric metrics one more time (defensive: argparse needs clean
# ints/floats, and a stray newline here would abort the whole recommendation).
maxrss_mb="${maxrss_mb//[!0-9.]/}"; maxrss_mb="${maxrss_mb:-0}"
cpu_eff="${cpu_eff//[!0-9.]/}"; cpu_eff="${cpu_eff:-0}"
avg_loop="${avg_loop//[!0-9.]/}"; avg_loop="${avg_loop:-0}"
nscf="${nscf//[!0-9]/}"; nscf="${nscf:-0}"
wall="${wall//[!0-9]/}"; wall="${wall:-0}"
NTASKS="${NTASKS//[!0-9]/}"; NTASKS="${NTASKS:-1}"

if "$PY" "$HELPER" "$OUTCAR" \
    --maxrss-mb "$maxrss_mb" --ntasks-test "$NTASKS" \
    --avg-loop "$avg_loop" --cpu-eff "$cpu_eff" --nscf "$nscf" --wall "$wall" \
    --partition main --slurm-partition "$MAIN_PART" \
    --cpus-per-node "$MAIN_CPN" --node-mem-mb "$MAIN_MEM" --max-cores "$MAXCORES" \
    --mem-util "$MEM_UTIL" --debug-margin-mb "$DEBUG_MARGIN_MB" \
    --prod-ranks "$PROD_RANKS" \
    --email "$EMAIL" --job-name "$JOBNAME" --exe "$VASP_EXE" --time "$PROD_TIME" \
    --modules "$MODS" --extra-env "${WP_EXTRA_ENV:-}" \
    --write-slurm "$SUBMIT_DIR/slurm_job.sh" --write-incar "$SUBMIT_DIR/INCAR.parallel"
then
    hdr "DONE"
    echo "  Benchmark inputs/outputs kept in: $RUNDIR"
    echo "  Production files written to your submit directory:"
    echo "    $SUBMIT_DIR/slurm_job.sh     (sbatch this to run the real calculation)"
    echo "    $SUBMIT_DIR/INCAR.parallel   (merge KPAR/NCORE/NSIM into your INCAR)"
else
    hdr "DONE (recommendation step failed -- see the error above)"
    echo "  The benchmark itself succeeded; only the recommendation helper failed."
    echo "  Your MEASURED peak memory was ${maxrss_mb} MB/rank on ${NTASKS} ranks."
    echo "  Size production from that: request MaxRSS / ${MEM_UTIL} per rank."
    echo "  Benchmark inputs/outputs kept in: $RUNDIR"
fi
echo "  end: $(date)"
