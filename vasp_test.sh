#!/usr/bin/env bash
###############################################################################
# vasp_test.sh   (invoked on PATH as: vasp-test)
#
# STAGE 3/3 of the pipeline: VALIDATE the recommended config + set final memory.
#
# CLUSTER PROFILE
#   The debug partition name, cores/node, memory/node, notification email and
#   the VASP module(s) to load all come from the profile written by
#   `vasp-configure` (~/.config/wolfpack-dft/cluster.conf). Built-in example
#   defaults are used if no profile exists.
#
# PIPELINE (run these three, in order, with NO arguments and NO manual steps):
#   vasp-dry-run            # STAGE 1: dry run -> .wolfpack/dryrun_OUTCAR
#   vasp-recommend-slurm    # STAGE 2: FIXED KPAR/NCORE/NSIM + ranks -> slurm.sh
#   vasp-test               # STAGE 3: THIS SCRIPT
#
# WHAT IT DOES
#   Reads the FIXED parallel config vasp-recommend chose (from .wolfpack/state.env)
#   and benchmarks THAT EXACT config -- not your raw INCAR. Because the recommended
#   rank count (e.g. 120) will not fit on the debug partition, it runs the same
#   KPAR/NCORE at the largest rank count that DOES fit (up to both debug nodes,
#   96 cores), at the maximum debug memory (node RAM minus a 16 GB reserve), for
#   30 minutes. When the budget is up it:
#
#     1. Reads the SLURM metrics (MaxRSS, CPU efficiency) of the FIXED config.
#     2. SCALES the measured per-rank memory from the test rank count up to the
#        production rank count (VASP component-distribution rules).
#     3. Sizes the production memory to your cluster's >=80% utilisation rule and
#        UPDATES slurm.sh in place (mem-per-cpu, and nodes if it must split).
#     4. Prints a VERDICT on whether the recommended config is adequate and
#        appends STAGE 3 to report.out.
#
#   The benchmark runs inside a throwaway sub-directory, so your existing
#   OUTCAR/WAVECAR/etc. are never touched and the folder stays clean.
#
# USAGE
#   cd <dir with INCAR / POSCAR / POTCAR / KPOINTS>      # after dry-run + recommend
#   vasp-test                        # renders ./slurm_vasptest.sh, submits it,
#                                    # then scales + updates slurm.sh + report.out
#
#   Tunables (export before running):
#     VASP_TEST_MINUTES=30          # length of the timed run (needs debug walltime)
#     VASP_TEST_MAX_CORES=96        # cap on debug ranks (default: 2 x cores/node)
#     VASP_EXE=vasp_std             # vasp_std | vasp_gam | vasp_ncl
#     VASP_TEST_MEM_UTIL=0.80       # request memory so usage >= this fraction
#     VASP_TEST_DEBUG_MARGIN_MB=16384  # memory kept free per debug/login node
#
# REQUIREMENTS
#   - Run vasp-dry-run + vasp-recommend-slurm first (this needs slurm.sh + state).
#   - SLURM job accounting (sacct/MaxRSS) enabled -> the memory is anchored to
#     the measured peak. If it is off, it falls back to VASP's own memory table.
###############################################################################

# --- Allow `vasp-test --help` to work outside of SLURM (handled in the parser
#     below too; this early check keeps --help working before set -u) ---------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,52p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
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

TEST_MINUTES="${VASP_TEST_MINUTES:-30}"
DEBUG_MARGIN_MB="${VASP_TEST_DEBUG_MARGIN_MB:-16384}"   # keep free on debug node

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) sed -n '2,52p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "vasp-test: unknown option '$1' (try --help)" >&2; shift ;;
    esac
done

# --- Read the FIXED config from vasp-recommend (STAGE 2 of the pipeline) ---- #
_wp_state="${WOLFPACK_STATE:-.wolfpack/state.env}"
# shellcheck source=/dev/null
[[ -f "$_wp_state" ]] && source "$_wp_state"
FIX_KPAR="${kpar:-1}"; FIX_NCORE="${ncore:-1}"; FIX_NPAR="${npar:-1}"
FIX_NSIM="${nsim:-4}"; PROD_RANKS="${ranks:-0}"
PROD_PARTITION="${prod_partition:-${WP_MAIN_PARTITION:-main}}"
PROD_CPN="${prod_cpn:-${WP_MAIN_CPUS_PER_NODE:-256}}"
PROD_NODE_MEM="${node_mem_mb:-${WP_MAIN_MEM_PER_NODE_MB:-256000}}"
MEM_UTIL="${mem_util:-${VASP_TEST_MEM_UTIL:-0.80}}"

# Emit the resolved module-load command lines (baked into the rendered job).
_wp_module_block() {
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        local cmd="${WP_MODULE_CMD:-ml}"
        if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
            [[ "$cmd" == "module" ]] && echo "module purge" || echo "ml purge"
        fi
        if [[ "$cmd" == "module" ]]; then echo "module load ${WP_VASP_MODULES}"
        else echo "ml ${WP_VASP_MODULES}"; fi
    else                                   # built-in example default
        echo "ml purge"
        echo "ml gcc/14.2.0-zen4-y"
        echo "ml vasp/6.4.3-mpi-openmp-h5-zen4-c"
    fi
}

# --- Submit side: fit the FIXED config into the debug partition + submit --- #
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    if ! command -v sbatch >/dev/null 2>&1; then
        echo "ERROR: sbatch not found. Run on a cluster login node." >&2; exit 1
    fi
    if [[ "${stage:-}" != "recommend" || ! -f slurm.sh ]]; then
        echo "ERROR: no recommendation found. Run the pipeline IN ORDER:" >&2
        echo "         vasp-dry-run  ->  vasp-recommend-slurm  ->  vasp-test" >&2
        exit 2
    fi
    part="${WP_DEBUG_PARTITION:-debug}"
    cpn="${WP_DEBUG_CPUS_PER_NODE:-48}"
    memnode="${WP_DEBUG_MEM_PER_NODE_MB:-360000}"
    # Largest rank count that (a) keeps KPAR x NCORE fixed, (b) fits in the
    # debug partition (up to BOTH debug nodes), and (c) does not exceed prod.
    max_test="${VASP_TEST_MAX_CORES:-$(( cpn * 2 ))}"
    unit=$(( FIX_KPAR * FIX_NCORE )); (( unit < 1 )) && unit=1
    tr=$(( (max_test / unit) * unit )); (( tr < unit )) && tr=$unit
    if (( PROD_RANKS > 0 && tr > PROD_RANKS )); then
        tr=$(( (PROD_RANKS / unit) * unit )); (( tr < unit )) && tr=$unit
    fi
    tnodes=$(( (tr + cpn - 1) / cpn )); (( tnodes < 1 )) && tnodes=1
    tntpn=$(( (tr + tnodes - 1) / tnodes ))
    usable=$(( memnode - DEBUG_MARGIN_MB )); (( usable < 1 )) && usable=$memnode
    mempc=$(( usable / tntpn )); (( mempc < 100 )) && mempc=100
    wmin=$(( TEST_MINUTES + 8 )); ttime=$(printf '%02d:%02d:00' $((wmin/60)) $((wmin%60)))
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    mkdir -p .wolfpack
    job="$PWD/slurm_vasptest.sh"
    {
        echo "#!/bin/bash"
        echo "#SBATCH --job-name=vasp_test"
        echo "#SBATCH --partition=${part}"
        echo "#SBATCH --nodes=${tnodes}"
        echo "#SBATCH --ntasks=${tr}"
        echo "#SBATCH --ntasks-per-node=${tntpn}"
        echo "#SBATCH --cpus-per-task=1"
        echo "#SBATCH --mem-per-cpu=${mempc}"
        echo "#SBATCH --time=${ttime}"
        if [[ -n "${WP_EMAIL:-}" ]]; then
            echo "#SBATCH --mail-user=${WP_EMAIL}"
            echo "#SBATCH --mail-type=ALL"
        fi
        echo "#SBATCH --output=.wolfpack/vasptest-%j.out"
        echo "#SBATCH --error=.wolfpack/vasptest-%j.err"
        echo ""
        echo "# Generated by vasp-test on $(date -Iseconds) -- STAGE 3/3 (exact job)."
        echo 'cd "$SLURM_SUBMIT_DIR" || exit 1'
        echo ""
        echo "# --- modules (resolved from your cluster profile) ---"
        _wp_module_block
        echo ""
        echo "export VASP_TEST_MINUTES='${TEST_MINUTES}'"
        echo "export WP_MODULES_PRELOADED=1"
        echo "exec '${self}'"
    } > "$job"
    chmod +x "$job"
    echo "STAGE 3: benchmarking the FIXED config (KPAR=${FIX_KPAR} NCORE=${FIX_NCORE} NSIM=${FIX_NSIM})" >&2
    echo "         at ${tr} ranks on '${part}' (${tnodes} node(s) x ${tntpn}, ${mempc} MB/cpu," >&2
    echo "         ${DEBUG_MARGIN_MB} MB/node reserved, ${TEST_MINUTES} min); production target ${PROD_RANKS} ranks." >&2
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

# Pin the benchmark to the EXACT parallel config vasp-recommend chose (so we
# validate that fixed layout), and skip WAVECAR/CHGCAR I/O. Appended values win
# in VASP, so we never alter your real INCAR's physics.
TEST_NPAR=$(( NTASKS / (FIX_KPAR * FIX_NCORE) )); (( TEST_NPAR < 1 )) && TEST_NPAR=1
{
    echo ""
    echo "# ---- appended by vasp-test (benchmark only; harmless duplicates) ----"
    echo "KPAR   = ${FIX_KPAR}"
    echo "NCORE  = ${FIX_NCORE}"
    echo "NSIM   = ${FIX_NSIM}"
    echo "LWAVE  = .FALSE."
    echo "LCHARG = .FALSE."
} >> INCAR

hdr "VASP RESOURCE BENCHMARK  (${PARTITION}, ${NTASKS} ranks, ${TEST_MINUTES} min)"
echo "  job id        : $SLURM_JOB_ID"
echo "  run directory : $RUNDIR"
echo "  executable    : $VASP_EXE"
echo "  testing config: KPAR=${FIX_KPAR} NCORE=${FIX_NCORE} NPAR=${TEST_NPAR} NSIM=${FIX_NSIM}  (FIXED by vasp-recommend)"
echo "  production goal: ${PROD_RANKS} ranks on '${PROD_PARTITION}'"
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
    else                                   # built-in example default
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
# 5. Scale the MEASUREMENT to the production config, update slurm.sh, report
#    (memory anchored to measured MaxRSS at the test scale, then projected to
#    the FIXED production rank count; cluster 80% rule applied.)
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

# Sanitise the numeric metrics (argparse needs clean ints/floats; a stray
# newline here would abort the whole STAGE 3 step).
maxrss_mb="${maxrss_mb//[!0-9.]/}"; maxrss_mb="${maxrss_mb:-0}"
cpu_eff="${cpu_eff//[!0-9.]/}"; cpu_eff="${cpu_eff:-0}"
avg_loop="${avg_loop//[!0-9.]/}"; avg_loop="${avg_loop:-0}"
nscf="${nscf//[!0-9]/}"; nscf="${nscf:-0}"
wall="${wall//[!0-9]/}"; wall="${wall:-0}"
NTASKS="${NTASKS//[!0-9]/}"; NTASKS="${NTASKS:-1}"

if [[ -z "$PY" || -z "$HELPER" ]]; then
    hdr "DONE (could not auto-update slurm.sh)"
    echo "  python3 and/or vasp_test_recommend.py were not found."
    echo "  MEASURED peak memory: ${maxrss_mb} MB/rank at ${NTASKS} ranks."
    echo "  Size production by hand: at ${PROD_RANKS} ranks request about"
    echo "  (measured x ${NTASKS}/${PROD_RANKS}) / ${MEM_UTIL} MB per rank."
    echo "  Benchmark outputs kept in: $RUNDIR"
    exit 0
fi

if "$PY" "$HELPER" "$OUTCAR" \
    --maxrss-mb "$maxrss_mb" --ntasks-test "$NTASKS" \
    --test-kpar "$FIX_KPAR" --test-ncore "$FIX_NCORE" --test-npar "$TEST_NPAR" \
    --prod-ranks "$PROD_RANKS" --prod-kpar "$FIX_KPAR" --prod-ncore "$FIX_NCORE" \
    --prod-npar "$FIX_NPAR" --prod-nsim "$FIX_NSIM" \
    --prod-partition "$PROD_PARTITION" --cpus-per-node "$PROD_CPN" \
    --node-mem-mb "$PROD_NODE_MEM" --mem-util "$MEM_UTIL" \
    --cpu-eff "$cpu_eff" --avg-loop "$avg_loop" --nscf "$nscf" --wall "$wall" \
    --update-slurm "$SUBMIT_DIR/slurm.sh" --report "$SUBMIT_DIR/report.out"
then
    # Tidy: keep the folder clean -- the benchmark run dir lives under .wolfpack.
    if [[ -d "$RUNDIR" ]]; then
        mkdir -p "$SUBMIT_DIR/.wolfpack"
        cp -f "$OUTCAR" "$SUBMIT_DIR/.wolfpack/vasptest_OUTCAR" 2>/dev/null || true
        rm -rf "$RUNDIR"
    fi
    { echo 'stage="test"'; } >> "$SUBMIT_DIR/.wolfpack/state.env" 2>/dev/null || true
    hdr "DONE -- pipeline complete"
    echo "  Production job ready: $SUBMIT_DIR/slurm.sh"
    echo "  (memory updated from this benchmark; merge KPAR/NCORE/NSIM into INCAR)"
    echo "  Full report        : $SUBMIT_DIR/report.out"
else
    hdr "DONE (scaling step failed -- see the error above)"
    echo "  The benchmark succeeded; only the scaling/update step failed."
    echo "  MEASURED peak memory: ${maxrss_mb} MB/rank at ${NTASKS} ranks."
    echo "  Benchmark outputs kept in: $RUNDIR"
fi
echo "  end: $(date)"
