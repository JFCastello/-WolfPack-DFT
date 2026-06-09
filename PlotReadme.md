# vasp-plot-fatbandsdos

Publication-ready **fat-band + DOS** figures from a standard VASP run. The band
panel encodes projection weight as **marker opacity** (RGB/duo) or **circle area**
(stacked); the DOS panel shares the energy axis and is projected onto the same
atom/orbital groups. Energies are referenced to E_F = 0; spin polarisation
and SOC are detected automatically.

---

## 1. Folder layout

```
<root>/
    Scf/    vasprun.xml             # reference Fermi level (dense SCF)
    Bands/  vasprun.xml  KPOINTS    # line-mode bands, LORBIT=11
    Dos/    vasprun.xml             # dense-mesh DOS, LORBIT=11
```
Output is written to `<root>/Plots/fatbands_dos.{png,pdf}` plus a text
`analysis_report.txt` summarising structure, gap, projections and INCAR tags.
(Sub-folder names are set at the top of the script: `SCF_DIR`, `BANDS_DIR`,
`DOS_DIR`, `OUT_DIR`.)

> **LORBIT:** use `LORBIT = 11` for the Bands and DOS runs so lm-resolved
> orbitals (`px`, `dz2`, …) are available. `LORBIT = 10` (s/p/d sums) still
> works for `s`, `p`, `d`, `f` groups.

---

## 2. Quick start

```bash
# step 1 — inspect species, atom tokens, and available orbitals
vasp-plot-fatbandsdos --root . --list

# step 2 — plot with a chosen method (--method is REQUIRED)
vasp-plot-fatbandsdos --root . --method rgb \
    --projections "(Cu-d),(V-d),(S-p)" \
    --title "CuVS_3 - G_0W_0"
```

With no `--projections`, the script colours one group per element so you always
get a figure to sanity-check first.

---

## 3. `--method` (REQUIRED)

A **very thin, very pale grey backbone** traces every band in the background of
*every* method (it is the only line drawn by `plain`). Method names are
case-insensitive and accept `-`/space for `_` (e.g. `One_Orbital`, `one-orbital`).

| Method | Groups | Encodes |
|--------|--------|---------|
| `plain` | 0 | no projection: pale backbone + a small **solid black circle at every k-point** where eigenvalues were computed; DOS shows the total only |
| `one_orbital` | exactly 1 | **pure-blue** circles; opacity = w_group / w_total (the duo/rgb opacity law with a single channel) |
| `duo` | exactly 2 | gradient between two vivid colours; opacity = total weight |
| `rgb` | 1–3 | additive RGB: colour = relative mix of groups; opacity = total weight |
| `stacked` | any number | sumo-style circles; area proportional to weight² |

```bash
vasp-plot-fatbandsdos ... --method plain        # no projection; black k-point dots
vasp-plot-fatbandsdos ... --method one_orbital  # 1 group -> pure-blue circles
vasp-plot-fatbandsdos ... --method rgb          # up to 3 groups -> R / G / B
vasp-plot-fatbandsdos ... --method duo          # exactly 2 groups
vasp-plot-fatbandsdos ... --method stacked      # any number of groups
```

### Auto-pick projections over an energy window (`--auto-projections N`)

Instead of giving `--projections`, let the tool choose the `N` most-important
`(element, dominant-l)` units over `[--emin, --emax]`. "Most important" is the
**projected DOS integrated over the window** (a proper states integral, summed
over spin) — a faithful, reproducible measure of which orbitals dominate the
range. For the fixed-count methods `N` is implied (`one_orbital`→1, `duo`→2,
`rgb`→3); `stacked` takes the `N` you pass. If the cell has fewer distinct
elements than `N`, selection falls back to inequivalent **Wyckoff sites** of the
same element (`Pt1-d, Pt2-d, …`), always in descending contribution order.

```bash
# the dominant orbital character between -3 and +3 eV, as pure-blue fat bands:
vasp-plot-fatbandsdos --root . --method one_orbital --auto-projections 1 \
    --emin -3 --emax 3 --name homo_character

# top-3 elements by window weight, as RGB:
vasp-plot-fatbandsdos --root . --method rgb --auto-projections 3 --emin -6 --emax 6
```

`--name BASENAME` controls the output filename written under `Plots/`
(default `fatbands_dos`).

### `vasp-quick-plots` — one figure per method, automatically

```bash
conda activate wolfpack-dft
vasp-quick-plots --emin -6 --emax 6 --title "CuVS_3"
#   -> Plots/{plain,one_orbital,duo,rgb,stacked}.{png,pdf}
vasp-quick-plots --methods plain,one_orbital,rgb   # subset
vasp-quick-plots --stacked-n 5                     # 5 units in the stacked plot
```

`vasp-quick-plots` runs `vasp-plot-fatbandsdos` once per method with the right
`--auto-projections` count and a distinct `--name`, and keeps going if one
method fails.

---

## 4. `--projections` syntax

Comma-separated, parenthesised groups: `(ATOM-ORBITAL),(ATOM-ORBITAL),...`

| Part | Examples | Meaning |
|------|----------|---------|
| **ATOM** | `Cu` | all atoms of element Cu |
| | `S1`, `S2`, `S3` | the 1st / 2nd / 3rd inequivalent S site (1-based) |
| **ORBITAL** | `s` `p` `d` `f` | orbital group (`f` only if the run stored it) |
| | `px` `dz2` … | a specific lm orbital (needs `LORBIT=11`) |
| | `d+s` | several orbitals combined with `+` |
| *(omitted)* | `(Cu)` | sum over all orbitals of that atom |

**Site numbering:** how `S1`, `S2`, … are assigned is controlled by `--group`
(default: symmetry-inequivalent Wyckoff orbits from spglib). Run `--list` to
see the exact per-site assignment before plotting.

### Projection errors
Clear, actionable errors are raised for:
```
(Y-d)     Atom of species "Y" was not found. Species present: Cu, V, S.
(S4-p)    Requested S4, but only 3 inequivalent S sites exist.
(Cu-f)    The "f" orbital is not available (projections contain only s, p, d).
(Cu-dz2)  Orbital "dz2" needs lm-resolved projections (LORBIT=11).
(Cu-xyz)  Unknown orbital "xyz". Use s, p, d, f or a specific lm orbital.
```

---

## 5. Titles (journal style)

`--title` accepts a light TeX-ish string with upright element/letter runs and
neat subscripts:

| Input | Renders as |
|-------|-----------|
| `CuVS_3 - G_0W_0` | CuVS₃ – G₀W₀ |
| `MoS_2 monolayer` | MoS₂ monolayer |
| `Fe_{12}O_{19}` | Fe₁₂O₁₉ |

With no `--title` the reduced formula is used; `--no-title` suppresses it.

---

## 6. All CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--root PATH` | `.` | calculation root containing `Scf/ Bands/ Dos/` |
| `--list` | – | print species / atom tokens / orbitals, then exit |
| **`--method {plain,one_orbital,duo,rgb,stacked}`** | **(REQUIRED)** | projection method (see §3) |
| `--projections "..."` | auto (one group/element) | atom+orbital groups (see §4) |
| `--auto-projections N` | `0` (off) | auto-pick the top-N `(element, l)` units over the window (see §3) |
| `--name BASENAME` | `fatbands_dos` | output base filename written under `Plots/` |
| `--spin {both,up,down}` | `both` | ISPIN=2: choose spin channel(s). Ignored for ISPIN=1 (one channel; see below). |
| `--title "..."` | reduced formula | journal-style title (see §5) |
| `--no-title` | – | suppress the title |
| `--emin` / `--emax` | auto-fit to bands | energy window (eV, rel. E_F); also bounds `--auto-projections` |
| `--group {symmetry,formula,element}` | `symmetry` | how S1/S2/… map to atoms |
| `--symprec F` | `0.01` Å | spglib tolerance for `--group symmetry` |
| `--markers N` | `0` (one per k-pt) | subsample markers on a dense k-path |
| `--marker-size F` | `3.0` pt² | fixed circle area (rgb/duo/one_orbital); weight → opacity |
| `--plain-marker-size F` | `4.0` pt² | black k-point circle area (plain) |
| `--alpha-min F` | `0.06` | min opacity at zero weight (rgb/duo/one_orbital) |
| `--alpha-max F` | `1.0` | max opacity at full weight (rgb/duo/one_orbital) |
| `--circle-size F` | `45` | circle area scale factor (stacked) |
| `--pickle` | off | also save the figure as `.fig.pkl` for later editing |
| `--formats png,pdf` | `png,pdf` | comma-separated output formats |
| `--dpi` | `300` | raster DPI |
| `--figw` / `--figh` | `8.2` / `5.2` in | figure size |
| `--font {sans-serif,serif}` | `sans-serif` | `serif` ≈ Times / PRB look |

> **Note:** `--smear`, `--fatness`, and `--no-normalize` are **not** CLI flags.
> DOS smearing is set automatically from `Dos/INCAR` (ISMEAR / SIGMA); a light
> Gaussian is applied only if no INCAR is found. These parameters are available
> when calling `generate()` from Python.

### Spin polarisation (ISPIN)

The plotter detects ISPIN automatically:

- **ISPIN = 1** (non spin-polarised): one channel. `--spin` is meaningless and
  is ignored (a single set of bands/DOS is drawn); passing `--spin up/down`
  prints a harmless note rather than an error.
- **ISPIN = 2** (collinear spin): `--spin both` overlays both channels
  (spin-up filled markers / solid DOS, spin-down open markers / mirrored DOS);
  `--spin up` or `--spin down` isolates one.
- **ISPIN ≥ 3** (non-collinear / spinor, 4 components): not implemented — the
  tool stops with a clear message instead of producing a wrong figure.

---

## 7. Python API

```python
from vasp_plot_fatbandsdos import generate

fig, axes = generate(root="path/to/calc",
                     method="rgb",
                     projections="(Cu-d),(S-p)",
                     title="CuVS_3", return_axes=True)
axes["bands"][0].set_ylim(-2, 2)    # tweak anything
fig.savefig("custom.pdf")
```

Or reload a pickled figure (written with `--pickle`):
```python
import pickle, matplotlib.pyplot as plt
fig = pickle.load(open("Plots/fatbands_dos.fig.pkl", "rb"))
fig.axes[0].set_title("edited"); fig.savefig("edited.png")
```

`generate()` accepts the same parameters as the CLI flags plus:
- `smear` — explicit Gaussian broadening σ (eV); `None` = auto from INCAR
- `emin`, `emax` — float or `None` (auto-fit)
- `return_data` — also return the parsed bands/DOS dicts

---

## 8. Install & package layout

Install the whole toolkit (this command included) with the repo installer:

```bash
cd WolfPack-DFT
./install.sh                 # symlinks the command + creates env 'wolfpack-dft'
conda activate wolfpack-dft  # provides pymatgen/numpy/matplotlib/scipy
```

The command `vasp-plot-fatbandsdos` is a `~/.local/bin` symlink to
`vasp_plot_fatbandsdos.py`. That file is a **thin master shim**: the real code
lives in the sibling `wolfpack_plot/` package, and the shim adds its own
(symlink-resolved) directory to `sys.path` so the package imports correctly even
when run through the symlink. Edits to any module take effect immediately — but
**keep `vasp_plot_fatbandsdos.py` next to the `wolfpack_plot/` folder.**

```
WolfPack-DFT/
    vasp_plot_fatbandsdos.py     # master entry point (command + import shim)
    wolfpack_plot/
        config.py      formatting.py   structure.py   vaspio.py
        physics.py     plotting.py     core.py        __init__.py
```

---

## 9. Troubleshooting

- **`fat bands will not be drawn`** — the Bands run has no projections; rerun
  with `LORBIT=11`. The DOS panel still works from the DOS run.
- **Garbled or missing high-symmetry labels** — labels come from your line-mode
  `Bands/KPOINTS`; make sure every segment endpoint is labelled after `!`.
- **Wrong Fermi level** — E_F is read from `Scf/` (vasprun → OUTCAR), falling
  back to `Bands/` only if necessary; point `--root` at a run with a dense SCF.
- **`--method rgb` error with > 3 groups** — rgb encodes at most 3 channels;
  use `--method stacked` for more groups or narrow your `--projections`.
