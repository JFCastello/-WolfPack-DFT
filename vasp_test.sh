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
#     1. Reads the SLURM accounting metrics (MaxRSS, CPU efficiency) and the
#        OUTCAR (per-SCF-step wall time, VASP's own memory table).
#     2. Feeds the resulting OUTCAR to vasp_recommend_slurm.py
#        (vasp-recommend-slurm) and CALIBRATES its memory model with the measured
#        MaxRSS, so the prediction matches what the job really used.
#     3. Prints a ready-to-submit SLURM script for the MAIN partition and an
#        INCAR snippet (KPAR / NCORE / NSIM) tuned for this exact job.
#
#   The benchmark runs inside a fresh sub-directory (vasp_test_<jobid>/) built
#   from copies of your inputs, so your existing OUTCAR/WAVECAR/etc. are never
#   touched.
#
# USAGE
#   cd <dir with INCAR / POSCAR / POTCAR / KPOINTS>
#   vasp-test                        # self-submits an 11-min benchmark to the
#                                    # configured debug partition, then advises
#
#   Tunables (export before running, or pass with --export):
#     VASP_TEST_MINUTES=11           # length of the timed run (<= ~25 on debug)
#     VASP_EXE=vasp_std              # vasp_std | vasp_gam | vasp_ncl
#     VASP_TEST_EMAIL=you@host       # email written into the emitted script
#     VASP_TEST_JOBNAME=VASP         # --job-name written into the emitted script
#     VASP_RECOMMEND=/path/to/vasp-recommend-slurm   # override recommender location
#
#   The advice is printed to the job's .out file (vasp_test-<jobid>.out).
#
# REQUIREMENTS
#   - SLURM job accounting (sacct/MaxRSS) enabled  -> gives the calibration.
#     If it is off, the script still recommends a layout from VASP's own
#     memory table; it just cannot calibrate it against measured RAM.
#   - vasp-recommend-slurm on PATH (installed by install.sh) for the final advice.
###############################################################################

# --- Allow `vasp-test --help` to work outside of SLURM -----------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,50p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
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

# --- Submit side: resubmit self onto the configured debug partition -------- #
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    part="${WP_DEBUG_PARTITION:-debug}"
    n="${WP_DEBUG_CPUS_PER_NODE:-48}"
    memnode="${WP_DEBUG_MEM_PER_NODE_MB:-360000}"
    mempc=$(( memnode / n )); (( mempc < 100 )) && mempc=100
    if ! command -v sbatch >/dev/null 2>&1; then
        echo "ERROR: sbatch not found. Run on a cluster login node." >&2; exit 1
    fi
    sb=(-J vasp_test -p "$part" --nodes=1 --ntasks="$n" --ntasks-per-node="$n"
        --cpus-per-task=1 --mem-per-cpu="$mempc" --time=00:18:00
        --output=vasp_test-%j.out --error=vasp_test-%j.err)
    [[ -n "${WP_EMAIL:-}" ]] && sb+=(--mail-user="$WP_EMAIL" --mail-type=ALL)
    echo "Submitting ${TEST_MINUTES}-min VASP benchmark: partition '$part', ${n} ranks, ${memnode} MB/node ..." >&2
    exec sbatch "${sb[@]}" "$0" "$@"
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
#    on the main partition, so the benchmark is representative)
# --------------------------------------------------------------------------- #
if [[ -n "${WP_VASP_MODULES:-}" ]]; then
    _wpcmd="${WP_MODULE_CMD:-ml}"
    if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
        { [[ "$_wpcmd" == "module" ]] && module purge || ml purge; } 2>/dev/null || true
    fi
    # shellcheck disable=SC2086
    if [[ "$_wpcmd" == "module" ]]; then module load $WP_VASP_MODULES
    else ml $WP_VASP_MODULES; fi
else                                       # built-in NLHPC default
    ml purge                              2>/dev/null || true
    ml gcc/14.2.0-zen4-y                  2>/dev/null || true
    ml vasp/6.4.3-mpi-openmp-h5-zen4-c    2>/dev/null || true
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
nscf=$(grep -c 'LOOP:' "$OUTCAR" 2>/dev/null || echo 0)
avg_loop=$(awk '/LOOP:/{ k=split($0,a,"real time"); if(k>1){ s+=a[2]+0; c++ } }
                END{ if(c>0) printf "%.2f", s/c; else printf "0" }' "$OUTCAR")

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
# 5. Locate vasp-recommend-slurm (vasp_recommend_slurm.py)
# --------------------------------------------------------------------------- #
PY="$(command -v python3 || command -v python || true)"
RECO=""
for cand in "${VASP_RECOMMEND:-}" \
            "$HOME/.local/bin/vasp-recommend-slurm" \
            "$(command -v vasp-recommend-slurm 2>/dev/null || true)" \
            "$HOME/Useful_scripts/vasp_recommend_slurm.py"; do
    if [[ -n "$cand" && -e "$cand" ]]; then RECO="$cand"; break; fi
done

if [[ -z "$PY" || -z "$RECO" ]]; then
    hdr "NEXT STEP (recommender not found on the compute node)"
    echo "  Could not locate python3 and/or vasp-recommend-slurm automatically."
    echo "  From a login node with the toolkit installed, run:"
    echo
    echo "      vasp-recommend-slurm $OUTCAR --partition main --mem-headroom 1.3 \\"
    echo "                     --email $EMAIL --job-name $JOBNAME"
    echo
    echo "  (MaxRSS measured above was ${maxrss_mb} MB/rank; size --mem-per-cpu from it.)"
    echo "  Benchmark outputs kept in: $RUNDIR"
    exit 0
fi

# --------------------------------------------------------------------------- #
# 6. Calibrate the memory model with the measured MaxRSS
#    predicted_test = recommender's per-rank prediction AT THE TEST LAYOUT
#    ratio          = measured MaxRSS / predicted_test   (model correction)
#    headroom       = ratio * 1.10, floored at the tool's 1.15 default
# --------------------------------------------------------------------------- #
predicted_test_mb=$("$PY" "$RECO" "$OUTCAR" --partition debug \
        --min-cores "$NTASKS" --max-cores "$NTASKS" --email "" --no-write 2>/dev/null \
    | awk '/per-rank total/{ for(i=1;i<=NF;i++) if($i=="MB"){ print $(i-1); exit } }')
predicted_test_mb="${predicted_test_mb:-0}"

headroom=$(awk -v m="$maxrss_mb" -v p="$predicted_test_mb" 'BEGIN{
        if(m>0 && p>0){ h=(m/p)*1.10 } else { h=1.30 }
        if(h<1.15) h=1.15;
        printf "%.2f", h }')

hdr "MEMORY-MODEL CALIBRATION"
if posq "$maxrss_mb" && posq "$predicted_test_mb"; then
    ratio=$(awk -v m="$maxrss_mb" -v p="$predicted_test_mb" 'BEGIN{printf "%.2f", m/p}')
    printf "  measured MaxRSS / rank   : %s MB\n" "$maxrss_mb"
    printf "  model prediction / rank  : %s MB   (at %s ranks)\n" "$predicted_test_mb" "$NTASKS"
    printf "  correction factor        : x%s\n" "$ratio"
    printf "  -> applying --mem-headroom %s to the main-partition recommendation\n" "$headroom"
else
    echo "  MaxRSS or model prediction unavailable -> using a safe --mem-headroom $headroom."
fi

# --------------------------------------------------------------------------- #
# 7. Final, calibrated recommendation for the MAIN partition
# --------------------------------------------------------------------------- #
hdr "RECOMMENDED MAIN-PARTITION SETUP  (copy-paste below)"
echo "Generated by vasp-recommend-slurm, calibrated with this benchmark's MaxRSS."
echo "Contains the INCAR snippet (KPAR / NCORE / NSIM) and a ready sbatch script."
echo
"$PY" "$RECO" "$OUTCAR" --partition main --mem-headroom "$headroom" \
      --email "$EMAIL" --job-name "$JOBNAME" \
      --write-slurm "$SUBMIT_DIR/slurm_job.sh" \
      --write-incar "$SUBMIT_DIR/INCAR.parallel"

hdr "DONE"
echo "  Benchmark inputs/outputs kept in: $RUNDIR"
echo "  Calibrated production files written to your submit directory:"
echo "    $SUBMIT_DIR/slurm_job.sh     (sbatch this to run the real calculation)"
echo "    $SUBMIT_DIR/INCAR.parallel   (merge KPAR/NCORE/NSIM into your INCAR)"
echo "  end: $(date)"
