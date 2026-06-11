# WolfPack-DFT Toolkit

A collection of helpers for running and analysing VASP calculations on SLURM clusters.
Install once with `./install.sh`: every script is exposed on `$PATH` via a
symlink in `~/.local/bin/`, so the commands work from any directory. Every
script supports `--help` / `-h`.

---

## Installation

```bash
git clone <this-repo> WolfPack-DFT   # or copy the folder onto your cluster
cd WolfPack-DFT
./install.sh                          # symlinks + conda env + cluster wizard
```

`install.sh`:

1. **Symlinks every command** into `~/.local/bin/` pointing back at this
   folder. The command name always matches the script (e.g. `vasp-clean` →
   `vasp_clean.sh`, `vasp-test` → `vasp_test.sh`, `vasp-recommend-slurm` →
   `vasp_recommend_slurm.py`). Scripts are *not* copied, so `git pull`
   updates every command at once — **don't delete this folder after installing.**
2. **Creates a conda environment** (`wolfpack-dft`) with every Python
   dependency the toolkit needs: `numpy`, `scipy`, `matplotlib`, `pymatgen`,
   plus the optional `glow` Markdown renderer used by `my-shortcuts`.
3. **Adds `~/.local/bin` to your `PATH`** (a small tagged block in `~/.bashrc`)
   if it isn't already there.
4. **Runs the cluster wizard** (`vasp-configure`) — see below.
5. **Writes a manifest** (`~/.local/share/wolfpack-dft/`) so the uninstaller
   can undo everything precisely.

Activate the environment before using the Python tools (`vasp-calculate-u`,
`build-supercell`, `vasp-plot-fatbandsdos`):

```bash
conda activate wolfpack-dft
```

Useful flags: `./install.sh --email me@uni.edu` (pre-fill email),
`--env NAME` (target env), `--bin-dir DIR`, `--no-conda` (symlinks only),
`--no-path`, `--no-configure` (skip the wizard), `-y` (no prompts; auto-detect
the cluster). See `./install.sh --help`.

### Cluster configuration (`vasp-configure`)

The toolkit is **not** wired to any one machine: a per-user *cluster profile*
(`~/.config/wolfpack-dft/cluster.conf`) tells the SLURM tools how your cluster
looks. `install.sh` runs the wizard for you; re-run it any time:

```bash
vasp-configure          # interactive wizard (detects + asks)
vasp-configure --show   # print the current profile
vasp-configure --edit   # hand-edit the profile in $EDITOR
```

> **A job died with `execve(): vasp_std: No such file or directory`?** That
> means the configured module line doesn't put `vasp_std` on `PATH` (a wrong or
> conflicting module — e.g. an Lmod *"cannot be loaded as requested"* error
> aborts the load, so VASP is never available). No reinstall needed:
>
> ```bash
> vasp-configure --verify   # loads your modules and reports exactly what fails
> vasp-configure            # re-pick a version — it now TEST-LOADS each choice
> vasp-configure --edit     # or fix the WP_VASP_MODULES line by hand
> ```
>
> The wizard now verifies every choice by actually loading it and checking that
> `vasp_std` appears, and when `module spider` lists several prerequisite
> combinations it tries each and keeps the first that works — so a conflicting
> set (like three different `gcc` versions) is rejected automatically.

It detects and lets you confirm/override:

- your **notification email** (used as `#SBATCH --mail-user`);
- the **VASP module(s)** to load — discovered from `module avail`/`spider`, so
  you **choose the version**, and its prerequisites are detected when possible;
- your **debug** and **main** partition names;
- **cores per node** and **memory per node** for each (from `sinfo`);
- the **maximum cores** you may request (from `sacctmgr`, else you set it).

Every value has a manual fallback if auto-detection isn't available. The result
flows into `vasp-recommend-slurm`, `vasp-dry-run` and `vasp-test`, so the SLURM
scripts they emit target **your** partitions and load **your** modules.

**No cluster? Install anyway.** The plotting and analysis tools
(`vasp-plot-fatbandsdos`, `vasp-quick-plots`, `vasp-check`, `build-supercell`,
`vasp-calculate-u`) need **no** cluster profile and no VASP install — only the
conda env. `install.sh` detects the absence of SLURM/modules and skips the
wizard, so you can install on a laptop and plot from copied calculation folders.

### Uninstallation

```bash
./uninstall.sh            # remove symlinks, the conda env, the PATH block,
                          # the manifest, and any legacy ~/Useful_scripts dir
./uninstall.sh -y         # same, no prompts
./uninstall.sh --keep-env # keep the conda environment
./uninstall.sh --purge-repo  # ALSO delete this toolkit folder
```

The uninstaller is nuclear but safe: it only removes the conda env if
`install.sh` created it, and it never deletes this source folder unless you
pass `--purge-repo`.

---

## Quick reference

| Command | Source script | What it does |
|---------|--------------|--------------|
| `vasp-configure` | `vasp_configure.sh` | Build your cluster profile (email, VASP modules, partitions, cores, memory, max-cores) |
| `vasp-dry-run` | `vasp_dry_run.sh` | **Pipeline STAGE 1** — 1-rank dry run on debug → memory table + starts `report.out` |
| `vasp-recommend-slurm` | `vasp_recommend_slurm.py` | **Pipeline STAGE 2** — read that OUTCAR → KPAR/NCORE + `slurm.sh` (80%-mem, multi-node split) |
| `vasp-test` | `vasp_test.sh` | **Pipeline STAGE 3** — 30-min benchmark of the *fixed* config → scale measured RAM to production → update `slurm.sh` |
| `vasp-check` | `vasp_check.sh` | Post-mortem sanity + physics analysis of any VASP run |
| `vasp-clean` | `vasp_clean.sh` | Selective cleanup of VASP output files (with dry-run) |
| `vasp-nuke` | `vasp_nuke.sh` | Fast no-questions-asked delete of all VASP output files |
| `run-nscf-steps` | `run_nscf_steps.sh` | Hubbard U workflow Step 1: submit NSCF perturbation jobs |
| `run-scf-steps` | `run_scf_steps.sh` | Hubbard U workflow Step 2: submit SCF perturbation jobs |
| `collect-u-data` | `collect_u_data.sh` | Hubbard U workflow Step 3: collect occupations → U_data.dat |
| `vasp-calculate-u` | `vasp_calculate_u.py` | Hubbard U workflow Step 4: linear fit → print U |
| `vasp-plot-fatbandsdos` | `vasp_plot_fatbandsdos.py` | Fat-band + projected DOS figure (pymatgen; `wolfpack_plot/` package) |
| `vasp-quick-plots` | `vasp_quick_plots.sh` | One figure per method (plain/one_orbital/duo/rgb/cmyk/stacked) into numbered `Plots/` sub-folders, projections auto-picked over an energy window |
| `build-supercell` | `build_supercell.py` | Build a plain VASP supercell from a POSCAR |
| `my-shortcuts` | `my_shortcuts.sh` | Print this README |

> Setup commands (run from this folder, not on `$PATH`): `./install.sh` and
> `./uninstall.sh` — see [Installation](#installation).

---

## 1. The parallelization pipeline (dry-run → recommend → test)

Three commands, run **in order, with no arguments and nothing to edit by hand**.
Each stage reads what the previous one left behind, so from a folder with just
`INCAR KPOINTS POSCAR POTCAR` you only ever type:

```bash
vasp-dry-run            # STAGE 1  (submit; wait for it to finish)
vasp-recommend-slurm    # STAGE 2  (instant, on the login node)
vasp-test               # STAGE 3  (submit; wait for it to finish)
```

When it's done the folder contains exactly:

```
INCAR  KPOINTS  POSCAR  POTCAR          # your inputs (untouched)
slurm_dryrun.sh  slurm_vasptest.sh      # the exact STAGE-1 / STAGE-3 jobs
slurm.sh                                # the production job, ready to sbatch
report.out                              # one tidy report from all 3 stages
```

Intermediates (the dry-run OUTCAR, pipeline state, SLURM logs) live in a hidden
`.wolfpack/` folder so your directory stays clean.

### STAGE 1 — `vasp-dry-run`

Renders a self-contained `slurm_dryrun.sh` (resolved `#SBATCH` + module loads
from your `vasp-configure` profile) and submits it. The job runs a 1-rank VASP
`--dry-run` inside `.wolfpack/`, captures VASP's memory table to
`.wolfpack/dryrun_OUTCAR`, and **starts `report.out`**.

```bash
vasp-dry-run            # writes ./slurm_dryrun.sh, submits it (~30 s of compute)
```

### STAGE 2 — `vasp-recommend-slurm`

With **no argument**, auto-finds `.wolfpack/dryrun_OUTCAR`. It enumerates
(KPAR, NCORE, NPAR) candidates, ranks them by the
[VASP-wiki parallelization rules](https://www.vasp.at/wiki/index.php/Category:Parallelization),
and writes the production job to **`slurm.sh`** with:

- the chosen **KPAR/NCORE/NSIM** embedded as comments (merge into your INCAR);
- a memory request sized to the **≥ 80 % utilisation** rule (see below);
- **automatic multi-node splitting** — if one node can't hold its ranks at that
  memory, the ranks are spread across more nodes so each node fits (the total
  rank count is unchanged).

It also appends its recommendation to `report.out` and saves the fixed config to
`.wolfpack/state.env` for STAGE 3.

```bash
vasp-recommend-slurm                    # auto-find OUTCAR -> ./slurm.sh + report.out
vasp-recommend-slurm dryrun_OUTCAR      # or pass an OUTCAR explicitly (manual use)
vasp-recommend-slurm --partition main --max-cores 256 --top 5
vasp-recommend-slurm --help             # full flag list
```

**Useful flags:** `--partition {main,debug,…}` · `--max-cores/--min-cores N` ·
`--mem-util F` (utilisation target, default `0.80`) ·
`--rss-overhead F` (VASP-table → real-RSS factor, default `1.4`) ·
`--calc-type {auto,dft,gw,gw-low,rpa-low}` · `--no-write` (print only).

> **Why the memory estimate here is only a starting point.** VASP's reported
> per-rank memory does **not** include FFT plans, MPI/UCX buffers, the
> scaLAPACK/ELPA workspace or the allocator high-water mark — real RSS is
> typically 1.4–3× larger (much more for GW/RPA). STAGE 2 multiplies by
> `--rss-overhead` and the 80 % rule to stay safe, but the **authoritative**
> memory comes from STAGE 3, which *measures* it.

### STAGE 3 — `vasp-test`

Reads the **fixed** config from STAGE 2 and benchmarks **that exact config** for
30 minutes — not your raw INCAR. The recommended rank count (e.g. 120) won't fit
on the debug partition, so it runs the same **KPAR/NCORE** at the largest rank
count that *does* fit (up to both debug nodes, 96 cores) at the maximum debug
memory (node RAM − 16 GB reserve). Then it:

1. reads the SLURM metrics (`MaxRSS`, CPU efficiency) of the fixed config;
2. **scales** the measured per-rank memory from the test rank count **up to the
   production rank count** (VASP component-distribution rules: wavefunctions
   ∝ 1/ranks, grid ∝ 1/NPAR, projectors ∝ 1/NCORE);
3. sizes the production memory to the **80 % rule** and **updates `slurm.sh` in
   place** (`--mem-per-cpu`, and `--nodes`/`--ntasks-per-node` if it must split);
4. prints a **VERDICT** on whether the recommended config is adequate and appends
   STAGE 3 to `report.out`.

```bash
vasp-test               # renders ./slurm_vasptest.sh, submits it, updates slurm.sh
# then, once you've merged KPAR/NCORE/NSIM into INCAR:
sbatch slurm.sh         # the real production job, with measured memory
```

**Cluster policies (defaults; override via env or the profile):**

- **Memory utilisation** — the request is sized so the job *uses* ≥ 80 % of what
  it asks for (`request = predicted_use / 0.80`): satisfies clusters that require
  high utilisation while keeping a ~20 % safety margin.
- **Debug/login reserve** — on the debug partition, **16 GB per node** is kept
  free so the (shared) login node stays responsive.

**Flags & tunables (export before running):**

| Variable | Default | Meaning |
|----------|---------|---------|
| `VASP_TEST_MINUTES` | `30` | length of the timed run (your debug walltime must allow it) |
| `VASP_TEST_MAX_CORES` | `2 × cores/node` | cap on debug ranks for the benchmark |
| `VASP_EXE` | `vasp_std` | `vasp_std` / `vasp_gam` / `vasp_ncl` |
| `VASP_TEST_MEM_UTIL` | `0.80` | request memory so usage ≥ this fraction |
| `VASP_TEST_DEBUG_MARGIN_MB` | `16384` | memory kept free per debug/login node |

The debug/main partitions, cores/node, memory/node, modules and email all come
from your `vasp-configure` profile (`vasp-configure --show` to check). The 80 %
target and RSS-overhead factor can be pinned in the profile as `WP_MEM_UTIL` and
`WP_RSS_OVERHEAD`.

> Requires SLURM job accounting (`sacct`/`MaxRSS`) so memory can be anchored to
> the measured peak. If it is off, it falls back to VASP's own memory table.

---

## 2. VASP run analysis

### `vasp-check`

Post-mortem analysis of a finished or killed VASP run. Detects the calculation
type automatically and runs 10 diagnostic sections:

1. File inventory
2. Run metadata (calc type, XC layer, INCAR tags)
3. Termination (normal / OOM / walltime / crash)
4. Data completeness / plottability verdict
5. Electronic SCF convergence
6. Ionic convergence and forces (relaxations)
7. Cell, volume and stress
8. Magnetization
9. Eigenvalues, gap, VBM/CBM, occupied bands, GW QP table
10. Pitfalls and recommendations

```bash
vasp-check              # analyse the current directory
vasp-check path/to/calc # analyse a specific directory
vasp-check --help
```

Exit codes: `0` = PASS, `1` = at least one FAIL, `2` = usage error.

---

## 3. Cleanup

### `vasp-clean` (preferred)

Smart cleanup with dry-run support, recursive mode, per-file size reporting,
and confirmation prompt before deleting.

```bash
vasp-clean                    # show what would be removed, then prompt
vasp-clean -n .               # dry-run: show without deleting
vasp-clean -r ./relax_runs    # recurse into all VASP sub-folders
vasp-clean -a -f calc1 calc2  # aggressive mode, no prompt
vasp-clean --help
```

**Removed by default:** WAVECAR CHG TMPCAR PCDAT WAVEDER STOPCAR REPORT HILLSPOT  
**Added with `-a`:** CHGCAR LOCPOT ELFCAR PROCAR DOSCAR EIGENVAL XDATCAR  
**Always kept:** INCAR POSCAR CONTCAR KPOINTS POTCAR OUTCAR OSZICAR vasprun.xml

### `vasp-nuke`

Fast, no-questions-asked delete — every VASP output file in one `rm` call.
Use `vasp-clean -n` first if you want to see what will be deleted.

```bash
vasp-nuke               # nuke current directory
vasp-nuke path/to/calc  # nuke a specific directory
```

---

## 4. Linear-response Hubbard U workflow

Four scripts that together implement the Cococcioni & de Gironcoli (PRB 2005)
linear-response U calculation. Run them **in order**:

```
Step 1: run-nscf-steps   →   Step 2: run-scf-steps
                                        ↓
Step 4: vasp-calculate-u      ←   Step 3: collect-u-data
```

### Setup (once per system)

```
working_dir/
    01_Groundstate/         converged DFT ground state (CHGCAR, WAVECAR,
                            POSCAR, POTCAR, KPOINTS). The perturbed atom
                            must be its own species in POSCAR/POTCAR.
    INCAR.nscf.template     base INCAR for NSCF runs (must have ICHARG=11;
                            must NOT set LDAUL/LDAUU/LDAUJ)
    INCAR.scf.template      base INCAR for SCF runs (no ICHARG=11 line)
    model_job.sh            SLURM template with #SBATCH -J/-o/-e lines
```

### Step 1 — `run-nscf-steps`

Submits one NSCF job per α value. Already-complete runs are skipped.

```bash
run-nscf-steps --ldaul "2 -1 -1" \
               --ldauu-template "{alpha} 0 0" \
               --ldauj-template "{alpha} 0 0"
# monitor: squeue -u $USER
```

### Step 2 — `run-scf-steps`

Same syntax as Step 1. Run after **all** NSCF jobs have finished. Use
`--lenient` if jobs were OOM-killed after reaching EDIFF.

```bash
run-scf-steps --ldaul "2 -1 -1" \
              --ldauu-template "{alpha} 0 0" \
              --ldauj-template "{alpha} 0 0"
```

### Step 3 — `collect-u-data`

Reads d- or f-electron occupations from all OUTCARs and writes `U_data.dat`.
Requires `LORBIT=11` in every INCAR.

```bash
collect-u-data                   # defaults: site=1, orbital=d
collect-u-data --site 2          # perturbed atom is POSCAR index 2
collect-u-data --orbital f       # use f-electron column
collect-u-data --lenient         # accept OOM-killed but converged runs
```

### Step 4 — `vasp-calculate-u`

Reads `U_data.dat`, fits χ₀ = d(dN_NSCF)/dα and χ = d(dN_SCF)/dα, and prints:

```
U = 1/χ - 1/χ₀
```

```bash
python vasp-calculate-u        # or: python vasp_calculate_u.py
```

---

## 5. Fat-band + projected DOS plot

### `vasp-plot-fatbandsdos`

Produces publication-quality fat-band + DOS figures. A **very thin, very pale
grey backbone** traces every band in the background of *every* method; coloured
markers (opacity = weight) sit on top, and the DOS shares the energy axis. See
[PlotReadme.md](PlotReadme.md) for the full reference. The implementation lives
in the `wolfpack_plot/` package; `vasp_plot_fatbandsdos.py` is the stable master
entry point (the command and `from vasp_plot_fatbandsdos import generate` both
keep working).

**`--method` is REQUIRED.**

```bash
# discover species, atom tokens, and available orbitals first:
vasp-plot-fatbandsdos --root . --list

# then plot (choose a method):
vasp-plot-fatbandsdos --root . --method rgb \
    --projections "(Cu-d),(V-d),(S-p)" \
    --title "CuVS_3 - G_0W_0"
```

| Method | Groups | Description |
|--------|--------|-------------|
| `plain` | 0 | no projection: pale backbone + a small **solid black circle at every k-point** |
| `one_orbital` | exactly 1 | **pure-blue** circles; opacity = w_group / w_total |
| `duo` | exactly 2 | two-colour gradient; opacity = total weight |
| `rgb` | 1–3 | additive colour: R/G/B channels; opacity = total weight |
| `cmyk` | exactly 4 | subtractive **CMYK** mix (C/M/Y/K); opacity = total weight |
| `stacked` | any | sumo-style circles; area ∝ weight² |

For **ISPIN=2**, `--spin up`/`down` draws that channel with the standard circles
(no cyan/magenta edges any more), and `--spin both` writes the spin-up plot, the
spin-down plot, **and** a dedicated overlaid plain plot (spin-up blue / spin-down
orange over dashed per-spin backbones). See [PlotReadme.md](PlotReadme.md) §6.

**Auto-pick projections over an energy window** — instead of `--projections`,
let the tool rank the `(element, dominant-l)` characters by their projected-DOS
contribution inside `[--emin, --emax]` and take the top *N* (falling back to
inequivalent Wyckoff sites `Pt1-d, Pt2-d, …` when there are too few elements):

```bash
vasp-plot-fatbandsdos --root . --method one_orbital --auto-projections 1 \
    --emin -3 --emax 3 --name homo_character
```

`--name` sets the output base filename under `Plots/`.

### `vasp-quick-plots`

One figure per method in a single command, with projections auto-picked over the
energy window (`one_orbital`→1, `duo`→2, `rgb`→3, `cmyk`→4, `stacked`→5 units),
each written into its own numbered sub-folder of `Plots/`. Needs the conda env
active.

```bash
conda activate wolfpack-dft
vasp-quick-plots --emin -6 --emax 6 --title "CuVS_3"
# writes Plots/{0_Plain,1_ONE,2_DUO,3_RGB,4_CMYK,5_Stacked}/

vasp-quick-plots --methods plain,rgb,cmyk          # a subset
vasp-quick-plots --stacked-n 6                      # 6 units in the stacked plot
```

With `--spin both`, every folder gets `_up` and `_down` plots and `0_Plain` also
gets the blue/orange overlaid plain plot; `--spin up`/`down` gives one per folder.

The contribution ranking is computed by integrating the projected DOS over the
window (a proper states integral, summed over spin), so it is a faithful,
reproducible measure of which orbitals dominate the chosen energy range.

---

## 6. Supercell builder

### `build-supercell`

Reads a VASP POSCAR, applies an integer scaling (diagonal `na nb nc` or full
3×3 matrix), and writes the supercell to a new POSCAR. Preserves selective
dynamics and velocities. No defects or dopants.

```bash
build-supercell POSCAR                        # default 2×2×2
build-supercell POSCAR -s 3 3 1               # 3×3×1 slab
build-supercell POSCAR -s 2 2 2 --sort        # also sort by electronegativity
build-supercell POSCAR -s -1 1 1  1 -1 1  1 1 -1 -o POSCAR_conv
                                              # primitive FCC → conventional
build-supercell --help
```

---

## 7. Utilities

### `my-shortcuts`

Prints this README from any directory. Uses `glow` for rendered Markdown if
available, falls back to `cat`.

```bash
my-shortcuts           # print (rendered if glow is installed)
my-shortcuts | less    # paginate
```

---

## Typical end-to-end flows

### New calculation (the parallelization pipeline)
```bash
vasp-configure                            # once: set up your cluster profile
# from a folder with INCAR KPOINTS POSCAR POTCAR — no arguments, nothing to edit:
vasp-dry-run                              # STAGE 1  (wait for it to finish)
vasp-recommend-slurm                      # STAGE 2  → slurm.sh + report.out
vasp-test                                 # STAGE 3  → measured memory in slurm.sh
# merge the KPAR/NCORE/NSIM shown in report.out into your INCAR, then:
sbatch slurm.sh                           # the production job, with measured memory
vasp-check                                # → sanity-check the result
vasp-clean -f .                           # → clean up
```

### Linear-response Hubbard U
```bash
# 1. Prepare 01_Groundstate/, INCAR templates, model_job.sh
run-nscf-steps --ldaul "2 -1" --ldauu-template "{alpha} 0" --ldauj-template "{alpha} 0"
# (wait for NSCF jobs)
run-scf-steps  --ldaul "2 -1" --ldauu-template "{alpha} 0" --ldauj-template "{alpha} 0"
# (wait for SCF jobs)
collect-u-data --site 1 --orbital d
python vasp-calculate-u                        # prints U
```

### Fat-band + DOS figure
```bash
# Folder layout: root/Scf/ root/Bands/ root/Dos/ (all with vasprun.xml)
vasp-plot-fatbandsdos --root . --list
vasp-plot-fatbandsdos --root . --method rgb \
    --projections "(Cu-d),(V-d),(S-p)" --title "CuVS_3"
# output: Plots/fatbands_dos.png and .pdf
```
