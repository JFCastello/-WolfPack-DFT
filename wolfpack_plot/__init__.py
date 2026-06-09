"""
wolfpack_plot
=============
Publication-ready fat-band + DOS plotting for VASP, split into focused modules:

    config      tunable constants (colours, sizes, methods, geometry)
    formatting  orbital bookkeeping + TeX / k-label / title formatting
    structure   species, Wyckoff grouping, projection-spec parsing, channels
    vaspio      KPOINTS / vasprun / INCAR reading, smearing, energy window
    physics     band & DOS weights, window-contribution ranking, gap, report
    plotting    backbone + per-method markers + figure assembly
    core        config, load_all, generate(), --list, argparse, main()

The stable entry point is the command ``vasp-plot-fatbandsdos`` (the file
``vasp_plot_fatbandsdos.py`` next to this package) and the importable API:

    from vasp_plot_fatbandsdos import generate    # or: from wolfpack_plot import generate
"""
from __future__ import annotations

from .config import METHODS
from .core import generate, main

__all__ = ["generate", "main", "METHODS"]
__version__ = "2.0.0"
