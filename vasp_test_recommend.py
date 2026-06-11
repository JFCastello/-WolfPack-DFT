#!/usr/bin/env python3
"""
vasp_test_recommend.py   (internal helper for vasp-test; not a user command)
===========================================================================
STAGE 3 of the dry-run -> recommend -> test pipeline.

vasp-recommend produced a FIXED parallel configuration (KPAR/NCORE/NSIM and a
target rank count, e.g. 120) and wrote it into slurm.sh. The benchmark cannot
fit 120 ranks on the 96-core debug partition, so vasp-test ran the SAME fixed
config at a smaller, debug-sized rank count and measured the real per-rank
memory (SLURM MaxRSS).

This helper then:
  * scales the measured per-rank memory from the TEST rank count to the
    PRODUCTION rank count using the VASP component-distribution rules
    (wavefunctions ~ 1/total_ranks, grid ~ 1/NPAR, projectors ~ 1/NCORE),
    anchored to the measurement;
  * sizes the production memory REQUEST to the cluster's >=80% utilisation rule
    (request = predicted_use / mem_util), splitting across nodes if one node
    cannot hold its ranks;
  * UPDATES slurm.sh in place (mem-per-cpu, nodes, ntasks-per-node);
  * prints a VERDICT on whether the recommended config is adequate and appends
    a STAGE 3 section to report.out.

Stdlib only -- runs on any compute node with python3.
"""
from __future__ import annotations

import argparse
import math
import re
from pathlib import Path


# --------------------------------------------------------------------------- #
# OUTCAR memory breakdown (for the test -> production scaling)
# --------------------------------------------------------------------------- #
def parse_outcar_memory(text: str) -> dict:
    """Parse the rank-0 memory breakdown (base/wave/grid/...) from OUTCAR text."""
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


def make_estimator(maxrss_mb, mem, nt, npar_t, ncore_t):
    """per_rank(ranks, npar, ncore) -> MB, anchored to the measured MaxRSS."""
    def model_total(ranks, npar, ncore):
        """Modelled total per-rank MB at a layout (VASP component-distribution rules)."""
        return (mem["base"] + mem["fft"] + mem["one"]
                + mem["wave"] * nt / max(ranks, 1)
                + mem["grid"] * npar_t / max(npar, 1)
                + mem["nonlr"] * ncore_t / max(ncore, 1))
    m_test = model_total(nt, npar_t, ncore_t)
    have_table = m_test > 1.0 and (mem["wave"] > 0 or mem["grid"] > 0)
    corr = (maxrss_mb / m_test) if (have_table and maxrss_mb > 0) else None

    def per_rank(ranks, npar, ncore):
        """Per-rank MB at (ranks, npar, ncore), anchored to the measured MaxRSS."""
        if corr is not None:
            return corr * model_total(ranks, npar, ncore)
        # No usable table: wavefunction-dominant 70%/30% split of MaxRSS.
        return maxrss_mb * (0.30 + 0.70 * nt / max(ranks, 1))
    return per_rank, corr


def round_up(x, step=50):
    """Round `x` up to the next multiple of `step`."""
    return int(math.ceil(max(x, 1.0) / step) * step)


def geometry(total, cpn, mem_per_cpu, node_mem, reserve=0):
    """(nodes, ntasks_per_node) that fit BOTH the cores and the node memory."""
    usable = max(mem_per_cpu, node_mem - max(reserve, 0))
    by_mem = max(1, usable // max(mem_per_cpu, 1))
    ntpn = min(cpn, total, by_mem)
    nodes = max(1, math.ceil(total / ntpn))
    ntpn = min(cpn, math.ceil(total / nodes))
    return nodes, ntpn


def _sub(text, pattern, repl):
    """Replace the first multiline match of `pattern` with `repl`."""
    return re.sub(pattern, repl, text, count=1, flags=re.MULTILINE)


def update_slurm(path, mem_per_cpu, nodes, ntpn):
    """Rewrite the production slurm.sh memory/geometry in place."""
    try:
        t = Path(path).read_text()
    except OSError:
        return False
    t = _sub(t, r"^#SBATCH --mem-per-cpu=.*$", f"#SBATCH --mem-per-cpu={mem_per_cpu}")
    t = _sub(t, r"^#SBATCH --nodes=.*$", f"#SBATCH --nodes={nodes}")
    t = _sub(t, r"^#SBATCH --ntasks-per-node=.*$", f"#SBATCH --ntasks-per-node={ntpn}")
    if "updated by vasp-test" not in t:
        t = t.replace("#!/bin/bash\n",
                      "#!/bin/bash\n# (memory updated by vasp-test from a real "
                      "benchmark; see report.out)\n", 1)
    try:
        Path(path).write_text(t)
        return True
    except OSError:
        return False


def main():
    """CLI entry: scale the measured memory to production, update slurm.sh and report.out."""
    p = argparse.ArgumentParser(description="vasp-test STAGE 3: scale + update slurm.sh")
    p.add_argument("outcar", type=Path)
    p.add_argument("--maxrss-mb", type=float, required=True)
    p.add_argument("--ntasks-test", type=int, required=True)
    p.add_argument("--test-kpar", type=int, default=1)
    p.add_argument("--test-ncore", type=int, default=1)
    p.add_argument("--test-npar", type=int, default=1)
    # production (fixed) config from vasp-recommend
    p.add_argument("--prod-ranks", type=int, required=True)
    p.add_argument("--prod-kpar", type=int, default=1)
    p.add_argument("--prod-ncore", type=int, default=1)
    p.add_argument("--prod-npar", type=int, default=1)
    p.add_argument("--prod-nsim", type=int, default=4)
    p.add_argument("--prod-partition", default="main")
    p.add_argument("--cpus-per-node", type=int, required=True)
    p.add_argument("--node-mem-mb", type=int, required=True)
    p.add_argument("--mem-util", type=float, default=0.80)
    # measured timing / efficiency (for the verdict + report)
    p.add_argument("--cpu-eff", type=float, default=0.0)
    p.add_argument("--avg-loop", type=float, default=0.0)
    p.add_argument("--nscf", type=int, default=0)
    p.add_argument("--wall", type=int, default=0)
    p.add_argument("--update-slurm", type=Path, default=None)
    p.add_argument("--report", type=Path, default=None)
    args = p.parse_args()

    text = ""
    try:
        text = Path(args.outcar).read_text(errors="replace")
    except OSError:
        pass
    mem = parse_outcar_memory(text)
    per_rank, corr = make_estimator(args.maxrss_mb, mem, args.ntasks_test,
                                    max(args.test_npar, 1), max(args.test_ncore, 1))

    # Per-rank memory at the PRODUCTION layout, scaled from the measurement.
    prod_use = per_rank(args.prod_ranks, max(args.prod_npar, 1),
                        max(args.prod_ncore, 1))
    mem_per_cpu = max(200, round_up(prod_use / max(args.mem_util, 0.05)))
    nodes, ntpn = geometry(args.prod_ranks, args.cpus_per_node, mem_per_cpu,
                           args.node_mem_mb)
    per_node_use = ntpn * prod_use / 1024.0
    per_node_req = ntpn * mem_per_cpu / 1024.0

    # ------------------------------------------------------------------- #
    # Verdict on the recommended (fixed) parallel config
    # ------------------------------------------------------------------- #
    verdict, advice = [], []
    if args.cpu_eff > 0:
        if args.cpu_eff >= 85:
            verdict.append(f"parallel efficiency GOOD ({args.cpu_eff:.0f}%)")
        elif args.cpu_eff >= 70:
            verdict.append(f"parallel efficiency OK ({args.cpu_eff:.0f}%)")
            advice.append("efficiency is moderate; a different KPAR/NCORE might be faster.")
        else:
            verdict.append(f"parallel efficiency LOW ({args.cpu_eff:.0f}%)")
            advice.append("efficiency is poor; consider re-running vasp-recommend with "
                          "different --nsim-choices, or fewer ranks.")
    fits = mem_per_cpu * ntpn <= args.node_mem_mb
    if fits and nodes == 1:
        verdict.append("memory fits one node")
    elif fits:
        verdict.append(f"memory fits across {nodes} nodes")
        advice.append(f"production memory needs {nodes} nodes ({ntpn} ranks/node) to fit.")
    else:
        verdict.append("memory does NOT fit")
        advice.append("even one node can't hold this; reduce ranks or use a large-mem partition.")
    adequate = (args.cpu_eff == 0 or args.cpu_eff >= 70) and fits
    headline = ("ADEQUATE -- the recommended config works; memory updated below."
                if adequate else
                "REVIEW -- see the notes; the recommended config may need tuning.")

    # ------------------------------------------------------------------- #
    # Build the STAGE 3 report section
    # ------------------------------------------------------------------- #
    L = []
    L.append("[BENCHMARK -- measured with the FIXED recommended config]")
    L.append(f"  ran at                  : {args.ntasks_test} ranks "
             f"(KPAR={args.test_kpar}, NCORE={args.test_ncore}, NPAR={args.test_npar})")
    L.append(f"  peak memory / rank      : {args.maxrss_mb:.0f} MB   (SLURM MaxRSS)")
    if args.cpu_eff > 0:
        L.append(f"  CPU efficiency          : {args.cpu_eff:.1f} %")
    if args.avg_loop > 0:
        L.append(f"  wall per SCF step       : {args.avg_loop:.2f} s  "
                 f"({args.nscf} steps in {args.wall}s)")
    if mem["total"] > 0 and corr:
        L.append(f"  VASP table / measured   : x{corr:.2f}  (real RSS vs VASP's table)")
    L.append("")
    L.append(f"[PRODUCTION -- the FIXED config at {args.prod_ranks} ranks]")
    L.append(f"  KPAR / NCORE / NPAR     : {args.prod_kpar} / {args.prod_ncore} / {args.prod_npar}")
    L.append(f"  NSIM                    : {args.prod_nsim}")
    L.append(f"  layout                  : {nodes} node(s) x {ntpn} ranks-per-node "
             f"on '{args.prod_partition}'")
    L.append("")
    L.append("[MEMORY -- measured, scaled to production, sized to the 80% rule]")
    L.append(f"  predicted use / rank    : {prod_use:.0f} MB  "
             f"(scaled {args.ntasks_test}->{args.prod_ranks} ranks)")
    L.append(f"  --mem-per-cpu (request) : {mem_per_cpu} MB  "
             f"(= {prod_use:.0f} / {args.mem_util:.2f})")
    L.append(f"  per node                : {per_node_use:.0f} GB used of "
             f"{per_node_req:.0f} GB requested  (target >= {args.mem_util*100:.0f}%)")
    L.append("")
    L.append(f"[VERDICT]  {headline}")
    for v in verdict:
        L.append(f"  - {v}")
    for a in advice:
        L.append(f"  ! {a}")
    body = "\n".join(L)

    print(body)

    if args.update_slurm and update_slurm(args.update_slurm, mem_per_cpu, nodes, ntpn):
        print(f"\n[FILES] updated production memory in {args.update_slurm} "
              f"-> --mem-per-cpu={mem_per_cpu}, --nodes={nodes}, "
              f"--ntasks-per-node={ntpn}")

    if args.report:
        bar = "#" * 78
        import datetime as _dt
        section = (f"\n{bar}\n#  STAGE 3/3 -- BENCHMARK + FINAL MEMORY (vasp-test)\n"
                   f"#  {_dt.datetime.now():%Y-%m-%d %H:%M:%S}\n{bar}\n\n{body}\n")
        try:
            with open(args.report, "a") as fh:
                fh.write(section)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
