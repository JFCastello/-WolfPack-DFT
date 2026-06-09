"""
wolfpack_plot.config
====================
All tunable constants for the fat-band / DOS plotter in one place: folder
names, the projection-method colour tables, marker/opacity laws, the shared
pale-grey band backbone, DOS styling, symmetry settings and figure geometry.

Nothing here imports the heavy scientific stack, so it is safe to import first
from every other module in the package.
"""
from __future__ import annotations

# --------------------------------------------------------------------------- #
# Folder layout (sub-folder names under <root>)
# --------------------------------------------------------------------------- #
SCF_DIR, BANDS_DIR, DOS_DIR, OUT_DIR = "Scf", "Bands", "Dos", "Plots"

# Energy window (eV, relative to E_F). None -> auto-fit to the band data.
EMIN, EMAX = None, None

# Used when --projections is not supplied. Same syntax as the CLI flag.
DEFAULT_PROJECTIONS = ""

# --------------------------------------------------------------------------- #
# Projection methods
# --------------------------------------------------------------------------- #
# Canonical method names. Aliases (any case, '-'/' ' for '_') are normalised by
# normalize_method().  See plotting.py for what each one draws.
#   "plain"       : no projection. Pale-grey backbone + a small solid black
#                   circle at every k-point where eigenvalues were computed.
#   "one_orbital" : exactly 1 group -> pure-blue circles; opacity = w/w_tot.
#   "duo"         : exactly 2 groups -> two-colour gradient; opacity = total wt.
#   "rgb"         : up to 3 groups  -> additive red/green/blue; opacity = total.
#   "stacked"     : any number of groups -> sumo stacked circles (area ~ w^2).
METHODS = ("plain", "one_orbital", "duo", "rgb", "stacked")
DEFAULT_METHOD = "rgb"

_METHOD_ALIASES = {
    "plain": "plain", "none": "plain", "bare": "plain",
    "one_orbital": "one_orbital", "oneorbital": "one_orbital",
    "one": "one_orbital", "single": "one_orbital", "mono": "one_orbital",
    "duo": "duo", "two": "duo",
    "rgb": "rgb",
    "stacked": "stacked", "stack": "stacked",
}


def normalize_method(name: str) -> str:
    """Map a user-supplied method name to its canonical form.

    Case-insensitive; treats '-' and ' ' as '_'.  e.g. "One_Orbital",
    "one-orbital", "ONE ORBITAL" -> "one_orbital".  Returns the input lowercased
    unchanged if it is not a known alias (the caller validates and errors).
    """
    if not name:
        return name
    key = str(name).strip().lower().replace("-", "_").replace(" ", "_")
    return _METHOD_ALIASES.get(key, key)


# How many projection groups each fixed-count method needs (None = any number).
METHOD_N_UNITS = {
    "plain": 0, "one_orbital": 1, "duo": 2, "rgb": 3, "stacked": None,
}

# --------------------------------------------------------------------------- #
# rgb / duo / one_orbital marker model
# --------------------------------------------------------------------------- #
RGB_CHANNELS = ("#FF0000", "#00FF00", "#0000FF")   # pure additive R, G, B
DUO_CHANNELS = ("#0066FF", "#FF8000")              # vivid blue <-> vivid orange
ONE_ORBITAL_CHANNEL = ("#0000FF",)                 # pure blue (single channel)

MARKER_SIZE = 3.0          # fixed circle area (pt^2) for every point (tiny)
ALPHA_MIN = 0.06           # opacity at S = 0  (faintest)
ALPHA_MAX = 1.0            # opacity at S = 1  (solid)
MARKER_TARGET = 0          # markers per k-path: 0 -> one per actual k-point
PROJ_CUTOFF = 1e-3         # ignore points whose group weight is below this

# --------------------------------------------------------------------------- #
# Spin markers (plain / one_orbital / duo / rgb, ONLY when both spins are shown)
# --------------------------------------------------------------------------- #
# With both spin channels overlaid, circles are replaced by very small
# triangles so the two channels never sit ambiguously on top of each other:
# spin-up -> up-triangle, spin-down -> down-triangle. The marker EDGE encodes
# the spin too -- pure cyan for up, pure magenta for down -- which stays visible
# even where the (weight-dependent) face is almost transparent.
SPIN_UP_MARKER = "^"
SPIN_DOWN_MARKER = "v"
# Dark cyan / dark magenta: a sweet spot that reads clearly against the white
# background (bright pure cyan/magenta wash out there) yet stays distinct from
# the face colours inside the triangles (duo blue/orange, rgb red/green/blue),
# so the spin outline never gets confused with the projection colour.
SPIN_UP_EDGE = "#0B9AA6"   # dark cyan   (spin up)
SPIN_DOWN_EDGE = "#C2188C" # dark magenta (spin down)
SPIN_EDGE_LW = 0.5         # triangle outline width (pt) -- keep them tiny

# --------------------------------------------------------------------------- #
# "plain" method: black k-point dots on the shared backbone
# --------------------------------------------------------------------------- #
PLAIN_MARKER_SIZE = 4.0    # small black circle/triangle area (pt^2)
PLAIN_MARKER_COLOR = "#000000"
PLAIN_ALPHA = 0.5          # intermediate opacity of the plain k-point markers
PLAIN_EVERY_KPOINT = True  # a dot at every computed k-point (no subsampling)

# --------------------------------------------------------------------------- #
# Shared band backbone -- drawn FIRST (in the background) for EVERY method.
# Deliberately very thin and very pale so it never competes with the markers;
# in "plain" mode it is the only line, faintly tracing the dispersion between
# the black k-point dots.
# --------------------------------------------------------------------------- #
BACKBONE_LW = 0.4          # very thin
BACKBONE_COLOR = "0.80"    # very pale grey (0=black, 1=white)

# --------------------------------------------------------------------------- #
# "stacked" method (sumo-compatible)
# --------------------------------------------------------------------------- #
STACKED_COLORS = ["#3952A3", "#FAA41A", "#67BC47", "#6ECCDD", "#ED2025"]
STACKED_CIRCLE_SIZE = 45.0    # sumo 'circle_size' (area; scaled by w**2); sumo=150
STACKED_PROJ_CUTOFF = 0.001   # sumo 'projection_cutoff'
STACKED_INTERP = 4            # sumo 'interpolate_factor'

# --------------------------------------------------------------------------- #
# Band-edge (VBM/CBM) markers
# --------------------------------------------------------------------------- #
EDGE_CORE = "#000000"      # band-edge dot core (black)
EDGE_HALO = "#FFFFFF"      # band-edge dot halo (white)

# --------------------------------------------------------------------------- #
# DOS styling
# --------------------------------------------------------------------------- #
DEFAULT_SMEAR = 0.05       # light Gaussian (eV) only if no INCAR is found at all
DOS_LW = 1.1               # projected-DOS curve width (pt)
DOS_TOTAL_LW = 0.6         # total-DOS outline width (pt)

# --------------------------------------------------------------------------- #
# Site grouping for numbered projection tokens (e.g. S1/S2)
# --------------------------------------------------------------------------- #
GROUP_MODE = "symmetry"    # "symmetry" | "formula" | "element"
SYMPREC = 1e-2             # spglib symmetry tolerance (Angstrom)

# --------------------------------------------------------------------------- #
# Figure geometry / output
# --------------------------------------------------------------------------- #
FIG_W, FIG_H = 8.2, 5.2
WIDTH_RATIOS = (3.0, 1.0)         # (all band sub-panels) : (DOS panel)
SEG_WSPACE = 0.16                 # gap between concatenated k-path sub-panels
KPT_LABEL_SIZE = 11               # font size of high-symmetry k-path labels
DPI = 300
OUT_FORMATS = ("png", "pdf")
FONT_FAMILY = "sans-serif"
SHOW_TITLE = True
DEFAULT_OUT_NAME = "fatbands_dos"  # base filename written under <root>/Plots/
