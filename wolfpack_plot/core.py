"""
wolfpack_plot.core
=================
Orchestration and the public/CLI surface: build a config, read everything,
resolve the projection groups (explicit, auto-selected over an energy window,
or one-per-element), build the figure, and the ``generate()`` API, ``--list``
discovery and ``main()`` entry point.
"""
from __future__ import annotations

import argparse
import pickle
import sys
import warnings
from pathlib import Path

from pymatgen.io.vasp.outputs import BSVasprun

from .config import (BANDS_DIR, DEFAULT_METHOD, DEFAULT_OUT_NAME,
                     DEFAULT_PROJECTIONS, DOS_DIR, DPI, EMAX, EMIN, FIG_H,
                     FIG_W, FONT_FAMILY, GROUP_MODE, KPT_LABEL_SIZE, MARKER_SIZE,
                     MARKER_TARGET, METHOD_N_UNITS, METHODS, OUT_DIR,
                     OUT_FORMATS, PLAIN_MARKER_SIZE, SCF_DIR, SHOW_TITLE,
                     SYMPREC, ALPHA_MAX, ALPHA_MIN, STACKED_CIRCLE_SIZE,
                     normalize_method)
from .formatting import format_kpt_label
from .physics import (analyze_band_gap, auto_select_units, classify_material,
                      contribution_table, units_to_projection_string,
                      write_report, _group_raw_weight)
from .plotting import build_figure
from .structure import (_auto_projection_groups, _partition, _reduced_formula,
                        _site_grouping, _species_counts, assign_channels,
                        parse_projection_spec)
from .vaspio import (_assign_labels, auto_energy_window, read_bands, read_dos,
                     read_fermi, resolve_dos_smearing)

try:
    from pymatgen.electronic_structure.core import Spin
except Exception:                                       # pragma: no cover
    Spin = None


# --------------------------------------------------------------------------- #
# Configuration, loading, public API
# --------------------------------------------------------------------------- #
def _make_cfg(**overrides):
    cfg = argparse.Namespace(
        root=Path("."), projections=None, method=DEFAULT_METHOD, spin="both",
        title=None, show_title=SHOW_TITLE, emin=None, emax=None,
        markers=MARKER_TARGET, marker_size=MARKER_SIZE,
        plain_marker_size=PLAIN_MARKER_SIZE,
        alpha_min=ALPHA_MIN, alpha_max=ALPHA_MAX,
        circle_size=STACKED_CIRCLE_SIZE,
        auto_projections=0, name=DEFAULT_OUT_NAME,
        group=GROUP_MODE, symprec=SYMPREC,
        smear=None, dpi=DPI, figw=FIG_W, figh=FIG_H,
        font=FONT_FAMILY, formats=",".join(OUT_FORMATS), pickle=False,
        verbose=False)
    for k, v in overrides.items():
        if not hasattr(cfg, k):
            raise TypeError(f"generate(): unknown option {k!r}")
        setattr(cfg, k, v)
    cfg.method = normalize_method(cfg.method)
    if cfg.method not in METHODS:
        raise ValueError(f"method must be one of {METHODS}, got {cfg.method!r}")
    if cfg.group not in ("symmetry", "formula", "element"):
        raise ValueError('group must be "symmetry", "formula" or "element", '
                         f'got {cfg.group!r}')
    cfg.root = Path(cfg.root)
    return cfg


def _resolve_spins_value(spin, is_spin):
    # ISPIN=1 (non spin-polarised): there is only one channel, so --spin is
    # meaningless. Ignore it (warn only if the user explicitly asked for a
    # specific channel) and always plot the single set of bands.
    if not is_spin:
        if spin in ("up", "down"):
            warnings.warn(
                f"the calculation is not spin-polarised (ISPIN=1); --spin "
                f"{spin} is ignored and the single channel is plotted.")
        return [Spin.up], False
    # ISPIN=2 (collinear spin): --spin selects up / down / both.
    if spin == "up":
        return [Spin.up], False
    if spin == "down":
        return [Spin.down], False
    return [Spin.up, Spin.down], True


def _resolve_groups(cfg, bands_data, dos_data, structure, n_orb, grouping, efermi):
    """Decide the projection groups for the chosen method.

    plain                   -> no groups.
    --projections given     -> parse them.
    --auto-projections N    -> rank (element|Wyckoff-site, dominant-l) over the
                               energy window and pick the top N.
    otherwise               -> one group per element (with per-method checks).
    """
    method = cfg.method
    if method == "plain":
        return []

    spec = cfg.projections if cfg.projections is not None else DEFAULT_PROJECTIONS
    auto_n = int(getattr(cfg, "auto_projections", 0) or 0)

    if not spec and auto_n > 0:
        fixed = METHOD_N_UNITS.get(method)
        n_needed = fixed if fixed else auto_n
        chosen, level, ranking = auto_select_units(
            dos_data["cdos"], efermi, cfg.emin, cfg.emax, structure, grouping,
            n_needed, symprec=getattr(cfg, "symprec", SYMPREC))
        if not chosen:
            raise ValueError(
                "auto-projection selection found no projected weight in the "
                f"window [{cfg.emin:g}, {cfg.emax:g}] eV. Check LORBIT and the "
                "energy bounds.")
        spec = units_to_projection_string(chosen)
        if cfg.verbose:
            print(f"      auto-projections: top {n_needed} unit(s) over "
                  f"[{cfg.emin:g}, {cfg.emax:g}] eV by window contribution "
                  f"(level: {level})")
            for line in contribution_table(ranking):
                print("    " + line)
            print(f"      -> --projections \"{spec}\"")
        if len(chosen) < n_needed:
            warnings.warn(
                f"auto-projections wanted {n_needed} unit(s) but only "
                f"{len(chosen)} carry weight; {method} may need more.")

    if spec:
        groups = parse_projection_spec(spec, structure, n_orb, grouping)
        if n_orb:
            for g in groups:
                if (_group_raw_weight(g, bands_data) or 0.0) <= 1e-8:
                    el, orb = g["plain"].split("-")[0], g["plain"].split("-", 1)[-1]
                    raise ValueError(
                        f'the projection group "{g["plain"]}" ({orb} on {el}) '
                        f'carries no projected weight in this calculation — check '
                        f'the orbital is in the PAW basis and LORBIT is set.')
    else:
        groups = _auto_projection_groups(structure, n_orb)
        n = len(groups)
        els = ", ".join(g["element"] for g in groups)
        if method == "one_orbital" and n != 1:
            raise ValueError(
                f"--method one_orbital draws exactly 1 group, but auto-detection "
                f"found {n} element(s) ({els}). Pass one explicitly, e.g. "
                f'--projections "({groups[0]["element"]}-d)", or use '
                f"--auto-projections 1 to pick the dominant one automatically.")
        if method == "rgb" and n > 3:
            raise ValueError(
                f"--method rgb encodes at most 3 groups, but this cell has "
                f"{n} elements ({els}). Give 3 groups explicitly, use "
                f"--auto-projections 3, or --method stacked. Run --list.")
        if method == "duo" and n != 2:
            raise ValueError(
                f"--method duo needs exactly 2 groups, but auto-detection found "
                f"{n} element(s) ({els}). Pass two explicitly or use "
                f"--auto-projections 2.")
        if cfg.verbose:
            print("      No --projections / --auto-projections -> one group per "
                  "element. Run --list to choose atom+orbital groups.")
    return assign_channels(groups, method)


def load_all(cfg):
    """Read VASP output and resolve projection groups from a config namespace."""
    root = cfg.root.expanduser().resolve()
    bands_dir, dos_dir, scf_dir = root / BANDS_DIR, root / DOS_DIR, root / SCF_DIR
    for d in (bands_dir, dos_dir):
        if not d.is_dir():
            raise FileNotFoundError(f"expected sub-folder not found: {d}")

    if cfg.verbose:
        print(f"[1/4] Reading Fermi level from {scf_dir} ...")
    efermi = read_fermi(scf_dir, fallback_dir=bands_dir)
    if cfg.verbose:
        print(f"      E_F = {efermi:.4f} eV")

    if cfg.verbose:
        print(f"[2/4] Reading band structure from {bands_dir} ...")
    bands_data = read_bands(bands_dir, efermi)
    ispin = bands_data.get("ispin", 1)
    if ispin >= 3:
        raise ValueError(
            f"ISPIN={ispin} is not supported yet — only ISPIN=1 (non "
            "spin-polarised) and ISPIN=2 (collinear spin) are implemented. "
            "Non-collinear/spinor output (4 spin components) is out of scope "
            "for this plotter.")
    spins, show_both = _resolve_spins_value(cfg.spin, bands_data["is_spin"])
    if cfg.verbose:
        print(f"      {sum(v.shape[0] for v in bands_data['bands'].values())} bands, "
              f"{len(bands_data['distance'])} k-points, "
              f"{len(bands_data['segments'])} path segment(s), "
              f"ISPIN={ispin} (spin={'yes' if bands_data['is_spin'] else 'no'}), "
              f"SOC={'yes' if bands_data['soc'] else 'no'}")

    if cfg.verbose:
        print(f"[3/4] Reading DOS from {dos_dir} ...")
    dos_data = read_dos(dos_dir, efermi)

    if getattr(cfg, "smear", None) is None:
        sigma, ismear, nedos, src = resolve_dos_smearing([dos_dir, scf_dir, bands_dir])
        cfg.smear = sigma
        if cfg.verbose:
            if src is not None:
                how = ("tetrahedron (ISMEAR=%d)" % ismear if (ismear is not None and ismear <= -4)
                       else "ISMEAR=%s" % ismear)
                grid = f", NEDOS={nedos}" if nedos else ""
                if sigma > 0:
                    print(f"      DOS: extra Gaussian {sigma:g} eV ({how}{grid}, from {src})")
                else:
                    print(f"      DOS: using VASP grid as-is, no extra smearing "
                          f"[{how}{grid}] (from {src})")
            else:
                print(f"      DOS: no INCAR found; applying light Gaussian "
                      f"{sigma:g} eV for smoothness")
                warnings.warn("No INCAR in Dos/Scf/Bands; applying a light "
                              f"default DOS Gaussian ({sigma:g} eV).")

    auto_lo, auto_hi = auto_energy_window(bands_data)
    if cfg.emin is None:
        cfg.emin = auto_lo
    if cfg.emax is None:
        cfg.emax = auto_hi
    if cfg.verbose:
        tag = "auto" if (EMIN is None and EMAX is None) else "auto/override"
        print(f"      energy window: [{cfg.emin:g}, {cfg.emax:g}] eV "
              f"({tag}; use --emin/--emax to change)")

    structure, n_orb = bands_data["structure"], bands_data["n_orb"]

    grouping = _site_grouping(structure, getattr(cfg, "group", GROUP_MODE),
                              getattr(cfg, "symprec", SYMPREC))
    if cfg.verbose:
        ginfo = grouping["info"]
        if grouping["mode"] == "symmetry":
            print(f"      site grouping: symmetry, space group "
                  f"{ginfo.get('spacegroup', '?')} (#{ginfo.get('number', '?')}), "
                  f"symprec={getattr(cfg, 'symprec', SYMPREC)} A")
            per = ", ".join(f"{el}:{n}" for el, n in grouping["n_sites"].items())
            print(f"      inequivalent sites per element: {per}")
        else:
            print(f"      site grouping: {grouping['mode']}")
        for w in ginfo.get("warnings", []):
            print(f"      WARNING: {w}")

    groups = _resolve_groups(cfg, bands_data, dos_data, structure, n_orb,
                             grouping, efermi)
    if cfg.verbose:
        if cfg.method == "plain":
            print("      method=plain; no projections (backbone + k-point dots).")
        else:
            mapping = " | ".join(
                f"{g.get('channel_name', '#%d' % (g.get('channel', 0) + 1))}: {g['plain']}"
                for g in groups)
            print(f"      method={cfg.method}; channels -> {mapping}")

    gap = analyze_band_gap(bands_data)               # band-edge analysis
    cfg._efermi = efermi                             # stash for the report
    if cfg.verbose:
        if gap.get("metal"):
            print("      band gap: metallic (bands cross E_F)")
        else:
            kind = "direct" if gap["direct"] else "indirect"
            print(f"      band gap: {gap['gap']:.4f} eV ({kind}, "
                  f"{classify_material(gap)})")
    return bands_data, dos_data, groups, spins, show_both, gap


def generate(root=".", *, return_axes=False, return_data=False, **kwargs):
    """Build the figure and return it (for use from another script)."""
    cfg = _make_cfg(root=root, **kwargs)
    bands_data, dos_data, groups, spins, show_both, gap = load_all(cfg)
    fig, axes = build_figure(bands_data, dos_data, groups, cfg, spins, show_both,
                             gap=gap)
    result = [fig]
    if return_axes:
        result.append(axes)
    if return_data:
        result.append(dict(bands=bands_data, dos=dos_data, groups=groups))
    return fig if len(result) == 1 else tuple(result)


# --------------------------------------------------------------------------- #
# Discovery (--list)
# --------------------------------------------------------------------------- #
def list_structure(bands_dir: Path, group_mode=GROUP_MODE, symprec=SYMPREC):
    vr = BSVasprun(str(bands_dir / "vasprun.xml"), parse_projected_eigen=True)
    bs = vr.get_band_structure(kpoints_filename=str(bands_dir / "KPOINTS"),
                               line_mode=True, efermi="smart")
    st = bs.structure
    n_orb = next(iter(bs.projections.values())).shape[2] if bs.projections else 0
    labels = _assign_labels(bs, bands_dir / "KPOINTS")
    path_labels = []
    for l in labels:
        if l and (not path_labels or path_labels[-1] != l):
            path_labels.append(l)

    red_formula, z = _reduced_formula(st)
    counts = _species_counts(st)
    grouping = _site_grouping(st, group_mode, symprec)
    site_label = grouping["labels"]
    info = grouping["info"]
    wyk = info.get("wyckoff", {})

    print(f"\nFormula unit   : {red_formula}   (cell {st.composition.formula}, "
          f"Z = {z} formula unit{'s' if z != 1 else ''})")
    print(f"Atoms          : {len(st)}")
    print(f"Spin polarised : {bs.is_spin_polarized}")
    if grouping["mode"] == "symmetry":
        print(f"Space group    : {info.get('spacegroup', '?')} "
              f"(#{info.get('number', '?')}), symprec = {symprec} A")
    print(f"Site grouping  : {grouping['mode']}"
          + (f"  (requested {group_mode}, fell back)" if grouping["mode"] != group_mode else ""))
    print(f"Orbital cols   : {n_orb}  "
          f"({'lm-resolved (LORBIT=11)' if n_orb >= 9 else 'spd-summed' if n_orb else 'none'})")
    avail = "s p d" + (" f" if n_orb >= 16 else "")
    print(f"Orbital tokens : {avail}"
          + ("  + lm: px,py,pz,dxy,dyz,dz2,dxz,dx2,..." if n_orb >= 9 else ""))
    if path_labels:
        print("k-path         : "
              + " - ".join(format_kpt_label(l).replace("$", "") for l in path_labels))

    if grouping["mode"] == "symmetry":
        desc = "each numbered token = one symmetry-inequivalent site (Wyckoff orbit)"
    elif grouping["mode"] == "formula":
        desc = (f"each numbered token = a block of Z={z} consecutive atoms "
                f"(POSCAR order)")
    else:
        desc = "each numbered token = a single atom (POSCAR index)"
    print(f"\nProjection grouping ({desc}):")
    has_wy = grouping["mode"] == "symmetry" and any(wyk.values())
    header = "  POSCAR  elem  token  " + ("wyck  " if has_wy else "") + "frac coords"
    print(header)
    for i, site in enumerate(st):
        el = site.specie.symbol
        a, b, c = site.frac_coords
        tok = site_label[i]
        wcol = (f"{(wyk.get(tok) or '-'):<4}  " if has_wy else "")
        print(f"  {i:>4}   {el:<4}  {tok:<5} {wcol}{a:7.4f} {b:7.4f} {c:7.4f}")

    tokens = []
    for el in counts:
        ns = grouping["n_sites"].get(el, 0)
        tokens.append(el)
        tokens += [f"{el}{k}" for k in range(1, ns + 1)] if ns > 1 else []
    print("\nValid atom tokens :", ", ".join(tokens))
    print("  (bare element = all its atoms; e.g. "
          + ", ".join(f"{el} = all {c}" for el, c in counts.items()) + ")")
    print('Example           : --projections "'
          + ",".join(f"({el}-d)" for el in counts) + '"')
    multi = [el for el in counts if grouping["n_sites"].get(el, 0) > 1]
    if multi:
        el = multi[0]
        per = ",".join(f"({el}{k}-p)" for k in range(1, grouping["n_sites"][el] + 1))
        print(f'  per-site example  : --projections "{per}"')

    note = info.get("note")
    if note:
        print(f"\nNote: {note}")
    for w in info.get("warnings", []):
        print(f"WARNING: {w}")

    if grouping["mode"] == "symmetry" and z > 1:
        formula_g = _site_grouping(st, "formula", symprec)
        if _partition(grouping["labels"]) != _partition(formula_g["labels"]):
            print("\nNote: the symmetry grouping differs from naive POSCAR "
                  "Z-blocks — the crystallographic result above is used. Pass "
                  "--group formula to force consecutive blocks instead.")
    print()


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def parse_args(argv=None):
    p = argparse.ArgumentParser(
        prog="vasp-plot-fatbandsdos",
        description="Publication-ready fat-band + DOS plot from a VASP folder.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Examples:\n'
            '  vasp-plot-fatbandsdos --root . --list\n'
            '  vasp-plot-fatbandsdos --root . --method plain\n'
            '  vasp-plot-fatbandsdos --root . --method one_orbital \\\n'
            '      --auto-projections 1 --emin -3 --emax 3\n'
            '  vasp-plot-fatbandsdos --root . --method rgb \\\n'
            '      --projections "(Cu-d),(V-d),(S-p)" --title "CuVS_3"\n'))
    p.add_argument("--root", default=".", type=Path,
                   help="Calculation root with Scf/ Bands/ Dos/ (default: .)")
    p.add_argument("--list", action="store_true",
                   help="Print species, per-element atom tokens and orbitals, then exit.")
    p.add_argument("--method", required=True,
                   help="REQUIRED method: plain | one_orbital | duo | rgb | "
                        "stacked. 'plain': no projection (pale backbone + black "
                        "k-point dots). 'one_orbital': 1 group -> pure-blue "
                        "circles (opacity=weight). 'duo': 2 groups -> two-colour "
                        "gradient. 'rgb': up to 3 -> red/green/blue. 'stacked': "
                        "any number, sumo circles (area ~ weight).")
    p.add_argument("--projections", default=None,
                   help="Projection groups, e.g. \"(Cu-d),(V-d),(S-p)\". "
                        "one_orbital: 1; duo: 2; rgb: 1-3; stacked: any.")
    p.add_argument("--auto-projections", dest="auto_projections", type=int,
                   default=0, metavar="N",
                   help="Instead of --projections, auto-pick the N most-"
                        "contributing (element, dominant-l) units over the "
                        "energy window (falls back to inequivalent Wyckoff sites "
                        "if there are too few elements). For fixed-count methods "
                        "(one_orbital/duo/rgb) N is taken from the method.")
    p.add_argument("--name", default=DEFAULT_OUT_NAME,
                   help=f"Base filename written under <root>/{OUT_DIR}/ "
                        f"(default: {DEFAULT_OUT_NAME}).")
    p.add_argument("--spin", choices=["both", "up", "down"], default="both",
                   help="Spin channel(s) to plot for ISPIN=2 (default: both). "
                        "Ignored for ISPIN=1 (a single channel is plotted).")
    p.add_argument("--title", default=None,
                   help='Title in TeX-ish form, e.g. "CuVS_3 - G_0W_0".')
    p.add_argument("--no-title", dest="show_title", action="store_false")
    p.add_argument("--group", choices=["symmetry", "formula", "element"],
                   default=GROUP_MODE,
                   help=f"How numbered tokens (S1,S2,...) map to atoms (default "
                        f"{GROUP_MODE}).")
    p.add_argument("--symprec", type=float, default=SYMPREC,
                   help=f"spglib symmetry tolerance (A) for --group symmetry "
                        f"(default {SYMPREC}).")
    p.add_argument("--markers", type=int, default=MARKER_TARGET,
                   help="(rgb/duo/one_orbital) circles along the k-path: 0 "
                        "(default) one per k-point; positive subsamples.")
    p.add_argument("--marker-size", dest="marker_size", type=float,
                   default=MARKER_SIZE,
                   help=f"(rgb/duo/one_orbital) fixed circle area pt^2 (default "
                        f"{MARKER_SIZE}); weight shown by opacity.")
    p.add_argument("--plain-marker-size", dest="plain_marker_size", type=float,
                   default=PLAIN_MARKER_SIZE,
                   help=f"(plain) black k-point circle area pt^2 (default "
                        f"{PLAIN_MARKER_SIZE}).")
    p.add_argument("--alpha-min", dest="alpha_min", type=float, default=ALPHA_MIN,
                   help=f"(rgb/duo/one_orbital) opacity at weight 0 (default {ALPHA_MIN}).")
    p.add_argument("--alpha-max", dest="alpha_max", type=float, default=ALPHA_MAX,
                   help=f"(rgb/duo/one_orbital) opacity at weight 1 (default {ALPHA_MAX}).")
    p.add_argument("--circle-size", dest="circle_size", type=float,
                   default=STACKED_CIRCLE_SIZE,
                   help=f"(stacked) circle area scale (default {STACKED_CIRCLE_SIZE:g}).")
    p.add_argument("--emin", type=float, default=None,
                   help="Lower energy bound (eV, rel. E_F); default auto-fit. "
                        "Also bounds --auto-projections selection.")
    p.add_argument("--emax", type=float, default=None,
                   help="Upper energy bound (eV, rel. E_F); default auto-fit. "
                        "Also bounds --auto-projections selection.")
    p.add_argument("--pickle", action="store_true",
                   help="Also write the figure as a .fig.pkl for later editing.")
    p.add_argument("--dpi", type=int, default=DPI)
    p.add_argument("--figw", type=float, default=FIG_W)
    p.add_argument("--figh", type=float, default=FIG_H)
    p.add_argument("--font", default=FONT_FAMILY, choices=["sans-serif", "serif"])
    p.add_argument("--formats", default=",".join(OUT_FORMATS),
                   help="Comma-separated output formats (e.g. png,pdf,svg).")
    p.set_defaults(show_title=SHOW_TITLE, smear=None)
    args = p.parse_args(argv)
    args.method = normalize_method(args.method)
    if args.method not in METHODS:
        p.error(f"--method must be one of {', '.join(METHODS)} "
                f"(got {args.method!r}).")
    return args


def main(argv=None):
    cfg = parse_args(argv)
    cfg.verbose = True

    root = cfg.root.expanduser().resolve()
    bands_dir, dos_dir = root / BANDS_DIR, root / DOS_DIR
    for d in (bands_dir, dos_dir):
        if not d.is_dir():
            sys.exit(f"ERROR: expected sub-folder not found: {d}")

    if cfg.list:
        list_structure(bands_dir, group_mode=cfg.group, symprec=cfg.symprec)
        return

    try:
        bands_data, dos_data, groups, spins, show_both, gap = load_all(cfg)
    except (ValueError, FileNotFoundError, RuntimeError) as exc:
        sys.exit(f"ERROR: {exc}")

    print(f"[4/4] Rendering figure (method={cfg.method}, {len(groups)} group(s), "
          f"spin={cfg.spin}, {len(bands_data['segments'])} k-path panel(s)) ...")
    fig, _axes = build_figure(bands_data, dos_data, groups, cfg, spins,
                              show_both, gap=gap)

    out_dir = root / OUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    name = cfg.name or DEFAULT_OUT_NAME
    written = []
    for fmt in [f.strip().lower() for f in cfg.formats.split(",") if f.strip()]:
        path = out_dir / f"{name}.{fmt}"
        fig.savefig(path, dpi=cfg.dpi, bbox_inches="tight")
        written.append(path)
    if cfg.pickle:
        pk = out_dir / f"{name}.fig.pkl"
        with open(pk, "wb") as fh:
            pickle.dump(fig, fh)
        written.append(pk)
    import matplotlib.pyplot as plt
    plt.close(fig)

    try:
        rep = write_report(out_dir / f"{name}.analysis_report.txt", root, cfg,
                           bands_data, dos_data, groups,
                           getattr(cfg, "_efermi", float("nan")), gap)
        written.append(rep)
    except Exception as exc:                          # noqa: BLE001
        print(f"  (warning: could not write analysis report: {exc})")

    print("Done. Wrote:")
    for pth in written:
        print(f"  {pth}")
