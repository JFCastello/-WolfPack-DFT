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
#   "cmyk"        : exactly 4 groups -> CMYK colour mix (C/M/Y/K); opacity = total.
#   "stacked"     : any number of groups -> sumo stacked circles (area ~ w^2).
METHODS = ("plain", "one_orbital", "duo", "rgb", "cmyk", "stacked")
DEFAULT_METHOD = "rgb"

_METHOD_ALIASES = {
    "plain": "plain", "none": "plain", "bare": "plain",
    "one_orbital": "one_orbital", "oneorbital": "one_orbital",
    "one": "one_orbital", "single": "one_orbital", "mono": "one_orbital",
    "duo": "duo", "two": "duo",
    "rgb": "rgb",
    "cmyk": "cmyk", "four": "cmyk", "quad": "cmyk",
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
    "plain": 0, "one_orbital": 1, "duo": 2, "rgb": 3, "cmyk": 4, "stacked": None,
}

# --------------------------------------------------------------------------- #
# rgb / duo / one_orbital / cmyk marker model
# --------------------------------------------------------------------------- #
RGB_CHANNELS = ("#FF0000", "#00FF00", "#0000FF")   # pure additive R, G, B
DUO_CHANNELS = ("#0066FF", "#FF8000")              # vivid blue <-> vivid orange
ONE_ORBITAL_CHANNEL = ("#0000FF",)                 # pure blue (single channel)
# CMYK: a 4-orbital generalisation of rgb using subtractive CMYK colour theory.
# The four group weights become the C, M, Y, K fractions of a CMYK colour, which
# is converted to RGB as R=(1-C)(1-K), G=(1-M)(1-K), B=(1-Y)(1-K). A point
# dominated by group 0 -> cyan, group 1 -> magenta, group 2 -> yellow,
# group 3 -> black. These per-channel legend swatches are those pure colours.
CMYK_CHANNELS = ("#00FFFF", "#FF00FF", "#FFFF00", "#000000")  # C, M, Y, K

MARKER_SIZE = 3.0          # fixed circle area (pt^2) for every point (tiny)
ALPHA_MIN = 0.06           # opacity at S = 0  (faintest)
ALPHA_MAX = 1.0            # opacity at S = 1  (solid)
MARKER_TARGET = 0          # markers per k-path: 0 -> one per actual k-point
PROJ_CUTOFF = 1e-3         # ignore points whose group weight is below this

# --------------------------------------------------------------------------- #
# Spin handling (ISPIN=2)
# --------------------------------------------------------------------------- #
# There is NO in-figure overlay of the two channels any more: --spin up / down
# each draw a single channel with the standard circles, and --spin both renders
# the spin-up plot, the spin-down plot, AND a dedicated two-colour overlaid
# "plain" plot (below).  No cyan/magenta marker edges are drawn for any method.

# --------------------------------------------------------------------------- #
# Overlaid "plain" plot (ISPIN=2, --spin both): both channels in ONE plain plot
# --------------------------------------------------------------------------- #
# No projections.  Spin-up bands are pure-RGB blue, spin-down pure-RGB orange,
# drawn as the usual slightly-translucent plain circles.  The single grey band
# backbone is replaced by TWO per-spin backbones: very thin, dashed, highly
# transparent, pale blue (up) and pale orange (down).
OVERLAY_UP_COLOR = "#0000FF"      # spin up   -> pure RGB blue
OVERLAY_DOWN_COLOR = "#FF8000"    # spin down -> vivid orange
OVERLAY_UP_BACKBONE = "#7FA8FF"   # pale blue   backbone (spin up)
OVERLAY_DOWN_BACKBONE = "#FFC080"  # pale orange backbone (spin down)
OVERLAY_BACKBONE_LW = 0.4         # very thin
OVERLAY_BACKBONE_LS = (0, (4, 3))  # dashed "--"
OVERLAY_BACKBONE_ALPHA = 0.30     # highly transparent

# --------------------------------------------------------------------------- #
# "plain" method: black k-point dots on the shared backbone
# --------------------------------------------------------------------------- #
PLAIN_MARKER_SIZE = 4.0    # small black circle area (pt^2)
PLAIN_MARKER_COLOR = "#000000"
PLAIN_ALPHA = 0.5          # intermediate opacity of the plain k-point markers

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
STACKED_COLORS = ["#3952A3", "#FAA41A", "#67BC47", "#6ECCDD", "#ED2025"]  # sumo palette
STACKED_CIRCLE_SIZE = 45.0    # sumo 'circle_size' (area; scaled by w**2); sumo=150
STACKED_PROJ_CUTOFF = 0.001   # sumo 'projection_cutoff'
STACKED_INTERP = 4            # sumo 'interpolate_factor'
# How sumo normalises each point's projection weights before sizing the circles:
#   "select" -> divide by the sum over the SELECTED groups (sumo's stacked look:
#               the chosen orbitals' circles share the marker area at each point);
#   "all"    -> divide by the total state weight (selected + unselected);
#   "none"   -> raw projection magnitudes.
STACKED_NORMALISE = "select"

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
