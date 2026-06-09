#!/usr/bin/env bash
###############################################################################
# vasp_configure.sh   (invoked on PATH as: vasp-configure)
#
# Build the WolfPack-DFT *cluster profile* -- the small file that tells the
# SLURM-emitting tools (vasp-recommend-slurm, vasp-dry-run, vasp-test) how YOUR
# cluster looks, so they stop being hard-wired to one machine:
#
#   * your notification email,
#   * which VASP module/version to use and the modules it needs loaded,
#   * the names of your debug and main partitions,
#   * cores-per-node and memory-per-node for each,
#   * the maximum number of cores you may request.
#
# It tries hard to DETECT these (Lmod/Environment-Modules `module avail`,
# `sinfo`, `sacctmgr`) and always lets you confirm or override every value;
# if detection is not possible it simply asks. The result is written to
#
#       ~/.config/wolfpack-dft/cluster.conf       (override with --conf / $WOLFPACK_CLUSTER_CONF)
#
# a plain KEY="value" file that is both sourced by the shell scripts and parsed
# by vasp-recommend-slurm.  Re-run any time to update it.
#
# USAGE
#   vasp-configure                       # interactive wizard (recommended)
#   vasp-configure --non-interactive     # detect + defaults, no prompts
#   vasp-configure --email me@uni.edu --main-partition compute \
#                  --debug-partition debug --vasp-modules "gcc/13 vasp/6.4.3"
#   vasp-configure --show                # print the current profile and exit
#   vasp-configure --help
#
# FLAGS (all optional; any provided value pre-fills the wizard / is used as-is
# in --non-interactive mode):
#   --email STR            --module-cmd {ml,module}
#   --vasp-modules "STR"   --main-partition NAME    --debug-partition NAME
#   --main-cpus N          --debug-cpus N
#   --main-mem MB          --debug-mem MB           --max-cores N
#   --conf PATH            --non-interactive | -y    --show
###############################################################################
set -uo pipefail

CONF="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
INTERACTIVE=1
SHOW_ONLY=0

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_rst} $*"; }
note() { printf '%s\n' "    ${c_cya}$*${c_rst}"; }
warn() { printf '%s\n' "    ${c_yel}WARN${c_rst} $*" >&2; }
usage(){ sed -n '2,49p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0; }

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
        -h|--help)          usage ;;
        *) warn "Unknown option: $1"; echo "Try: vasp-configure --help" >&2; exit 2 ;;
    esac
done

if [[ $SHOW_ONLY -eq 1 ]]; then
    if [[ -f "$CONF" ]]; then info "Cluster profile: $CONF"; cat "$CONF"; else
        warn "No profile at $CONF. Run 'vasp-configure' to create one."; exit 1; fi
    exit 0
fi

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
ask() {  # ask VARNAME "prompt" "default"
    local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
    if [[ $INTERACTIVE -eq 0 ]]; then printf -v "$__var" '%s' "$__def"; return; fi
    if [[ -n "$__def" ]]; then read -r -p "    $__prompt [$__def]: " __ans || true
    else                      read -r -p "    $__prompt: " __ans || true; fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# Make `module`/`ml` callable inside this non-login shell if possible.
if ! type module >/dev/null 2>&1 && ! type ml >/dev/null 2>&1; then
    for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh \
             "${LMOD_PKG:-}/init/bash" "${MODULESHOME:-}/init/bash"; do
        [[ -n "$f" && -f "$f" ]] && { source "$f" 2>/dev/null && break; }
    done
fi

run_module() {  # run the module command whichever flavour exists
    if type module >/dev/null 2>&1; then module "$@"
    elif type ml >/dev/null 2>&1; then ml "$@"
    else return 127; fi
}

have_modules() { type module >/dev/null 2>&1 || type ml >/dev/null 2>&1; }

detect_vasp_modules() {
    { run_module -t avail 2>&1; run_module -t spider 2>&1; } 2>/dev/null \
      | grep -iE 'vasp' \
      | sed -E 's/[[:space:]]*$//; s/\(default\)//I; s/:$//' \
      | grep -vE '^/|^[[:space:]]*$' \
      | awk '{$1=$1; print}' | sort -u
}

detect_prereqs() {  # parse Lmod 'module spider' prerequisite block for $1
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

# ---- 2. module system + VASP modules ----
info "VASP installation (module system)"
if [[ -z "$WP_MODULE_CMD" ]]; then
    if type ml >/dev/null 2>&1; then WP_MODULE_CMD="ml"
    elif type module >/dev/null 2>&1; then WP_MODULE_CMD="module"
    else WP_MODULE_CMD="ml"; fi
fi
if have_modules; then
    note "module command: $WP_MODULE_CMD"
    mapfile -t VASP_CANDS < <(detect_vasp_modules)
    if [[ ${#VASP_CANDS[@]} -gt 0 && $INTERACTIVE -eq 1 && -z "$WP_VASP_MODULES" ]]; then
        echo "    Detected VASP modules on this cluster:"
        i=1; for c in "${VASP_CANDS[@]}"; do printf "      %2d) %s\n" "$i" "$c"; i=$((i+1)); done
        echo "       m) enter module spec(s) manually"
        echo "       s) skip (no module loaded)"
        read -r -p "    Choose VASP module [1]: " pick || true; pick="${pick:-1}"
        case "$pick" in
            s|S) WP_VASP_MODULES="" ;;
            m|M) read -r -p "    Module spec(s) (space-separated): " WP_VASP_MODULES || true ;;
            *) if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=${#VASP_CANDS[@]} )); then
                   chosen="${VASP_CANDS[pick-1]}"
                   prereq="$(detect_prereqs "$chosen")"
                   [[ -n "$prereq" ]] && note "prerequisites detected: $prereq"
                   WP_VASP_MODULES="${prereq:+$prereq }$chosen"
               else warn "invalid choice; leaving module list empty."; fi ;;
        esac
    elif [[ ${#VASP_CANDS[@]} -eq 0 && -z "$WP_VASP_MODULES" ]]; then
        warn "no VASP module found via 'module avail/spider'. Enter it manually below."
    fi
else
    warn "no Lmod/Environment-Modules detected. If your cluster loads VASP another"
    warn "way, enter the module spec(s) manually (or leave blank)."
fi
ask WP_VASP_MODULES "Module(s) to load for VASP (space-separated)" "$WP_VASP_MODULES"
ask WP_MODULE_CMD   "Module command (ml | module)" "$WP_MODULE_CMD"
ask WP_MODULE_PURGE "Run 'module purge' before loading? (1/0)" "$WP_MODULE_PURGE"
ask WP_VASP_STD     "VASP std executable name" "$WP_VASP_STD"
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
ask WP_MAIN_CPUS_PER_NODE   "MAIN  cores per node"        "$WP_MAIN_CPUS_PER_NODE"
ask WP_MAIN_MEM_PER_NODE_MB "MAIN  memory per node (MB)"  "$WP_MAIN_MEM_PER_NODE_MB"
ask WP_DEBUG_CPUS_PER_NODE  "DEBUG cores per node"        "$WP_DEBUG_CPUS_PER_NODE"
ask WP_DEBUG_MEM_PER_NODE_MB "DEBUG memory per node (MB)" "$WP_DEBUG_MEM_PER_NODE_MB"
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
echo "    vasp-test. Re-run 'vasp-configure' any time to change them."
