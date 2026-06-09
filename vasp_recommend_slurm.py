#!/usr/bin/env python3
"""
vasp_recommend_slurm.py   (command: vasp-recommend-slurm)
========================================================

VASP parallelization recommender for SLURM clusters, rewritten from the
official VASP documentation.  The goal is to give configurations that (a)
follow the rules documented on https://vasp.at/wiki and (b) come with an honest
per-MPI-rank memory prediction so that the SLURM script you submit will
actually fit in the partition you target.

CLUSTER PROFILE
  The partition names, cores/node, memory/node, the module-load lines for your
  chosen VASP build, the notification email and the account core cap are read
  from the per-user profile written by `vasp-configure`
  (~/.config/wolfpack-dft/cluster.conf).  Without a profile, the built-in NLHPC
  partitions below are used as a worked example/default.

Authoritative references (all consulted while writing this script):

  * https://vasp.at/wiki/Optimizing_the_parallelization
  * https://vasp.at/wiki/Category:Parallelization
  * https://vasp.at/wiki/NCORE
  * https://vasp.at/wiki/NPAR
  * https://vasp.at/wiki/KPAR
  * https://vasp.at/wiki/NSIM
  * https://vasp.at/wiki/LPLANE
  * https://vasp.at/wiki/Memory_requirements
  * https://vasp.at/wiki/Not_enough_memory
  * https://vasp.at/wiki/Performance_issues,_try_NCORE,_KPAR,_ALGO,_LREAL
  * https://wiki.nlhpc.cl/VASP                          (NLHPC SLURM recipe)
  * https://docs.nersc.gov/applications/vasp/           (memory scaling, OUTCAR)

================================================================================
WHAT THIS REWRITE FIXES COMPARED TO THE OLD TOOL
================================================================================

1. Memory prediction is now anchored to VASP itself.
   ----------------------------------------------------------------------------
   The dry-run OUTCAR contains an authoritative memory table written by VASP:

       total amount of memory used by VASP MPI-rank0  457796. kBytes
       =======================================================================
         base      :  30000. kBytes
         nonlr-proj:  12085. kBytes
         fftplans  :  29652. kBytes
         grid      :  54584. kBytes
         one-center:    211. kBytes
         wavefun   : 331264. kBytes

   This is the per-rank memory VASP would actually use under the layout used
   for the dry run.  The new tool parses this table and rescales each line
   to the candidate (NCORE, NPAR, KPAR) layout using the distribution rules
   from the VASP wiki:

       wavefun     scales as 1 / total_ranks
                   (orbitals fully distributed across NPAR*NCORE*KPAR)
       grid        scales as 1 / NPAR
                   (z-slab distribution with LPLANE; replicated per k-group
                    so KPAR does NOT reduce per-rank grid memory)
       nonlr-proj  scales as 1 / NCORE
                   (PAW projectors are distributed across the band group)
       fftplans, base, one-center: ~ constant per rank
       scaLAPACK NBANDS^2 workspace: NBANDS^2 * 16 * KPAR / total_ranks
                   (distributed within the k-group; KPAR REPLICATES it)

   If the OUTCAR does not have a memory table (older builds, very short
   aborts), the tool falls back to the formulas given on
   https://vasp.at/wiki/Memory_requirements .

2. NCORE > 1 is now allowed (and often preferred).
   ----------------------------------------------------------------------------
   The VASP wiki explicitly states:

       "On massively parallel systems and modern multi-core machines we
        strongly recommend to set  NCORE = 2 up to number-of-cores-per-socket
        (or number-of-cores-per-node)."           (NCORE wiki page)

   and

       "Setting NCORE equal to the number of cores per NUMA domain is often
        a particularly good choice."              (NCORE wiki page)

   The old tool hard-coded NCORE = 1.  That follows the NLHPC SLURM template
   verbatim but contradicts the upstream VASP recipe and, for >100 atoms,
   leaves a factor-of-up-to-four performance on the table.  This rewrite
   enumerates NCORE in {1, 2, ..., min(cores_per_node, NUMA-size*2)} and
   lets the scoring choose.  The SLURM script still emits OMP_NUM_THREADS=1
   and --cpus-per-task=1, so the result is still pure MPI; only the INCAR's
   NCORE knob changes.

3. Special case for bulk systems with small unit cells.
   ----------------------------------------------------------------------------
   Per the VASP wiki: "For bulk systems with small unit cells (NBANDS is
   small, NKPTS is large), NCORE=1 and KPAR=NKPTS is optimal."  The scoring
   recognises this and gives that exact configuration a large bonus.

4. The parallelization identity is enforced correctly.
   ----------------------------------------------------------------------------
   The VASP wiki defines

           total_ranks = (ranks parallelising bands) * NCORE * KPAR * IMAGES
           NPAR        = (total_ranks / KPAR) / NCORE          (with IMAGES=1)

   The old tool had NPAR * KPAR ~ total_ranks (i.e. it silently fixed
   NCORE=1).  This rewrite uses the full identity NPAR*NCORE*KPAR = total
   and enumerates the divisor lattice properly.

5. The dry-run's actual NPAR/NCORE/KPAR are now parsed.
   ----------------------------------------------------------------------------
   VASP writes two unambiguous lines into the dry-run OUTCAR header:

       distrk: each k-point on   1 cores,    1 groups
       distr:  one band on  NCORE=   1 cores,    1 groups

   The first tells us KPAR_dry (number of k-point groups) and the rank count
   per k-group; the second gives NCORE_dry and NPAR_dry (number of band
   groups).  Without these we cannot rescale the memory table.

================================================================================
HOW TO USE THIS SCRIPT
================================================================================

Step 1 -- generate a dry-run OUTCAR
-----------------------------------
In your calculation directory with valid INCAR/POSCAR/POTCAR/KPOINTS, add
ALGO=None temporarily (or use the --dry-run command-line option of VASP),
then run VASP for a few seconds on any number of ranks (1 is fine):

    cp INCAR INCAR.production
    echo 'ALGO = None' >> INCAR
    srun -n 1 vasp_std         # ranks here only set the memory table layout
    cp OUTCAR dryrun_OUTCAR
    mv INCAR.production INCAR

A dry run on 1 rank is the most informative because it reports the FULL
arrays before any distribution; from that the tool can predict per-rank
memory for any candidate (KPAR, NCORE, NPAR) you might consider.

Step 2 -- run the recommender
-----------------------------
    python3 vasp_recommend_slurm.py dryrun_OUTCAR

That prints (a) the dry-run summary, (b) the top candidates table, and
(c) a ready-to-submit NLHPC SLURM script for the best one.

Useful flags
------------
    --partition {main,debug,general,largemem}     default: main
    --max-cores N        account-wide MPI-rank cap (default 120)
    --min-cores N        smallest total_ranks to evaluate (default 8)
    --mem-headroom F     safety multiplier on memory estimate (default 1.15)
    --cores-per-node N   override the partition's CPUs-per-node
    --numa-cores N       override the NUMA-domain core count (for NCORE tuning)
    --top N              how many rows to print (default 10)
    --csv FILE           write the full ranked list as CSV
    --email user@host    inserted into the SLURM script
    --job-name NAME      SLURM --job-name (default: VASP)
    --executable EXE     force vasp_std|vasp_gam|vasp_ncl (else auto from OUTCAR)
    --time D-HH:MM:SS    SLURM time limit (default: 7-00:00:00)
    --calc-type {auto,dft,gw,gw-low,rpa-low}
                         override automatic DFT/GW/RPA detection (default: auto)
    --nomega N           override NOMEGA parsed from OUTCAR (for GW grid split)
    --no-maxmem          suppress MAXMEM from the generated INCAR snippet
    --gw-mem-per-rank MB override the empirical GW per-rank anchor (MB)
    --gw-ref-ranks N     override the reference rank count used for GW scaling
    --gw-ref-encutgw EV  override the reference ENCUTGW used for GW scaling
    --strict-ncore-one   force NCORE=1 (strict NLHPC recipe; not recommended)
    --allow-kpar-above-irr  permit KPAR > NKPTS (off by default per wiki)
    --nsim-choices 1 2 4 8  enumerate these NSIM values (default 4 only; CPU)

================================================================================
PHILOSOPHICAL NOTE
================================================================================
This is still a candidate generator, not a proof of optimality.  The
official VASP recipe (https://vasp.at/wiki/Optimizing_the_parallelization)
remains: "Run a few test calculations varying the parallel setup and use
the optimal choice of parameters for the rest of the calculations."  Use
the top 2-3 candidates this tool prints as your starting point for a short
benchmark, then commit to the fastest.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple


# ============================================================================
# NLHPC partition catalogue
# ============================================================================
# Numbers come from https://wiki.nlhpc.cl/VASP and the NLHPC hardware page.
# ``mem_per_cpu_mb`` is the value NLHPC itself uses in its SLURM templates.
# ``numa_cores`` is the typical NUMA-domain size; if you care about the
# exact number, run ``lstopo`` or ``numactl --hardware`` on a compute node
# and override with --numa-cores.
NLHPC_PARTITIONS: Dict[str, Dict[str, object]] = {
    # -- AMD Zen4 (Genoa) partitions --------------------------------------
    "main": {
        "cpus_per_node": 256,
        "mem_per_cpu_mb": 2839,
        "numa_cores": 16,
        "arch": "amd-zen4",
        "modules": [
            "ml gcc/14.2.0-zen4-y",
            "ml vasp/6.4.3-mpi-openmp-h5-zen4-c",
        ],
        "extra_env": [
            "export OMPI_MCA_mtl=ofi",
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
        ],
    },
    "debug": {
        "cpus_per_node": 48,
        "mem_per_cpu_mb": 7600,
        "numa_cores": 24,
        "arch": "amd-zen4",
        "modules": [
            "ml gcc/14.2.0-zen4-y",
            "ml vasp/6.4.3-mpi-openmp-h5-zen4-c",
        ],
        "extra_env": [
            "export OMPI_MCA_mtl=ofi",
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
        ],
    },
    # -- Intel partitions --------------------------------------------------
    "general": {
        "cpus_per_node": 44,
        "mem_per_cpu_mb": 4200,
        "numa_cores": 22,
        "arch": "intel",
        "modules": [
            "ml purge",
            "ml intel/2022.00",
            "ml VASP/6.3.2",
        ],
        "extra_env": [
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
            "export MKL_DYNAMIC=FALSE",
        ],
    },
    "largemem": {
        "cpus_per_node": 44,
        "mem_per_cpu_mb": 16500,
        "numa_cores": 22,
        "arch": "intel",
        "modules": [
            "ml purge",
            "ml intel/2022.00",
            "ml VASP/6.3.2",
        ],
        "extra_env": [
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
            "export MKL_DYNAMIC=FALSE",
        ],
    },
}


# ============================================================================
# Data classes
# ============================================================================


@dataclass
class MemoryBreakdown:
    """The 'total amount of memory used by VASP MPI-rank0' table, in MB.

    All values are MB (the OUTCAR reports kBytes; we convert at parse time).
    A field is None when the dry-run OUTCAR does not contain the table.
    """
    base_mb: Optional[float] = None
    nonlr_proj_mb: Optional[float] = None
    fftplans_mb: Optional[float] = None
    grid_mb: Optional[float] = None
    one_center_mb: Optional[float] = None
    wavefun_mb: Optional[float] = None
    total_mb: Optional[float] = None        # the headline number from OUTCAR

    def has_data(self) -> bool:
        return self.total_mb is not None


@dataclass
class DryRunSummary:
    """Quantities parsed from a previous VASP dry-run OUTCAR."""
    outcar_path: Path

    # --- System / electronic structure ---
    irr_kpoints: Optional[int] = None    # number of irreducible k-points
    nkpts: Optional[int] = None          # NKPTS as printed by VASP
    nbands: Optional[int] = None
    nions: Optional[int] = None
    nelect: Optional[float] = None
    ispin: int = 1
    nplwv: Optional[int] = None          # max plane waves over all k-points
    coarse_fft: Optional[Tuple[int, int, int]] = None   # NGX, NGY, NGZ
    fine_fft: Optional[Tuple[int, int, int]] = None     # NGXF, NGYF, NGZF
    is_gamma_only: bool = False

    # --- Algorithm settings (informational) ---
    algo: Optional[str] = None
    lreal: Optional[str] = None
    encut: Optional[float] = None

    # --- GW / RPA detection and tags ---
    # calc_type is one of: "DFT", "GW_CONVENTIONAL", "GW_LOWSCALING",
    # "RPA_LOWSCALING".  See detect_calculation_type().
    calc_type: str = "DFT"
    gw_algo: Optional[str] = None        # the ALGO string that triggered GW/RPA
    nomega: Optional[int] = None         # NOMEGA: number of (imaginary) frequencies
    nomegar: Optional[int] = None        # NOMEGAR (real-axis frequencies)
    nelmgw: Optional[int] = None         # NELMGW / (NELM for GW in 6.2 and older)
    encutgw: Optional[float] = None      # ENCUTGW: response-function cutoff
    nbandsgw: Optional[int] = None       # NBANDSGW: bands updated in self-consistency
    loptics: Optional[bool] = None       # LOPTICS (writes WAVEDER)
    ntaupar_dry: Optional[int] = None    # NTAUPAR found in the OUTCAR (if any)
    nomegapar_dry: Optional[int] = None  # NOMEGAPAR found in the OUTCAR (if any)
    # Low-scaling-specific FFT grids (printed by VASP for space-time GW/RPA):
    #   "FFT grid for exact exchange (Hartree Fock)"  -> fft_exx
    #   "FFT grid for supercell:"                      -> fft_supercell
    fft_exx: Optional[Tuple[int, int, int]] = None
    fft_supercell: Optional[Tuple[int, int, int]] = None
    # VASP's own printed low-scaling estimate, if present in the OUTCAR:
    #   "min. memory requirement per mpi rank 1234 MB, per node 9872 MB"
    vasp_min_mem_per_rank_mb: Optional[float] = None
    vasp_min_mem_per_node_mb: Optional[float] = None

    # --- Parallel layout the DRY RUN itself used ---
    # These are essential for rescaling the memory table.
    dry_total_ranks: Optional[int] = None
    dry_kpar: Optional[int] = None
    dry_ncore: Optional[int] = None
    dry_npar: Optional[int] = None

    # --- Memory table reported by VASP for the dry-run layout ---
    memory: MemoryBreakdown = field(default_factory=MemoryBreakdown)


@dataclass
class MemoryEstimate:
    """Per-rank and per-job memory estimate, all in MB."""
    wavefun_mb: float = 0.0
    grid_mb: float = 0.0
    nonlr_proj_mb: float = 0.0
    fftplans_mb: float = 0.0
    base_mb: float = 0.0
    one_center_mb: float = 0.0
    scalapack_mb: float = 0.0
    safety_mb: float = 0.0

    per_rank_mb: float = 0.0
    total_job_mb: float = 0.0
    suggested_mem_per_cpu_mb: int = 0

    partition_mem_per_cpu_mb: int = 0
    fits_partition: bool = True

    model: str = "fallback"   # "rescaled-from-outcar" or "fallback-formulas"

    # --- Low-scaling GW/RPA extras (filled only for space-time GW/RPA) ---
    # The dominant low-scaling term: (Green's function + polarizability) on
    # the imaginary-time/-frequency grids.  See estimate_lowscaling_gw_memory.
    gw_grid_term_mb: float = 0.0         # per-rank cost of the imaginary-grid arrays
    gw_per_node_mb: float = 0.0          # per-node requirement (per_rank * ranks/node)
    maxmem_mb: int = 0                   # MAXMEM value we recommend putting in the INCAR
    gw_grid_source: str = ""             # "outcar-grids", "fine-fft-proxy", or "unknown"


@dataclass
class Candidate:
    """A complete (total_ranks, KPAR, NCORE, NPAR, NSIM, LPLANE) recipe."""
    score: float
    total_ranks: int
    kpar: int
    ncore: int
    npar: int
    nsim: int
    lplane: bool
    ranks_per_kgroup: int           # = total_ranks / KPAR = NPAR * NCORE
    bands_per_group: float          # = NBANDS / NPAR
    effective_nbands: int           # NBANDS rounded up to multiple of NPAR
    nodes: int
    ntasks_per_node: int
    cpu_bind: str
    memory: MemoryEstimate
    contributions: Dict[str, float] = field(default_factory=dict)
    reasons: List[str] = field(default_factory=list)

    # --- GW / RPA extras (defaults keep DFT candidates unchanged) ---
    calc_type: str = "DFT"
    nomega: Optional[int] = None       # echoed from the dry run, for the INCAR comment
    ntaupar: Optional[int] = None      # low-scaling: imaginary-time grid groups
    nomegapar: Optional[int] = None    # low-scaling: imaginary-frequency grid groups
    recommend_maxmem: bool = False     # whether the INCAR snippet should set MAXMEM

    @property
    def sort_key(self) -> Tuple[float, int, int, int]:
        """Highest score first; tie-break by larger total_ranks then KPAR."""
        return (-self.score, -self.total_ranks, -self.kpar, -self.ncore)

    @property
    def incar_snippet(self) -> str:
        if self.calc_type == "DFT":
            return self._incar_snippet_dft()
        if self.calc_type == "GW_CONVENTIONAL":
            return self._incar_snippet_gw_conventional()
        # GW_LOWSCALING or RPA_LOWSCALING
        return self._incar_snippet_gw_lowscaling()

    def _incar_snippet_dft(self) -> str:
        return (
            "# --- Parallelization (VASP wiki recipe; pure MPI) ---\n"
            f"KPAR   = {self.kpar}\n"
            f"NCORE  = {self.ncore}\n"
            f"NSIM   = {self.nsim}\n"
            f"LPLANE = {format_bool(self.lplane)}\n"
            f"# Derived only: NPAR = {self.npar}  (do NOT set BOTH NCORE and NPAR)\n"
            "# I/O hygiene:\n"
            "LWAVE  = .FALSE.\n"
            "LCHARG = .FALSE.\n"
            "LVTOT  = .FALSE."
        )

    def _incar_snippet_gw_conventional(self) -> str:
        # Conventional (quartic-scaling) GW parallelizes ONLY over k-points.
        # NCORE / NPAR > 1 do not help the GW step itself, so we pin NCORE = 1
        # and drive everything through KPAR.
        # https://vasp.at/wiki/Practical_guide_to_GW_calculations
        rpk = self.ranks_per_kgroup
        return (
            "# --- Parallelization: CONVENTIONAL (quartic-scaling) GW ---\n"
            "# GW parallelizes only over k-points -> KPAR is the lever; NCORE = 1.\n"
            f"KPAR  = {self.kpar}    # k-point groups (divisor of NKPTS)\n"
            "NCORE = 1     # REQUIRED for the GW step (no band-FFT distribution)\n"
            f"# Each k-point group gets {rpk} rank(s); they parallelize the\n"
            "# internal DFT/Exact diagonalization. Do NOT set NPAR for GW.\n"
            "# GW essentials (keep consistent with your DFT/Exact pre-step):\n"
            "ISMEAR = 0 ; SIGMA = 0.05   # small SIGMA to avoid partial occupancies\n"
            "# LOPTICS = .TRUE.          # insulators/semiconductors; OMIT for metals\n"
            "# I/O: keep WAVECAR/WAVEDER from the DFT step; do not delete them."
        )

    def _incar_snippet_gw_lowscaling(self) -> str:
        # Low-scaling (space-time) GW/RPA: the imaginary-grid split via
        # NTAUPAR / NOMEGAPAR is the lever. VASP strongly recommends setting
        # MAXMEM and letting it pick NTAUPAR/NOMEGAPAR automatically.
        # https://vasp.at/wiki/Practical_guide_to_GW_calculations
        # https://vasp.at/wiki/NTAUPAR  https://vasp.at/wiki/NOMEGAPAR
        is_rpa = self.calc_type == "RPA_LOWSCALING"
        head = "LOW-SCALING RPA" if is_rpa else "LOW-SCALING (space-time) GW"
        maxmem = self.memory.maxmem_mb
        nomega_cmt = (f"  # NOMEGA = {self.nomega} (must be divisible by both)"
                      if self.nomega else "")
        lines = [
            f"# --- Parallelization: {head} ---",
            "# Primary lever: the imaginary time/frequency grid split.",
            "# VASP recommends setting MAXMEM and letting it choose NTAUPAR/NOMEGAPAR.",
            f"KPAR     = {self.kpar}     # k-point groups (divisor of NKPTS)",
            "NCORE    = 1      # leave band-FFT distribution off; use the grid split",
        ]
        if self.recommend_maxmem and maxmem > 0:
            lines += [
                f"MAXMEM   = {maxmem}   # MB available to ONE mpi rank on a node;",
                "#                       VASP auto-selects NTAUPAR/NOMEGAPAR to fit.",
            ]
        if self.ntaupar and self.nomegapar:
            lines += [
                "# Explicit override (only if you do NOT trust the MAXMEM auto-pick):",
                f"# NTAUPAR   = {self.ntaupar}{nomega_cmt}",
                f"# NOMEGAPAR = {self.nomegapar}",
                "#   Both MUST be divisors of NOMEGA. Larger NTAUPAR = faster but more RAM.",
            ]
        elif self.ntaupar:
            lines += [
                f"# NTAUPAR = {self.ntaupar}{nomega_cmt}  (divisor of NOMEGA; larger=faster,more RAM)",
            ]
        lines += [
            "ISMEAR = 0 ; SIGMA = 0.05",
            "# LOPTICS = .TRUE.   # insulators/semiconductors; OMIT for metals",
        ]
        return "\n".join(lines)


# ============================================================================
# Small utilities
# ============================================================================


def positive_divisors(n: int) -> List[int]:
    """Return all positive divisors of n in ascending order."""
    if n <= 0:
        return []
    small: List[int] = []
    large: List[int] = []
    root = math.isqrt(n)
    for i in range(1, root + 1):
        if n % i == 0:
            small.append(i)
            j = n // i
            if j != i:
                large.append(j)
    return small + list(reversed(large))


def format_bool(value: bool) -> str:
    return ".TRUE." if value else ".FALSE."


def round_up_to_multiple(n: int, m: int) -> int:
    if m <= 0:
        return n
    return ((n + m - 1) // m) * m


def round_up_mem(mb: float, step: int = 50) -> int:
    """Round memory up to a 'nice' multiple of `step` MB (min 100 MB)."""
    return int(math.ceil(max(mb, 100.0) / step) * step)


# ============================================================================
# OUTCAR parsing
# ============================================================================


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise SystemExit(f"Could not read {path}: {exc}") from exc


def _first_int(patterns: Sequence[str], text: str) -> Optional[int]:
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
        if match:
            try:
                return int(match.group(1))
            except (ValueError, IndexError):
                continue
    return None


def _first_float(patterns: Sequence[str], text: str) -> Optional[float]:
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
        if match:
            try:
                return float(match.group(1))
            except (ValueError, IndexError):
                continue
    return None


def _first_str(patterns: Sequence[str], text: str) -> Optional[str]:
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
        if match:
            try:
                return match.group(1).strip()
            except IndexError:
                continue
    return None


def _parse_fft_grid(text: str, fine: bool) -> Optional[Tuple[int, int, int]]:
    """Parse 'dimension x,y,z NGX = .. NGY = .. NGZ = ..' or NGXF/.. line."""
    if fine:
        pattern = r"NGXF\s*=\s*(\d+)\s+NGYF\s*=\s*(\d+)\s+NGZF\s*=\s*(\d+)"
    else:
        # The 'NGX = ' line appears for the coarse grid; be careful not to match NGXF.
        pattern = r"(?<!F)NGX\s*=\s*(\d+)\s+NGY\s*=\s*(\d+)\s+NGZ\s*=\s*(\d+)"
    match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
    if match:
        return (int(match.group(1)), int(match.group(2)), int(match.group(3)))
    return None


def _parse_dry_distribution(text: str) -> Tuple[Optional[int], Optional[int],
                                                Optional[int], Optional[int]]:
    """Return (total_ranks_dry, kpar_dry, ncore_dry, npar_dry).

    VASP prints, near the top of the OUTCAR, two unambiguous lines:

        running on    1 total cores
        distrk:  each k-point on    1 cores,    1 groups
        distr:   one band on  NCORE=   1 cores,    1 groups

    The 'groups' field of distrk gives KPAR.
    The NCORE= field of distr gives NCORE.
    The 'groups' field of distr gives NPAR.
    """
    total = _first_int(
        [r"running on\s+(\d+)\s+total cores"],
        text,
    )
    kpar = None
    ncore = None
    npar = None

    m_kpar = re.search(
        r"distrk:\s*each k-point on\s+\d+\s+cores,\s*(\d+)\s+groups",
        text,
        flags=re.IGNORECASE,
    )
    if m_kpar:
        kpar = int(m_kpar.group(1))

    m_ncore = re.search(
        r"distr:\s*one band on\s+NCORE\s*=\s*(\d+)\s+cores,\s*(\d+)\s+groups",
        text,
        flags=re.IGNORECASE,
    )
    if m_ncore:
        ncore = int(m_ncore.group(1))
        npar = int(m_ncore.group(2))

    # Consistency: derive the missing field from the parallelization
    # identity total_ranks = NPAR * NCORE * KPAR (with IMAGES=1).
    if not total and kpar and ncore and npar:
        # 'running on N total cores' is sometimes missing (older builds,
        # short reports, certain MPI launchers).  This is the common case.
        total = kpar * ncore * npar
    if total and kpar and ncore and not npar:
        npar = max(1, (total // kpar) // ncore)
    if total and ncore and npar and not kpar:
        kpar = max(1, total // (ncore * npar))
    if total and kpar and npar and not ncore:
        ncore = max(1, total // (kpar * npar))

    return total, kpar, ncore, npar


def _parse_memory_table(text: str) -> MemoryBreakdown:
    """Parse the 'total amount of memory used by VASP MPI-rank0' table.

    Output is in MB.  Returns an empty MemoryBreakdown if the table is
    missing (e.g. very old VASP, aborted dry run).  Different VASP builds
    format this table slightly differently (column width, trailing dots,
    optional spaces), so we try a few patterns per row.
    """
    mb = MemoryBreakdown()

    # Headline number.  Match with or without trailing period after the value.
    m_total = re.search(
        r"total amount of memory used by VASP MPI-rank0"
        r"\s+([0-9]+(?:\.[0-9]+)?)\.?\s*k[bB]ytes",
        text,
    )
    if m_total:
        try:
            mb.total_mb = float(m_total.group(1)) / 1024.0
        except ValueError:
            pass

    # Per-row labels.  VASP has used several spellings over the years; map
    # them all to the same MemoryBreakdown attribute.
    row_keys = {
        "base":       "base_mb",
        "nonlr-proj": "nonlr_proj_mb",
        "nonl-proj":  "nonlr_proj_mb",    # older VASP spelling
        "nonl_proj":  "nonlr_proj_mb",    # very old variant
        "fftplans":   "fftplans_mb",
        "fft-plans":  "fftplans_mb",
        "grid":       "grid_mb",
        "one-center": "one_center_mb",
        "one_center": "one_center_mb",
        "wavefun":    "wavefun_mb",
        "wavefunctions": "wavefun_mb",    # defensive
    }
    for outcar_label, attr in row_keys.items():
        # Several alternative patterns; first match wins.  We do NOT use \b
        # at the start because some labels contain '-' or '_' which are not
        # word-character boundaries.  We anchor on at-least-one whitespace
        # before the label instead.
        patterns = [
            # Standard:    label  :   1234. kBytes
            rf"(?:^|\s){re.escape(outcar_label)}\s*:\s*"
            rf"([0-9]+(?:\.[0-9]+)?)\.?\s*k[bB]ytes",
            # Fortran overflow guard (rare): label : ******* kBytes -> skip
            # Sometimes the value sits on the next line:
            rf"(?:^|\s){re.escape(outcar_label)}\s*:\s*\n\s*"
            rf"([0-9]+(?:\.[0-9]+)?)\.?\s*k[bB]ytes",
        ]
        for pattern in patterns:
            m = re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE)
            if m:
                try:
                    setattr(mb, attr, float(m.group(1)) / 1024.0)
                except ValueError:
                    pass
                break

    return mb


# ----------------------------------------------------------------------------
# GW / RPA recognition
# ----------------------------------------------------------------------------
# ALGO values that select a GW or RPA calculation, split by implementation.
# Names are compared upper-cased and stripped.  VASP.5 aliases are included.
#   * Conventional (quartic-scaling) GW: parallelizes over k-points (KPAR) only.
#   * Low-scaling / space-time GW (names end in 'R'): use NTAUPAR / NOMEGAPAR.
#   * Low-scaling RPA (ACFDTR / RPAR): same imaginary-grid machinery as GW-R.
GW_CONVENTIONAL_ALGOS = {
    "G0W0", "GW0", "GW",
    "EVGW0", "EVGW", "QPGW0", "QPGW",
    "SCGW0", "SCGW",          # VASP.5 aliases for QPGW0 / QPGW
}
GW_LOWSCALING_ALGOS = {
    "G0W0R", "EVGW0R", "GW0R", "GWR",
    "SCGW0R", "SCGWR",        # aliases
}
RPA_LOWSCALING_ALGOS = {
    "ACFDTR", "RPAR",         # low-scaling RPA / ACFDT (space-time)
}


# ----------------------------------------------------------------------------
# Empirical memory anchor for CONVENTIONAL (quartic-scaling) GW
# ----------------------------------------------------------------------------
# The DFT-style rank-0 memory table that VASP prints does NOT include the
# screened-Coulomb / polarizability arrays chi(G,G',omega) that dominate
# conventional-GW memory, so rescaling that table (as for DFT) under-predicts
# GW per-rank memory by ~10x.  Instead we anchor to a MEASURED data point and
# scale it by the variables that actually drive GW memory.
#
# Measured reference (Castello, CuVS3, G0W0@PBE+U via EVGW0, NLHPC):
#     per-rank memory   ~ 2292 MB
#     NOMEGA            = 100
#     ISPIN             = 2
#     NKPTS (irred.)    = 96
#     ENCUTGW           = 608 eV   (defaulted to ENCUT; SEE WARNING below)
#     KPAR              = 21
#     total MPI ranks   = 252      (ASSUMED 21x12; override with --gw-ref-ranks)
#
# Similarity scaling applied to a candidate (same machine/system family):
#     per_rank_GW ~ ANCHOR
#         * (NOMEGA      / NOMEGA_ref)
#         * (ISPIN       / ISPIN_ref)
#         * (ENCUTGW     / ENCUTGW_ref)^3      # chi ~ N_resp^2 ~ ENCUTGW^3
#         * (ranks_per_kgroup_ref / ranks_per_kgroup)   # arrays split over the group
# where ranks_per_kgroup = total_ranks / KPAR.
#
# The ENCUTGW dependence is CUBIC: it is by far the strongest memory knob.
# The reference ENCUTGW is unknown (it was commented out and thus defaulted to
# ENCUT = 608); 608 eV would normally OOM, so the true value used was very
# likely smaller.  Pass --gw-ref-encutgw with the value actually used to make
# the cross-ENCUTGW scaling (e.g. a 200->400 convergence sweep) quantitative.
GW_CONV_REF = {
    "per_rank_mb": 2292.0,
    "nomega": 100,
    "ispin": 2,
    "nkpts": 96,
    "encutgw": 608.0,
    "kpar": 21,
    "total_ranks": 252,   # assumption; ranks_per_kgroup_ref = 252/21 = 12
}


def _parse_named_fft_grid(text: str, header: str) -> Optional[Tuple[int, int, int]]:
    """Parse a 'NGX = .. NGY = .. NGZ = ..' triple that follows a header line.

    Low-scaling GW/RPA OUTCARs print, e.g.:

        FFT grid for exact exchange (Hartree Fock)
          NGX =  30 NGY =  30 NGZ =  30
        FFT grid for supercell:
          NGX =  60 NGY =  60 NGZ =  60

    `header` is a regex fragment identifying the introductory line.  We then
    look for the first NGX/NGY/NGZ triple appearing after it.
    """
    m_head = re.search(header, text, flags=re.IGNORECASE)
    if not m_head:
        return None
    tail = text[m_head.end():m_head.end() + 400]
    m = re.search(
        r"NGX\s*=?\s*(\d+)\s+NGY\s*=?\s*(\d+)\s+NGZ\s*=?\s*(\d+)",
        tail,
        flags=re.IGNORECASE,
    )
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return None


def _parse_lowscaling_minmem(text: str) -> Tuple[Optional[float], Optional[float]]:
    """Parse VASP's own low-scaling memory estimate, if present.

        min. memory requirement per mpi rank 1234 MB, per node 9872 MB

    Returns (per_rank_mb, per_node_mb).  This is VASP's authoritative number
    for the chosen NTAUPAR; when present we surface it verbatim.
    """
    m = re.search(
        r"min\.?\s*memory requirement per mpi rank\s+([0-9]+(?:\.[0-9]+)?)\s*MB"
        r".*?per node\s+([0-9]+(?:\.[0-9]+)?)\s*MB",
        text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not m:
        return None, None
    try:
        return float(m.group(1)), float(m.group(2))
    except ValueError:
        return None, None


def detect_calculation_type(
    s: DryRunSummary,
    text: str,
    override: Optional[str] = None,
) -> Tuple[str, Optional[str]]:
    """Classify the dry run as DFT / conventional-GW / low-scaling-GW / RPA.

    Returns (calc_type, gw_algo_string).

    Recognition is deliberately robust because the recommended dry-run recipe
    (append ``ALGO = None``) MASKS the real GW ALGO in the OUTCAR.  We therefore
    look at several independent signals:

      1. The ALGO string itself (authoritative when not masked).
      2. Low-scaling fingerprints that ALGO=None does NOT remove:
         the "FFT grid for exact exchange / supercell" lines, the
         "min. memory requirement per mpi rank ... per node" line, or an
         NTAUPAR / NOMEGAPAR echo.
      3. Conventional-GW fingerprints: NOMEGA together with a GW-only tag
         (NELMGW, ENCUTGW, NBANDSGW, or LSPECTRALGW).

    A manual ``override`` (from --calc-type) always wins.
    """
    if override and override != "auto":
        mapping = {
            "dft": ("DFT", None),
            "gw": ("GW_CONVENTIONAL", s.algo),
            "gw-low": ("GW_LOWSCALING", s.algo),
            "rpa-low": ("RPA_LOWSCALING", s.algo),
        }
        if override in mapping:
            return mapping[override]

    algo_up = (s.algo or "").strip().upper()
    # When the dry run masked ALGO with None (the recommended recipe appends
    # 'ALGO = None'), s.algo is the literal string "None"; treat it as masked
    # so the fingerprint branches report a helpful label instead of "None".
    algo_masked = (not s.algo) or algo_up in ("NONE", "NOTHING")
    algo_display = None if algo_masked else s.algo

    # 1. Direct ALGO match (only meaningful if ALGO wasn't overwritten by None).
    if algo_up in RPA_LOWSCALING_ALGOS:
        return "RPA_LOWSCALING", s.algo
    if algo_up in GW_LOWSCALING_ALGOS:
        return "GW_LOWSCALING", s.algo
    if algo_up in GW_CONVENTIONAL_ALGOS:
        return "GW_CONVENTIONAL", s.algo

    # 2. Low-scaling fingerprints (survive ALGO=None).
    lowscaling_markers = (
        s.fft_exx is not None
        or s.fft_supercell is not None
        or s.vasp_min_mem_per_rank_mb is not None
        or s.ntaupar_dry is not None
        or s.nomegapar_dry is not None
        or re.search(r"FFT grid for exact exchange", text, re.IGNORECASE) is not None
        or re.search(r"low.?scaling\s+(GW|RPA)", text, re.IGNORECASE) is not None
    )
    if lowscaling_markers:
        # Distinguish RPA from GW by other tags if we can; default to GW.
        if re.search(r"\bACFDT\b|\bRPA\b", text, re.IGNORECASE) \
                and not re.search(r"\bGW\b", text, re.IGNORECASE):
            return "RPA_LOWSCALING", algo_display or "(low-scaling RPA, ALGO masked)"
        return "GW_LOWSCALING", algo_display or "(low-scaling GW, ALGO masked)"

    # 3. Conventional-GW fingerprints: NOMEGA + a GW-only tag.
    has_gw_tag = (
        s.nelmgw is not None
        or s.encutgw is not None
        or s.nbandsgw is not None
        or re.search(r"\bLSPECTRALGW\b", text, re.IGNORECASE) is not None
        or re.search(r"\bNOMEGAR\b", text, re.IGNORECASE) is not None
    )
    if s.nomega is not None and has_gw_tag:
        return "GW_CONVENTIONAL", algo_display or "(GW, ALGO masked)"
    # ENCUTGW alone is a strong GW signal even without NOMEGA parsed.
    if s.encutgw is not None and (s.nomega is not None or has_gw_tag):
        return "GW_CONVENTIONAL", algo_display or "(GW, ALGO masked)"

    return "DFT", None


def parse_outcar(outcar_path: Path,
                 calc_type_override: Optional[str] = None) -> DryRunSummary:
    text = _read_text(outcar_path)
    s = DryRunSummary(outcar_path=outcar_path)

    # System dimensions
    s.irr_kpoints = _first_int(
        [
            r"irreducible k-points\s*[:=]\s*(\d+)",
            r"Found\s+(\d+)\s+irreducible k-points",
            r"number of irreducible k-points:\s*(\d+)",
        ],
        text,
    )
    s.nkpts = _first_int(
        [
            r"NKPTS\s*=\s*(\d+)",
            r"k-points\s+NKPTS\s*=\s*(\d+)",
        ],
        text,
    )
    s.nbands = _first_int(
        [
            r"NBANDS\s*=\s*(\d+)",
            r"number of bands\s+NBANDS\s*=\s*(\d+)",
        ],
        text,
    )
    s.nions = _first_int([r"NIONS\s*=\s*(\d+)"], text)
    s.nelect = _first_float([r"NELECT\s*=\s*([0-9]+(?:\.[0-9]+)?)"], text)
    s.ispin = _first_int([r"ISPIN\s*=\s*(\d+)"], text) or 1
    # NPLWV / NRPLWV: VASP sometimes prints overflowed '********' for large
    # systems and sometimes omits the line entirely.  Try several spellings.
    s.nplwv = _first_int(
        [
            r"\bNPLWV\s*=\s*(\d+)",
            r"\bNRPLWV\s*=\s*(\d+)",
            r"total plane-waves\s+NPLWV\s*=\s*(\d+)",
            r"total plane-waves\s*:\s*(\d+)",
            r"max plane-waves\s*=\s*(\d+)",
            r"maximum number of plane-waves\s*[:=]\s*(\d+)",
        ],
        text,
    )
    s.coarse_fft = _parse_fft_grid(text, fine=False)
    s.fine_fft = _parse_fft_grid(text, fine=True)
    # If NPLWV is not in the OUTCAR (or overflowed), estimate it from the
    # coarse FFT grid.  VASP sizes the FFT box so that 2|G_cut| just fits
    # inside it; the number of plane waves inside the sphere |G|<|G_cut| is
    # approximately (pi/48) * NGX*NGY*NGZ.  This is rough but in the right
    # order of magnitude; the memory model uses VASP's TOTAL anchor instead
    # whenever the OUTCAR provides it, so this fallback rarely matters.
    if s.nplwv is None and s.coarse_fft is not None:
        ngx, ngy, ngz = s.coarse_fft
        s.nplwv = max(1, int(ngx * ngy * ngz * math.pi / 48.0))
    s.is_gamma_only = (
        (s.irr_kpoints is not None and s.irr_kpoints == 1)
        or (s.nkpts is not None and s.nkpts == 1)
    )

    # Algorithm / cutoff.  Use \b to avoid matching IALGO when looking for ALGO.
    s.algo = _first_str([r"(?<![A-Z])ALGO\s*=\s*(\S+)"], text)
    s.lreal = _first_str([r"(?<![A-Z])LREAL\s*=\s*([^\s#]+)"], text)
    s.encut = _first_float([r"(?<![A-Z])ENCUT\s*=\s*([0-9.]+)"], text)

    # --- GW / RPA tags (informational + needed for the τ/ω grid split) ---
    s.nomega = _first_int([r"\bNOMEGA\s*=\s*(\d+)"], text)
    s.nomegar = _first_int([r"\bNOMEGAR\s*=\s*(\d+)"], text)
    s.nelmgw = _first_int([r"\bNELMGW\s*=\s*(\d+)"], text)
    s.encutgw = _first_float([r"\bENCUTGW\s*=\s*([0-9.]+)"], text)
    s.nbandsgw = _first_int([r"\bNBANDSGW\s*=\s*(\d+)"], text)
    s.ntaupar_dry = _first_int([r"\bNTAUPAR\s*=\s*(\d+)"], text)
    s.nomegapar_dry = _first_int([r"\bNOMEGAPAR\s*=\s*(\d+)"], text)
    _loptics = _first_str([r"\bLOPTICS\s*=\s*([TF\.]\w*)"], text)
    if _loptics is not None:
        s.loptics = _loptics.strip().upper().startswith((".T", "T"))
    # Low-scaling FFT grids (printed only for space-time GW/RPA runs):
    s.fft_exx = _parse_named_fft_grid(
        text, r"FFT grid for exact exchange(?:\s*\(Hartree[ -]?Fock\))?")
    s.fft_supercell = _parse_named_fft_grid(text, r"FFT grid for supercell")
    # VASP's own printed low-scaling memory estimate, if present:
    (s.vasp_min_mem_per_rank_mb,
     s.vasp_min_mem_per_node_mb) = _parse_lowscaling_minmem(text)

    # Dry-run parallel layout (essential for rescaling memory)
    (s.dry_total_ranks, s.dry_kpar,
     s.dry_ncore, s.dry_npar) = _parse_dry_distribution(text)

    # VASP-reported memory breakdown for the dry-run layout
    s.memory = _parse_memory_table(text)

    # Classify DFT vs GW vs RPA from all available signals.
    s.calc_type, s.gw_algo = detect_calculation_type(
        s, text, override=calc_type_override)

    return s


# ============================================================================
# Memory model
# ============================================================================


def _fallback_wavefun_mb(summary: DryRunSummary, ncore: int, npar: int,
                         kpar: int) -> float:
    """Wavefunction storage per rank, from the wiki formula.

    Per https://vasp.at/wiki/Memory_requirements:
        NKDIM * NBANDS * NRPLWV * 16  bytes
    where NRPLWV is the max number of plane waves over k-points (NPLWV in
    the dry-run).  Distributing fully over the rank lattice gives:

        per_rank = (NBANDS * NKPTS * NPLWV * ISPIN * 16) / (NPAR*NCORE*KPAR)
    """
    if not (summary.nbands and summary.nplwv):
        return 0.0
    nkpts = summary.nkpts or summary.irr_kpoints or 1
    total = npar * ncore * kpar
    if total <= 0:
        return 0.0
    bytes_per_rank = (
        summary.nbands * nkpts * summary.nplwv * (summary.ispin or 1) * 16.0
    ) / total
    return bytes_per_rank / (1024.0 ** 2)


def _fallback_grid_mb(summary: DryRunSummary, npar: int) -> float:
    """Grid (charge density / potential) work-array memory per rank.

    Per https://vasp.at/wiki/Memory_requirements ~10 arrays of size
        4 * (NGXF/2 + 1) * NGYF * NGZF * 16  bytes
    are allocated.  With LPLANE=.TRUE. these are distributed in z-slabs
    over NPAR ranks within a k-group.  Each k-group has its own copy;
    KPAR does NOT reduce the per-rank cost.
    """
    grid = summary.fine_fft or summary.coarse_fft
    if grid is None:
        return 0.0
    ngxf, ngyf, ngzf = grid
    n_arrays = 10
    bytes_total = n_arrays * 4.0 * (ngxf // 2 + 1) * ngyf * ngzf * 16.0
    per_rank = bytes_total / max(1, npar)
    return per_rank / (1024.0 ** 2)


def _fallback_proj_mb(summary: DryRunSummary, ncore: int) -> float:
    """PAW projector memory per rank.

    Rough empirical scaling: ~ 0.5 MB per ion per total-projector unit,
    distributed across NCORE within the band group.  This is a rough
    upper bound; the rescaled-from-OUTCAR branch is far more accurate.
    """
    natoms = summary.nions or 0
    # ~50 MB per 100 atoms; ScaLAPACK in VASP 6 typically holds projectors
    # in a denser form than this, but better to over- than under-estimate.
    raw = 0.5 * natoms
    return raw / max(1, ncore)


def _scalapack_mb(summary: DryRunSummary, total_ranks: int, kpar: int) -> float:
    """ScaLAPACK NBANDS x NBANDS sub-space matrix per rank.

    Distributed within each k-group; replicated across k-groups:
        per_rank = NBANDS^2 * 16 * KPAR / total_ranks
    """
    if not summary.nbands:
        return 0.0
    bytes_per_rank = (
        (summary.nbands ** 2) * 16.0 * max(1, kpar) / max(1, total_ranks)
    )
    return bytes_per_rank / (1024.0 ** 2)


def estimate_memory(
    *,
    summary: DryRunSummary,
    total_ranks: int,
    kpar: int,
    ncore: int,
    npar: int,
    partition_mem_per_cpu_mb: int,
    safety_factor: float,
) -> MemoryEstimate:
    """Predict per-rank memory for a candidate layout.

    Three-tier strategy, from most-accurate to least:

      Tier 1  ("rescaled-from-outcar"):
        The dry-run OUTCAR contains the FULL memory breakdown
        (base / nonlr-proj / fftplans / grid / one-center / wavefun).
        Each row is rescaled to the candidate layout using the wiki
        distribution rules:
            wavefun     : scales as 1 / total_ranks    (fully distributed)
            grid        : scales as 1 / NPAR           (z-slab; per k-group)
            nonlr-proj  : scales as 1 / NCORE          (per k-group)
            fftplans, base, one-center : ~ constant per rank
        scaLAPACK NBANDS^2 workspace is added on top (it is NOT in the
        table): per_rank = NBANDS^2 * 16 * KPAR / total_ranks.

      Tier 2  ("rescaled-from-outcar-total-only"):
        The OUTCAR has the headline 'total amount of memory used by VASP
        MPI-rank0 X kBytes' line but not the per-row breakdown.  In this
        tier we DECOMPOSE the total assuming the typical VASP CPU mix
        (wavefun ~ 80%, grid ~ 15%, nonlr-proj ~ 5%, fixed ~100 MB
        overhead) and rescale each component by its own distribution
        rule.  This is far less accurate than Tier 1 but FAR more
        accurate than ignoring the OUTCAR's TOTAL and going to formulas.

      Tier 3  ("fallback-formulas"):
        No memory table at all.  Use the wiki's analytical formulas with
        whatever dimensions were parsed (NPLWV, FFT grid, NBANDS, NKPTS).
        If NPLWV is missing, NPLWV is approximated from the FFT grid by
        the inscribed-sphere ratio at the parse stage.
    """
    est = MemoryEstimate(partition_mem_per_cpu_mb=partition_mem_per_cpu_mb)

    if total_ranks <= 0 or kpar <= 0 or ncore <= 0 or npar <= 0:
        return est

    mem_table = summary.memory
    have_total = mem_table.total_mb is not None
    have_individual_rows = (
        mem_table.wavefun_mb is not None
        and mem_table.grid_mb is not None
    )
    have_dry_layout = (
        summary.dry_total_ranks is not None
        and summary.dry_kpar is not None
        and summary.dry_ncore is not None
        and summary.dry_npar is not None
    )

    # ------------------------------------------------------------------
    # Tier 1: full breakdown available (best case).
    # ------------------------------------------------------------------
    if have_individual_rows and have_dry_layout:
        est.model = "rescaled-from-outcar"
        m = mem_table
        d_total = max(1, summary.dry_total_ranks)
        d_ncore = max(1, summary.dry_ncore)
        d_npar = max(1, summary.dry_npar)

        est.wavefun_mb = (m.wavefun_mb or 0.0) * d_total / total_ranks
        est.grid_mb = (m.grid_mb or 0.0) * d_npar / npar
        est.nonlr_proj_mb = (m.nonlr_proj_mb or 0.0) * d_ncore / ncore
        est.base_mb = m.base_mb or 30.0
        est.fftplans_mb = m.fftplans_mb or 30.0
        est.one_center_mb = m.one_center_mb or 0.5
        est.scalapack_mb = _scalapack_mb(summary, total_ranks, kpar)

    # ------------------------------------------------------------------
    # Tier 2: only the headline TOTAL is available.
    # ------------------------------------------------------------------
    elif have_total and have_dry_layout:
        est.model = "rescaled-from-outcar-total-only"
        d_total = max(1, summary.dry_total_ranks)
        d_ncore = max(1, summary.dry_ncore)
        d_npar = max(1, summary.dry_npar)

        # Fixed per-rank overhead that does NOT redistribute with the layout
        # (base + fftplans + one_center + small libraries).  Typical VASP 6
        # values are: base ~30 MB, fftplans ~40 MB, one_center ~5-50 MB.
        # We use 100 MB as a conservative single number; the actual breakdown
        # is rebuilt below for the human-readable output.
        const_overhead_mb = 100.0

        # Everything else at dry layout (per rank)
        distributed_per_rank_dry = max(0.0,
                                       (mem_table.total_mb or 0.0) - const_overhead_mb)

        # Decompose into wavefun / grid / nonlr-proj using a generic split
        # observed in practice on VASP 6 CPU calculations of medium-large
        # systems.  These fractions are conservative biases, NOT precise.
        wavefun_frac = 0.80
        grid_frac = 0.15
        proj_frac = 0.05

        wavefun_dry = wavefun_frac * distributed_per_rank_dry   # per rank
        grid_dry = grid_frac * distributed_per_rank_dry         # per rank
        proj_dry = proj_frac * distributed_per_rank_dry         # per rank

        # Rescale each by its documented distribution rule.
        est.wavefun_mb = wavefun_dry * d_total / total_ranks
        est.grid_mb = grid_dry * d_npar / npar
        est.nonlr_proj_mb = proj_dry * d_ncore / ncore
        est.base_mb = 30.0
        est.fftplans_mb = 50.0
        est.one_center_mb = 20.0
        est.scalapack_mb = _scalapack_mb(summary, total_ranks, kpar)

    # ------------------------------------------------------------------
    # Tier 3: no memory information at all.  Pure formulas.
    # ------------------------------------------------------------------
    else:
        est.model = "fallback-formulas"
        est.wavefun_mb = _fallback_wavefun_mb(summary, ncore, npar, kpar)
        est.grid_mb = _fallback_grid_mb(summary, npar)
        est.nonlr_proj_mb = _fallback_proj_mb(summary, ncore)
        est.base_mb = 30.0
        est.fftplans_mb = 30.0
        est.one_center_mb = 0.5
        est.scalapack_mb = _scalapack_mb(summary, total_ranks, kpar)

    base_sum = (
        est.wavefun_mb
        + est.grid_mb
        + est.nonlr_proj_mb
        + est.fftplans_mb
        + est.base_mb
        + est.one_center_mb
        + est.scalapack_mb
    )

    # Sanity floor for Tiers 1 and 2: at the dry-run layout the prediction
    # must be at least 0.95 * TOTAL_dry per rank.  This guards against
    # accidental under-prediction (the failure mode that the user hit).
    if est.model.startswith("rescaled-from-outcar") and have_total \
            and have_dry_layout \
            and total_ranks == summary.dry_total_ranks \
            and kpar == summary.dry_kpar \
            and ncore == summary.dry_ncore \
            and npar == summary.dry_npar:
        # Force the dry-run point of the surface to match the OUTCAR TOTAL.
        # If our breakdown sums to less than what VASP actually reported,
        # raise it.  We never lower it (that would mask a real over-estimate).
        floor = 0.95 * (mem_table.total_mb or 0.0)
        if base_sum < floor:
            # Attribute the missing amount to "safety_mb" so the breakdown
            # printed to the user remains internally consistent.
            est.safety_mb = floor - base_sum
            base_sum = floor

    # Safety margin: (safety_factor - 1) of base + 100 MB floor for MPI
    # buffers, library overhead, FFT scratch, I/O caches not in the OUTCAR
    # memory table.  100 MB is enough to absorb the usual difference between
    # VASP's reported TOTAL and the kernel's RSS high-water-mark at runtime.
    est.safety_mb = (est.safety_mb if est.safety_mb else 0.0) \
        + (max(safety_factor, 1.0) - 1.0) * base_sum + 100.0

    est.per_rank_mb = base_sum + est.safety_mb
    est.total_job_mb = est.per_rank_mb * total_ranks
    est.suggested_mem_per_cpu_mb = round_up_mem(est.per_rank_mb)
    # "Fits" = within 1.5x of the partition default mem-per-cpu.  The SLURM
    # script asks for the suggested value explicitly, so it will SCHEDULE
    # even above default; but going much above default usually means you
    # have to give up cores per node and that's what we want to penalise.
    est.fits_partition = (
        est.suggested_mem_per_cpu_mb <= 1.5 * partition_mem_per_cpu_mb
    )
    return est


# ============================================================================
# Suggested rank counts
# ============================================================================


def suggest_total_ranks(
    *,
    min_cores: int,
    max_cores: int,
    cpus_per_node: int,
    irr_kpoints: Optional[int],
    nbands: Optional[int],
) -> List[int]:
    """Pick a smart, deduplicated set of total_ranks values to evaluate."""
    out: set[int] = set()

    # Full-node multiples
    n = cpus_per_node
    while n <= max_cores:
        out.add(n)
        n += cpus_per_node

    # Common fractions of a node (lets the small AMD-main jobs be evaluated)
    for frac_div in (2, 4, 8, 16):
        f = cpus_per_node // frac_div
        if min_cores <= f <= max_cores:
            out.add(f)

    # Multiples of NKPTS (so KPAR = NKPTS is a divisor of total_ranks)
    if irr_kpoints and irr_kpoints > 1:
        n = irr_kpoints
        while n <= max_cores:
            if n >= min_cores:
                out.add(n)
            n += irr_kpoints

    # Round numbers commonly used in VASP benchmarks / NLHPC docs
    for n in (8, 12, 16, 20, 24, 32, 40, 44, 48, 64, 80, 88, 96, 120, 128):
        if min_cores <= n <= max_cores:
            out.add(n)

    # NPAR x KPAR style numbers with NBANDS-friendly NPAR values
    if nbands:
        for npar in (2, 4, 6, 8, 12, 16, 24, 32):
            for kpar in (1, 2, 4, 8):
                for ncore in (1, 2, 4, 8):
                    t = npar * kpar * ncore
                    if min_cores <= t <= max_cores:
                        out.add(t)

    if min_cores <= max_cores:
        out.add(max_cores)

    return sorted(out)


# ============================================================================
# Scoring
# ============================================================================


def score_candidate(
    *,
    summary: DryRunSummary,
    partition_info: Dict[str, object],
    cpus_per_node: int,
    numa_cores: Optional[int],
    max_cores: int,
    candidate: Candidate,
) -> Tuple[float, Dict[str, float]]:
    """Compute a transparent score with named contributions (each in 'points').

    Larger is better.  The weights are calibrated so that:
      * a HARD wiki violation (e.g. KPAR > NKPTS) -> very large negative
      * the recommended setting (NCORE ~ sqrt(rpk), NCORE | NUMA) -> ~+25
      * memory not fitting in partition default -> -40 (eclipses most bonuses)
      * throughput term: ~+10 for using the full account allowance
    """
    parts: Dict[str, float] = {}

    irr_k = summary.irr_kpoints or summary.nkpts
    nbands = summary.nbands
    natoms = summary.nions
    ngz = (summary.coarse_fft or summary.fine_fft or (0, 0, 0))[2] or None
    is_amd_zen4 = partition_info.get("arch") == "amd-zen4"

    rpk = candidate.ranks_per_kgroup       # = total_ranks / KPAR = NPAR*NCORE

    # ---- 1. KPAR rules ---------------------------------------------------
    # KPAR must divide total_ranks (the enumerator guarantees this).
    if candidate.total_ranks % candidate.kpar != 0:
        parts["KPAR_must_divide_total_ranks_(HARD_RULE)"] = -1000.0

    # KPAR should be a divisor of NKPTS (VASP wiki rule).
    if irr_k and irr_k > 0:
        if irr_k % candidate.kpar == 0:
            parts["kpar_factorises_nkpts"] = 18.0
        else:
            parts["kpar_does_NOT_factorise_nkpts"] = -25.0

        # Reward k-point coverage; saturate as KPAR approaches NKPTS.
        # Smaller weight than the divisibility bonus -- the wiki advice
        # "increase KPAR up to NKPTS" is explicitly CONDITIONAL on memory
        # permitting it (https://vasp.at/wiki/Optimizing_the_parallelization
        # and https://vasp.at/wiki/Not_enough_memory).  The memory-cost
        # penalties below will down-rank a high-KPAR config that doesn't
        # actually fit.
        parts["kpar_kpoint_coverage"] = 6.0 * math.sqrt(
            min(1.0, candidate.kpar / max(1, irr_k))
        )

    # Gamma-only / NKPTS = 1: KPAR must be 1.
    if summary.is_gamma_only and candidate.kpar != 1:
        parts["gamma_only_requires_kpar_1_(HARD_RULE)"] = -200.0

    # Wiki special case: bulk + small NBANDS + many k-points -> NCORE=1, KPAR=NKPTS.
    if (irr_k and irr_k > 1 and nbands and nbands <= 64
            and candidate.kpar == irr_k and candidate.ncore == 1):
        parts["wiki_small_cell_many_kpts_recipe"] = 25.0

    # ---- 2. NCORE rules --------------------------------------------------
    # NCORE should divide cores per node (FFTs stay intra-node).
    if cpus_per_node % candidate.ncore == 0:
        parts["ncore_divides_cpus_per_node"] = 8.0
    else:
        parts["ncore_does_NOT_divide_cpus_per_node"] = -15.0

    # Wiki recommendation (NCORE wiki page): NCORE ~ sqrt(available_ranks).
    if rpk > 0 and candidate.ncore > 0:
        ideal = max(1, int(round(math.sqrt(rpk))))
        delta = abs(candidate.ncore - ideal)
        # Bell-shaped reward; ideal -> +12, drops off quickly.
        parts["ncore_near_sqrt_available"] = 12.0 * math.exp(-delta * delta / 4.0)

    # NUMA-aware setting (NCORE wiki: "particularly good choice").
    if numa_cores and numa_cores > 0:
        if candidate.ncore == numa_cores:
            parts["ncore_equals_numa_size"] = 14.0
        elif candidate.ncore == numa_cores // 2 and numa_cores >= 4:
            parts["ncore_half_numa_size"] = 5.0

    # Wiki "Performance issues" guidance: NCORE for large atom counts.
    if natoms:
        if natoms > 400 and 12 <= candidate.ncore <= 16:
            parts["large_system_high_ncore_recipe"] = 10.0
        elif 100 <= natoms <= 400 and 4 <= candidate.ncore <= 12:
            parts["medium_system_moderate_ncore_recipe"] = 8.0
        elif natoms < 50 and candidate.ncore == 1:
            parts["small_system_ncore_1_recipe"] = 5.0

    # NCORE = available_ranks (== NPAR=1) is essentially never optimal.
    if candidate.npar == 1 and rpk > 1:
        parts["npar_1_no_band_parallelism_(HARD_PENALTY)"] = -60.0

    # ---- 3. NPAR / NBANDS load balance ----------------------------------
    if nbands and candidate.npar > 0:
        if candidate.npar > nbands:
            parts["npar_exceeds_nbands_(HARD_PENALTY)"] = -120.0
        elif nbands % candidate.npar == 0:
            parts["nbands_divisible_by_npar"] = 10.0
        else:
            padding = round_up_to_multiple(nbands, candidate.npar) - nbands
            parts["nbands_padding_penalty"] = -1.0 * padding

        bpg = candidate.bands_per_group
        if 4.0 <= bpg <= 16.0:
            parts["bands_per_group_sweet_spot"] = 10.0
        elif 2.0 <= bpg < 4.0 or 16.0 < bpg <= 32.0:
            parts["bands_per_group_acceptable"] = 4.0
        elif bpg < 1.0:
            parts["bands_per_group_too_few"] = -15.0
        elif bpg > 64.0:
            parts["bands_per_group_too_many"] = -6.0

    # ---- 4. k-group placement vs node / NUMA -----------------------------
    if numa_cores and numa_cores > 0:
        if rpk == numa_cores:
            parts["kgroup_equals_numa"] = 8.0
        elif rpk < numa_cores and numa_cores % rpk == 0:
            parts["kgroup_fits_inside_one_numa"] = 4.0
        elif rpk > numa_cores and rpk % numa_cores == 0:
            parts["kgroup_spans_integer_numas"] = 3.0
        elif rpk > numa_cores and numa_cores % rpk != 0 and rpk % numa_cores != 0:
            parts["kgroup_awkward_numa_layout"] = -4.0

    if rpk == cpus_per_node:
        parts["kgroup_equals_one_node"] = 6.0
    elif rpk < cpus_per_node and cpus_per_node % rpk == 0:
        parts["kgroup_fits_inside_one_node"] = 4.0
    elif rpk > cpus_per_node:
        if rpk % cpus_per_node == 0:
            parts["kgroup_spans_integer_nodes"] = 2.0
        else:
            parts["kgroup_straddles_node_boundary"] = -8.0

    # ---- 5. LPLANE / NGZ rule -------------------------------------------
    if ngz and candidate.npar > 0:
        threshold = 3.0 * candidate.nodes / candidate.npar
        if candidate.lplane:
            if ngz >= threshold:
                parts["lplane_TRUE_satisfies_ngz_rule"] = 3.0
            else:
                parts["lplane_TRUE_violates_ngz_rule_(PENALTY)"] = -10.0
            if ngz % candidate.npar == 0:
                parts["lplane_perfect_load_balance"] = 3.0
            if candidate.nodes >= 16:
                parts["lplane_TRUE_many_nodes_penalty"] = -3.0
        else:
            if candidate.nodes >= 16 or ngz < threshold:
                parts["lplane_FALSE_appropriate_for_layout"] = 3.0
            else:
                parts["lplane_FALSE_unnecessary_(SMALL_PENALTY)"] = -1.5
    else:
        # Default-on LPLANE is the wiki default (and the NLHPC template).
        parts["lplane_default_preference"] = 1.5 if candidate.lplane else -1.5

    # ---- 6. NSIM ---------------------------------------------------------
    if candidate.nsim == 4:
        parts["nsim_4_cpu_default"] = 4.0
    elif candidate.nsim in (2, 8):
        parts["nsim_acceptable"] = 2.0
    elif candidate.nsim == 1:
        parts["nsim_1_slow_network_recipe"] = 1.0
    else:
        parts["nsim_unusual"] = -1.0

    # ---- 7. Memory feasibility ------------------------------------------
    # Memory cost is the binding constraint on NLHPC's small per-CPU RAM
    # budget (2839 MB on `main`).  The VASP wiki explicitly conditions the
    # "increase KPAR up to NKPTS" advice on "given sufficient memory" -- so
    # the penalties below have to be strong enough to overcome the +6
    # kpar_coverage bonus when KPAR maxing forces a memory-heavy layout.
    mem = candidate.memory
    if not mem.fits_partition:
        parts["MEMORY_EXCEEDS_PARTITION_(HARD_PENALTY)"] = -40.0
    elif mem.suggested_mem_per_cpu_mb > mem.partition_mem_per_cpu_mb:
        parts["memory_above_partition_default_(non-default_alloc)"] = -12.0
    elif mem.suggested_mem_per_cpu_mb > 0.85 * mem.partition_mem_per_cpu_mb:
        parts["memory_uses_>85pct_of_partition_default"] = -5.0
    elif mem.suggested_mem_per_cpu_mb < 0.5 * mem.partition_mem_per_cpu_mb:
        # Memory-efficient configurations get an explicit bonus.  This
        # rewards layouts (typically KPAR=1, moderate NCORE) that leave
        # plenty of headroom on the per-CPU RAM budget.
        parts["memory_well_below_partition_default"] = 5.0
    elif mem.suggested_mem_per_cpu_mb < 0.7 * mem.partition_mem_per_cpu_mb:
        parts["memory_comfortably_below_partition_default"] = 3.0

    # ---- 8. Compactness / SLURM accounting -------------------------------
    if candidate.total_ranks % cpus_per_node == 0:
        parts["full_nodes_only"] = 3.0
    elif candidate.nodes >= 2 and candidate.total_ranks % candidate.ntasks_per_node != 0:
        parts["uneven_last_node"] = -2.0

    # ---- 9. Throughput term ----------------------------------------------
    # Reward using more ranks, sub-linearly (avoid blindly maximising cores
    # at huge memory cost; the memory penalty takes care of that case).
    parts["throughput_scaling"] = 5.0 * math.sqrt(
        candidate.total_ranks / max(1, max_cores)
    )

    # ---- 10. NLHPC-specific bonus: KPAR ~ 4 on AMD `main` ---------------
    # NLHPC's documented recipe for the AMD partition.
    if is_amd_zen4 and irr_k and irr_k >= 4:
        if candidate.kpar == 4:
            parts["nlhpc_amd_kpar_4_default"] = 3.0
        elif candidate.kpar in (2, 8) and irr_k % candidate.kpar == 0:
            parts["nlhpc_amd_kpar_near_4"] = 1.5

    score = float(sum(parts.values()))
    return score, parts


# ============================================================================
# Explanation strings (for the human-friendly "[WHY]" section)
# ============================================================================


def explain_contributions(parts: Dict[str, float], top: int = 10) -> List[str]:
    ordered = sorted(parts.items(), key=lambda kv: abs(kv[1]), reverse=True)[:top]
    out: List[str] = []
    for key, value in ordered:
        sign = "+" if value >= 0 else "-"
        label = key.replace("_", " ")
        out.append(f"  {sign}{abs(value):6.2f}  {label}")
    return out


# ============================================================================
# Candidate enumeration
# ============================================================================


def build_candidates(
    *,
    summary: DryRunSummary,
    min_cores: int,
    max_cores: int,
    partition_name: str,
    cpus_per_node: int,
    numa_cores: Optional[int],
    safety_factor: float,
    limit_kpar_to_irr: bool,
    nsim_choices: Sequence[int],
    strict_ncore_one: bool,
) -> List[Candidate]:
    """Enumerate all valid (total_ranks, KPAR, NCORE, NPAR, NSIM, LPLANE)."""
    if max_cores < min_cores or max_cores < 1:
        raise SystemExit("--max-cores must be >= --min-cores and >= 1.")

    partition_info = NLHPC_PARTITIONS[partition_name]
    part_mem_per_cpu = int(partition_info["mem_per_cpu_mb"])  # type: ignore[arg-type]

    irr_k = summary.irr_kpoints or summary.nkpts

    rank_choices = suggest_total_ranks(
        min_cores=min_cores,
        max_cores=max_cores,
        cpus_per_node=cpus_per_node,
        irr_kpoints=irr_k,
        nbands=summary.nbands,
    )

    # Upper bound on NCORE: number of cores per node (intra-node FFTs).
    # We don't let NCORE exceed cpus_per_node (each band group should fit on
    # one node).
    ncore_cap = cpus_per_node

    candidates: List[Candidate] = []
    for total_ranks in rank_choices:
        ntasks_per_node = min(total_ranks, cpus_per_node)
        nodes = max(1, math.ceil(total_ranks / ntasks_per_node))

        # KPAR enumeration: divisors of total_ranks; capped to NKPTS by default.
        kpar_choices = positive_divisors(total_ranks)
        if summary.is_gamma_only:
            kpar_choices = [1]
        elif limit_kpar_to_irr and irr_k:
            filtered = [k for k in kpar_choices if k <= max(1, irr_k)]
            if filtered:
                kpar_choices = filtered

        for kpar in kpar_choices:
            rpk = total_ranks // kpar
            if rpk <= 0:
                continue

            # NCORE choices: divisors of rpk, up to ncore_cap.
            if strict_ncore_one:
                ncore_choices = [1]
            else:
                ncore_choices = [c for c in positive_divisors(rpk) if c <= ncore_cap]
                # Cap to a sensible upper bound: 2x NUMA size, else cores/node.
                if numa_cores and numa_cores > 0:
                    soft_cap = min(ncore_cap, 2 * numa_cores)
                    ncore_choices = [c for c in ncore_choices if c <= soft_cap]

            for ncore in ncore_choices:
                npar = rpk // ncore
                if npar <= 0 or rpk % ncore != 0:
                    continue
                # Cannot have more band groups than bands.
                if summary.nbands and npar > summary.nbands:
                    continue

                bpg = (summary.nbands / npar) if summary.nbands else 0.0
                effective_nbands = (
                    round_up_to_multiple(summary.nbands, npar)
                    if summary.nbands else 0
                )

                memory = estimate_memory(
                    summary=summary,
                    total_ranks=total_ranks,
                    kpar=kpar,
                    ncore=ncore,
                    npar=npar,
                    partition_mem_per_cpu_mb=part_mem_per_cpu,
                    safety_factor=safety_factor,
                )

                for nsim in nsim_choices:
                    for lplane in (True, False):
                        cand = Candidate(
                            score=0.0,
                            total_ranks=total_ranks,
                            kpar=kpar,
                            ncore=ncore,
                            npar=npar,
                            nsim=nsim,
                            lplane=lplane,
                            ranks_per_kgroup=rpk,
                            bands_per_group=bpg,
                            effective_nbands=effective_nbands,
                            nodes=nodes,
                            ntasks_per_node=ntasks_per_node,
                            cpu_bind="cores",
                            memory=memory,
                        )
                        score, parts = score_candidate(
                            summary=summary,
                            partition_info=partition_info,
                            cpus_per_node=cpus_per_node,
                            numa_cores=numa_cores,
                            max_cores=max_cores,
                            candidate=cand,
                        )
                        cand.score = score
                        cand.contributions = parts
                        cand.reasons = explain_contributions(parts)
                        candidates.append(cand)

    candidates.sort(key=lambda c: c.sort_key)
    return candidates


def best_per_total_ranks(candidates: Sequence[Candidate]) -> List[Candidate]:
    """Keep only the highest-scoring candidate per total_ranks value."""
    seen: Dict[int, Candidate] = {}
    for c in candidates:
        prev = seen.get(c.total_ranks)
        if prev is None or c.score > prev.score:
            seen[c.total_ranks] = c
    return sorted(seen.values(), key=lambda c: c.sort_key)


# ============================================================================
# GW / RPA memory model and candidate enumeration
# ============================================================================
#
# Two regimes, recognised automatically (see detect_calculation_type):
#
#   * CONVENTIONAL (quartic-scaling) GW -- ALGO in {G0W0, GW0, EVGW0, QPGW0,
#     GW, EVGW, QPGW}.  The GW step parallelises ONLY over k-points (KPAR).
#     NCORE / NPAR > 1 do not accelerate the GW part, so we pin NCORE = 1 and
#     enumerate KPAR over the divisors of total_ranks (capped to NKPTS).  The
#     per-rank memory profile is close enough to the DFT one that we reuse the
#     existing OUTCAR-anchored estimate_memory() with ncore=1.
#       Refs: https://vasp.at/wiki/Practical_guide_to_GW_calculations
#             https://vasp.at/wiki/NCORE  (band-FFT distribution unused for GW)
#
#   * LOW-SCALING / space-time GW & RPA -- ALGO in {G0W0R, EVGW0R, GW0R, GWR}
#     or {ACFDTR, RPAR}.  The imaginary time/frequency grid NOMEGA is split
#     into NTAUPAR * NOMEGAPAR groups (both must divide NOMEGA); NTAUPAR drives
#     memory and runtime.  VASP recommends setting MAXMEM and letting it pick
#     NTAUPAR/NOMEGAPAR.  Per-rank memory follows the wiki formula
#         bytes ~ (Pi_exx * Pi_supercell) / (NCPU / NTAUPAR) * 16
#     with Pi_* the products of the two reported FFT grids.
#       Refs: https://vasp.at/wiki/Practical_guide_to_GW_calculations
#             https://vasp.at/wiki/NTAUPAR  https://vasp.at/wiki/NOMEGAPAR


def estimate_lowscaling_gw_memory(
    *,
    summary: DryRunSummary,
    total_ranks: int,
    ntaupar: int,
    ranks_per_node: int,
    partition_mem_per_cpu_mb: int,
    safety_factor: float,
) -> MemoryEstimate:
    """Per-rank / per-node memory for a low-scaling GW or RPA layout.

    Implements the VASP-documented estimate
    (https://vasp.at/wiki/Practical_guide_to_GW_calculations):

        bytes_per_rank ~ (NGX*NGY*NGZ)_exx * (NGX*NGY*NGZ)_supercell
                         / ( NCPU / NTAUPAR ) * 16

    The two grids are the "FFT grid for exact exchange (Hartree Fock)" and the
    "FFT grid for supercell" lines.  If the dry run was produced with
    ALGO=None (the grids are then absent), we fall back to a coarse proxy
    built from the fine FFT grid and flag it; in that case the user should do
    a brief REAL low-scaling dry run so VASP prints the grids and its own
    "min. memory requirement per mpi rank ... per node ..." line, which is
    authoritative.
    """
    est = MemoryEstimate(partition_mem_per_cpu_mb=partition_mem_per_cpu_mb)
    est.model = "gw-lowscaling-formula"
    if total_ranks <= 0 or ntaupar <= 0:
        return est

    # Determine the two grid-point products.
    if summary.fft_exx is not None and summary.fft_supercell is not None:
        ex = summary.fft_exx
        sc = summary.fft_supercell
        prod_exx = float(ex[0] * ex[1] * ex[2])
        prod_sc = float(sc[0] * sc[1] * sc[2])
        est.gw_grid_source = "outcar-grids"
    else:
        # Proxy: use the fine (or coarse) FFT grid for both factors.  This is
        # only an order-of-magnitude stand-in until a real GW dry run is done.
        grid = summary.fine_fft or summary.coarse_fft
        if grid is None:
            est.gw_grid_source = "unknown"
            return est
        prod = float(grid[0] * grid[1] * grid[2])
        # The supercell grid is typically smaller than the HF grid; assume the
        # HF grid ~ this grid and the supercell grid ~ (this grid)/8 as a rough,
        # deliberately conservative-ish proxy.
        prod_exx = prod
        prod_sc = prod / 8.0
        est.gw_grid_source = "fine-fft-proxy"

    cores_per_tau_group = max(1.0, total_ranks / float(ntaupar))
    bytes_per_rank = prod_exx * prod_sc / cores_per_tau_group * 16.0
    grid_term_mb = bytes_per_rank / (1024.0 ** 2)

    est.gw_grid_term_mb = grid_term_mb
    # Fixed overhead per rank (orbitals, projectors, FFT plans, MPI buffers).
    fixed_overhead_mb = 250.0
    base_sum = grid_term_mb + fixed_overhead_mb

    # If VASP already printed its own per-rank number for THIS layout, trust it
    # as a floor (never predict below VASP's own estimate).
    if summary.vasp_min_mem_per_rank_mb is not None:
        base_sum = max(base_sum, summary.vasp_min_mem_per_rank_mb)

    est.wavefun_mb = grid_term_mb          # reuse the slot for display continuity
    est.base_mb = fixed_overhead_mb
    est.safety_mb = (max(safety_factor, 1.0) - 1.0) * base_sum + 100.0
    est.per_rank_mb = base_sum + est.safety_mb
    est.gw_per_node_mb = est.per_rank_mb * max(1, ranks_per_node)
    est.total_job_mb = est.per_rank_mb * total_ranks
    est.suggested_mem_per_cpu_mb = round_up_mem(est.per_rank_mb)
    # MAXMEM is the per-rank memory budget VASP should assume.  Recommend the
    # partition's per-CPU RAM (slightly discounted for safety) so VASP's own
    # NTAUPAR/NOMEGAPAR auto-selection lands inside the node budget.
    est.maxmem_mb = int(max(200, math.floor(0.92 * partition_mem_per_cpu_mb)))
    est.fits_partition = (
        est.suggested_mem_per_cpu_mb <= 1.5 * partition_mem_per_cpu_mb
    )
    return est


def estimate_conventional_gw_memory(
    *,
    summary: DryRunSummary,
    total_ranks: int,
    kpar: int,
    ncore: int,
    npar: int,
    partition_mem_per_cpu_mb: int,
    safety_factor: float,
    ref: Optional[Dict[str, float]] = None,
    ref_ranks_override: Optional[int] = None,
    ref_encutgw_override: Optional[float] = None,
    anchor_override: Optional[float] = None,
) -> MemoryEstimate:
    """Per-rank memory for a CONVENTIONAL (quartic-scaling) GW layout.

    per_rank = base_DFT(orbitals + FFT + projectors)  +  GW_excess
    where GW_excess is the measured per-rank GW cost (chi/W over NOMEGA),
    anchored to GW_CONV_REF and scaled by NOMEGA, ISPIN, ENCUTGW^3, and
    1/ranks_per_kgroup.  This corrects the ~10x under-prediction that arises
    from reusing the DFT memory table (which omits the GW response arrays).
    """
    r = dict(GW_CONV_REF)
    if ref:
        r.update(ref)
    anchor_mb = float(anchor_override if anchor_override is not None
                      else r["per_rank_mb"])
    ref_ranks = int(ref_ranks_override if ref_ranks_override is not None
                    else r["total_ranks"])
    ref_kpar = int(r["kpar"])
    ref_encutgw = float(ref_encutgw_override if ref_encutgw_override is not None
                        else r["encutgw"])
    ref_nomega = float(r["nomega"])
    ref_ispin = float(r["ispin"])
    ref_rpk = max(1.0, ref_ranks / float(max(1, ref_kpar)))

    # 1) Base (non-GW) per-rank cost: reuse the OUTCAR-anchored DFT model,
    #    but strip its safety buffer so we don't double-count headroom.
    base_est = estimate_memory(
        summary=summary, total_ranks=total_ranks, kpar=kpar, ncore=ncore,
        npar=npar, partition_mem_per_cpu_mb=partition_mem_per_cpu_mb,
        safety_factor=1.0,
    )
    base_mb = max(0.0, base_est.per_rank_mb - base_est.safety_mb)

    # 2) GW excess: similarity scaling around the measured anchor.  We anchor
    #    on the GW-specific excess (anchor minus the base AT the reference),
    #    so the same base model is not counted twice.
    # Reference base at the reference layout (so anchor - ref_base = pure GW):
    ref_total = max(1, ref_ranks)
    ref_npar = max(1, ref_total // max(1, ref_kpar))
    ref_base_est = estimate_memory(
        summary=summary, total_ranks=ref_total, kpar=ref_kpar, ncore=1,
        npar=ref_npar, partition_mem_per_cpu_mb=partition_mem_per_cpu_mb,
        safety_factor=1.0,
    )
    ref_base_mb = max(0.0, ref_base_est.per_rank_mb - ref_base_est.safety_mb)
    gw_excess_ref = max(0.0, anchor_mb - ref_base_mb)

    rpk = max(1.0, total_ranks / float(max(1, kpar)))
    nomega = float(summary.nomega or ref_nomega)
    ispin = float(summary.ispin or ref_ispin)
    # ENCUTGW defaults to ENCUT when unset.
    encutgw = float(summary.encutgw or summary.encut or ref_encutgw)

    gw_excess = (
        gw_excess_ref
        * (nomega / ref_nomega)
        * (ispin / ref_ispin)
        * (encutgw / ref_encutgw) ** 3
        * (ref_rpk / rpk)
    )

    est = MemoryEstimate(partition_mem_per_cpu_mb=partition_mem_per_cpu_mb)
    est.model = f"gw-conventional-empirical (anchor {anchor_mb:.0f} MB/rank)"
    est.gw_grid_source = (
        f"anchor: CuVS3 EVGW0, {anchor_mb:.0f} MB/rank @ {ref_ranks} ranks "
        f"(KPAR {ref_kpar}), NOMEGA {ref_nomega:.0f}, ISPIN {ref_ispin:.0f}, "
        f"ENCUTGW {ref_encutgw:.0f}"
    )
    est.base_mb = base_mb
    est.gw_grid_term_mb = gw_excess
    core_sum = base_mb + gw_excess
    est.safety_mb = (max(safety_factor, 1.0) - 1.0) * core_sum + 100.0
    est.per_rank_mb = core_sum + est.safety_mb
    est.gw_per_node_mb = est.per_rank_mb * min(total_ranks, max(1, summary.nkpts or total_ranks))
    est.total_job_mb = est.per_rank_mb * total_ranks
    est.suggested_mem_per_cpu_mb = round_up_mem(est.per_rank_mb)
    est.fits_partition = (
        est.suggested_mem_per_cpu_mb <= 1.5 * partition_mem_per_cpu_mb
    )
    return est


def _gw_divisor_pairs(nomega: int) -> List[Tuple[int, int]]:
    """All (NTAUPAR, NOMEGAPAR) pairs that both divide NOMEGA.

    Per the wiki both tags must be divisors of NOMEGA.  We return every such
    pair (the product need not equal NOMEGA); the builder filters them against
    the available rank count.
    """
    divs = positive_divisors(nomega)
    return [(t, w) for t in divs for w in divs]


def score_gw_candidate(
    *,
    summary: DryRunSummary,
    partition_info: Dict[str, object],
    cpus_per_node: int,
    numa_cores: Optional[int],
    max_cores: int,
    candidate: Candidate,
) -> Tuple[float, Dict[str, float]]:
    """Transparent score for a GW / RPA candidate (larger is better).

    The lever depends on the regime:
      * conventional GW -> KPAR (NCORE pinned to 1).
      * low-scaling GW/RPA -> KPAR plus NTAUPAR/NOMEGAPAR (divisors of NOMEGA).
    Memory feasibility uses the same partition-budget penalties as the DFT
    path so a layout that does not fit is strongly down-ranked.
    """
    parts: Dict[str, float] = {}
    irr_k = summary.irr_kpoints or summary.nkpts
    is_amd_zen4 = partition_info.get("arch") == "amd-zen4"
    low = candidate.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")

    # ---- KPAR rules (shared) --------------------------------------------
    if candidate.total_ranks % candidate.kpar != 0:
        parts["KPAR_must_divide_total_ranks_(HARD_RULE)"] = -1000.0
    if summary.is_gamma_only and candidate.kpar != 1:
        parts["gamma_only_requires_kpar_1_(HARD_RULE)"] = -200.0
    if irr_k and irr_k > 0:
        if irr_k % candidate.kpar == 0:
            parts["kpar_factorises_nkpts"] = 20.0
        else:
            parts["kpar_does_NOT_factorise_nkpts_(HARD)"] = -60.0
        # GW parallel efficiency lives almost entirely on KPAR (conventional)
        # or shares the budget with the grid split (low-scaling).  Reward
        # k-point coverage more strongly than in DFT, but still saturate.
        coverage_weight = 10.0 if not low else 6.0
        parts["kpar_kpoint_coverage"] = coverage_weight * math.sqrt(
            min(1.0, candidate.kpar / max(1, irr_k))
        )

    # ---- NCORE must be 1 for GW -----------------------------------------
    if candidate.ncore != 1:
        parts["gw_requires_ncore_1_(HARD_RULE)"] = -300.0
    else:
        parts["gw_ncore_1_ok"] = 4.0

    # ---- Conventional GW: cores per k-group ------------------------------
    rpk = candidate.ranks_per_kgroup
    if not low:
        # Each k-point group's ranks speed the internal DFT/Exact step.  A
        # handful of ranks per group is healthy; one rank per k-point (rpk=1)
        # wastes the band parallelism, and a huge group has poor efficiency.
        if rpk == 1 and (irr_k or 0) > 1:
            parts["gw_one_rank_per_kgroup_(WEAK)"] = -6.0
        elif 2 <= rpk <= cpus_per_node:
            parts["gw_healthy_kgroup_size"] = 6.0
        if rpk <= cpus_per_node:
            parts["gw_kgroup_fits_one_node"] = 3.0
        elif rpk % cpus_per_node != 0:
            parts["gw_kgroup_straddles_node_(PENALTY)"] = -8.0

    # ---- Low-scaling GW/RPA: NTAUPAR / NOMEGAPAR -------------------------
    if low:
        nomega = candidate.nomega or summary.nomega
        t = candidate.ntaupar or 1
        w = candidate.nomegapar or 1
        if nomega:
            if nomega % t == 0:
                parts["ntaupar_divides_nomega"] = 10.0
            else:
                parts["ntaupar_NOT_divisor_of_nomega_(HARD)"] = -80.0
            if nomega % w == 0:
                parts["nomegapar_divides_nomega"] = 6.0
            else:
                parts["nomegapar_NOT_divisor_of_nomega_(HARD)"] = -60.0
        # The τ/ω groups partition the available ranks: NTAUPAR*NOMEGAPAR must
        # divide the per-k-group rank count.
        if rpk % max(1, t * w) == 0:
            parts["tau_omega_groups_partition_ranks"] = 8.0
        else:
            parts["tau_omega_groups_do_NOT_fit_ranks_(HARD)"] = -120.0
        # Larger NTAUPAR is faster (VASP defaults to the largest that fits in
        # MAXMEM); reward it, but only when memory actually fits (handled by
        # the memory penalties below).
        if nomega:
            parts["ntaupar_speed_preference"] = 6.0 * math.sqrt(
                min(1.0, t / max(1, nomega))
            )

    # ---- Memory feasibility (shared with DFT weights) -------------------
    mem = candidate.memory
    if not mem.fits_partition:
        parts["MEMORY_EXCEEDS_PARTITION_(HARD_PENALTY)"] = -40.0
    elif mem.suggested_mem_per_cpu_mb > mem.partition_mem_per_cpu_mb:
        parts["memory_above_partition_default_(non-default_alloc)"] = -12.0
    elif mem.suggested_mem_per_cpu_mb > 0.85 * mem.partition_mem_per_cpu_mb:
        parts["memory_uses_>85pct_of_partition_default"] = -5.0
    elif mem.suggested_mem_per_cpu_mb < 0.5 * mem.partition_mem_per_cpu_mb:
        parts["memory_well_below_partition_default"] = 5.0
    elif mem.suggested_mem_per_cpu_mb < 0.7 * mem.partition_mem_per_cpu_mb:
        parts["memory_comfortably_below_partition_default"] = 3.0

    # ---- Compactness / SLURM accounting ---------------------------------
    if candidate.total_ranks % cpus_per_node == 0:
        parts["full_nodes_only"] = 3.0
    elif candidate.nodes >= 2 and candidate.total_ranks % candidate.ntasks_per_node != 0:
        parts["uneven_last_node"] = -2.0

    # ---- Throughput term -------------------------------------------------
    parts["throughput_scaling"] = 5.0 * math.sqrt(
        candidate.total_ranks / max(1, max_cores)
    )

    # ---- NLHPC AMD bonus: KPAR ~ 4 --------------------------------------
    if is_amd_zen4 and irr_k and irr_k >= 4:
        if candidate.kpar == 4:
            parts["nlhpc_amd_kpar_4_default"] = 3.0
        elif candidate.kpar in (2, 8) and irr_k % candidate.kpar == 0:
            parts["nlhpc_amd_kpar_near_4"] = 1.5

    score = float(sum(parts.values()))
    return score, parts


def build_gw_candidates(
    *,
    summary: DryRunSummary,
    min_cores: int,
    max_cores: int,
    partition_name: str,
    cpus_per_node: int,
    numa_cores: Optional[int],
    safety_factor: float,
    limit_kpar_to_irr: bool,
    recommend_maxmem: bool,
    gw_anchor_override: Optional[float] = None,
    gw_ref_ranks_override: Optional[int] = None,
    gw_ref_encutgw_override: Optional[float] = None,
) -> List[Candidate]:
    """Enumerate GW / RPA layouts (NCORE pinned to 1).

    Conventional GW: vary total_ranks and KPAR (divisor of total_ranks, capped
    to NKPTS by default).  Low-scaling GW/RPA: additionally vary the
    (NTAUPAR, NOMEGAPAR) divisor pair of NOMEGA, keeping NTAUPAR*NOMEGAPAR a
    divisor of the per-k-group rank count.
    """
    if max_cores < min_cores or max_cores < 1:
        raise SystemExit("--max-cores must be >= --min-cores and >= 1.")

    partition_info = NLHPC_PARTITIONS[partition_name]
    part_mem_per_cpu = int(partition_info["mem_per_cpu_mb"])  # type: ignore[arg-type]
    irr_k = summary.irr_kpoints or summary.nkpts
    low = summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")

    rank_choices = suggest_total_ranks(
        min_cores=min_cores,
        max_cores=max_cores,
        cpus_per_node=cpus_per_node,
        irr_kpoints=irr_k,
        nbands=summary.nbands,
    )

    # NOMEGA is required to enumerate τ/ω splits for low-scaling.  If it was
    # not parsed, fall back to MAXMEM-only (no explicit NTAUPAR/NOMEGAPAR).
    nomega = summary.nomega
    pairs = _gw_divisor_pairs(nomega) if (low and nomega) else [(1, 1)]

    candidates: List[Candidate] = []
    for total_ranks in rank_choices:
        ntasks_per_node = min(total_ranks, cpus_per_node)
        nodes = max(1, math.ceil(total_ranks / ntasks_per_node))

        kpar_choices = positive_divisors(total_ranks)
        if summary.is_gamma_only:
            kpar_choices = [1]
        elif limit_kpar_to_irr and irr_k:
            filtered = [k for k in kpar_choices if k <= max(1, irr_k)]
            if filtered:
                kpar_choices = filtered

        for kpar in kpar_choices:
            rpk = total_ranks // kpar          # ranks per k-point group
            if rpk <= 0:
                continue
            ncore = 1
            npar = rpk                          # NCORE=1 => NPAR = available

            if not low:
                # One conventional-GW candidate per (total_ranks, KPAR).
                memory = estimate_conventional_gw_memory(
                    summary=summary,
                    total_ranks=total_ranks,
                    kpar=kpar,
                    ncore=ncore,
                    npar=npar,
                    partition_mem_per_cpu_mb=part_mem_per_cpu,
                    safety_factor=safety_factor,
                    ref_ranks_override=gw_ref_ranks_override,
                    ref_encutgw_override=gw_ref_encutgw_override,
                    anchor_override=gw_anchor_override,
                )
                cand = Candidate(
                    score=0.0, total_ranks=total_ranks, kpar=kpar, ncore=ncore,
                    npar=npar, nsim=4, lplane=True, ranks_per_kgroup=rpk,
                    bands_per_group=(summary.nbands / npar) if summary.nbands else 0.0,
                    effective_nbands=(round_up_to_multiple(summary.nbands, npar)
                                      if summary.nbands else 0),
                    nodes=nodes, ntasks_per_node=ntasks_per_node, cpu_bind="cores",
                    memory=memory, calc_type=summary.calc_type, nomega=summary.nomega,
                )
                score, p = score_gw_candidate(
                    summary=summary, partition_info=partition_info,
                    cpus_per_node=cpus_per_node, numa_cores=numa_cores,
                    max_cores=max_cores, candidate=cand)
                cand.score = score
                cand.contributions = p
                cand.reasons = explain_contributions(p)
                candidates.append(cand)
                continue

            # Low-scaling: enumerate (NTAUPAR, NOMEGAPAR) divisor pairs that
            # partition the per-k-group rank count.
            for (t, w) in pairs:
                if rpk % (t * w) != 0:
                    continue
                # If NOMEGA is unknown we only iterate the (1,1) sentinel and
                # present a MAXMEM-only recommendation (knobs shown as None).
                knob_t: Optional[int] = t if summary.nomega else None
                knob_w: Optional[int] = w if summary.nomega else None
                memory = estimate_lowscaling_gw_memory(
                    summary=summary,
                    total_ranks=total_ranks,
                    ntaupar=t,
                    ranks_per_node=ntasks_per_node,
                    partition_mem_per_cpu_mb=part_mem_per_cpu,
                    safety_factor=safety_factor,
                )
                cand = Candidate(
                    score=0.0, total_ranks=total_ranks, kpar=kpar, ncore=ncore,
                    npar=npar, nsim=4, lplane=True, ranks_per_kgroup=rpk,
                    bands_per_group=0.0, effective_nbands=0, nodes=nodes,
                    ntasks_per_node=ntasks_per_node, cpu_bind="cores",
                    memory=memory, calc_type=summary.calc_type, nomega=summary.nomega,
                    ntaupar=knob_t, nomegapar=knob_w, recommend_maxmem=recommend_maxmem,
                )
                score, p = score_gw_candidate(
                    summary=summary, partition_info=partition_info,
                    cpus_per_node=cpus_per_node, numa_cores=numa_cores,
                    max_cores=max_cores, candidate=cand)
                cand.score = score
                cand.contributions = p
                cand.reasons = explain_contributions(p)
                candidates.append(cand)

    candidates.sort(key=lambda c: c.sort_key)
    return candidates


# ============================================================================
# SLURM template
# ============================================================================


def pick_executable(summary: DryRunSummary, override: Optional[str]) -> str:
    if override:
        return override
    return "vasp_gam" if summary.is_gamma_only else "vasp_std"


def slurm_script(
    *,
    candidate: Candidate,
    partition_name: str,
    partition_info: Dict[str, object],
    summary: DryRunSummary,
    email: Optional[str],
    job_name: str,
    executable: str,
    time_limit: str,
) -> str:
    # Use the candidate's suggested mem-per-cpu directly.  NLHPC's
    # partition default is just the value SLURM uses if you don't ask --
    # asking for less is perfectly fine and helps the scheduler pack other
    # jobs alongside yours.  Asking for more is fine too (the SLURM script
    # below will already do so when the prediction says we need it).
    # The only reason to clamp UP to the partition default would be if the
    # prediction were untrustworthy; with Tier 1/2 anchoring on VASP's own
    # number, it's not.  We still never go below 200 MB.
    mem_per_cpu = max(200, candidate.memory.suggested_mem_per_cpu_mb)
    # If we recommend MAXMEM in the INCAR (low-scaling GW/RPA), SLURM must
    # grant at least that much per rank or VASP's auto-chosen NTAUPAR will be
    # OOM-killed by the cgroup.  Add a little headroom above MAXMEM.
    if getattr(candidate, "recommend_maxmem", False) and candidate.memory.maxmem_mb:
        mem_per_cpu = max(mem_per_cpu, candidate.memory.maxmem_mb + 150)
    modules: List[str] = list(partition_info["modules"])     # type: ignore[arg-type]
    extra_env: List[str] = list(partition_info["extra_env"]) # type: ignore[arg-type]

    lines = [
        "#!/bin/bash",
        f'#SBATCH --job-name="{job_name}"',
        f"#SBATCH --partition={partition_info.get('slurm_name', partition_name)}",
        f"#SBATCH --time={time_limit}",
        f"#SBATCH --ntasks={candidate.total_ranks}",
        f"#SBATCH --ntasks-per-node={candidate.ntasks_per_node}",
        "#SBATCH --cpus-per-task=1",                    # pure MPI
        f"#SBATCH --mem-per-cpu={mem_per_cpu}",
        "#SBATCH --output=%x-%j.out",
        "#SBATCH --error=%x-%j.err",
    ]
    if email:
        lines.append(f"#SBATCH --mail-user={email}")
        lines.append("#SBATCH --mail-type=ALL")

    lines.extend(["", "# --- Modules (from your cluster profile) ---", *modules])
    lines.extend(["", "# --- Pure-MPI environment ---", *extra_env])
    lines.extend([
        "",
        '# Optional housekeeping:',
        '# rm -f DOSCAR PROCAR XDATCAR OSZICAR OUTCAR vasprun.xml REPORT',
        "",
        'echo "Inicio: $(date)"',
        f"/usr/bin/time -v srun --cpu-bind={candidate.cpu_bind} {executable}",
        'echo "Fin:    $(date)"',
    ])
    return "\n".join(lines)


# ============================================================================
# Output / pretty printing
# ============================================================================


def print_dryrun_summary(summary: DryRunSummary) -> None:
    print("=" * 78)
    print(" VASP PARALLELIZATION RECOMMENDER (NLHPC, pure MPI) ".center(78, "="))
    print("=" * 78)
    print("Built from the VASP wiki rules at https://vasp.at/wiki/Category:Performance.")
    print("Final answer is the result of a SHORT benchmark: take the top 2-3 candidates")
    print("from this tool, run a few SCF steps with each, and keep the fastest.\n")

    print("[DRY-RUN SUMMARY]")
    print(f"  OUTCAR                  : {summary.outcar_path}")
    _calc_label = {
        "DFT": "DFT / standard SCF",
        "GW_CONVENTIONAL": "GW (conventional / quartic-scaling)",
        "GW_LOWSCALING": "GW (low-scaling / space-time)",
        "RPA_LOWSCALING": "RPA (low-scaling / space-time)",
    }.get(summary.calc_type, summary.calc_type)
    print(f"  detected calculation    : {_calc_label}")
    if summary.calc_type != "DFT":
        print(f"  GW/RPA ALGO             : {summary.gw_algo}")
    print(f"  ALGO                    : {summary.algo}"
          f"   LREAL : {summary.lreal}   ENCUT : {summary.encut}")
    print(f"  irreducible k-points    : {summary.irr_kpoints}")
    print(f"  NKPTS                   : {summary.nkpts}")
    print(f"  NBANDS                  : {summary.nbands}")
    print(f"  NIONS                   : {summary.nions}")
    print(f"  NELECT                  : {summary.nelect}")
    print(f"  ISPIN                   : {summary.ispin}")
    print(f"  NPLWV (max plane waves) : {summary.nplwv}")
    print(f"  gamma-only / NKPTS=1    : {summary.is_gamma_only}")
    if summary.calc_type != "DFT":
        print(f"  NOMEGA                  : {summary.nomega}"
              f"   NELMGW : {summary.nelmgw}   ENCUTGW : {summary.encutgw}")
        if summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING"):
            print(f"  FFT grid (exact exch.)  : {summary.fft_exx}")
            print(f"  FFT grid (supercell)    : {summary.fft_supercell}")
            if summary.vasp_min_mem_per_rank_mb is not None:
                print(f"  VASP min mem / rank     : "
                      f"{summary.vasp_min_mem_per_rank_mb:.0f} MB"
                      f"   / node : {summary.vasp_min_mem_per_node_mb:.0f} MB"
                      "   (authoritative)")
    if summary.coarse_fft is not None:
        x, y, z = summary.coarse_fft
        print(f"  coarse FFT (NGX,Y,Z)    : {x} x {y} x {z}")
    if summary.fine_fft is not None:
        x, y, z = summary.fine_fft
        print(f"  fine FFT (NGXF,YF,ZF)   : {x} x {y} x {z}")
    print()
    print("[DRY-RUN PARALLEL LAYOUT  (essential for memory rescaling)]")
    print(f"  total ranks in dry run  : {summary.dry_total_ranks}")
    print(f"  KPAR  (dry run)         : {summary.dry_kpar}")
    print(f"  NCORE (dry run)         : {summary.dry_ncore}")
    print(f"  NPAR  (dry run)         : {summary.dry_npar}")
    print()
    if summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING"):
        print("[MEMORY MODEL]  low-scaling GW/RPA -> per-rank cost is set by the")
        print("  imaginary-time/-frequency grid split (NTAUPAR), estimated from the")
        print("  HF/supercell FFT grids via the VASP wiki formula. The DFT-style")
        print("  rank0 memory table is not used here.")
        if summary.vasp_min_mem_per_rank_mb is None:
            print("  TIP: the dry run did not print VASP's own")
            print("       'min. memory requirement per mpi rank ... per node' line.")
            print("       Do a brief REAL low-scaling run (not ALGO=None) to get it;")
            print("       that number is authoritative and the tool will honour it.")
        print()
        return
    print("[VASP MEMORY TABLE  (from the dry-run OUTCAR; per MPI rank)]")
    m = summary.memory
    if m.has_data():
        def _row(label: str, value: Optional[float]) -> str:
            return f"  {label:<22}: {value:8.1f} MB" if value is not None \
                else f"  {label:<22}:    (not reported)"
        print(_row("base", m.base_mb))
        print(_row("nonlr-proj", m.nonlr_proj_mb))
        print(_row("fftplans", m.fftplans_mb))
        print(_row("grid", m.grid_mb))
        print(_row("one-center", m.one_center_mb))
        print(_row("wavefun", m.wavefun_mb))
        if m.total_mb is not None:
            print(f"  {'TOTAL (rank 0)':<22}: {m.total_mb:8.1f} MB")
        # Tell the user which prediction tier we will use.
        rows_present = all(
            getattr(m, f) is not None
            for f in ("wavefun_mb", "grid_mb", "nonlr_proj_mb")
        )
        if rows_present:
            print("  Model: TIER 1 (per-row rescaling -- most accurate).")
        else:
            print("  Model: TIER 2 (TOTAL anchor + 80/15/5 wavefun/grid/proj split).")
            print("         Less accurate than Tier 1 but ANCHORED to VASP's own number.")
            print("         To get Tier 1, run the dry run on a recent VASP 6 build")
            print("         that prints the full breakdown rows.")
    else:
        print("  No memory table found in the dry-run OUTCAR.")
        print("  -> Falling back to https://vasp.at/wiki/Memory_requirements formulas")
        print("     (TIER 3 -- least accurate).  Re-run the dry run with ALGO=None")
        print("     on >= 1 rank with a recent VASP build to get an OUTCAR memory table.")
    print()


def print_partition_summary(
    *,
    partition_name: str,
    partition_info: Dict[str, object],
    cpus_per_node: int,
    numa_cores: Optional[int],
    min_cores: int,
    max_cores: int,
) -> None:
    real = partition_info.get("slurm_name", partition_name)
    label = f"{partition_name} -> {real}" if real != partition_name else partition_name
    print("[TARGET HARDWARE]")
    print(f"  partition               : {label}"
          f" ({partition_info.get('arch')})")
    print(f"  CPUs per node           : {cpus_per_node}")
    print(f"  NUMA cores              : {numa_cores}")
    print(f"  partition mem/CPU       : {partition_info.get('mem_per_cpu_mb')} MB"
          " (SLURM default)")
    print(f"  account core cap        : {max_cores}"
          f"  (range scanned: {min_cores}..{max_cores})")
    print(f"  parallel mode           : pure MPI (OMP=1, -c 1)")
    print()


def print_candidate_table(candidates: Sequence[Candidate], top: int) -> None:
    print("[TOP CANDIDATES]  (best INCAR shown for each total_ranks; sorted by score)")
    calc_type = candidates[0].calc_type if candidates else "DFT"
    low = calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")
    if low:
        header = (
            " rk |  score | ranks | nodes | ntpn |KPAR| rpk |NTAUPAR|NOMEGAPAR"
            "|  mem/CPU(MB) | MAXMEM"
        )
        print(header)
        print("-" * len(header))
        for idx, c in enumerate(candidates[:top], start=1):
            print(
                f" {idx:>2} | {c.score:>6.1f} | {c.total_ranks:>5} | {c.nodes:>5} |"
                f" {c.ntasks_per_node:>4} |{c.kpar:>4}| {c.ranks_per_kgroup:>3} |"
                f" {str(c.ntaupar):>5} | {str(c.nomegapar):>7} |"
                f" {c.memory.suggested_mem_per_cpu_mb:>10} | {c.memory.maxmem_mb:>6}"
            )
        print()
        return
    if calc_type == "GW_CONVENTIONAL":
        header = (
            " rk |  score | ranks | nodes | ntpn |KPAR| rpk (ranks/k-group)"
            " |  mem/CPU(MB)"
        )
        print(header)
        print("-" * len(header))
        for idx, c in enumerate(candidates[:top], start=1):
            print(
                f" {idx:>2} | {c.score:>6.1f} | {c.total_ranks:>5} | {c.nodes:>5} |"
                f" {c.ntasks_per_node:>4} |{c.kpar:>4}| {c.ranks_per_kgroup:>18} |"
                f" {c.memory.suggested_mem_per_cpu_mb:>10}"
            )
        print()
        return
    header = (
        " rk |  score | ranks | nodes | ntpn |KPAR|NCORE|NPAR | b/grp | NSIM | LPL "
        "|  mem/CPU(MB)"
    )
    print(header)
    print("-" * len(header))
    for idx, c in enumerate(candidates[:top], start=1):
        bpg = f"{c.bands_per_group:.2f}" if c.bands_per_group else "-"
        lpl = "T" if c.lplane else "F"
        print(
            f" {idx:>2} | {c.score:>6.1f} | {c.total_ranks:>5} | {c.nodes:>5} |"
            f" {c.ntasks_per_node:>4} |{c.kpar:>4}|{c.ncore:>5}|{c.npar:>4} |"
            f" {bpg:>5} | {c.nsim:>4} | {lpl:>3} |"
            f" {c.memory.suggested_mem_per_cpu_mb:>10}"
        )
    print()


def print_best_candidate(
    *,
    candidate: Candidate,
    partition_name: str,
    partition_info: Dict[str, object],
    summary: DryRunSummary,
    email: Optional[str],
    job_name: str,
    executable: str,
    time_limit: str,
) -> None:
    print("=" * 78)
    print(" BEST CANDIDATE ".center(78, "="))
    print("=" * 78)
    low = candidate.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")
    conv = candidate.calc_type == "GW_CONVENTIONAL"
    print(f"score                   : {candidate.score:.1f}")
    print(f"calculation type        : {candidate.calc_type}")
    print(f"total MPI ranks         : {candidate.total_ranks}")
    print(f"nodes                   : {candidate.nodes}")
    print(f"ntasks-per-node         : {candidate.ntasks_per_node}")
    print(f"KPAR                    : {candidate.kpar}")
    if low or conv:
        print(f"NCORE                   : 1    (REQUIRED: GW has no band-FFT split)")
        print(f"ranks per k-point group : {candidate.ranks_per_kgroup}")
    else:
        print(f"NCORE                   : {candidate.ncore}")
        print(f"NPAR (derived)          : {candidate.npar}"
              "    (do NOT set both NCORE and NPAR)")
        print(f"NSIM                    : {candidate.nsim}")
        print(f"LPLANE                  : {format_bool(candidate.lplane)}")
        print(f"effective NBANDS        : {candidate.effective_nbands}"
              f"  (raw dry-run: {summary.nbands})")
        print(f"bands per band-group    : {candidate.bands_per_group:.2f}")
    if low:
        print(f"NOMEGA                  : {candidate.nomega}")
        print(f"NTAUPAR (time grid)     : {candidate.ntaupar}"
              "    (divisor of NOMEGA; larger = faster, more RAM)")
        print(f"NOMEGAPAR (freq grid)   : {candidate.nomegapar}"
              "    (divisor of NOMEGA)")
        print(f"recommended MAXMEM      : {candidate.memory.maxmem_mb} MB/rank")
    print()

    if low:
        print(f"[MEMORY ESTIMATE  ({candidate.memory.model};"
              f" grids: {candidate.memory.gw_grid_source})]")
        m = candidate.memory
        print(f"  imaginary-grid arrays : {m.gw_grid_term_mb:9.1f} MB  (per rank)")
        print(f"  fixed overhead        : {m.base_mb:9.1f} MB")
        print(f"  safety buffer         : {m.safety_mb:9.1f} MB")
        print(f"  ---")
        print(f"  per-rank total        : {m.per_rank_mb:9.1f} MB")
        print(f"  per-node total        : {m.gw_per_node_mb / 1024.0:9.2f} GB"
              f"  ({candidate.ntasks_per_node} ranks/node)")
        print(f"  whole-job total       : {m.total_job_mb / 1024.0:9.2f} GB")
        print(f"  suggested --mem-per-cpu : {m.suggested_mem_per_cpu_mb} MB  "
              f"(partition default: {m.partition_mem_per_cpu_mb} MB)")
        fits = "YES" if m.fits_partition else \
            "NO  -- lower NTAUPAR, use fewer ranks, or a larger-memory partition"
        print(f"  fits partition?         : {fits}")
        if m.gw_grid_source == "fine-fft-proxy":
            print("  NOTE: grids estimated from the fine FFT mesh (ALGO=None dry run).")
            print("        For an accurate number, do a brief REAL low-scaling run so")
            print("        VASP prints its HF/supercell grids and its own")
            print("        'min. memory requirement per mpi rank ... per node' line.")
        print()
    elif conv:
        m = candidate.memory
        print(f"[MEMORY ESTIMATE  ({m.model})]")
        print(f"  calibrated to your measurement; {m.gw_grid_source}")
        print(f"  base (orbitals+FFT+proj): {m.base_mb:9.1f} MB  (per rank)")
        print(f"  GW excess (chi/W, NOMEGA): {m.gw_grid_term_mb:9.1f} MB"
              f"  (scales 1/(ranks-per-k-group), NOMEGA, ISPIN, ENCUTGW^3)")
        print(f"  safety buffer           : {m.safety_mb:9.1f} MB")
        print(f"  ---")
        print(f"  per-rank total          : {m.per_rank_mb:9.1f} MB")
        print(f"  whole-job total         : {m.total_job_mb / 1024.0:9.2f} GB")
        print(f"  suggested --mem-per-cpu : {m.suggested_mem_per_cpu_mb} MB  "
              f"(partition default: {m.partition_mem_per_cpu_mb} MB)")
        fits = "YES" if m.fits_partition else \
            "NO  -- raise total ranks, lower KPAR, or use a larger-mem partition"
        print(f"  fits partition?         : {fits}")
        # ENCUTGW is the dominant (cubic) memory knob; flag the default=ENCUT trap.
        eff_encutgw = summary.encutgw or summary.encut
        if summary.encutgw is None and summary.encut is not None:
            print(f"  WARNING: ENCUTGW is unset -> defaults to ENCUT = "
                  f"{summary.encut:.0f} eV. GW memory ~ ENCUTGW^3, so this is")
            print(f"           the OOM-prone choice. Set ENCUTGW explicitly "
                  f"(e.g. 200-400) and converge it; halving ENCUTGW cuts this")
            print(f"           estimate ~8x. Pass --gw-ref-encutgw with the "
                  f"value used for your 2292 MB run to calibrate the sweep.")
        print()
    else:
        print(f"[MEMORY ESTIMATE  ({candidate.memory.model})]")
        m = candidate.memory
        print(f"  wavefun (per rank)    : {m.wavefun_mb:9.1f} MB")
        print(f"  grid    (per rank)    : {m.grid_mb:9.1f} MB")
        print(f"  nonlr-proj (per rank) : {m.nonlr_proj_mb:9.1f} MB")
        print(f"  fftplans (per rank)   : {m.fftplans_mb:9.1f} MB")
        print(f"  base + one-center     : {(m.base_mb + m.one_center_mb):9.1f} MB")
        print(f"  scaLAPACK workspace   : {m.scalapack_mb:9.1f} MB")
        print(f"  safety buffer         : {m.safety_mb:9.1f} MB")
        print(f"  ---")
        print(f"  per-rank total        : {m.per_rank_mb:9.1f} MB")
        print(f"  whole-job total       : {m.total_job_mb / 1024.0:9.2f} GB")
        print(f"  suggested --mem-per-cpu : {m.suggested_mem_per_cpu_mb} MB  "
              f"(partition default: {m.partition_mem_per_cpu_mb} MB)")
        fits = "YES" if m.fits_partition else \
            "NO  -- pick a larger-memory partition or fewer ranks"
        print(f"  fits partition?         : {fits}")
        print()

    print("[WHY]  (top score contributions)")
    for line in candidate.reasons:
        print(line)
    print()

    print("[INCAR SNIPPET]  (copy into your INCAR)")
    print("-" * 78)
    print(candidate.incar_snippet)
    print("-" * 78)
    print()

    print("[SLURM SCRIPT]  (copy into job.sh; submit with `sbatch job.sh`)")
    print("-" * 78)
    print(slurm_script(
        candidate=candidate,
        partition_name=partition_name,
        partition_info=partition_info,
        summary=summary,
        email=email,
        job_name=job_name,
        executable=executable,
        time_limit=time_limit,
    ))
    print("-" * 78)
    print()


def write_csv(path: Path, candidates: Sequence[Candidate]) -> None:
    fieldnames = [
        "score", "total_ranks", "nodes", "ntasks_per_node",
        "kpar", "ncore", "npar", "nsim", "lplane",
        "ranks_per_kgroup", "bands_per_group", "effective_nbands",
        "mem_model",
        "mem_per_cpu_suggested_mb", "mem_per_rank_mb", "mem_total_gb",
        "wavefun_mb", "grid_mb", "nonlr_proj_mb", "fftplans_mb",
        "base_one_center_mb", "scalapack_mb", "safety_mb",
        "fits_partition", "incar_snippet", "reasons", "contributions",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for c in candidates:
            m = c.memory
            writer.writerow({
                "score": f"{c.score:.3f}",
                "total_ranks": c.total_ranks,
                "nodes": c.nodes,
                "ntasks_per_node": c.ntasks_per_node,
                "kpar": c.kpar,
                "ncore": c.ncore,
                "npar": c.npar,
                "nsim": c.nsim,
                "lplane": c.lplane,
                "ranks_per_kgroup": c.ranks_per_kgroup,
                "bands_per_group": f"{c.bands_per_group:.4f}",
                "effective_nbands": c.effective_nbands,
                "mem_model": m.model,
                "mem_per_cpu_suggested_mb": m.suggested_mem_per_cpu_mb,
                "mem_per_rank_mb": f"{m.per_rank_mb:.1f}",
                "mem_total_gb": f"{m.total_job_mb / 1024.0:.2f}",
                "wavefun_mb": f"{m.wavefun_mb:.1f}",
                "grid_mb": f"{m.grid_mb:.1f}",
                "nonlr_proj_mb": f"{m.nonlr_proj_mb:.1f}",
                "fftplans_mb": f"{m.fftplans_mb:.1f}",
                "base_one_center_mb": f"{(m.base_mb + m.one_center_mb):.1f}",
                "scalapack_mb": f"{m.scalapack_mb:.1f}",
                "safety_mb": f"{m.safety_mb:.1f}",
                "fits_partition": m.fits_partition,
                "incar_snippet": c.incar_snippet.replace("\n", " | "),
                "reasons": " ; ".join(r.strip() for r in c.reasons),
                "contributions": " ; ".join(
                    f"{k}={v:+.2f}" for k, v in sorted(
                        c.contributions.items(), key=lambda kv: -abs(kv[1])
                    )
                ),
            })


# ============================================================================
# CLI
# ============================================================================


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "NLHPC VASP parallelization recommender (pure MPI). "
            "Reads a dry-run OUTCAR, follows the VASP wiki recipe to enumerate "
            "candidate (KPAR, NCORE, NPAR, NSIM, LPLANE) tuples, rescales "
            "VASP's own memory table to predict per-rank RAM for each, and "
            "prints INCAR + SLURM for the best one."
        )
    )
    parser.add_argument("outcar", type=Path,
                        help="Path to a previous dry-run OUTCAR "
                             "(ALGO=None or vasp --dry-run).")
    parser.add_argument("--max-cores", type=int, default=None,
                        help="Account-wide MPI-rank cap (default: from the "
                             "cluster profile written by vasp-configure, else "
                             "120).")
    parser.add_argument("--min-cores", type=int, default=8,
                        help="Smallest total_ranks to evaluate (default 8).")
    parser.add_argument("--partition",
                        choices=sorted(NLHPC_PARTITIONS.keys()),
                        default="main",
                        help="Logical partition: 'main' or 'debug' (mapped to "
                             "your real partition names by vasp-configure; "
                             "default: main).")
    parser.add_argument("--cores-per-node", type=int, default=None,
                        help="Override CPUs/node (defaults to the cluster "
                             "profile / built-in table).")
    parser.add_argument("--numa-cores", type=int, default=None,
                        help="NUMA-domain size in cores (defaults to the "
                             "profile/table; verify with lstopo / numactl "
                             "--hardware).")
    parser.add_argument("--mem-headroom", type=float, default=1.15,
                        help="Safety multiplier on the RAM estimate "
                             "(default 1.15).  At default, Tier 1 predictions "
                             "(per-row rescaling of VASP's own memory table) "
                             "end up about 15-20%% above actual peak usage. "
                             "Raise to 1.30-1.50 if you have hit OOM kills "
                             "or if you trust VASP's numbers less; lower to "
                             "1.05 for a very tight ask.")
    parser.add_argument("--top", type=int, default=10,
                        help="Number of top candidates to print (default 10).")
    parser.add_argument("--csv", type=Path, default=None,
                        help="Optional path: write the full ranked list as CSV.")
    parser.add_argument("--write-slurm", type=Path, default=Path("slurm_job.sh"),
                        metavar="FILE",
                        help="Write the recommended SLURM script to this file "
                             "(default: ./slurm_job.sh) so the exact job you "
                             "submit is on disk for inspection. Use --no-write "
                             "to only print it.")
    parser.add_argument("--write-incar", type=Path, default=Path("INCAR.parallel"),
                        metavar="FILE",
                        help="Write the recommended INCAR parallelization "
                             "snippet to this file (default: ./INCAR.parallel).")
    parser.add_argument("--no-write", action="store_true",
                        help="Do not write any files; only print to stdout.")
    parser.add_argument("--email", type=str, default=None,
                        help="Email injected into the SLURM script (default: "
                             "from the cluster profile written by "
                             "vasp-configure; empty -> no --mail-user line).")
    parser.add_argument("--job-name", type=str, default="VASP",
                        help="SLURM --job-name value (default: VASP).")
    parser.add_argument("--executable", type=str, default=None,
                        choices=["vasp_std", "vasp_gam", "vasp_ncl"],
                        help="VASP executable. Auto-detected from dry run if "
                             "omitted.")
    parser.add_argument("--strict-ncore-one", action="store_true",
                        help="Force NCORE=1 in all candidates (strict NLHPC "
                             "template).  By default we enumerate NCORE > 1 "
                             "as well, following the VASP wiki recommendation "
                             "of NCORE ~ sqrt(available_ranks) on modern "
                             "multi-core nodes.")
    parser.add_argument("--allow-kpar-above-irr", action="store_true",
                        help="Allow KPAR > NKPTS in the enumeration "
                             "(off by default per VASP wiki).")
    parser.add_argument("--nsim-choices", type=int, nargs="+",
                        default=[4],
                        help="NSIM values to enumerate (default: 4 only; "
                             "VASP wiki gives 4 as the CPU default. Pass "
                             "e.g. --nsim-choices 2 4 8 to widen the sweep).")
    parser.add_argument("--time", type=str, default="7-00:00:00",
                        help="SLURM --time value (default: 7-00:00:00).")
    parser.add_argument("--calc-type", choices=["auto", "dft", "gw", "gw-low",
                                                "rpa-low"],
                        default="auto",
                        help="Force the calculation type instead of detecting "
                             "it from the OUTCAR. 'gw' = conventional "
                             "(quartic-scaling) GW (KPAR-only, NCORE=1); "
                             "'gw-low' = low-scaling/space-time GW "
                             "(NTAUPAR/NOMEGAPAR); 'rpa-low' = low-scaling RPA. "
                             "Default 'auto' inspects ALGO and GW fingerprints "
                             "(useful when the dry run masked ALGO with None).")
    parser.add_argument("--nomega", type=int, default=None,
                        help="Override NOMEGA for low-scaling GW/RPA "
                             "(number of imaginary grid points). Only needed "
                             "if it could not be parsed from the OUTCAR; "
                             "NTAUPAR and NOMEGAPAR must both divide it.")
    parser.add_argument("--no-maxmem", action="store_true",
                        help="For low-scaling GW/RPA, do NOT emit a MAXMEM line "
                             "in the INCAR snippet (only show explicit "
                             "NTAUPAR/NOMEGAPAR instead). By default the tool "
                             "recommends MAXMEM, per the VASP wiki.")
    parser.add_argument("--gw-mem-per-rank", type=float, default=None,
                        metavar="MB",
                        help="CONVENTIONAL GW only: measured per-rank memory "
                             "(MB) to anchor the GW memory model. Default "
                             "anchor is 2292 MB (CuVS3 EVGW0). Set this to your "
                             "own measured value to recalibrate.")
    parser.add_argument("--gw-ref-ranks", type=int, default=None, metavar="N",
                        help="CONVENTIONAL GW only: total MPI ranks used in the "
                             "run that produced --gw-mem-per-rank (default "
                             "assumes 252). Needed to scale the anchor by "
                             "ranks-per-k-group; pass the real value of your "
                             "2292 MB run.")
    parser.add_argument("--gw-ref-encutgw", type=float, default=None,
                        metavar="EV",
                        help="CONVENTIONAL GW only: the ENCUTGW (eV) actually "
                             "used in the anchor run. The GW memory scales as "
                             "ENCUTGW^3, so this is essential for an ENCUTGW "
                             "convergence sweep. Default assumes 608 (=ENCUT).")
    return parser


# ============================================================================
# Cluster profile (written by vasp-configure)
# ============================================================================
# The toolkit ships with the NLHPC partitions above as a built-in default, but
# `vasp-configure` writes a per-user profile describing the ACTUAL cluster
# (partition names, cores/node, memory/node, the module-load lines for the
# chosen VASP build, the notification email and the account core cap). When
# that profile exists we fold it into the 'main' and 'debug' partitions so the
# emitted SLURM script targets the real partitions and loads the real modules.


def _config_path() -> Path:
    env = os.environ.get("WOLFPACK_CLUSTER_CONF")
    if env:
        return Path(env).expanduser()
    return Path.home() / ".config" / "wolfpack-dft" / "cluster.conf"


def load_cluster_profile() -> Dict[str, str]:
    """Parse the KEY="value" profile from vasp-configure; {} if none exists."""
    path = _config_path()
    prof: Dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError:
        return prof
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        prof[key.strip()] = val.strip().strip('"').strip("'")
    return prof


def _profile_module_lines(prof: Dict[str, str]) -> List[str]:
    """Build the module-load command lines from the profile."""
    mods = (prof.get("WP_VASP_MODULES") or "").split()
    if not mods:
        return []
    cmd = (prof.get("WP_MODULE_CMD") or "ml").strip()
    purge = str(prof.get("WP_MODULE_PURGE", "1")).strip().lower() \
        not in ("0", "", "false", "no")
    if cmd == "module":
        lines = ["module purge"] if purge else []
        lines.append("module load " + " ".join(mods))
    else:
        lines = ["ml purge"] if purge else []
        lines.append("ml " + " ".join(mods))
    return lines


def _profile_extra_env(prof: Dict[str, str]) -> List[str]:
    return [e.strip() for e in (prof.get("WP_EXTRA_ENV") or "").split(";")
            if e.strip()]


def apply_cluster_profile(prof: Dict[str, str]) -> None:
    """Fold the user's cluster profile into NLHPC_PARTITIONS['main'/'debug']."""
    if not prof:
        return
    mods = _profile_module_lines(prof)
    env = _profile_extra_env(prof)

    def _apply(key: str, name_k: str, cpus_k: str, mem_k: str) -> None:
        info = dict(NLHPC_PARTITIONS.get(key, {}))
        cpus = prof.get(cpus_k, "")
        mem = prof.get(mem_k, "")
        if cpus.isdigit():
            cpn = int(cpus)
            info["cpus_per_node"] = cpn
            if mem.isdigit():
                info["mem_per_cpu_mb"] = max(1, int(mem) // cpn)
        numa = prof.get("WP_MAIN_NUMA_CORES", "")
        if numa.isdigit():
            info["numa_cores"] = int(numa)
        if mods:
            info["modules"] = list(mods)
        if env:
            info["extra_env"] = list(env)
        name = prof.get(name_k, "").strip()
        if name:
            info["slurm_name"] = name
        info.setdefault("arch", "configured")
        NLHPC_PARTITIONS[key] = info

    _apply("main", "WP_MAIN_PARTITION",
           "WP_MAIN_CPUS_PER_NODE", "WP_MAIN_MEM_PER_NODE_MB")
    _apply("debug", "WP_DEBUG_PARTITION",
           "WP_DEBUG_CPUS_PER_NODE", "WP_DEBUG_MEM_PER_NODE_MB")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    # Fold the per-user cluster profile (vasp-configure) into the partition
    # catalogue and resolve email / core-cap defaults from it.
    profile = load_cluster_profile()
    apply_cluster_profile(profile)
    if args.email is None:
        args.email = profile.get("WP_EMAIL", "") or ""
    if args.max_cores is None:
        mc = profile.get("WP_MAX_CORES", "")
        args.max_cores = int(mc) if mc.isdigit() else 120

    summary = parse_outcar(args.outcar, calc_type_override=args.calc_type)
    # Allow a manual NOMEGA override for low-scaling τ/ω enumeration.
    if args.nomega is not None:
        summary.nomega = args.nomega

    partition_info = NLHPC_PARTITIONS[args.partition]
    cpus_per_node = args.cores_per_node \
        or int(partition_info["cpus_per_node"])  # type: ignore[arg-type]
    numa_cores = args.numa_cores
    if numa_cores is None and partition_info.get("numa_cores"):
        numa_cores = int(partition_info["numa_cores"])  # type: ignore[arg-type]

    print_dryrun_summary(summary)
    print_partition_summary(
        partition_name=args.partition,
        partition_info=partition_info,
        cpus_per_node=cpus_per_node,
        numa_cores=numa_cores,
        min_cores=args.min_cores,
        max_cores=args.max_cores,
    )

    is_gw = summary.calc_type in (
        "GW_CONVENTIONAL", "GW_LOWSCALING", "RPA_LOWSCALING")
    if is_gw:
        if summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING") \
                and not summary.nomega:
            print("[GW NOTE] Low-scaling GW/RPA detected but NOMEGA could not "
                  "be read from the OUTCAR.\n"
                  "          Falling back to a MAXMEM-only recommendation (no "
                  "explicit NTAUPAR/NOMEGAPAR).\n"
                  "          Pass --nomega N to enumerate the time/frequency "
                  "grid split explicitly.\n")
        candidates = build_gw_candidates(
            summary=summary,
            min_cores=args.min_cores,
            max_cores=args.max_cores,
            partition_name=args.partition,
            cpus_per_node=cpus_per_node,
            numa_cores=numa_cores,
            safety_factor=args.mem_headroom,
            limit_kpar_to_irr=not args.allow_kpar_above_irr,
            recommend_maxmem=not args.no_maxmem,
            gw_anchor_override=args.gw_mem_per_rank,
            gw_ref_ranks_override=args.gw_ref_ranks,
            gw_ref_encutgw_override=args.gw_ref_encutgw,
        )
    else:
        candidates = build_candidates(
            summary=summary,
            min_cores=args.min_cores,
            max_cores=args.max_cores,
            partition_name=args.partition,
            cpus_per_node=cpus_per_node,
            numa_cores=numa_cores,
            safety_factor=args.mem_headroom,
            limit_kpar_to_irr=not args.allow_kpar_above_irr,
            nsim_choices=tuple(args.nsim_choices),
            strict_ncore_one=args.strict_ncore_one,
        )

    if not candidates:
        print("No valid candidates could be generated. "
              "Check --min-cores / --max-cores and your dry-run OUTCAR.",
              file=sys.stderr)
        return 1

    # Best-per-rank-count table.
    best_each = best_per_total_ranks(candidates)
    print_candidate_table(best_each, top=max(1, args.top))

    executable = pick_executable(summary, args.executable)
    print_best_candidate(
        candidate=candidates[0],
        partition_name=args.partition,
        partition_info=partition_info,
        summary=summary,
        email=args.email or None,
        job_name=args.job_name,
        executable=executable,
        time_limit=args.time,
    )

    if args.csv is not None:
        write_csv(args.csv, candidates)
        print(f"[CSV] Full ranked list written to {args.csv}")

    # Write the recommended SLURM script + INCAR snippet to disk so the exact
    # job you submit is recoverable if it later fails (see also vasp-test).
    if not args.no_write:
        script_text = slurm_script(
            candidate=candidates[0],
            partition_name=args.partition,
            partition_info=partition_info,
            summary=summary,
            email=args.email or None,
            job_name=args.job_name,
            executable=executable,
            time_limit=args.time,
        )
        try:
            sp_path = Path(args.write_slurm)
            sp_path.write_text(script_text + "\n")
            try:
                os.chmod(sp_path, 0o755)
            except OSError:
                pass
            inc_path = Path(args.write_incar)
            inc_path.write_text(
                "# INCAR parallelization snippet (vasp-recommend-slurm)\n"
                + candidates[0].incar_snippet + "\n")
            print()
            print(f"[FILES] SLURM script written to : {sp_path}"
                  f"   (submit with: sbatch {sp_path})")
            print(f"[FILES] INCAR snippet written to: {inc_path}"
                  f"   (merge into your INCAR)")
        except OSError as exc:
            print(f"[FILES] WARNING: could not write output files: {exc}",
                  file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
