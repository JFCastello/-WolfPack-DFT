#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
vasp_plot_fatbandsdos.py  (invoked on PATH as: vasp-plot-fatbandsdos)
====================================================================
Master entry point for the WolfPack-DFT fat-band + DOS plotter.

The implementation lives in the ``wolfpack_plot`` package that sits next to this
file; this thin shim only makes that package importable (even when the command
is run through a ~/.local/bin symlink) and re-exports the stable public API so
that both of these keep working unchanged:

    # command line
    vasp-plot-fatbandsdos --root . --method rgb --projections "(Cu-d),(V-d),(S-p)"

    # from another script
    from vasp_plot_fatbandsdos import generate
    fig, axes = generate(root=".", method="rgb",
                         projections="(Cu-d),(S-p)", return_axes=True)

Projection methods (``--method``):
    plain        no projection -- pale-grey backbone + a small solid black
                 circle at every k-point where eigenvalues were computed.
    one_orbital  exactly one group -> pure-blue circles; opacity = weight share.
    duo          exactly two groups -> two-colour gradient; opacity = total weight.
    rgb          up to three groups -> additive red/green/blue; opacity = total.
    stacked      any number of groups -> sumo stacked circles (area ~ weight^2).

Auto projection picking (``--auto-projections N``) ranks the (element,
dominant-l) characters by their projected-DOS contribution inside the energy
window and selects the top N, falling back to inequivalent Wyckoff sites
(Pt1-d, Pt2-d, ...) when there are too few distinct elements.

Requires: pymatgen, numpy, matplotlib, scipy.
"""
from __future__ import annotations

import os
import sys

# Make the sibling ``wolfpack_plot`` package importable regardless of how this
# file is reached -- in particular when it is executed through a symlink in
# ~/.local/bin, whose directory does NOT contain the package. os.path.realpath
# follows the symlink back to the real toolkit directory.
_PKG_DIR = os.path.dirname(os.path.realpath(__file__))
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

from wolfpack_plot import generate, main          # noqa: E402,F401
from wolfpack_plot.core import load_all, _make_cfg, list_structure  # noqa: E402,F401
from wolfpack_plot.config import METHODS          # noqa: E402,F401

__all__ = ["generate", "main", "load_all", "list_structure", "METHODS"]


if __name__ == "__main__":
    main()
