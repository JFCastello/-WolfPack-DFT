"""
wolfpack_plot.structure
=======================
Structure-side bookkeeping: how atoms map to elements and to numbered
projection tokens (S1, S2, ... via symmetry/formula/element grouping), parsing
the ``--projections`` mini-language into validated group dicts, the
one-group-per-element fallback, and assigning each group a colour/channel for
the chosen drawing method.
"""
from __future__ import annotations

import re
import warnings
from collections import OrderedDict, defaultdict

import matplotlib
from pymatgen.core.periodic_table import Element

from .config import (DUO_CHANNELS, GROUP_MODE, ONE_ORBITAL_CHANNEL,
                     RGB_CHANNELS, STACKED_COLORS, SYMPREC)
from .formatting import _GROUP_TOKENS, _orb_tex, _validate_orbital


# --------------------------------------------------------------------------- #
# Species / sites
# --------------------------------------------------------------------------- #
def _species_sites(structure):
    """OrderedDict element -> [site indices] in POSCAR order."""
    out = OrderedDict()
    for i, site in enumerate(structure):
        out.setdefault(site.specie.symbol, []).append(i)
    return out


def _species_counts(structure):
    """OrderedDict element -> atom count, in POSCAR order."""
    return OrderedDict((el, len(idx)) for el, idx in _species_sites(structure).items())


def _reduced_formula(structure):
    """Deduce the formula unit. Returns (formula_string, Z)."""
    from math import gcd
    from functools import reduce
    counts = _species_counts(structure)
    z = reduce(gcd, counts.values()) if counts else 1
    z = max(z, 1)
    parts = []
    for el, c in counts.items():
        n = c // z
        parts.append(el if n == 1 else f"{el}{n}")
    return "".join(parts), z


def _symmetry_orbits(structure, symprec):
    """Symmetry-inequivalent orbits via spglib (through pymatgen)."""
    from pymatgen.symmetry.analyzer import SpacegroupAnalyzer
    sga = SpacegroupAnalyzer(structure, symprec=symprec)
    symm = sga.get_symmetrized_structure()
    eqi = symm.equivalent_indices                       # list[list[int]]
    wys = list(getattr(symm, "wyckoff_symbols", [None] * len(eqi)))
    orbits = []
    for grp, wy in zip(eqi, wys):
        orbits.append({"indices": sorted(int(i) for i in grp), "wyckoff": wy})
    info = dict(spacegroup=sga.get_space_group_symbol(),
                number=int(sga.get_space_group_number()))
    return orbits, info


def _site_grouping(structure, mode="symmetry", symprec=SYMPREC):
    """Resolve how numbered projection tokens (S1, S2, ...) map to atoms.

    Returns dict: mode (actually used), labels {idx->token}, order
    {token->[indices]}, n_sites {element->count}, info (diagnostics + warnings).
    """
    sps = _species_sites(structure)
    info = {"warnings": []}
    used = mode

    if mode == "symmetry":
        try:
            orbits, sym = _symmetry_orbits(structure, symprec)
        except Exception as exc:                        # noqa: BLE001
            msg = (f"symmetry analysis failed "
                   f"({exc.__class__.__name__}: {exc}); falling back to "
                   f"formula-block grouping. Adjust --symprec or use "
                   f"--group formula.")
            warnings.warn(msg)
            info["warnings"].append(msg)
            info["error"] = str(exc)
            used = "formula"
        else:
            info.update(sym)
            info["note"] = ("symmetry is crystallographic (atomic positions "
                            "only); magnetic ordering is not considered.")
            if len(orbits) >= len(structure):
                msg = (f"symmetry found NO equivalent atoms (space group "
                       f"{sym.get('spacegroup', '?')} #{sym.get('number', '?')}): "
                       f"every atom is distinct, so each numbered token is a "
                       f"single atom. The structure may be distorted or "
                       f"--symprec ({symprec} A) too tight — try a looser value "
                       f"(e.g. 0.05) or --group formula.")
                warnings.warn(msg)
                info["warnings"].append(msg)

    if used == "symmetry":
        by_el = OrderedDict()
        for orb in orbits:
            el = structure[orb["indices"][0]].specie.symbol
            by_el.setdefault(el, []).append(orb)
        labels, order, n_sites, wyk = {}, OrderedDict(), {}, {}
        for el, orbs in by_el.items():
            orbs.sort(key=lambda o: o["indices"][0])
            n_sites[el] = len(orbs)
            for k, orb in enumerate(orbs, 1):
                tok = f"{el}{k}"
                order[tok] = list(orb["indices"])
                wyk[tok] = orb["wyckoff"]
                for ai in orb["indices"]:
                    labels[ai] = tok
        info["wyckoff"] = wyk
        return dict(mode="symmetry", labels=labels, order=order,
                    n_sites=n_sites, info=info)

    if used == "formula":
        _f, z = _reduced_formula(structure)
        info["Z"] = z
        info["reduced_formula"] = _f
        labels, order, n_sites = {}, OrderedDict(), {}
        for el, idxs in sps.items():
            ns = len(idxs) // z
            n_sites[el] = ns
            for k in range(1, ns + 1):
                tok = f"{el}{k}"
                blk = list(idxs[(k - 1) * z:k * z])
                order[tok] = blk
                for ai in blk:
                    labels[ai] = tok
        return dict(mode="formula", labels=labels, order=order,
                    n_sites=n_sites, info=info)

    # element mode
    labels, order, n_sites = {}, OrderedDict(), {}
    for el, idxs in sps.items():
        n_sites[el] = len(idxs)
        for k, ai in enumerate(idxs, 1):
            tok = f"{el}{k}"
            order[tok] = [ai]
            labels[ai] = tok
    return dict(mode="element", labels=labels, order=order,
                n_sites=n_sites, info=info)


def _grouping_hint(grouping, el):
    """Human-readable phrase describing how many sites `el` has, for errors."""
    ns = grouping["n_sites"].get(el, 0)
    info = grouping["info"]
    if grouping["mode"] == "symmetry":
        sg = info.get("spacegroup", "?")
        num = info.get("number", "?")
        return (f"space group {sg} (#{num}) has {ns} symmetry-inequivalent "
                f"{el} site(s)")
    if grouping["mode"] == "formula":
        return (f"the reduced formula {info.get('reduced_formula', '?')} "
                f"(Z={info.get('Z', '?')}) has {ns} inequivalent {el} site(s)")
    return f"there are {ns} {el} atom(s)"


def parse_projection_spec(spec, structure, n_orb, grouping):
    """Parse '(Cu-d),(V-d),(S1-p),...' into validated group dicts."""
    items = re.findall(r"\(([^()]*)\)", spec)
    if not items:                                   # lenient: allow no parens
        items = [x for x in spec.split(",") if x.strip()]
    if not items:
        raise ValueError(
            f"Could not parse --projections {spec!r}. Expected groups like "
            f'"(Cu-d),(V-d),(S1-p)".')

    sps = _species_sites(structure)
    order = grouping["order"]
    groups = []
    for item in items:
        raw = item.strip()
        site_tok, orb_tok = (raw.split("-", 1) + [""])[:2]
        site_tok, orb_tok = site_tok.strip(), orb_tok.strip()

        m = re.fullmatch(r"([A-Za-z]{1,2})(\d*)", site_tok)
        if not m:
            raise ValueError(
                f'Could not parse atom token "{site_tok}" in group "({raw})". '
                f'Use forms like Cu, S1, V2.')
        el_raw, idx = m.group(1), m.group(2)
        el = el_raw[0].upper() + el_raw[1:].lower()

        if el not in sps:
            avail = ", ".join(sps)
            extra = ""
            try:
                Element(el)
            except Exception:                        # noqa: BLE001
                extra = " (not a recognised element symbol)"
            raise ValueError(
                f'Atom of species "{el_raw}" was not found in the calculation'
                f'{extra}. Species present: {avail}.')

        if idx:
            tok = f"{el}{idx}"
            if tok not in order:
                ns = grouping["n_sites"].get(el, 0)
                rng = f"{el}1" if ns <= 1 else f"{el}1..{el}{ns}"
                raise ValueError(
                    f'Requested {tok}, but {_grouping_hint(grouping, el)} — use '
                    f'{rng}, or a bare "{el}" to sum all {len(sps[el])} {el} '
                    f'atoms. Run --list to inspect the site grouping.')
            sites = list(order[tok])
            site_lbl = r"\mathrm{%s}_{%s}" % (el, idx)
            plain = tok
        else:
            sites = list(sps[el])
            site_lbl = r"\mathrm{%s}" % el
            plain = el

        if orb_tok == "":
            orbitals = ["s", "p", "d"] + (["f"] if n_orb >= 16 else [])
            label = "$%s$" % site_lbl
            plain_orb = "all"
        else:
            orbitals = [o for o in orb_tok.split("+") if o]
            for o in orbitals:
                _validate_orbital(o, n_orb, el)
            label = "$%s\\ %s$" % (site_lbl, "+".join(_orb_tex(o) for o in orbitals))
            plain_orb = orb_tok

        groups.append(dict(label=label, plain=f"{plain}-{plain_orb}",
                           sites=sites, orbitals=orbitals, element=el,
                           wyckoff=grouping["info"].get("wyckoff", {}).get(plain)))
    return groups


def _auto_projection_groups(structure, n_orb):
    """Fallback: one group per element, summed over all orbitals."""
    orbitals = ["s", "p", "d"] + (["f"] if n_orb >= 16 else [])
    sps = _species_sites(structure)
    return [dict(label=r"$\mathrm{%s}$" % el, plain=el, sites=list(idx),
                 orbitals=orbitals, element=el)
            for el, idx in sps.items()]


# --------------------------------------------------------------------------- #
# Colours / channels per method
# --------------------------------------------------------------------------- #
def assign_channels(groups, method):
    """Assign each group a channel index + colour for the chosen --method, and
    validate the group count.

      plain       : no groups expected (projections are ignored) -> returns [].
      one_orbital : exactly 1 group -> pure blue.
      duo         : exactly 2 groups -> two opposite colours.
      rgb         : 1-3 groups -> red, green, blue (>3 rejected; <3 warns).
      stacked     : any number of groups -> sumo's colour cycle.
    """
    n = len(groups)
    if method == "plain":
        return []                                 # plain never draws projections
    if method == "one_orbital":
        if n != 1:
            raise ValueError(
                f"--method one_orbital draws exactly 1 projection group, but "
                f"{n} were given. Pass a single group, e.g. "
                f'--projections "(Cu-d)".')
        g = groups[0]
        g["channel"], g["channel_name"], g["color"] = 0, "blue", ONE_ORBITAL_CHANNEL[0]
    elif method == "rgb":
        if n > 3:
            raise ValueError(
                f"--method rgb encodes at most 3 groups (one each for red, green "
                f"and blue), but {n} were given. Pick three (atom, orbital) "
                f'groups, e.g. --projections "(Cu-d),(V-d),(S-p)", or use '
                f"--method stacked for more.")
        if n < 3:
            warnings.warn(
                f"--method rgb is designed for 3 groups; you gave {n}, so "
                f"{'one channel is' if n == 2 else 'two channels are'} unused. "
                "For 2 groups, --method duo gives a cleaner two-colour gradient.")
        names = ["red", "green", "blue"]
        for i, g in enumerate(groups):
            g["channel"], g["channel_name"], g["color"] = i, names[i], RGB_CHANNELS[i]
    elif method == "duo":
        if n != 2:
            raise ValueError(
                f"--method duo needs exactly 2 groups (it draws a two-colour "
                f"gradient between them), but {n} were given. Use --method rgb "
                f"for 3, --method one_orbital for 1, or --method stacked for any "
                f"number.")
        names = ["A", "B"]
        for i, g in enumerate(groups):
            g["channel"], g["channel_name"], g["color"] = i, names[i], DUO_CHANNELS[i]
    elif method == "stacked":
        if n < 1:
            raise ValueError("--method stacked needs at least one group.")
        cyc = list(STACKED_COLORS) + list(
            matplotlib.rcParams["axes.prop_cycle"].by_key()["color"])
        for i, g in enumerate(groups):
            g["channel"], g["color"] = i, cyc[i % len(cyc)]
    else:
        raise ValueError(f"unknown method {method!r}")
    return groups


def _partition(labels):
    """Set of index-sets induced by a {idx->token} labeling (for comparison)."""
    groups = defaultdict(set)
    for idx, tok in labels.items():
        groups[tok].add(idx)
    return {frozenset(v) for v in groups.values()}
