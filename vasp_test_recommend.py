#!/usr/bin/env python3
"""
vasp_test_recommend.py   (internal helper for vasp-test; not a user command)
===========================================================================
Turn the MEASURED results of a `vasp-test` benchmark into a production-job
recommendation.  Unlike vasp-recommend (which PREDICTS memory from VASP's own
table + a model), this anchors everything to what the benchmark ACTUALLY used:

  * per-rank memory is anchored to the measured SLURM MaxRSS, then scaled to the
    production rank layout using the VASP component-distribution rules
    (wavefunctions ~ 1/total_ranks, grid ~ 1/NPAR, projectors ~ 1/NCORE);
  * KPAR / NCORE / NSIM are taken from the layout the benchmark actually ran;
  * the memory REQUEST honours two cluster policies passed in on the CLI:
      - a minimum memory-utilisation fraction (e.g. 0.80): the job must use at
        least this fraction of what it requests, so we request need/fraction;
      - a per-node reserve (e.g. 16 GB) kept free on the debug/login partition
        so interactive logins are not starved.

Output mirrors vasp-recommend's format: a [MEASURED] block, an [INCAR SNIPPET]
and a ready-to-submit [SLURM SCRIPT]; it also writes slurm_job.sh + INCAR.parallel.

This module is intentionally dependency-free (Python stdlib only) so it runs on
a compute node with any python3.
"""
from __future__ import annotations

import argparse
import math
import os
import re
from pathlib import Path


# --------------------------------------------------------------------------- #
# OUTCAR parsing (self-contained; mirrors the patterns in vasp_recommend_slurm)
# --------------------------------------------------------------------------- #
def _read(path):
    try:
        return Path(path).read_text(errors="replace")
    except OSError:
        return ""


def _int(patterns, text):
    for p in patterns:
        m = re.search(p, text, re.IGNORECASE | re.MULTILINE)
        if m:
            try:
                return int(m.group(1))
            except (ValueError, IndexError):
                pass
    return None


def parse_outcar_layout(text):
    """Return the parallel layout VASP actually used: (total, kpar, ncore, npar)."""
    total = _int([r"running on\s+(\d+)\s+total cores"], text)
    kpar = ncore = npar = None
    m = re.search(r"distrk:\s*each k-point on\s+\d+\s+cores,\s*(\d+)\s+groups", text, re.I)
    if m:
        kpar = int(m.group(1))
    m = re.search(r"distr:\s*one band on\s+NCORE\s*=\s*(\d+)\s+cores,\s*(\d+)\s+groups", text, re.I)
    if m:
        ncore, npar = int(m.group(1)), int(m.group(2))
    if not total and kpar and ncore and npar:
        total = kpar * ncore * npar
    if total and kpar and ncore and not npar:
        npar = max(1, (total // kpar) // ncore)
    return total, kpar, ncore, npar


def parse_outcar_memory(text):
    """Return the rank-0 memory breakdown in MB (keys may be 0.0 if absent)."""
    out = dict(base=0.0, nonlr=0.0, fft=0.0, grid=0.0, one=0.0, wave=0.0, total=0.0)
    m = re.search(r"total amount of memory used by VASP MPI-rank0\s+([0-9.]+)\.?\s*k[bB]ytes", text)
    if m:
        out["total"] = float(m.group(1)) / 1024.0
    rows = {"base": "base", "nonlr-proj": "nonlr", "nonl-proj": "nonlr",
            "fftplans": "fft", "grid": "grid", "one-center": "one", "wavefun": "wave"}
    for label, key in rows.items():
        m = re.search(rf"(?:^|\s){re.escape(label)}\s*:\s*([0-9.]+)\.?\s*k[bB]ytes",
                      text, re.IGNORECASE | re.MULTILINE)
        if m:
            out[key] = float(m.group(1)) / 1024.0
    return out


# --------------------------------------------------------------------------- #
# Memory model -- ANCHORED to the measured MaxRSS
# --------------------------------------------------------------------------- #
def make_memory_estimator(maxrss_mb, mem, nt, npar_t, ncore_t):
    """Return per_rank(ranks, npar, ncore) -> MB, anchored to the measurement.

    The OUTCAR breakdown gives the component split at the TEST layout; we scale
    each component by its VASP distribution rule and multiply by a single
    correction factor so the model reproduces the MEASURED MaxRSS exactly at the
    test point. If no breakdown is available we fall back to scaling MaxRSS with
    a wavefunction-dominant 70%/30% (variable/fixed) split.
    """
    def model_total(ranks, npar, ncore):
        return (mem["base"] + mem["fft"] + mem["one"]
                + mem["wave"] * nt / max(ranks, 1)
                + mem["grid"] * npar_t / max(npar, 1)
                + mem["nonlr"] * ncore_t / max(ncore, 1))

    m_test = model_total(nt, npar_t, ncore_t)
    have_table = m_test > 1.0 and (mem["wave"] > 0 or mem["grid"] > 0)
    if have_table and maxrss_mb > 0:
        corr = maxrss_mb / m_test          # anchor to the measurement
    elif have_table:
        corr = 1.0                         # no MaxRSS: trust VASP's own table
    else:
        corr = None                        # neither: flat fallback below

    def per_rank(ranks, npar, ncore):
        if corr is not None:
            return corr * model_total(ranks, npar, ncore)
        if maxrss_mb > 0:                      # no usable table: conservative
            return maxrss_mb * (0.30 + 0.70 * nt / max(ranks, 1))
        return None

    return per_rank, corr, m_test


def round_up(x, step=50):
    return int(math.ceil(max(x, 1.0) / step) * step)


# --------------------------------------------------------------------------- #
# SLURM script (vasp-recommend-compatible format)
# --------------------------------------------------------------------------- #
def slurm_script(*, job_name, partition, time_limit, ntasks, ntpn, mem_per_cpu,
                 email, modules, extra_env, exe):
    L = ["#!/bin/bash",
         f'#SBATCH --job-name="{job_name}"',
         f"#SBATCH --partition={partition}",
         f"#SBATCH --time={time_limit}",
         f"#SBATCH --ntasks={ntasks}",
         f"#SBATCH --ntasks-per-node={ntpn}",
         "#SBATCH --cpus-per-task=1",
         f"#SBATCH --mem-per-cpu={mem_per_cpu}",
         "#SBATCH --output=%x-%j.out",
         "#SBATCH --error=%x-%j.err"]
    if email:
        L += [f"#SBATCH --mail-user={email}", "#SBATCH --mail-type=ALL"]
    L += ["", "# --- Modules (from your cluster profile) ---"]
    L += [m for m in modules if m.strip()]
    if extra_env:
        L += ["", "# --- Environment ---"]
        L += [e.strip() for e in extra_env.split(";") if e.strip()]
    L += ["", 'echo "Inicio: $(date)"',
          f"/usr/bin/time -v srun --cpu-bind=cores {exe}",
          'echo "Fin:    $(date)"']
    return "\n".join(L)


def incar_snippet(kpar, ncore, npar, nsim):
    return ("# --- Parallelization tailored from your vasp-test benchmark ---\n"
            f"KPAR   = {kpar}\n"
            f"NCORE  = {ncore}\n"
            f"NSIM   = {nsim}\n"
            "LPLANE = .TRUE.\n"
            f"# Derived only: NPAR = {npar}  (do NOT set BOTH NCORE and NPAR)\n"
            "# I/O hygiene:\n"
            "LWAVE  = .FALSE.\n"
            "LCHARG = .FALSE.\n"
            "LVTOT  = .FALSE.")


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main():
    p = argparse.ArgumentParser(description="vasp-test measurement-based recommender")
    p.add_argument("outcar", type=Path)
    p.add_argument("--maxrss-mb", type=float, required=True,
                   help="measured peak per-rank memory (SLURM MaxRSS), MB")
    p.add_argument("--ntasks-test", type=int, required=True)
    p.add_argument("--avg-loop", type=float, default=0.0)
    p.add_argument("--cpu-eff", type=float, default=0.0)
    p.add_argument("--nscf", type=int, default=0)
    p.add_argument("--wall", type=int, default=0)
    # target partition + policies
    p.add_argument("--partition", default="main", help="logical target (main/debug)")
    p.add_argument("--slurm-partition", default="main", help="real #SBATCH name")
    p.add_argument("--cpus-per-node", type=int, required=True)
    p.add_argument("--node-mem-mb", type=int, required=True)
    p.add_argument("--max-cores", type=int, default=0)
    p.add_argument("--is-debug", action="store_true",
                   help="apply the per-node reserve (debug/login partition)")
    p.add_argument("--debug-margin-mb", type=int, default=16384)
    p.add_argument("--mem-util", type=float, default=0.80,
                   help="required memory-utilisation fraction (request need/util)")
    p.add_argument("--prod-ranks", type=int, default=0, help="0 = auto")
    p.add_argument("--nsim", type=int, default=4)
    p.add_argument("--email", default="")
    p.add_argument("--job-name", default="VASP")
    p.add_argument("--exe", default="vasp_std")
    p.add_argument("--time", default="7-00:00:00")
    p.add_argument("--modules", default="", help="newline-joined module-load lines")
    p.add_argument("--extra-env", default="")
    p.add_argument("--write-slurm", type=Path, default=None)
    p.add_argument("--write-incar", type=Path, default=None)
    args = p.parse_args()

    text = _read(args.outcar)
    nt_o, kpar_t, ncore_t, npar_t = parse_outcar_layout(text)
    nt = args.ntasks_test or nt_o or 1
    kpar_t = kpar_t or 1
    ncore_t = ncore_t or 1
    npar_t = npar_t or max(1, (nt // kpar_t) // ncore_t)
    nkpts = _int([r"NKPTS\s*=\s*(\d+)"], text) or 0
    nbands = _int([r"NBANDS\s*=\s*(\d+)"], text) or 0
    mem = parse_outcar_memory(text)

    per_rank, corr, m_test = make_memory_estimator(
        args.maxrss_mb, mem, nt, npar_t, ncore_t)

    # --- production layout: keep the TESTED kpar/ncore (tailored from the run) #
    kpar = min(kpar_t, nkpts) if nkpts > 0 else kpar_t
    kpar = max(kpar, 1)
    ncore = max(ncore_t, 1)
    unit = kpar * ncore
    cap = args.max_cores or args.cpus_per_node
    # Default to the TESTED rank count: at that scale the per-rank memory is the
    # MEASURED value exactly (no extrapolation), which is the most reliable. Use
    # --prod-ranks to scale up (memory is then extrapolated by the model).
    if args.prod_ranks > 0:
        target = min(args.prod_ranks, cap) if cap else args.prod_ranks
    else:
        target = nt
    prod = max(unit, (target // unit) * unit)
    npar = max(1, prod // unit)
    prod = unit * npar                                   # exact multiple of unit
    extrapolated = (prod != nt)

    # --- per-rank need at production, then the 80%-utilisation request -------- #
    need = per_rank(prod, npar, ncore)
    if need and need > 0:
        request_per_rank = need / max(args.mem_util, 0.05)
        mem_per_cpu = max(round_up(request_per_rank, 50), 200)
        mem_model = ("anchored to measured MaxRSS via the OUTCAR breakdown"
                     if corr is not None else
                     "scaled from measured MaxRSS (no OUTCAR table; 70/30 split)")
    else:
        mem_per_cpu = max(round_up(args.node_mem_mb / args.cpus_per_node, 50), 200)
        need = mem_per_cpu * args.mem_util
        mem_model = "partition default (no memory measurement available)"

    # --- node packing, honouring the debug reserve --------------------------- #
    usable_node = args.node_mem_mb - (args.debug_margin_mb if args.is_debug else 0)
    ntpn = min(args.cpus_per_node, prod)
    if mem_per_cpu * ntpn > usable_node:
        ntpn = max(1, int(usable_node // mem_per_cpu))
    # keep ntpn a divisor-friendly value and recompute node count
    ntpn = min(ntpn, prod)
    nodes = max(1, math.ceil(prod / ntpn))
    per_node_mem_gb = ntpn * mem_per_cpu / 1024.0
    used_per_node_gb = ntpn * need / 1024.0

    # ----------------------------------------------------------------------- #
    # Report
    # ----------------------------------------------------------------------- #
    bar = "=" * 78
    print(bar)
    print(" RECOMMENDED PRODUCTION SETUP  (tailored from your benchmark) ".center(78, "="))
    print(bar)
    print("Memory and layout below come from what THIS job actually measured,")
    print("not from a generic model.\n")

    print("[MEASURED  (from the benchmark run)]")
    print(f"  test ranks              : {nt}  (KPAR={kpar_t}, NCORE={ncore_t}, NPAR={npar_t})")
    print(f"  peak memory / rank      : {args.maxrss_mb:.0f} MB   (SLURM MaxRSS -- ground truth)")
    if mem['total'] > 0:
        print(f"  VASP rank-0 table total : {mem['total']:.0f} MB"
              + (f"   (measured/table = x{corr:.2f})" if corr else ""))
    if args.cpu_eff > 0:
        print(f"  CPU efficiency          : {args.cpu_eff:.1f} %")
    if args.avg_loop > 0:
        print(f"  wall per SCF step       : {args.avg_loop:.2f} s   "
              f"({args.nscf} steps in {args.wall}s)")
    print(f"  NKPTS / NBANDS          : {nkpts} / {nbands}")
    print()

    print(f"[PRODUCTION LAYOUT  -> partition '{args.slurm_partition}']")
    print(f"  total MPI ranks         : {prod}")
    print(f"  nodes x ntasks-per-node : {nodes} x {ntpn}")
    print(f"  KPAR / NCORE / NPAR     : {kpar} / {ncore} / {npar}   (from your run)")
    print(f"  NSIM                    : {args.nsim}")
    print()

    print("[MEMORY  (measured -> request)]")
    if extrapolated:
        print(f"  basis                   : EXTRAPOLATED from {nt} to {prod} ranks "
              f"({mem_model})")
        print("                            (less certain than the measured scale; "
              "to be safe, benchmark at this size with --debug-nodes)")
    else:
        print(f"  basis                   : MEASURED directly at {prod} ranks "
              "(no extrapolation)")
    print(f"  predicted use / rank    : {need:.0f} MB  (at {prod} ranks)")
    print(f"  utilisation policy       : request so use >= {args.mem_util*100:.0f}% of alloc")
    print(f"  --mem-per-cpu           : {mem_per_cpu} MB   "
          f"(= {need:.0f} / {args.mem_util:.2f}, rounded up)")
    print(f"  -> per node             : {used_per_node_gb:.1f} GB used of "
          f"{per_node_mem_gb:.1f} GB requested")
    if args.is_debug:
        print(f"  debug reserve kept free : {args.debug_margin_mb/1024:.0f} GB/node "
              f"(usable {usable_node/1024:.0f} of {args.node_mem_mb/1024:.0f} GB)")
        if mem_per_cpu * ntpn > usable_node:
            print("  WARNING: even one rank exceeds the usable memory; lower the rank "
                  "count or use the main partition.")
    print()

    incar = incar_snippet(kpar, ncore, npar, args.nsim)
    print("[INCAR SNIPPET]  (copy into your INCAR)")
    print("-" * 78)
    print(incar)
    print("-" * 78)
    print()

    modlines = [m for m in args.modules.split("\n")] if args.modules else []
    script = slurm_script(job_name=args.job_name, partition=args.slurm_partition,
                          time_limit=args.time, ntasks=prod, ntpn=ntpn,
                          mem_per_cpu=mem_per_cpu, email=args.email or None,
                          modules=modlines, extra_env=args.extra_env, exe=args.exe)
    print("[SLURM SCRIPT]  (copy into job.sh; submit with `sbatch job.sh`)")
    print("-" * 78)
    print(script)
    print("-" * 78)

    if args.write_slurm:
        Path(args.write_slurm).write_text(script + "\n")
        try:
            os.chmod(args.write_slurm, 0o755)
        except OSError:
            pass
        print(f"\n[FILES] SLURM script  -> {args.write_slurm}")
    if args.write_incar:
        Path(args.write_incar).write_text(incar + "\n")
        print(f"[FILES] INCAR snippet -> {args.write_incar}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
