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
#   vasp-configure --verify              # load the modules and check vasp_std
#   vasp-configure --help
#
# FLAGS (all optional; any provided value pre-fills the wizard / is used as-is
# in --non-interactive mode):
#   --email STR            --module-cmd {ml,module}
#   --vasp-modules "STR"   --main-partition NAME    --debug-partition NAME
#   --main-cpus N          --debug-cpus N
#   --main-mem MB          --debug-mem MB           --max-cores N
#   --conf PATH            --non-interactive | -y    --show    --edit    --verify
#
# FIX A BROKEN VASP/MODULE CHOICE  (e.g. a job died with
#   "execve(): vasp_std: No such file or directory")
#   That means the configured module line does not put vasp_std on PATH (a
#   wrong/conflicting module). No reinstall needed — diagnose and re-point it:
#       vasp-configure --verify # load the modules and report what's wrong
#       vasp-configure          # re-run the wizard and pick another version
#                               #   (it now TEST-LOADS each choice automatically)
#       vasp-configure --edit   # hand-edit the WP_VASP_MODULES line
#       vasp-configure --show   # inspect the current profile
###############################################################################
set -uo pipefail

CONF="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
INTERACTIVE=1
SHOW_ONLY=0
EDIT_ONLY=0
VERIFY_ONLY=0

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
        --edit)             EDIT_ONLY=1; shift ;;
        --verify)           VERIFY_ONLY=1; shift ;;
        -h|--help)          usage ;;
        *) warn "Unknown option: $1"; echo "Try: vasp-configure --help" >&2; exit 2 ;;
    esac
done

if [[ $SHOW_ONLY -eq 1 ]]; then
    if [[ -f "$CONF" ]]; then info "Cluster profile: $CONF"; cat "$CONF"; else
        warn "No profile at $CONF. Run 'vasp-configure' to create one."; exit 1; fi
    exit 0
fi

if [[ $EDIT_ONLY -eq 1 ]]; then
    # Quick way to fix a wrong/missing module line (or any value) by hand.
    if [[ ! -f "$CONF" ]]; then
        printf '%s\n' "==> No profile yet — generating defaults to edit ($CONF)"
        "$0" --non-interactive --conf "$CONF" >/dev/null 2>&1 || true
    fi
    editor="${VISUAL:-${EDITOR:-}}"
    [[ -z "$editor" ]] && editor="$(command -v nano || command -v vim \
        || command -v vi || echo vi)"
    printf '%s\n' "==> Opening $CONF in '$editor' (edit, e.g., WP_VASP_MODULES) ..."
    "$editor" "$CONF"
    if [[ -f "$CONF" ]]; then
        printf '%s\n' "==> Saved. Current profile:"; cat "$CONF"
    fi
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

detect_prereqs_all() {  # ALL alternative prerequisite lines from 'module spider'
    # Lmod prints "You will need to load all module(s) on any one of the lines
    # below" followed by several indented lines -- each line is ONE valid combo.
    local out; out="$(run_module spider "$1" 2>&1)" || return 0
    printf '%s\n' "$out" | awk '
        /You will need to load all module/ {grab=1; next}
        grab!=1 {next}
        NF==0 { if (started) exit; next }
        /^[[:space:]]/ { started=1; sub(/^[[:space:]]+/,""); gsub(/[[:space:]]+/," "); print; next }
        { if (started) exit }'
}

# Load $1 (a module list) in a throwaway subshell and report whether the
# executable $2 (default vasp_std) ends up on PATH. 0=works, 1=fails, 2=cannot
# test (no module system / empty list). The parent shell is NOT modified.
verify_modules() {
    local mods="$1" exe="${2:-vasp_std}"
    [[ -z "$mods" ]] && return 2
    have_modules || return 2
    ( run_module purge >/dev/null 2>&1 || true
      # word-splitting of $mods is intentional
      # shellcheck disable=SC2086
      if [[ "${WP_MODULE_CMD:-ml}" == "module" ]]; then module load $mods >/dev/null 2>&1 || true
      else ml $mods >/dev/null 2>&1 || true; fi
      command -v "$exe" >/dev/null 2>&1 )
}

# Echo the Lmod error lines produced when loading $1 (for diagnostics).
diagnose_modules() {
    local mods="$1" err
    # shellcheck disable=SC2086
    err=$( { run_module purge
             if [[ "${WP_MODULE_CMD:-ml}" == "module" ]]; then module load $mods
             else ml $mods; fi
           } 2>&1 1>/dev/null )
    printf '%s\n' "$err" | grep -iE 'error|cannot be loaded|conflict|not found' | head -6
}

# Find a module set that actually exposes the VASP executable: try the bare
# module, then each 'module spider' alternative, and return the first that
# verifies. Echoes the working set; return 0 if verified, 1 if none verified,
# 2 if it could not be tested on this node.
resolve_working_modules() {
    local vasp="$1" exe="${WP_VASP_STD:-vasp_std}" line pre
    if ! have_modules; then
        pre="$(detect_prereqs_all "$vasp" | head -1)"
        echo "${pre:+$pre }$vasp"; return 2
    fi
    if verify_modules "$vasp" "$exe"; then echo "$vasp"; return 0; fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if verify_modules "$line $vasp" "$exe"; then echo "$line $vasp"; return 0; fi
    done < <(detect_prereqs_all "$vasp")
    pre="$(detect_prereqs_all "$vasp" | head -1)"
    echo "${pre:+$pre }$vasp"; return 1
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
# --verify: load the configured modules and check the VASP executable appears.
# This is the quickest way to diagnose a "vasp_std: No such file or directory"
# job failure (run it on a login/compute node that has the module system).
# --------------------------------------------------------------------------- #
if [[ $VERIFY_ONLY -eq 1 ]]; then
    [[ -f "$CONF" ]] && source "$CONF" \
        || { warn "no profile at $CONF — run 'vasp-configure' first."; exit 1; }
    exe="${WP_VASP_STD:-vasp_std}"
    info "Verifying VASP modules from $CONF"
    echo "    modules : ${WP_VASP_MODULES:-(none)}  [${WP_MODULE_CMD:-ml}]"
    echo "    exe     : $exe"
    if [[ -z "${WP_VASP_MODULES:-}" ]]; then
        warn "no modules configured (WP_VASP_MODULES empty)."; exit 1
    fi
    if ! have_modules; then
        warn "no Lmod/Environment-Modules on THIS machine — run --verify on a"
        warn "login/compute node of the cluster."; exit 2
    fi
    if verify_modules "$WP_VASP_MODULES" "$exe"; then
        info "${c_grn}OK${c_rst}: '$exe' is available after loading your modules."
        exit 0
    fi
    warn "FAILED: after loading your modules, '$exe' is NOT on PATH."
    warn "This is exactly what makes SLURM jobs die with"
    warn "  'execve(): $exe: No such file or directory'."
    echo "    Lmod said:"
    diagnose_modules "$WP_VASP_MODULES" | sed 's/^/      /'
    echo
    echo "    Fix it with either:"
    echo "      vasp-configure          # re-pick a VASP version (auto-verified)"
    echo "      vasp-configure --edit   # correct the WP_VASP_MODULES line by hand"
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
                   echo "    Testing which module set actually exposes ${WP_VASP_STD}"
                   echo "    (loading candidates in a throwaway shell) ..."
                   if WP_VASP_MODULES="$(resolve_working_modules "$chosen")"; then
                       note "verified: '$WP_VASP_MODULES' makes ${WP_VASP_STD} available"
                   else
                       warn "no tested combination exposed ${WP_VASP_STD}; using a best"
                       warn "guess below — confirm/fix it before submitting jobs."
                   fi
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

# Final safety net: actually load the chosen modules and confirm the executable
# shows up. This is what prevents the "vasp_std: No such file or directory"
# job failure from a wrong/conflicting module line.
if [[ -n "$WP_VASP_MODULES" ]] && have_modules; then
    if verify_modules "$WP_VASP_MODULES" "$WP_VASP_STD"; then
        note "module check OK: '${WP_VASP_STD}' is on PATH after loading."
    else
        warn "MODULE CHECK FAILED — after loading your modules, '${WP_VASP_STD}'"
        warn "is NOT on PATH, so SLURM jobs would die with"
        warn "  'execve(): ${WP_VASP_STD}: No such file or directory'."
        diagnose_modules "$WP_VASP_MODULES" | sed 's/^/      Lmod: /'
        if [[ $INTERACTIVE -eq 1 ]]; then
            ask WP_VASP_MODULES "Re-enter a working module list (or keep to fix later)" \
                "$WP_VASP_MODULES"
            verify_modules "$WP_VASP_MODULES" "$WP_VASP_STD" \
                && note "module check OK now." \
                || warn "still failing — fix later with 'vasp-configure --verify'."
        else
            warn "Re-run 'vasp-configure' (interactive) or 'vasp-configure --edit'."
        fi
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
