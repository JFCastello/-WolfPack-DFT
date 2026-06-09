#!/usr/bin/env bash
###############################################################################
# vasp_configure.sh   (invoked on PATH as: vasp-configure)
#
# Build the WolfPack-DFT *cluster profile* -- the small file that tells the
# SLURM-emitting tools (vasp-recommend-slurm, vasp-dry-run, vasp-test) how YOUR
# cluster looks, so they stop being hard-wired to one machine:
#
#   * your notification email,
#   * which VASP module(s) to load (you pick the version and the modules),
#   * the names of your debug and main partitions,
#   * cores-per-node and memory-per-node for each,
#   * the maximum number of cores you may request.
#
# Detected values (Lmod/Environment-Modules, sinfo, sacctmgr) are offered as
# defaults; you confirm or edit every one. The result is written to
#
#       ~/.config/wolfpack-dft/cluster.conf   (override with --conf / $WOLFPACK_CLUSTER_CONF)
#
# a plain KEY="value" file, sourced by the shell scripts and parsed by
# vasp-recommend-slurm. Re-run any time to update it.
#
# USAGE
#   vasp-configure                    # interactive wizard
#   vasp-configure --non-interactive  # detect + defaults, no prompts
#   vasp-configure --vasp-modules "aocc/4.2.0 vasp/6.5.0-mpi-zen4-h"
#   vasp-configure --show             # print the current profile and exit
#   vasp-configure --edit             # hand-edit the profile in $EDITOR
#   vasp-configure --verify           # load the modules and check vasp_std
#   vasp-configure --help
#
# FLAGS (all optional; a provided value pre-fills the wizard / is used as-is
# in --non-interactive mode):
#   --email STR            --vasp-modules "STR"     --vasp-std NAME
#   --main-partition NAME  --debug-partition NAME
#   --main-cpus N          --debug-cpus N
#   --main-mem MB          --debug-mem MB           --max-cores N
#   --module-cmd {ml,module}
#   --conf PATH            --non-interactive | -y    --show  --edit  --verify
#
# IF A JOB DIES WITH "execve(): vasp_std: No such file or directory"
#   The configured modules don't put vasp_std on PATH (usually a missing
#   compiler/MPI prerequisite). No reinstall needed:
#       vasp-configure --verify   # report whether the modules expose vasp_std
#       vasp-configure            # re-run and set the module line (add the compiler)
#       vasp-configure --edit     # hand-edit WP_VASP_MODULES
###############################################################################
set -uo pipefail

CONF="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
INTERACTIVE=1; SHOW_ONLY=0; EDIT_ONLY=0; VERIFY_ONLY=0

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_rst} $*"; }
note() { printf '%s\n' "    ${c_cya}$*${c_rst}"; }
warn() { printf '%s\n' "    ${c_yel}WARN${c_rst} $*" >&2; }
usage(){ sed -n '2,53p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0; }

# --------------------------------------------------------------------------- #
# Profile variables (pre-seeded by flags / detection / prompts)
# --------------------------------------------------------------------------- #
WP_EMAIL=""; WP_MODULE_CMD=""; WP_MODULE_PURGE="1"; WP_VASP_MODULES=""
WP_VASP_STD="vasp_std"; WP_VASP_GAM="vasp_gam"; WP_VASP_NCL="vasp_ncl"
WP_EXTRA_ENV="export OMP_NUM_THREADS=1;export MKL_NUM_THREADS=1"
WP_MAIN_PARTITION=""; WP_DEBUG_PARTITION=""
WP_MAIN_CPUS_PER_NODE=""; WP_DEBUG_CPUS_PER_NODE=""
WP_MAIN_MEM_PER_NODE_MB=""; WP_DEBUG_MEM_PER_NODE_MB=""
WP_MAIN_NUMA_CORES=""; WP_MAX_CORES=""

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)            WP_EMAIL="${2:?}"; shift 2 ;;
        --module-cmd)       WP_MODULE_CMD="${2:?}"; shift 2 ;;
        --vasp-modules)     WP_VASP_MODULES="${2:?}"; shift 2 ;;
        --vasp-std)         WP_VASP_STD="${2:?}"; shift 2 ;;
        --main-partition)   WP_MAIN_PARTITION="${2:?}"; shift 2 ;;
        --debug-partition)  WP_DEBUG_PARTITION="${2:?}"; shift 2 ;;
        --main-cpus)        WP_MAIN_CPUS_PER_NODE="${2:?}"; shift 2 ;;
        --debug-cpus)       WP_DEBUG_CPUS_PER_NODE="${2:?}"; shift 2 ;;
        --main-mem)         WP_MAIN_MEM_PER_NODE_MB="${2:?}"; shift 2 ;;
        --debug-mem)        WP_DEBUG_MEM_PER_NODE_MB="${2:?}"; shift 2 ;;
        --max-cores)        WP_MAX_CORES="${2:?}"; shift 2 ;;
        --conf)             CONF="${2:?}"; shift 2 ;;
        -y|--non-interactive) INTERACTIVE=0; shift ;;
        --show)             SHOW_ONLY=1; shift ;;
        --edit)             EDIT_ONLY=1; shift ;;
        --verify)           VERIFY_ONLY=1; shift ;;
        -h|--help)          usage ;;
        *) warn "Unknown option: $1"; echo "Try: vasp-configure --help" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
ask() {  # ask VARNAME "prompt" "default"   (keeps default on empty / non-interactive)
    local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
    if [[ $INTERACTIVE -eq 0 ]]; then printf -v "$__var" '%s' "$__def"; return; fi
    if [[ -n "$__def" ]]; then read -r -p "    $__prompt [$__def]: " __ans || true
    else                      read -r -p "    $__prompt: " __ans || true; fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# Make module / ml callable in this (possibly non-login) shell if we can.
if ! type module >/dev/null 2>&1 && ! type ml >/dev/null 2>&1; then
    for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh \
             "${LMOD_PKG:-}/init/bash" "${MODULESHOME:-}/init/bash"; do
        [[ -n "$f" && -f "$f" ]] && { source "$f" 2>/dev/null && break; }
    done
fi
have_modules() { type module >/dev/null 2>&1 || type ml >/dev/null 2>&1; }
run_module()   { if type module >/dev/null 2>&1; then module "$@"
                 elif type ml >/dev/null 2>&1; then ml "$@"; else return 127; fi; }

# Auto-pick the loader command and keep it valid (only ml / module).
[[ -z "$WP_MODULE_CMD" ]] && { type ml >/dev/null 2>&1 && WP_MODULE_CMD=ml || WP_MODULE_CMD=module; }
case "$WP_MODULE_CMD" in ml|module) ;; *) WP_MODULE_CMD=ml ;; esac

# Load a module list ($1) and report whether the executable ($2, default
# vasp_std) lands on PATH. Runs in a throwaway subshell; 0=ok 1=fail 2=can't test.
verify_modules() {
    local mods="$1" exe="${2:-vasp_std}"
    [[ -z "$mods" ]] && return 2
    have_modules || return 2
    ( run_module purge >/dev/null 2>&1 || true
      # shellcheck disable=SC2086  (word-split the module list on purpose)
      if [[ "$WP_MODULE_CMD" == module ]]; then module load $mods >/dev/null 2>&1 || true
      else ml $mods >/dev/null 2>&1 || true; fi
      command -v "$exe" >/dev/null 2>&1 )
}

# Echo the Lmod error lines from loading $1 (for diagnostics).
diagnose_modules() {
    local mods="$1" err
    # shellcheck disable=SC2086
    err=$( { run_module purge
             if [[ "$WP_MODULE_CMD" == module ]]; then module load $mods; else ml $mods; fi
           } 2>&1 1>/dev/null )
    printf '%s\n' "$err" | grep -iE 'error|cannot be loaded|unknown|not found|conflict' | head -6
}

# List VASP modules from 'module avail'/'spider' (names only).
detect_vasp_modules() {
    { run_module -t avail 2>&1; run_module -t spider 2>&1; } 2>/dev/null \
      | grep -iE 'vasp' \
      | sed -E 's/[[:space:]]*$//; s/\(default\)//I; s/:$//' \
      | grep -vE '^/|^[[:space:]]*$' \
      | awk '{$1=$1; print}' | sort -u
}

# Suggest the prerequisite line (compiler/MPI) for a module from 'module spider'
# -- just the first "you will need to load" line, not the whole dependency tree.
detect_prereqs() {
    local out; out="$(run_module spider "$1" 2>&1)" || return 0
    printf '%s\n' "$out" | awk '
        /You will need to load all module/ {grab=1; next}
        grab && NF { sub(/^[[:space:]]+/,""); gsub(/[[:space:]]+/," "); print; exit }'
}

sinfo_partitions() { command -v sinfo >/dev/null 2>&1 && sinfo -h -o "%P" 2>/dev/null; }
default_partition() { sinfo_partitions | tr ' ' '\n' | grep '\*' | tr -d '* ' | head -1; }
guess_debug_part()  { sinfo_partitions | tr ' *' '\n\n' | grep -iE 'debug|devel|test|short' | head -1; }
cpus_of()  { command -v sinfo >/dev/null 2>&1 && sinfo -h -p "$1" -o "%c" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1; }
mem_of()   { command -v sinfo >/dev/null 2>&1 && sinfo -h -p "$1" -o "%m" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1; }
detect_max_cores() {
    command -v sacctmgr >/dev/null 2>&1 || return 0
    sacctmgr -nP show assoc user="$USER" format=GrpTRES,MaxTRES 2>/dev/null \
      | tr '|,' '\n\n' | grep -iE '^cpu=' | grep -oE '[0-9]+' | sort -n | tail -1
}

# --------------------------------------------------------------------------- #
# --show : print the current profile and exit
# --------------------------------------------------------------------------- #
if [[ $SHOW_ONLY -eq 1 ]]; then
    if [[ -f "$CONF" ]]; then info "Cluster profile: $CONF"; cat "$CONF"
    else warn "No profile at $CONF. Run 'vasp-configure' to create one."; exit 1; fi
    exit 0
fi

# --------------------------------------------------------------------------- #
# --edit : open the profile in $EDITOR (create defaults first if missing)
# --------------------------------------------------------------------------- #
if [[ $EDIT_ONLY -eq 1 ]]; then
    if [[ ! -f "$CONF" ]]; then
        info "No profile yet — generating defaults to edit ($CONF)"
        "$0" --non-interactive --conf "$CONF" >/dev/null 2>&1 || true
    fi
    editor="${VISUAL:-${EDITOR:-}}"
    [[ -z "$editor" ]] && editor="$(command -v nano || command -v vim || command -v vi || echo vi)"
    info "Opening $CONF in '$editor' (edit, e.g., WP_VASP_MODULES) ..."
    "$editor" "$CONF"
    [[ -f "$CONF" ]] && { info "Saved. Current profile:"; cat "$CONF"; }
    exit 0
fi

# --------------------------------------------------------------------------- #
# --verify : load the configured modules and check the VASP executable appears.
# (The quickest way to diagnose an "execve(): vasp_std: No such file" failure.)
# --------------------------------------------------------------------------- #
if [[ $VERIFY_ONLY -eq 1 ]]; then
    [[ -f "$CONF" ]] && source "$CONF" \
        || { warn "no profile at $CONF — run 'vasp-configure' first."; exit 1; }
    case "$WP_MODULE_CMD" in ml|module) ;; *) WP_MODULE_CMD=ml ;; esac
    exe="${WP_VASP_STD:-vasp_std}"
    info "Verifying VASP modules from $CONF"
    echo "    modules : ${WP_VASP_MODULES:-(none)}  [$WP_MODULE_CMD]"
    echo "    exe     : $exe"
    [[ -z "${WP_VASP_MODULES:-}" ]] && { warn "no modules configured (WP_VASP_MODULES empty)."; exit 1; }
    have_modules || { warn "no module system here — run --verify on a cluster login node."; exit 2; }
    if verify_modules "$WP_VASP_MODULES" "$exe"; then
        info "${c_grn}OK${c_rst}: '$exe' is available after loading your modules."
        exit 0
    fi
    warn "FAILED: after loading your modules, '$exe' is NOT on PATH."
    warn "Jobs will die with 'execve(): $exe: No such file or directory'."
    echo "    Lmod said:"; diagnose_modules "$WP_VASP_MODULES" | sed 's/^/      /'
    echo
    echo "    Fix: vasp-configure   (set the module line, add the compiler/MPI)"
    echo "         vasp-configure --edit   (edit WP_VASP_MODULES by hand)"
    exit 1
fi

# --------------------------------------------------------------------------- #
# Wizard
# --------------------------------------------------------------------------- #
info "WolfPack-DFT cluster configuration"
echo "    profile file : $CONF"
[[ $INTERACTIVE -eq 0 ]] && echo "    mode         : non-interactive (detect + defaults)"
echo

# ---- 1. email ----
info "Notification email (used as #SBATCH --mail-user in emitted scripts)"
: "${WP_EMAIL:=$(git config --get user.email 2>/dev/null || echo "${EMAIL:-}")}"
ask WP_EMAIL "Email (blank = no mail line)" "$WP_EMAIL"
echo

# ---- 2. VASP modules ----
info "VASP modules to load"
if have_modules && [[ $INTERACTIVE -eq 1 && -z "$WP_VASP_MODULES" ]]; then
    note "module command: $WP_MODULE_CMD"
    mapfile -t VASP_CANDS < <(detect_vasp_modules)
    chosen=""
    if [[ ${#VASP_CANDS[@]} -gt 0 ]]; then
        echo "    Detected VASP modules:"
        i=1; for c in "${VASP_CANDS[@]}"; do printf "      %2d) %s\n" "$i" "$c"; i=$((i+1)); done
        echo "       m) type the module(s) manually"
        echo "       s) skip (no module)"
        read -r -p "    Choose [1]: " pick || true; pick="${pick:-1}"
        case "$pick" in
            s|S) chosen="" ;;
            m|M) read -r -p "    Modules to load (space-separated): " WP_VASP_MODULES || true; chosen="" ;;
            *)   if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=${#VASP_CANDS[@]} )); then
                     chosen="${VASP_CANDS[pick-1]}"
                 else warn "invalid choice."; fi ;;
        esac
        if [[ -n "$chosen" ]]; then
            # Pre-fill a SHORT, sensible default: the compiler/MPI prerequisite
            # that 'module spider' reports, plus the chosen module. You can edit
            # this freely on the next line (e.g. add a compiler like aocc/4.2.0).
            prereq="$(detect_prereqs "$chosen")"
            if [[ -n "$prereq" ]]; then
                note "module spider suggests loading first:  $prereq"
                WP_VASP_MODULES="$prereq $chosen"
            else
                WP_VASP_MODULES="$chosen"
            fi
        fi
    else
        warn "no VASP module detected via 'module avail/spider' — type it below."
    fi
elif ! have_modules; then
    warn "no Lmod/Environment-Modules on this machine. If your cluster loads VASP"
    warn "another way, type the module spec(s) below (or leave blank to skip)."
fi

# THE single place you define the module line. Edit it freely -- add the
# compiler/MPI (e.g. 'aocc/4.2.0 vasp/6.5.0-mpi-zen4-h') if VASP needs them.
ask WP_VASP_MODULES "Modules to load for VASP (space-separated; add compiler/MPI if needed)" "$WP_VASP_MODULES"
ask WP_VASP_STD     "VASP std executable name" "$WP_VASP_STD"

# Informational check -- never blocks, never loops.
if [[ -n "$WP_VASP_MODULES" ]] && have_modules; then
    if verify_modules "$WP_VASP_MODULES" "$WP_VASP_STD"; then
        note "checked: '$WP_VASP_STD' is on PATH after loading these modules."
    else
        warn "could NOT confirm '$WP_VASP_STD' loads from these modules:"
        diagnose_modules "$WP_VASP_MODULES" | sed 's/^/      Lmod: /'
        warn "double-check the list (likely a missing compiler/MPI). You can"
        warn "re-test any time with:  vasp-configure --verify"
    fi
fi
echo

# ---- 3. partitions ----
info "SLURM partitions"
if [[ $INTERACTIVE -eq 1 ]] && command -v sinfo >/dev/null 2>&1; then
    parts="$(sinfo_partitions | tr '\n' ' ')"
    [[ -n "$parts" ]] && note "partitions on this cluster: $parts"
fi
: "${WP_MAIN_PARTITION:=$(default_partition)}"; : "${WP_MAIN_PARTITION:=main}"
: "${WP_DEBUG_PARTITION:=$(guess_debug_part)}"; : "${WP_DEBUG_PARTITION:=$WP_MAIN_PARTITION}"
ask WP_MAIN_PARTITION  "MAIN (production) partition name"   "$WP_MAIN_PARTITION"
ask WP_DEBUG_PARTITION "DEBUG (short/test) partition name"  "$WP_DEBUG_PARTITION"
echo

# ---- 4. per-partition node specs ----
info "Node resources (cores / memory per node)"
: "${WP_MAIN_CPUS_PER_NODE:=$(cpus_of "$WP_MAIN_PARTITION")}";   : "${WP_MAIN_CPUS_PER_NODE:=128}"
: "${WP_DEBUG_CPUS_PER_NODE:=$(cpus_of "$WP_DEBUG_PARTITION")}"; : "${WP_DEBUG_CPUS_PER_NODE:=$WP_MAIN_CPUS_PER_NODE}"
: "${WP_MAIN_MEM_PER_NODE_MB:=$(mem_of "$WP_MAIN_PARTITION")}";  : "${WP_MAIN_MEM_PER_NODE_MB:=$(( WP_MAIN_CPUS_PER_NODE * 2000 ))}"
: "${WP_DEBUG_MEM_PER_NODE_MB:=$(mem_of "$WP_DEBUG_PARTITION")}";: "${WP_DEBUG_MEM_PER_NODE_MB:=$WP_MAIN_MEM_PER_NODE_MB}"
ask WP_MAIN_CPUS_PER_NODE    "MAIN  cores per node"        "$WP_MAIN_CPUS_PER_NODE"
ask WP_MAIN_MEM_PER_NODE_MB  "MAIN  memory per node (MB)"  "$WP_MAIN_MEM_PER_NODE_MB"
ask WP_DEBUG_CPUS_PER_NODE   "DEBUG cores per node"        "$WP_DEBUG_CPUS_PER_NODE"
ask WP_DEBUG_MEM_PER_NODE_MB "DEBUG memory per node (MB)"  "$WP_DEBUG_MEM_PER_NODE_MB"
echo

# ---- 5. max cores ----
info "Maximum cores you may request (account / QOS cap)"
detected_max="$(detect_max_cores)"
if [[ -n "$detected_max" ]]; then note "detected account CPU cap: $detected_max"
else note "could not detect a cap automatically — defaulting to one MAIN node."; fi
: "${WP_MAX_CORES:=${detected_max:-$WP_MAIN_CPUS_PER_NODE}}"
ask WP_MAX_CORES "Max total cores per job" "$WP_MAX_CORES"
echo

# ---- 6. write the profile ----
mkdir -p "$(dirname "$CONF")"
{
    echo "# WolfPack-DFT cluster profile -- generated by vasp-configure on $(date -Iseconds)"
    echo "# Sourced by the shell job scripts and parsed by vasp-recommend-slurm."
    echo "# Re-run 'vasp-configure' to regenerate, or edit by hand (KEY=\"value\")."
    echo
    for k in WP_EMAIL WP_MODULE_CMD WP_MODULE_PURGE WP_VASP_MODULES \
             WP_VASP_STD WP_VASP_GAM WP_VASP_NCL WP_EXTRA_ENV \
             WP_MAIN_PARTITION WP_DEBUG_PARTITION \
             WP_MAIN_CPUS_PER_NODE WP_DEBUG_CPUS_PER_NODE \
             WP_MAIN_MEM_PER_NODE_MB WP_DEBUG_MEM_PER_NODE_MB \
             WP_MAIN_NUMA_CORES WP_MAX_CORES; do
        printf '%s="%s"\n' "$k" "${!k}"
    done
} > "$CONF"

info "${c_grn}Wrote $CONF${c_rst}"
echo
echo "    email           : ${WP_EMAIL:-(none)}"
echo "    VASP modules    : ${WP_VASP_MODULES:-(none)}  [$WP_MODULE_CMD]"
echo "    main partition  : $WP_MAIN_PARTITION  (${WP_MAIN_CPUS_PER_NODE} cores, ${WP_MAIN_MEM_PER_NODE_MB} MB/node)"
echo "    debug partition : $WP_DEBUG_PARTITION  (${WP_DEBUG_CPUS_PER_NODE} cores, ${WP_DEBUG_MEM_PER_NODE_MB} MB/node)"
echo "    max cores/job   : $WP_MAX_CORES"
echo
echo "    These values now flow into vasp-recommend-slurm, vasp-dry-run and"
echo "    vasp-test. Re-run 'vasp-configure' (or --edit) any time to change them."
