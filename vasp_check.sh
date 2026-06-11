#!/usr/bin/env bash
#==============================================================================
# vasp_check.sh  —  post-mortem sanity + physics analysis for a finished
#                   (or KILLED) VASP run.
#
# Recognises the calculation TYPE from INCAR (with OUTCAR fallback):
#     * static SCF                (NSW=0 / IBRION=-1)
#     * non-self-consistent       (ICHARG=11 -> band-structure or DOS)
#     * ionic / cell relaxation   (NSW>0, IBRION 1/2/3; ISIF decides ions/cell)
#     * AIMD                      (IBRION=0)
#     * DFPT / linear response    (IBRION 5/6/7/8, LEPSILON, LCALCEPS)
#     * G0W0 / GW0 / EVGW0 / QPGW / scGW  (single-shot vs eigenvalue/QP scGW)
#     * RPA / ACFDT, BSE          (light handling)
#   plus the XC layer: GGA, GGA+U, HSE/PBE0 hybrid.
#
# It does FOUR jobs:
#   (1) computational / convergence audit (SCF, forces, stress, GW knobs)
#   (2) physics / interpretation (gap + VBM/CBM with full k-coords, moments,
#       QP renormalisation, Z factors)
#   (3) for KILLED runs: figure out WHY (OOM vs walltime vs crash, parsing the
#       scheduler logs) and classify the data as PLOTTABLE / PARTIAL / NOT
#   (4) flags common pitfalls per calculation type.
#
# Usage:   vasp_check.sh [DIR]            (default DIR = .)
#          vasp_check.sh -h | --help
#
# Exit:    0 = PASS / PASS-with-warnings, 1 = at least one FAIL, 2 = usage error
#==============================================================================
set -uo pipefail

#------------------------------- presentation --------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; MAG=$'\e[35m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""; MAG=""
fi

FAILS=0; WARNS=0
hdr(){  printf '\n%s== %s ==%s\n' "$B$CYN" "$1" "$R"; }
kv(){   printf '  %-30s %s\n' "$1" "$2"; }
ok(){   printf '  %s[ OK ]%s %s\n'   "$GRN" "$R" "$1"; }
warn(){ printf '  %s[WARN]%s %s\n'   "$YEL" "$R" "$1"; WARNS=$((WARNS+1)); }
fail(){ printf '  %s[FAIL]%s %s\n'   "$RED" "$R" "$1"; FAILS=$((FAILS+1)); }
note(){ printf '  %s%s%s\n' "$DIM" "$1" "$R"; }
tip(){  printf '  %s>> %s%s\n' "$MAG" "$1" "$R"; }

usage(){
  cat <<'EOF'
vasp_check.sh [DIR]   Post-mortem sanity + physics analysis of a VASP run.
                      DIR defaults to the current directory.
  -h, --help          Show this help.

WHAT IT CHECKS (10 sections)
  1. File inventory      -- which VASP files are present and their sizes
  2. Run metadata        -- detected calc type (static SCF / ionic relax / AIMD /
                           DFPT / GW / RPA / BSE), XC (GGA / GGA+U / hybrid),
                           key INCAR tags (KPAR, NCORE, NBANDS, ENCUT, LORBIT...)
  3. Termination         -- normal exit, walltime/OOM kill, or crash;
                           PRICEL info-only vs actual internal error distinguished
  4. Data completeness   -- vasprun.xml, EIGENVAL, PROCAR, GW QP-table;
                           PLOTTABLE / PARTIAL / NOT USABLE verdict for killed runs
  5. Electronic (SCF)    -- NELM hits, entropy/atom, non-self-consistent notice
  6. Ionic convergence   -- EDIFFG criterion, max|F|, energy monotonicity (relaxations)
  7. Cell / stress       -- volume, lattice vectors, residual pressure (Pulay)
  8. Magnetization       -- net moment, per-atom moments, FM/AFM/nonmagnetic hint
  9. Eigenvalues & gap   -- fundamental gap (VASP's own line + occupation cross-check),
                           VBM/CBM with full k-coords, occupied bands, GW QP table
 10. Pitfalls            -- smearing choice, KPAR divisibility, NBANDS headroom,
                           GW knobs (NCORE=1, ENCUTGW default warning), LDA+U geometry
  Verdict               -- TOTEN, energy/atom, overall PASS / PASS-with-warnings / FAIL

READS (when present)
  OUTCAR  OSZICAR  INCAR  KPOINTS  POSCAR  CONTCAR  vasprun.xml
  EIGENVAL  DOSCAR  PROCAR  and any slurm-*.out / *.o<jobid>
  The INCAR echoed inside OUTCAR is the primary source of VASP parameters.

EXIT CODES
  0  PASS (clean or with warnings only)
  1  at least one FAIL flag raised
  2  usage error (bad option, DIR not found, no readable OUTCAR)
EOF
  exit "${1:-0}"
}

#------------------------------- arguments -----------------------------------
DIR="."
case "${1:-}" in
  -h|--help) usage 0 ;;
  "") : ;;
  -*) echo "error: unknown option '$1'" >&2; usage 2 ;;
  *) DIR="$1" ;;
esac
[[ -d "$DIR" ]] || { echo "error: '$DIR' is not a directory" >&2; exit 2; }
cd "$DIR" || { echo "error: cannot cd into '$DIR'" >&2; exit 2; }

OUT=OUTCAR; OSZ=OSZICAR; INC=INCAR
[[ -s $OUT ]] || { echo "error: no readable OUTCAR in $(pwd)" >&2; exit 2; }

# scheduler / stdout-stderr logs that may hold OOM / walltime messages
shopt -s nullglob
SLURM_LOGS=( slurm-*.out slurm-*.err *.o[0-9]* *.e[0-9]* *.out *.err *.log )
shopt -u nullglob
# de-duplicate and drop OUTCAR-like names we already handle
declare -A _seen=()
LOGS=()
for f in "${SLURM_LOGS[@]}"; do
  [[ -s $f ]] || continue
  [[ $f == OUTCAR || $f == OSZICAR || $f == vasprun.xml ]] && continue
  [[ -n ${_seen[$f]:-} ]] && continue
  _seen[$f]=1; LOGS+=( "$f" )
done

printf '%s%s VASP run analysis: %s %s\n' "$B" "$CYN" "$(pwd)" "$R"

#--------------------------- parameter helpers -------------------------------
# getp TAG : first numeric value of "TAG = <num>" echoed in OUTCAR (defaults
#            already applied), falling back to INCAR.
getp(){
  local v
  v=$(awk -v t="$1" '
    match($0, t"[[:space:]]*=[[:space:]]*[-+0-9.][-+0-9.EeDd]*"){
      s=substr($0,RSTART,RLENGTH); sub(/.*=[[:space:]]*/,"",s);
      gsub(/[Dd]/,"E",s); print s; exit }' "$OUT")
  if [[ -z $v && -s $INC ]]; then
    v=$(awk -v t="$1" '
      /^[[:space:]]*[#!]/ {next}
      match($0, t"[[:space:]]*=[[:space:]]*[-+0-9.][-+0-9.EeDd]*"){
        s=substr($0,RSTART,RLENGTH); sub(/.*=[[:space:]]*/,"",s);
        gsub(/[Dd]/,"E",s); print s; exit }' "$INC")
  fi
  printf '%s' "$v"
}

# gettag TAG FILE : first RHS *string* token of "TAG = value", comments stripped,
#                   case-insensitive on the tag, anchored so LDAU != LDAUL etc.
gettag(){
  local t="$1" f="$2"
  [[ -s $f ]] || return 0
  awk -v t="$t" '
    { line=$0; sub(/[#!].*/,"",line); U=toupper(line); T=toupper(t);
      if (match(U, "(^|[ \t;])" T "[ \t]*=[ \t]*[^ \t;]+")) {
        s=substr(line,RSTART,RLENGTH);
        sub(/^[ \t;]+/,"",s); sub(/.*=[ \t]*/,"",s);
        print s; exit } }' "$f"
}
# value preferring INCAR (user intent) then OUTCAR (effective)
INCVAL(){ local v; v=$(gettag "$1" "$INC"); [[ -z $v ]] && v=$(gettag "$1" "$OUT"); printf '%s' "$v"; }

# getlog TAG : T/F for a logical, OUTCAR then INCAR
getlog(){
  local v
  v=$(grep -m1 -iE "(^|[[:space:];])$1[[:space:]]*=" "$OUT" 2>/dev/null)
  [[ -z $v && -s $INC ]] && v=$(grep -m1 -iE "(^|[[:space:];])$1[[:space:]]*=" "$INC" 2>/dev/null)
  if printf '%s' "$v" | grep -qiE '=[[:space:]]*\.?[Tt]'; then echo T; else echo F; fi
}
has(){ grep -qi -- "$1" "$OUT"; }
ucase(){ printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

#============================ 1. FILE INVENTORY ==============================
hdr "File inventory"
for f in OUTCAR OSZICAR INCAR KPOINTS POSCAR CONTCAR vasprun.xml EIGENVAL DOSCAR PROCAR WAVECAR CHGCAR; do
  if [[ -s $f ]]; then printf '  %-12s %s%10s B%s\n' "$f" "$DIM" "$(wc -c <"$f")" "$R"
  else printf '  %-12s %s(absent)%s\n' "$f" "$DIM" "$R"; fi
done
if ((${#LOGS[@]})); then note "scheduler logs seen: ${LOGS[*]}"; else note "no scheduler/stdout logs in this directory (OOM cause may be undiagnosable here)"; fi

#============================ 2. PARAMETERS + TYPE ===========================
NIONS=$(getp NIONS);   NIONS=${NIONS:-0}
NBANDS=$(getp NBANDS); ISPIN=$(getp ISPIN); NKPTS=$(getp NKPTS)
NELM=$(getp NELM);     NELMIN=$(getp NELMIN)
EDIFF=$(getp EDIFF);   EDIFFG=$(getp EDIFFG)
IBRION=$(getp IBRION); NSW=$(getp NSW); ISIF=$(getp ISIF); ICHARG=$(getp ICHARG)
ISMEAR=$(getp ISMEAR); SIGMA=$(getp SIGMA)
ENCUT=$(getp ENCUT);   LORBIT=$(getp LORBIT)
KPAR=$(getp KPAR);     NCORE=$(getp NCORE);  NPAR=$(getp NPAR)
NOMEGA=$(getp NOMEGA); ENCUTGW=$(getp ENCUTGW); NBANDSGW=$(getp NBANDSGW)
NTAUPAR=$(getp NTAUPAR); NOMEGAPAR=$(getp NOMEGAPAR)
HFSCREEN=$(getp HFSCREEN); AEXX=$(getp AEXX)
LSORBIT=$(getlog LSORBIT)
LHF=$(getlog LHFCALC)
# LDA+U: master switch OR any of the per-shell tags / banner
if [[ $(getlog LDAU) == T ]] || grep -qiE 'LDA\+U is selected|LDAUTYPE|LDAUL[[:space:]]*=' "$OUT" 2>/dev/null; then LDAU=T; else LDAU=F; fi
ALGO=$(INCVAL ALGO); ALGO_UC=$(ucase "$ALGO")
VASPVER=$(grep -m1 -E 'vasp\.[0-9]' "$OUT" | awk '{print $1}')
ENCUTGW_SET=$(gettag ENCUTGW "$INC")   # explicitly in INCAR? (empty -> defaulted)

# ---------- calculation-type decision tree (INCAR-driven) ----------
gw_family=0; gw_lowscaling=0; rpa=0; bse=0
case "$ALGO_UC" in
  *GW*)   gw_family=1 ;;
  RPA|ACFDT|ACFDTR|RPAR) rpa=1 ;;
  BSE|TDHF|TIMEEV)       bse=1 ;;
esac
# GW can also be implied by tags even if ALGO got masked (e.g. dry runs)
if [[ -n ${NOMEGA:-} && ${NOMEGA%.*} -gt 0 ]] || [[ -n ${NBANDSGW:-} ]]; then gw_family=1; fi
# QP table in OUTCAR is the strongest confirmation
grep -q 'QP-energies' "$OUT" 2>/dev/null && gw_family=1
# low-scaling space-time / cubic GW: ALGO is a GW variant ending in R, OR partitioning tags explicitly > 0
[[ $ALGO_UC == *GW* && $ALGO_UC == *R ]] && { gw_family=1; gw_lowscaling=1; }
ntp=${NTAUPAR%.*}; nop=${NOMEGAPAR%.*}
[[ ${ntp:-0} =~ ^-?[0-9]+$ && ${ntp:-0} -gt 0 ]] && { gw_family=1; gw_lowscaling=1; }
[[ ${nop:-0} =~ ^-?[0-9]+$ && ${nop:-0} -gt 0 ]] && { gw_family=1; gw_lowscaling=1; }

CALC_BASE=""
if   ((gw_family)); then CALC_BASE="GW"
elif ((rpa));       then CALC_BASE="RPA/ACFDT"
elif ((bse));       then CALC_BASE="BSE"
elif [[ ${IBRION%.*} =~ ^(5|6|7|8)$ ]] || [[ $(getlog LEPSILON) == T || $(getlog LCALCEPS) == T ]]; then
     CALC_BASE="DFPT/linear-response"
elif [[ ${NSW:-0} != "" && ${NSW%.*} -gt 0 && ${IBRION:-2} != "" ]]; then
     if [[ ${IBRION%.*} == 0 ]]; then CALC_BASE="AIMD"
     else
       case "${ISIF%.*}" in
         3|6|7) CALC_BASE="cell relaxation (ISIF=${ISIF%.*}, cell+ions)";;
         4|5)   CALC_BASE="cell relaxation (ISIF=${ISIF%.*}, shape, fixed V)";;
         *)     CALC_BASE="ionic relaxation (ISIF=${ISIF:-2})";;
       esac
     fi
elif [[ ${ICHARG%.*} == 11 ]]; then
     CALC_BASE="non-self-consistent (ICHARG=11: band structure or DOS)"
else CALC_BASE="static SCF"
fi

# XC layer (AEXX-aware). NOTE: a GW run sets LHFCALC=T / AEXX=1.0 internally for the self-energy;
# that is NOT a hybrid groundstate, so for GW we report the underlying functional instead.
CALC_XC="GGA"
ax=${AEXX:-0}
if [[ $LHF == T ]] && ! ((gw_family)); then
  if [[ -n ${HFSCREEN:-} ]] && awk -v s="${HFSCREEN:-0}" 'BEGIN{exit !(s>0)}'; then CALC_XC="HSE-type screened hybrid"
  elif awk -v a="$ax" 'BEGIN{exit !(a>=0.18 && a<=0.32)}'; then CALC_XC="PBE0-type hybrid (AEXX=${ax})"
  elif awk -v a="$ax" 'BEGIN{exit !(a>=0.95)}'; then CALC_XC="Hartree-Fock (AEXX=1)"
  else CALC_XC="hybrid (AEXX=${ax})"; fi
fi
[[ $LDAU == T ]] && CALC_XC="${CALC_XC}+U"

# GW flavour text
GW_FLAVOUR=""
if ((gw_family)); then
  case "$ALGO_UC" in
    G0W0*) GW_FLAVOUR="G0W0 (single-shot, no self-consistency)";;
    GW0*|EVGW0*) GW_FLAVOUR="GW0/EVGW0 (eigenvalue self-consistency in G; W fixed at DFT)";;
    QPGW*|SCGW*|GW*) GW_FLAVOUR="QP/scGW (self-consistent quasiparticle)";;
    *) GW_FLAVOUR="GW family (ALGO=${ALGO:-?})";;
  esac
  ((gw_lowscaling)) && GW_FLAVOUR="$GW_FLAVOUR  [low-scaling / space-time]"
fi

hdr "Run metadata"
kv "VASP version"        "${VASPVER:-?}"
kv "Atoms (NIONS)"       "${NIONS:-?}"
kv "Bands (NBANDS)"      "${NBANDS:-?}"
kv "k-points (NKPTS)"    "${NKPTS:-?}"
kv "ISPIN  (SOC)"        "${ISPIN:-?}    ($LSORBIT)"
kv "ENCUT (eV)"          "${ENCUT:-?}"
kv "ISMEAR / SIGMA"      "${ISMEAR:-?} / ${SIGMA:-?}"
kv "EDIFF / EDIFFG"      "${EDIFF:-?} / ${EDIFFG:-?}"
kv "IBRION/NSW/ISIF"     "${IBRION:-?} / ${NSW:-?} / ${ISIF:-?}"
kv "ICHARG"             "${ICHARG:-?}"
kv "KPAR/NCORE/NPAR"     "${KPAR:-?} / ${NCORE:-?} / ${NPAR:-?}"
kv "LORBIT"             "${LORBIT:-?}"
kv "${B}Detected type${R}"  "$B$CALC_BASE$R  ${DIM}[$CALC_XC]$R"
[[ -n $GW_FLAVOUR ]] && kv "GW flavour" "$GW_FLAVOUR"
if ((gw_family)); then
  nbgw="${NBANDSGW:-?}"; [[ ${NBANDSGW%.*} == -1 ]] && nbgw="default(all)"
  kv "GW knobs" "NOMEGA=${NOMEGA:-?}  ENCUTGW=${ENCUTGW:-?}$([[ -z $ENCUTGW_SET ]] && echo ' (defaulted=2/3*ENCUT)')  NBANDSGW=${nbgw}$( ((gw_lowscaling)) || echo '  (conventional quartic-scaling: NTAUPAR/NOMEGAPAR off)')"
  [[ $LHF == T ]] && note "LHFCALC=T / AEXX=${AEXX:-1.0} here are GW's internal exact-exchange settings for the self-energy, not a hybrid groundstate."
fi

#============================ 3. TERMINATION =================================
hdr "Termination / integrity"
# completion markers that are independent of the timing footer
RELAX_DONE=0; SCF_CONVERGED=0
grep -qiE 'reached required accuracy - stopping structural energy minimi[sz]ation' "$OUT" && RELAX_DONE=1
grep -q 'aborting loop because EDIFF is reached' "$OUT" && SCF_CONVERGED=1

NORMAL=0; TERM="killed"
if grep -q 'General timing and accounting' "$OUT"; then
  NORMAL=1; TERM="normal"
  ok "Normal termination (timing footer present)."
  ELAPSED=$(grep -m1 'Elapsed time' "$OUT" | awk '{print $NF}')
  [[ -n ${ELAPSED:-} ]] && note "Elapsed wall time: ${ELAPSED} s"
elif [[ $CALC_BASE == *relax* ]] && ((RELAX_DONE)); then
  TERM="completed-no-footer"
  ok "Relaxation reached required accuracy (converged) -- but the timing footer is absent."
  note "VASP finished the optimisation and wrote the final structure/wavefunctions; the OUTCAR was almost"
  note "certainly truncated AFTER the run (copy/transfer). This is NOT a crash and the data is complete."
elif [[ ( $CALC_BASE == "static SCF" || $CALC_BASE == non-self* ) ]] && ((SCF_CONVERGED)) && ! ((gw_family)); then
  TERM="completed-no-footer"
  warn "SCF converged (EDIFF reached) but no timing footer -> OUTCAR likely truncated after the run; data is probably complete (verify below)."
else
  warn "No 'General timing' footer and no completion marker -> run was KILLED or truncated MID-calculation."
fi

# ---- where did it stop? (last meaningful activity) ----
LAST_STAGE="unknown"
if ((gw_family)) && grep -qiE 'response function|polariz|screened|self-energy|NQ=|calculate.*W|HEAD OF MICRO|RESPONSER' "$OUT"; then
  LAST_STAGE="GW response-function / polarizability / screened-Coulomb step (before any QP energies)"
fi
LAST_SCF=$(awk '/^[[:space:]]*[A-Za-z]+:[[:space:]]+[0-9]+[[:space:]]/{s=$1" iter "$2} END{print s}' "$OSZ" 2>/dev/null)
TAIL3=$(grep -vE '^[[:space:]]*$' "$OUT" | tail -n 3)

# ---- classify a kill: OOM vs walltime vs crash (parse logs + OUTCAR) ----
KILL_REASON=""; OOM=0; WALL=0; SEG=0; MPI=0; VMEM=0
if [[ $TERM == killed ]]; then
  pat_oom='oom-kill|out of memory|oomkilled|out-of-memory|cgroup out-of-memory|killed process|cannot allocate memory|exceeded.*memory limit|memory cgroup out of memory|oom_reaper|oom score'
  pat_wall='due to time limit|time limit|cancelled at .* due to time|exceeded.*wall'
  pat_seg='segmentation fault|sigsegv|signal 11|address not mapped'
  pat_mpi='mpi_abort|bad termination of one of your application|application terminated with the exit string|pmpi_|noticed that process rank'
  pat_vmem='forrtl: severe \(41\)|insufficient virtual memory|allocation would exceed|error allocating|allocation .*failed|not enough memory|out of memory error'
  for f in "$OUT" "${LOGS[@]}"; do
    [[ -s $f ]] || continue
    grep -qiE "$pat_oom"  "$f" && OOM=1
    grep -qiE "$pat_wall" "$f" && WALL=1
    grep -qiE "$pat_seg"  "$f" && SEG=1
    grep -qiE "$pat_mpi"  "$f" && MPI=1
    grep -qiE "$pat_vmem" "$f" && VMEM=1
  done
  if   ((WALL)); then KILL_REASON="WALLTIME (scheduler time limit hit)"
  elif ((OOM||VMEM)); then KILL_REASON="OOM (out of memory)"
  elif ((SEG)); then KILL_REASON="SEGFAULT (crash)"
  elif ((MPI)); then KILL_REASON="MPI abort (cause not explicit; inspect logs)"
  else KILL_REASON="truncated, cause not found in OUTCAR/logs (no scheduler log here; a kernel SIGKILL OOM leaves no trace)"
  fi
  kv "Stopped during" "$LAST_STAGE"
  [[ -n ${LAST_SCF:-} ]] && kv "Last SCF line" "$LAST_SCF"
  fail "Kill reason: $KILL_REASON"
  note "last non-empty OUTCAR lines:"; printf '%s\n' "$TAIL3" | sed 's/^/        /'

  # likely physical cause, tied to calc type
  if ((OOM||VMEM)) || [[ $KILL_REASON == truncated* ]]; then
    if ((gw_family)); then
      tip "GW memory is dominated by the polarizability / screened-Coulomb arrays, NOT DFT memory."
      tip "Memory ~ ENCUTGW^3 (dominant) * NOMEGA * ISPIN / (ranks per k-group). Lower ENCUTGW, lower NOMEGA,"
      tip "raise KPAR or total ranks, or for low-scaling raise NTAUPAR/NOMEGAPAR (more groups -> less mem/group)."
    elif [[ $CALC_BASE == *relax* || $CALC_BASE == "static SCF" || $CALC_BASE == non-self* ]]; then
      tip "DFT OOM scales with NKPTS*NBANDS*ENCUT and the FFT grid. Add nodes/ranks, raise KPAR (if NKPTS allows),"
      tip "set NCORE>1 to spread bands across cores, or trim NBANDS to the minimum you actually need."
    fi
  elif ((WALL)); then
    tip "Walltime kill: request more time, or restart from WAVECAR/CHGCAR (ISTART=1 / ICHARG=1) to continue."
  fi
fi

# ---- hard error signatures (PRICEL handled separately, see below) ----
ERRS=$(grep -nEi 'VERY BAD NEWS|internal error|ZBRENT: fatal|EDDDAV.*ZHEGV|call to ZHEGV|BRMIX: very serious|SGRCON|Fatal error|please rerun|ERROR FEXCP|ERROR: missing' "$OUT" \
       | grep -viE 'internal error in subroutine PRICEL' | head -20 || true)
if [[ -n $ERRS ]]; then
  fail "Fatal error signatures in OUTCAR:"; printf '%s\n' "$ERRS" | sed 's/^/        /'
else
  ok "No fatal error signatures in OUTCAR (PRICEL checked separately)."
fi

# ---- PRICEL: distinguish the benign notice from the genuine internal error ----
if grep -qi 'internal error in subroutine PRICEL' "$OUT"; then
  fail "PRICEL internal error: symmetry/primitive-cell detection FAILED."
  tip "Atoms slightly off ideal sites or a bad lattice. Tighten/loosen SYMPREC, or set ISYM=0 to bypass symmetry."
elif grep -qi 'Subroutine PRICEL returns' "$OUT"; then
  PRC=$(grep -A2 -i 'Subroutine PRICEL returns' "$OUT" | grep -vi 'returns' | grep -vE '^[[:space:]]*$' | head -1)
  note "PRICEL notice (informational, printed at start-up, NOT a failure):"
  [[ -n $PRC ]] && note "    \"$PRC\""
  note "    VASP found a smaller/primitive cell than the one you supplied while building the"
  note "    k-mesh symmetry. It does not stop the run and does not invalidate results."
  if [[ $TERM == killed ]]; then
    note "    -> Here the run was killed LATER; this PRICEL line is unrelated to the kill."
  fi
fi

#==================== 3b. PLOTTABILITY / DATA COMPLETENESS ===================
# For killed runs especially: did the data you care about survive to disk?
hdr "Data completeness / plottability"
PLOT_VERDICT="FULL"; PLOT_WHY=()

# vasprun.xml well-formed? (the gate for pymatgen Vasprun/BSVasprun)
VR_OK=0
if [[ -s vasprun.xml ]]; then
  if tail -c 8192 vasprun.xml | grep -q '</modeling>'; then VR_OK=1; fi
fi

# EIGENVAL complete? header line 6 = "NELECT NKPTS NBANDS"; count k-blocks (NF==4 floats)
EIG_OK=0; EIG_HAVE=0; EIG_WANT=0
if [[ -s EIGENVAL ]]; then
  read -r EIG_WANT EIG_NB < <(awk 'NR==6{printf "%d %d", $2, $3; exit}' EIGENVAL)
  EIG_HAVE=$(awk 'NR>6 && NF==4 && $1 ~ /^-?[0-9.]+$/ && $4 ~ /^-?[0-9.]+$/{c++} END{print c+0}' EIGENVAL)
  if [[ ${EIG_WANT:-0} -gt 0 && ${EIG_HAVE:-0} -ge ${EIG_WANT:-1} ]]; then EIG_OK=1; fi
fi

# PROCAR complete? (needed for FAT bands) header line 2 has the counts
PRO_OK=0; PRO_HAVE=0; PRO_WANT=0
if [[ -s PROCAR ]]; then
  PRO_WANT=$(awk 'NR==2{for(i=1;i<=NF;i++) if($i=="k-points:"){print $(i+1); exit}}' PROCAR)
  PRO_HAVE=$(grep -cE '^k-point[[:space:]]+[0-9]+' PROCAR)
  PRO_WANT=${PRO_WANT:-0}
  if [[ ${PRO_WANT:-0} -gt 0 ]]; then
    # PROCAR repeats the k-block per spin channel
    need=$PRO_WANT; [[ ${ISPIN%.*} == 2 ]] && need=$((PRO_WANT*2))
    [[ ${PRO_HAVE:-0} -ge $need ]] && PRO_OK=1
  fi
fi

# final eigenvalue block inside OUTCAR complete? (skip the "plane waves per k-point" listing)
OUTEIG_HAVE=$(awk '
  /spin component/{sp=$NF}
  /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ {k[sp"|"$2]=1}
  END{n=0; for(i in k)n++; print n+0}' "$OUT")
OUTEIG_OK=0
if [[ -n ${NKPTS:-} && ${NKPTS%.*} -gt 0 ]]; then
  want=${NKPTS%.*}; [[ ${ISPIN%.*} == 2 ]] && want=$((want*2))
  [[ ${OUTEIG_HAVE:-0} -ge $want ]] && OUTEIG_OK=1
fi

# QP table completeness (GW only)
QP_OK=0; QP_HAVE=0
if ((gw_family)); then
  QP_HAVE=$(awk '
    /QP shifts/ && /iteration/ { delete K; next }    # genuine new GW iteration banner
    /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ { kp=$2+0 }
    /KS-energies/ && /QP-energies/ { K[kp]=1 }
    END{ n=0; for(i in K)n++; print n+0 }' "$OUT")
  if [[ -n ${NKPTS:-} && ${QP_HAVE:-0} -ge ${NKPTS%.*} ]]; then QP_OK=1; fi
fi

kv "vasprun.xml well-formed" "$([[ $VR_OK == 1 ]] && echo 'yes (</modeling> closed)' || echo 'NO / missing')"
[[ -s EIGENVAL ]] && kv "EIGENVAL k-blocks"  "${EIG_HAVE}/${EIG_WANT:-?}"
[[ -s PROCAR   ]] && kv "PROCAR k-blocks"    "${PRO_HAVE}/$([[ ${ISPIN%.*} == 2 ]] && echo $((${PRO_WANT:-0}*2)) || echo ${PRO_WANT:-?}) (fat bands)"
kv "OUTCAR final eig blocks"  "${OUTEIG_HAVE}/$([[ ${ISPIN%.*} == 2 ]] && echo $((${NKPTS%.*}*2)) || echo ${NKPTS%.*})"
((gw_family)) && kv "QP table k-points" "${QP_HAVE}/${NKPTS%.*}"

# ---- verdict ----
if ((gw_family)); then
  # GW: the deliverable is the QP table, so completeness is judged on it (footer or not)
  if   ((QP_OK)); then PLOT_VERDICT="PLOTTABLE"; PLOT_WHY+=("QP table complete for all k-points")
  elif [[ ${QP_HAVE:-0} -gt 0 ]]; then PLOT_VERDICT="PARTIAL"; PLOT_WHY+=("QP table only partially written (${QP_HAVE}/${NKPTS%.*} k-points)")
  else PLOT_VERDICT="NOT USABLE"; PLOT_WHY+=("no QP energies were written (run stopped before/inside the GW step)")
  fi
  # the underlying DFT eigenvalues may still be usable
  if ((OUTEIG_OK)); then PLOT_WHY+=("note: the preceding DFT eigenvalues ARE complete (${OUTEIG_HAVE} blocks) if you only need DFT-level bands")
  fi
elif [[ $TERM == normal || $TERM == completed-no-footer ]]; then
  PLOT_VERDICT="FULL"
  PLOT_WHY+=("run completed ($([[ $TERM == normal ]] && echo 'timing footer present' || echo 'reached required accuracy; footer absent but data complete'))")
  [[ $VR_OK == 0 ]] && PLOT_WHY+=("verify the standard outputs (vasprun.xml/EIGENVAL/PROCAR) are present in the directory")
else
  # killed mid-run, non-GW: judge by what survived to disk
  if   ((VR_OK)); then PLOT_VERDICT="PLOTTABLE"; PLOT_WHY+=("vasprun.xml is well-formed -> pymatgen Vasprun/BSVasprun will parse it")
  elif ((EIG_OK)); then PLOT_VERDICT="PLOTTABLE"; PLOT_WHY+=("EIGENVAL is complete -> read bands via pymatgen Eigenval/Procar")
  elif ((OUTEIG_OK)); then PLOT_VERDICT="PARTIAL"; PLOT_WHY+=("eigenvalues complete in OUTCAR but vasprun/EIGENVAL truncated -> scrape from OUTCAR, pymatgen XML path may fail")
  else PLOT_VERDICT="NOT USABLE"; PLOT_WHY+=("eigenvalues incomplete and vasprun.xml truncated")
  fi
  if [[ $PLOT_VERDICT == PLOTTABLE || $PLOT_VERDICT == PARTIAL ]] && [[ -s PROCAR && $PRO_OK == 0 ]]; then
    PLOT_WHY+=("but PROCAR is truncated (${PRO_HAVE} blocks) -> FAT-band overlays will fail; plain bands still OK")
  fi
fi

case "$PLOT_VERDICT" in
  FULL)        ok   "PLOTTABLE (full): $(IFS=';'; echo "${PLOT_WHY[*]}")";;
  PLOTTABLE)   ok   "PLOTTABLE: $(IFS=';'; echo "${PLOT_WHY[*]}")";;
  PARTIAL)     warn "PARTIALLY plottable: $(IFS=';'; echo "${PLOT_WHY[*]}")";;
  *)           fail "NOT usable for plotting: $(IFS=';'; echo "${PLOT_WHY[*]}")";;
esac
note "Rule of thumb: a SIGKILL (kernel OOM) can land AFTER all eigenvalues/QP energies are flushed -> still"
note "plottable; if it lands mid-write, vasprun.xml/PROCAR truncate mid-tag and pymatgen throws a parse error."

#============================ 4. ELECTRONIC SCF =============================
hdr "Electronic (SCF) convergence"
NONSCF=0; [[ $CALC_BASE == non-self* || ${ICHARG%.*} == 11 ]] && NONSCF=1
if [[ -s $OSZ ]]; then
  awk -v nelm="${NELM%.*}" '
    /^[[:space:]]*[A-Za-z]+:[[:space:]]+[0-9]+[[:space:]]/ { ec++; next }
    /F=/ { ionic++; tot+=ec; maxec=(ec>maxec?ec:maxec);
           if (nelm>0 && ec>=nelm) { stuck++; bad[stuck]=ionic" ("ec")"; } ec=0 }
    END{ printf "  ionic steps logged : %d\n", ionic;
         printf "  max SCF iters/step : %d  (NELM=%s)\n", maxec, (nelm>0?nelm:"?");
         printf "  total SCF iters    : %d\n", tot;
         if (stuck>0){ printf "  __NELMHIT__ %d step(s) hit NELM:", stuck;
            for(i=1;i<=stuck && i<=8;i++) printf " %s", bad[i]; printf "\n" } }' "$OSZ" \
  | while IFS= read -r line; do
      if [[ $line == *"__NELMHIT__"* ]]; then
        if ((NONSCF)); then note "${line#  __NELMHIT__ } (expected: fixed-charge run does not self-consist)"
        else fail "${line#  __NELMHIT__ } -> non-convergence; raise NELM, adjust mixing (AMIX/BMIX), or ALGO."; fi
      else printf '%s\n' "$line"; fi
    done
  if ! awk -v nelm="${NELM%.*}" '/^[[:space:]]*[A-Za-z]+:[[:space:]]+[0-9]+/{n=$2} /F=/{if(nelm>0 && n>=nelm)c++} END{exit (c>0?0:1)}' "$OSZ"; then
    ((NONSCF)) || ok "Every ionic step converged electronically below NELM."
  fi
else
  warn "No OSZICAR -> SCF trajectory unavailable."
fi
((NONSCF)) && note "Non-self-consistent run (ICHARG=11): charge density is frozen; 'convergence' = one diagonalisation pass. Ensure the CHGCAR came from a converged self-consistent run."

# smearing entropy per atom
EENTRO=$(grep 'EENTRO' "$OUT" | tail -n1 | awk '{print $NF}')
if [[ -n ${EENTRO:-} && ${NIONS%.*} -gt 0 ]]; then
  TSpa=$(awk -v e="$EENTRO" -v n="${NIONS%.*}" 'BEGIN{printf "%.3e", (e<0?-e:e)/n}')
  kv "Entropy |T*S|/atom (eV)" "$TSpa"
  if awk -v x="$TSpa" 'BEGIN{exit !(x>1e-3)}'; then
    warn "Smearing entropy/atom > 1 meV: metallic DOS at E_F, or SIGMA too large."
  else ok "Smearing entropy negligible -> insulating/gapped solution."; fi
fi

#============================ 5. IONIC / FORCES =============================
if [[ $CALC_BASE == *relax* ]]; then
  hdr "Ionic convergence & forces"
  if ((RELAX_DONE)); then
    ok "Relaxation converged (reached required accuracy)."
  else
    warn "No 'reached required accuracy' -> relaxation did NOT meet EDIFFG (still running / hit NSW / killed)."
  fi
  awk '
    /TOTAL-FORCE/ { inb=1; started=0; cmax=0; ss=0; n=0; next }
    inb && /^[[:space:]]*-+[[:space:]]*$/ {
      if(!started){started=1; next}
      else { blk++; traj[blk]=cmax; fmax=cmax; frms=sqrt(ss/(n>0?n:1)); fn=n; inb=0; started=0; next } }
    inb && started { m=sqrt($4*$4+$5*$5+$6*$6); if(m>cmax)cmax=m; ss+=m*m; n++ }
    /total drift:/ { dx=$3; dy=$4; dz=$5 }
    END{ if(blk==0){print "  __NOFORCE__"; exit}
         printf "  force blocks (ionic) : %d\n", blk;
         printf "  final max |F| (eV/A) : %.4f\n", fmax;
         printf "  final RMS |F| (eV/A) : %.4f   over %d atoms\n", frms, fn;
         if(dx!=""){d=sqrt(dx*dx+dy*dy+dz*dz); printf "  total drift |d|      : %.4f   [%.1e %.1e %.1e]\n", d, dx,dy,dz}
         s=(blk>12?blk-11:1); printf "  max|F| trajectory    :"; for(i=s;i<=blk;i++) printf " %.3f", traj[i]; printf "\n" }' "$OUT" \
  | while IFS= read -r l; do [[ $l == *"__NOFORCE__"* ]] && { warn "No TOTAL-FORCE block found."; continue; }; printf '%s\n' "$l"; done

  FMAX=$(awk '/TOTAL-FORCE/{inb=1;st=0;cmax=0;next}
              inb&&/^[[:space:]]*-+[[:space:]]*$/{if(!st){st=1;next}else{fm=cmax;inb=0;st=0;next}}
              inb&&st{m=sqrt($4*$4+$5*$5+$6*$6);if(m>cmax)cmax=m} END{printf "%.5f", fm}' "$OUT")
  if [[ -n ${EDIFFG:-} ]] && awk -v g="$EDIFFG" 'BEGIN{exit !(g<0)}'; then
    THR=$(awk -v g="$EDIFFG" 'BEGIN{printf "%.5f", -g}')
    if awk -v f="$FMAX" -v t="$THR" 'BEGIN{exit !(f<=t)}'; then ok "max|F|=${FMAX} <= |EDIFFG|=${THR} eV/A."
    else warn "max|F|=${FMAX} > |EDIFFG|=${THR} eV/A (selective-dynamics-fixed atoms excluded by VASP's own test)."; fi
  else note "EDIFFG>=0 -> energy-based stopping; force threshold not applied."; fi

  if [[ -s $OSZ ]]; then
    awk '/F=/{e=$3; gsub(/[Dd]/,"E",e); v[++k]=e+0}
         END{ if(k<2){print "  single ionic point (monotonicity n/a)"; exit}
              up=0; for(i=2;i<=k;i++) if(v[i]>v[i-1]+1e-6) up++;
              printf "  ionic energy steps   : %d   dE(last)= %.3e eV\n", k, v[k]-v[k-1];
              if(up>0) printf "  __ENUP__ %d uphill energy move(s) (step too large / rough PES?)\n", up;
              else     printf "  energy monotonically non-increasing across ionic steps.\n" }' "$OSZ" \
    | while IFS= read -r l; do [[ $l == *"__ENUP__"* ]] && { warn "${l#  __ENUP__ }"; continue; }; printf '%s\n' "$l"; done
  fi
fi

#============================ 6. CELL / STRESS =============================
if [[ $CALC_BASE == *relax* || $CALC_BASE == "static SCF" || ((gw_family)) ]]; then
  hdr "Cell, volume & stress"
  VOL=$(grep 'volume of cell' "$OUT" | tail -n1 | awk '{print $NF}')
  kv "Final cell volume (A^3)" "${VOL:-?}"
  LV=$(grep -A1 'length of vectors' "$OUT" | tail -n1)
  [[ -n $LV ]] && kv "|a| |b| |c| (A)" "$(echo "$LV" | awk '{printf "%.4f %.4f %.4f", $1,$2,$3}')"
  PRESS=$(grep 'external pressure' "$OUT" | tail -n1)
  if [[ -n $PRESS ]]; then
    P=$(echo "$PRESS" | awk '{for(i=1;i<=NF;i++) if($i=="pressure"){print $(i+2); break}}')
    PUL=$(echo "$PRESS" | awk '{print $(NF-1)}')
    kv "External pressure (kB)" "${P:-?}   (Pulay corr ~ ${PUL:-?} kB)"
    if [[ $CALC_BASE == *cell* ]] && awk -v p="${P:-0}" 'BEGIN{exit !((p<0?-p:p)>5)}'; then
      warn "Residual |pressure| > 5 kB after a cell relaxation -> raise ENCUT/PREC and re-relax (Pulay stress)."
    fi
  fi
fi

#======================= 7. MAGNETIZATION ===================================
if [[ ${ISPIN%.*} == 2 || $LSORBIT == T ]]; then
  hdr "Magnetization"
  NETMAG=$(awk '/mag=/{for(i=1;i<=NF;i++) if($i=="mag="){m=$(i+1)}} END{print m}' "$OSZ" 2>/dev/null)
  # fallback: VASP prints "number of electron  N   magnetization  M" each step (independent of LORBIT)
  [[ -z ${NETMAG:-} ]] && NETMAG=$(awk '/number of electron/ && /magnetization/{m=$NF} END{print m}' "$OUT")
  [[ -n ${NETMAG:-} ]] && kv "Net cell moment (uB)" "$NETMAG"
  PERAT=$(awk '
    /magnetization \(x\)/ { cap=1; n=0; delete v; next }
    cap && /# of ion/      { hd=1; next }
    cap && hd && /^[[:space:]]*-+/ { dash++; if(dash==2){cap=0;hd=0;dash=0}; next }
    cap && hd && /^[[:space:]]*[0-9]+[[:space:]]/ { n++; v[n]=$NF }
    END{ for(i=1;i<=n;i++) printf "%d:%.3f ", i, v[i] }' "$OUT")
  if [[ -n $PERAT ]]; then
    note "per-atom m_tot (uB):"
    printf '%s\n' "$PERAT" | tr ' ' '\n' | awk -F: 'NF==2{printf "  ion %-4s % 7.3f", $1, $2; if(++c%5==0)printf "\n"} END{if(c%5)printf "\n"}'
    awk -v s="$PERAT" 'BEGIN{
      n=split(s,a," "); sum=0; absmax=0; nbig=0;
      for(i=1;i<=n;i++){ split(a[i],b,":"); m=b[2]+0; sum+=m; am=(m<0?-m:m); if(am>absmax)absmax=am; if(am>0.2)nbig++ }
      printf "  sum m = %+.3f uB ; max|m| = %.3f uB ; sites |m|>0.2 = %d\n", sum, absmax, nbig;
      if(absmax<0.1){ print "__NONMAG__" }
      else if((sum<0?-sum:sum)<0.1 && nbig>=2){ print "__AFM__" } }' \
    | while IFS= read -r l; do case "$l" in
        *__NONMAG__*) note "Negligible local moments everywhere -> nonmagnetic solution (consistent with closed-shell ions, e.g. Cu+ d10 / V5+ d0). If you expected magnetism, re-seed MAGMOM, check NUPDOWN and ISYM.";;
        *__AFM__*)    ok "Zero net moment but large alternating local moments -> antiferromagnetic ordering (physical).";;
        *)            printf '%s\n' "$l";; esac; done
  else
    if [[ -n ${NETMAG:-} ]] && awk -v m="$NETMAG" 'BEGIN{exit !((m<0?-m:m)<0.05)}'; then
      note "Per-atom block absent (LORBIT=0), but net moment ~0 -> nonmagnetic / fully compensated. Set LORBIT=11 to resolve per-site moments (AFM vs nonmagnetic)."
    else
      note "Per-atom magnetization block not found (set LORBIT=10/11 to print per-site moments)."
    fi
  fi
fi

#==================== 8. EIGENVALUES / OCCUPATIONS / GAP ====================
hdr "Eigenvalues, occupations & gap (KS / DFT+U)"
EF=$(grep 'E-fermi' "$OUT" | tail -n1 | awk '{for(i=1;i<=NF;i++) if($i=="E-fermi"){print $(i+2); break}}')
kv "E-fermi (eV)" "${EF:-?}"

# --- VASP's OWN gap determination (authoritative; prints VBM/CBM with k-coords) ---
awk '
  /val\. band max:/ {
    for(i=1;i<=NF;i++) if($i=="@"){ai=i} ; for(i=1;i<=NF;i++) if($i=="="){ei=i}
    vmax=$(ai-1)+0; vx=$(ei+1); vy=$(ei+2); vz=$(ei+3); next }
  /cond\. band min:/ {
    for(i=1;i<=NF;i++) if($i=="@"){ai=i} ; for(i=1;i<=NF;i++) if($i=="="){ei=i}
    cmin=$(ai-1)+0; cx=$(ei+1); cy=$(ei+2); cz=$(ei+3); next }
  /fundamental gap:/ { g=$NF+0; sg=g; svm=vmax; scm=cmin; svx=vx;svy=vy;svz=vz; scx=cx;scy=cy;scz=cz; got=1; next }
  END{
    if(!got){ print "NOVASPGAP"; exit }
    kind=(svx==scx && svy==scy && svz==scz ? "DIRECT":"INDIRECT");
    printf "  fundamental gap (VASP): %.4f eV   (%s)\n", sg, kind;
    printf "  VBM (val. band max)  : % .4f eV   @ k = (%s %s %s)\n", svm, svx,svy,svz;
    printf "  CBM (cond. band min) : % .4f eV   @ k = (%s %s %s)\n", scm, scx,scy,scz;
  }' "$OUT" \
| while IFS= read -r l; do
    [[ $l == NOVASPGAP ]] && { note "VASP did not print an explicit gap block (metal, or ISMEAR/run type suppresses it) -> using occupation scan below."; continue; }
    printf '%s\n' "$l"
  done

# --- independent occupation-based cross-check (also catches partial occupancy / metal) ---
awk -v ef="${EF:-0}" '
  function abs(x){return x<0?-x:x}
  /spin component/ { sp=$NF+0; next }
  /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ {
    for(i=1;i<=NF;i++) if($i==":"){ci=i; break}
    kp=$(ci-1)+0; KX[kp]=$(ci+1); KY[kp]=$(ci+2); KZ[kp]=$(ci+3); inb=0; next }
  /band No\./ && $0 !~ /KS-energies/ { inb=1; if(sp=="")sp=1; next }   # DFT occ block only, not QP table
  inb && $1 ~ /^[0-9]+$/ && NF>=3 {
    bi=$1+0; en=$2+0; oc=$3+0; key=sp SUBSEP kp SUBSEP bi;
    E[key]=en; O[key]=oc; SP[key]=sp; KPk[key]=kp; BI[key]=bi; SEEN[key]=1;
    if(oc>omax)omax=oc;
    next }
  inb && /^[[:space:]]*$/ { inb=0 }
  END{
    nn=0; for(k in SEEN)nn++; if(nn==0||omax<=0){print "NODATA"; exit}
    full=omax; occT=0.5*full; plo=0.02*full; phi=0.98*full;
    vbm=-1e30; cbm=1e30; vkk=""; ckk=""; vss=""; css=""; vbi=""; cbi="";
    for(k in SEEN){ e=E[k]; o=O[k]; kp=KPk[k];
      if(o>occT){ if(e>vbm){vbm=e;vkk=kp;vss=SP[k];vbi=BI[k]}
                  if(!(kp in vk) || e>vk[kp]) vk[kp]=e }
      else      { if(e<cbm){cbm=e;ckk=kp;css=SP[k];cbi=BI[k]}
                  if(!(kp in ck) || e<ck[kp]) ck[kp]=e } }
    printf "  full occupancy (norm): %.4f\n", full;
    printf "  [xcheck] highest occ  : % .4f eV   band %s spin %s  k-pt %s  (% .5f % .5f % .5f)\n", vbm,vbi,vss,vkk,KX[vkk],KY[vkk],KZ[vkk];
    printf "  [xcheck] lowest unocc : % .4f eV   band %s spin %s  k-pt %s  (% .5f % .5f % .5f)\n", cbm,cbi,css,ckk,KX[ckk],KY[ckk],KZ[ckk];
    gap=cbm-vbm;
    if(gap>0.02){
      kind=(vkk==ckk?"DIRECT":"INDIRECT");
      printf "  [xcheck] gap (occ)    : %.4f eV  (%s)\n", gap, kind;
      if(vss!=css) printf "  (VBM and CBM are in different spin channels)\n";
      # smallest vertical (direct) gap over k-points where both defined
      dg=1e30; dgk="";
      for(kp in vk){ if(kp in ck){ d=ck[kp]-vk[kp]; if(d>0 && d<dg){dg=d; dgk=kp} } }
      if(dg<1e29) printf "  direct (vertical) gap: %.4f eV  at k-pt %s  (% .5f % .5f % .5f)\n", dg, dgk, KX[dgk],KY[dgk],KZ[dgk];
      printf "  VBM/CBM rel. E_fermi : % .3f / % .3f eV\n", vbm-ef, cbm-ef;
      np=0; for(k in SEEN){o=O[k]; if(o>plo&&o<phi)np++}
      if(np==0) print "__INSULATOR__"; else printf "  %d partially-occupied state(s) near E_F\n", np;
    } else { printf "  [xcheck] gap (occ)    : %.4f eV\n", (gap>0?gap:0); print "__METAL__"; }
  }' "$OUT" \
| while IFS= read -r l; do case "$l" in
    NODATA) warn "No final eigenvalue block in OUTCAR (NWRITE too low or truncated).";;
    *__INSULATOR__*) ok "No partial occupations across E_F -> clean insulator/semiconductor.";;
    *__METAL__*)     warn "VBM>=CBM with fractional occupations -> metallic (or smearing bridges a tiny gap).";;
    *) printf '%s\n' "$l";; esac; done
note "This is the Kohn-Sham (DFT/DFT+U) gap. For the optical/QP gap use the GW section."

#=================== 8b. OCCUPIED BANDS & NBANDS FOR GW =====================
# Robust count of occupied bands -> the anchor for NBANDS in the GW first step
# (exact diagonalization, ALGO=Exact). Ref: vasp.at/wiki/Practical_guide_to_GW_calculations
hdr "Occupied bands & NBANDS (first GW step: exact diagonalization)"
NELECT=$(awk '/NELECT/{for(i=1;i<=NF;i++) if($i=="NELECT"){print $(i+2); exit}}' "$OUT")
NONCOL=$(getlog LNONCOLLINEAR)
# per-spin full occupancy: 1.0 for ISPIN=2 or non-collinear/SOC; 2.0 for spin-paired ISPIN=1
if [[ ${ISPIN%.*} == 2 || $NONCOL == T || $LSORBIT == T ]]; then FMAX=1.0; SPINPAIR=0; else FMAX=2.0; SPINPAIR=1; fi

# Count from the FINAL eigenvalue dump only (everything after the last "E-fermi :" line),
# so multi-step relaxations report the converged occupation, not an early step.
EFLINE=$(grep -n 'E-fermi' "$OUT" | tail -1 | cut -d: -f1)
OCC_INFO=$(tail -n +"${EFLINE:-1}" "$OUT" 2>/dev/null | awk -v fmax="$FMAX" '
  /spin component/ { sp=$NF+0; next }
  /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ { kp=$2+0; if(sp=="")sp=1; occ[sp,kp]=0; next }
  /band No\./ && $0 !~ /KS-energies/ { inb=1; if(sp=="")sp=1; next }
  inb && $1 ~ /^[0-9]+$/ && NF>=3 {
    b=$1+0; o=$3+0; if(o>mo)mo=o;
    if(o > 0.5*fmax){ occ[sp,kp]++; if(b>hi[sp])hi[sp]=b }
    if(o > 0.05*fmax && o < 0.95*fmax){ part++; if(b>hipart)hipart=b }
    next }
  inb && /^[[:space:]]*$/ { inb=0 }
  END{
    for(key in occ){ split(key,a,SUBSEP); s=a[1]; if(occ[key]>nmax[s])nmax[s]=occ[key] }
    n1=(1 in nmax)?nmax[1]:0; n2=(2 in nmax)?nmax[2]:0; nocc=(n1>n2?n1:n2);
    printf "%d %d %d %.4f %d %d\n", nocc, n1, n2, mo+0, part+0, hipart+0
  }')
read NOCC NOCC1 NOCC2 MAXOCC NPART HIPART <<<"${OCC_INFO:-0 0 0 0 0 0}"
N_OCC=${NOCC:-0}

# expected occupied bands from the electron count (independent cross-check)
NEXP=$(awk -v ne="${NELECT:-0}" -v isp="${ISPIN%.*}" -v nc="$NONCOL" -v so="$LSORBIT" -v mag="${NETMAG:-0}" 'BEGIN{
  m=(mag<0?-mag:mag);
  if(nc=="T"||so=="T") e=ne;        # 1 electron per spinor band
  else if(isp==2)      e=(ne+m)/2;  # the larger spin channel sets NBANDS
  else                 e=ne/2;      # 2 electrons per band
  printf "%.0f", e }')

if [[ ${N_OCC:-0} -gt 0 ]]; then
  kv "electrons (NELECT)" "${NELECT:-?}"
  if   [[ $NONCOL == T || $LSORBIT == T ]]; then kv "spin treatment" "non-collinear / SOC (spinor bands, 1 e-/band)"
  elif ((SPINPAIR));                        then kv "spin treatment" "spin-paired (ISPIN=1, 2 e-/band)"
  else kv "spin treatment" "collinear spin-polarised (ISPIN=2, 1 e-/band/spin)"; fi
  if [[ ${ISPIN%.*} == 2 && ${NOCC1:-0} -ne ${NOCC2:-0} ]]; then
    kv "occupied bands N_occ" "${N_OCC}   (spin-up ${NOCC1} / spin-down ${NOCC2}; NBANDS is per spin -> use the larger)"
  elif [[ ${ISPIN%.*} == 2 ]]; then
    kv "occupied bands N_occ" "${N_OCC}   (per spin; both channels equal -> non-magnetic)"
  else
    kv "occupied bands N_occ" "${N_OCC}"
  fi
  if [[ ${N_OCC} == ${NEXP} ]]; then
    ok "Cross-check vs NELECT: ${NEXP} occupied bands -> agrees (count is exact)."
  else
    warn "Occupation count (${N_OCC}) != NELECT-derived (${NEXP}): partial occupancies or a spin-imbalanced/odd-electron case -> verify before trusting N_occ."
  fi
  kv "highest occ / first empty (LUMO)" "band ${N_OCC} / band $((N_OCC+1))"
  if [[ ${NPART:-0} -eq 0 ]]; then
    ok "No partial occupancies (max f=${MAXOCC} of ${FMAX}) -> N_occ is an exact integer."
  else
    warn "${NPART} partially-occupied band(s) (highest at band ${HIPART}) -> metallic/smeared; N_occ is fuzzy."
    tip "GW needs integer occupancies: keep ISMEAR=0 with a small SIGMA (the wiki: 'small sigma is required to avoid partial occupancies')."
  fi

  # plane-wave ceiling = the most orbitals VASP can diagonalize at this ENCUT
  PWMAX=$(grep -iE 'maximum number of plane-waves' "$OUT" | head -1 | awk '{print $NF+0}')
  PWMIN=$(grep -E '^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:.*plane waves' "$OUT" | awk '{n=$NF+0; if(min==""||n<min)min=n} END{print min+0}')
  CEIL=${PWMIN:-$PWMAX}
  nb=${NBANDS%.*}
  echo "  ---- sizing NBANDS for the ALGO=Exact step ----"
  [[ ${CEIL:-0} -gt 0 ]] && kv "plane-wave ceiling" "~${CEIL} bands (max VASP can diagonalize at ENCUT=${ENCUT:-?} eV; the basis limit)"
  if [[ ${nb:-0} -gt 0 ]]; then
    kv "this OUTCAR: NBANDS" "${nb}  ->  $((nb - N_OCC)) empty band(s) above N_occ"
  fi
  tip "First GW step (per the VASP GW guide): ALGO=Exact, NELM=1, LOPTICS=.TRUE., ISMEAR=0/SIGMA=0.05, restart from the"
  tip "converged ground-state WAVECAR. Set NBANDS well above N_occ=${N_OCC} and CONVERGE the QP gap vs NBANDS *and* ENCUTGW"
  tip "together; the guide recommends taking as many empty states as the basis allows (toward ~${CEIL:-the PW limit})."
  if [[ ${nb:-0} -gt 0 ]]; then
    tip "For pure-MPI: make NBANDS a multiple of the MPI ranks-per-k-point (= total ranks / KPAR) so VASP does not silently raise it."
  fi
else
  note "No final eigenvalue/occupation block found -> cannot determine occupied bands (NWRITE too low, or OUTCAR truncated before the eigenvalues)."
fi

#======================= 9. G0W0 / GW QUASIPARTICLE ========================
if ((gw_family)); then
  hdr "GW / quasiparticle analysis"
  awk '
    function abs(x){return x<0?-x:x}
    /QP shifts/ && /iteration/ {        # start of a new GW/QP iteration -> reset
      delete SEEN; delete KS; delete QP; delete ZZ; delete OC; delete KPk; delete BI;
      niter++; next }
    /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ {
      for(i=1;i<=NF;i++) if($i==":"){ci=i;break}
      kp=$(ci-1)+0; KX[kp]=$(ci+1); KY[kp]=$(ci+2); KZ[kp]=$(ci+3); inb=0; next }
    /KS-energies/ && /QP-energies/ {    # per-k-point column header: detect columns only
      col=0; zc=0; ocl=0;
      for(i=1;i<=NF;i++){ tok=$i; if(tok=="No."||tok=="no.")continue; col++; U=toupper(tok);
                          if(U=="Z")zc=col; if(U ~ /OCCUPATION/)ocl=col }
      inb=1; next }
    inb && $1 ~ /^[0-9]+$/ {
      b=$1+0; ks=$2+0; qp=$3+0;
      z=(zc>0 && zc<=NF)?$zc+0:0; o=(ocl>0 && ocl<=NF)?$ocl+0:$NF+0;
      key=kp SUBSEP b; SEEN[key]=1; KS[key]=ks; QP[key]=qp; ZZ[key]=z; OC[key]=o; KPk[key]=kp; BI[key]=b; next }
    inb && /^[[:space:]]*$/ { inb=0 }
    END{
      nc=0; for(k in SEEN)nc++;
      if(nc==0){print "NOQP"; exit}
      if(niter==0) niter=1;            # single-shot G0W0 may not print a "QP shifts" banner
      ksv=-1e30;ksc=1e30;qpv=-1e30;qpc=1e30; zs=0;zn=0; vkk="";ckk="";vbi="";cbi="";
      for(k in SEEN){
        if(OC[k]>0.5){ if(KS[k]>ksv)ksv=KS[k]; if(QP[k]>qpv){qpv=QP[k];vkk=KPk[k];vbi=BI[k]} }
        else         { if(KS[k]<ksc)ksc=KS[k]; if(QP[k]<qpc){qpc=QP[k];ckk=KPk[k];cbi=BI[k]} }
        if(ZZ[k]>0.01 && ZZ[k]<1.5){ zs+=ZZ[k]; zn++ } }
      ksgap=ksc-ksv; qpgap=qpc-qpv;
      printf "  GW iterations (tables): %d\n", niter;
      printf "  KS gap (DFT input)   : %.4f eV\n", ksgap;
      kind=(vkk==ckk?"DIRECT":"INDIRECT");
      printf "  QP gap (GW)          : %.4f eV  (%s)\n", qpgap, kind;
      printf "  gap renormalisation  : %+.4f eV  (QP - KS)\n", qpgap-ksgap;
      printf "  QP VBM               : % .4f eV  band %s k-pt %s  (% .5f % .5f % .5f)\n", qpv,vbi,vkk,KX[vkk],KY[vkk],KZ[vkk];
      printf "  QP CBM               : % .4f eV  band %s k-pt %s  (% .5f % .5f % .5f)\n", qpc,cbi,ckk,KX[ckk],KY[ckk],KZ[ckk];
      if(zn>0){ printf "  mean Z (renorm.)     : %.3f  over %d states\n", zs/zn, zn;
                if(zs/zn<0.6) print "__LOWZ__" }
    }' "$OUT" \
  | while IFS= read -r l; do case "$l" in
      NOQP)       warn "No 'KS-energies/QP-energies' table found -> not a finished GW run, or output not written (likely killed before the QP step).";;
      *__LOWZ__*) warn "Mean Z < 0.6: strong self-energy / near-breakdown of perturbation theory -> check NBANDS, NOMEGA, ENCUTGW convergence.";;
      *) printf '%s\n' "$l";; esac; done
  note "GW gaps converge SLOWLY in NBANDS and NOMEGA, and ~ENCUTGW^3 in basis. Verify against a convergence series."
fi

#======================= 10. PITFALLS & RECOMMENDATIONS =====================
hdr "Pitfalls & recommendations"
ISM=${ISMEAR%.*}

# --- smearing choice vs calculation type ---
if [[ $ISM =~ ^-?[0-9]+$ ]]; then
  if [[ $CALC_BASE == *relax* && $ISM == -5 ]]; then
    warn "ISMEAR=-5 (tetrahedron) gives poor FORCES/stress -> use ISMEAR=0 (or 1/2) during relaxation."
  fi
  if [[ ( $CALC_BASE == "static SCF" || $CALC_BASE == non-self* ) && $ISM -ge 1 ]]; then
    tip "ISMEAR>=1 (Methfessel-Paxton) is for metals; for an insulator/DOS use ISMEAR=-5 (tetrahedron) or 0."
  fi
  if [[ $ISM == -5 && -n ${NKPTS:-} && ${NKPTS%.*} -lt 4 ]]; then
    warn "ISMEAR=-5 with very few k-points (${NKPTS}) -> tetrahedron method is unreliable / VASP may refuse."
  fi
  if [[ $ISM -ge 0 ]] && awk -v s="${SIGMA:-0}" 'BEGIN{exit !(s>0 && s<0.005)}'; then
    warn "ISMEAR>=0 with SIGMA<0.005 eV: occupations can flicker / SCF oscillate; ~0.02-0.05 eV is safer."
  fi
fi

# --- LDA+U geometry consistency (your CuVS3 0_GGA -> 1_GGA_U workflow) ---
if [[ $LDAU == T && ( $CALC_BASE == "static SCF" || ((gw_family)) ) ]]; then
  warn "LDA+U active in a non-relaxing run: make sure the GEOMETRY was relaxed with the SAME LDAU settings."
  tip "A +U static on a plain-GGA geometry is inconsistent; re-relax under identical LDAUU/LDAUL/LDAUJ first."
  tip "Note: a large U applied to a nominally EMPTY d-shell (e.g. V5+ d0) acts mostly as a conduction-band shift,"
  tip "not as a self-interaction correction. Sanity-check whether U belongs on that shell at all."
fi

# --- GW-specific knobs ---
if ((gw_family)); then
  if [[ -n ${NCORE:-} && ${NCORE%.*} -gt 1 ]]; then
    fail "NCORE=${NCORE} with GW: GW requires NCORE=1. Parallelise over k-points with KPAR instead."
  fi
  if [[ -z $ENCUTGW_SET ]]; then
    warn "ENCUTGW not set in INCAR -> defaulted to 2/3*ENCUT = ~$(awk -v e="${ENCUT:-0}" 'BEGIN{printf "%.0f", e*2.0/3.0}') eV."
    tip "ENCUTGW is the dominant memory knob (~cube). Set it explicitly and converge it; this also fixes the"
    tip "GW memory estimate you have been calibrating (the commented-out ENCUTGW was the missing anchor value)."
  fi
  if [[ -n ${NBANDS:-} && -n ${NBANDSGW:-} ]] && awk -v a="${NBANDS%.*}" -v b="${NBANDSGW%.*}" 'BEGIN{exit !(b>0 && b>0.8*a)}'; then
    warn "NBANDSGW (${NBANDSGW}) is close to NBANDS (${NBANDS}); GW needs MANY empty bands -> increase NBANDS."
  fi
  tip "The DFT step feeding GW must be well converged with plenty of empty states (LOPTICS=.TRUE., large NBANDS)."
fi

# --- KPAR divisibility (your KPAR=21 vs NKPTS=96 lesson) ---
if [[ -n ${KPAR:-} && ${KPAR%.*} -gt 1 && -n ${NKPTS:-} && ${NKPTS%.*} -gt 0 ]]; then
  if (( ${NKPTS%.*} % ${KPAR%.*} != 0 )); then
    warn "KPAR=${KPAR} does not divide NKPTS=${NKPTS} -> uneven k-group load (idle ranks). Pick a divisor of NKPTS."
  fi
fi

# --- NBANDS headroom for the gap (reuses the robust N_occ from the occupied-bands section) ---
if [[ -n ${NBANDS:-} && ${N_OCC:-0} -gt 0 ]]; then
  nb=${NBANDS%.*}; head=$(( nb - N_OCC ))
  if ((gw_family)); then
    if (( head < nb/4 )); then
      warn "GW with only ${head} empty bands above N_occ=${N_OCC} -> the screened interaction / QP energies are under-converged."
      tip "GW typically needs hundreds of empty bands; raise NBANDS substantially (and converge it) in the exact-diagonalization step."
    fi
  else
    if (( head < 2 )); then
      warn "Highest occupied band is at/next to NBANDS=${nb} (only ${head} empty): CBM/DOS tail unreliable; raise NBANDS."
    elif (( head < 4 )); then
      note "Only ${head} empty bands above N_occ=${N_OCC} -> fine for the gap, thin for an unoccupied-DOS tail or as a GW starting point."
    fi
  fi
fi

# --- band-plot smoothness (jagged-band diagnosis) ---
if [[ $CALC_BASE == non-self* ]]; then
  tip "Jagged/'ripped' bands have THREE causes: (a) plotter connectivity at crossings, (b) too few k-points per"
  tip "segment in the line-mode KPOINTS, (c) NBANDS-ceiling noise. Diagnose separately; (b) is the usual fix here."
fi

[[ $WARNS == 0 && $FAILS == 0 ]] && ok "No pitfalls flagged for this configuration."

#============================ FINAL VERDICT =================================
hdr "Verdict"
ETOT=$(grep 'free  energy   TOTEN' "$OUT" | tail -n1 | awk '{print $(NF-1)}')
ESIG0=$(grep 'energy(sigma->0)' "$OUT" | tail -n1 | awk '{print $NF}')
[[ -n ${ETOT:-} ]]  && kv "Final TOTEN (eV)"      "$ETOT"
[[ -n ${ESIG0:-} ]] && kv "energy(sigma->0) (eV)" "$ESIG0"
if [[ -n ${ETOT:-} && ${NIONS%.*} -gt 0 ]]; then
  kv "Energy / atom (eV)" "$(awk -v e="$ETOT" -v n="${NIONS%.*}" 'BEGIN{printf "%.6f", e/n}')"
fi
kv "Calculation"  "$CALC_BASE  [$CALC_XC]"
case "$TERM" in
  normal)              kv "Termination" "normal (timing footer present)";;
  completed-no-footer) kv "Termination" "completed (reached required accuracy; footer absent -> OUTCAR truncated post-run, not a crash)";;
  *)                   kv "Termination" "KILLED: ${KILL_REASON:-cause not determined}";;
esac
kv "Plottability" "$PLOT_VERDICT"

echo
if [[ $FAILS -gt 0 ]]; then
  printf '%s%s OVERALL: FAIL  (%d failed, %d warnings)%s\n' "$B" "$RED" "$FAILS" "$WARNS" "$R"; exit 1
elif [[ $WARNS -gt 0 ]]; then
  printf '%s%s OVERALL: PASS with %d warning(s)%s\n' "$B" "$YEL" "$WARNS" "$R"; exit 0
else
  printf '%s%s OVERALL: PASS - clean, converged, physically consistent%s\n' "$B" "$GRN" "$R"; exit 0
fi
