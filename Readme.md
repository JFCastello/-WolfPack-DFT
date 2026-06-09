# WolfPack-DFT Toolkit

A personal collection of helpers for VASP calculations on NLHPC (Chilean HPC).
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
| `vasp-dry-run` | `vasp_dry_run.sh` | Submit a 1-rank VASP dry run to your debug partition |
| `vasp-test` | `vasp_test.sh` | 11-min debug benchmark → measured RAM/efficiency → calibrated main-partition INCAR + SLURM script |
| `vasp-recommend-slurm` | `vasp_recommend_slurm.py` | Read dry-run OUTCAR → suggest KPAR/NCORE + SLURM script |
| `vasp-check` | `vasp_check.sh` | Post-mortem sanity + physics analysis of any VASP run |
| `vasp-clean` | `vasp_clean.sh` | Selective cleanup of VASP output files (with dry-run) |
| `vasp-nuke` | `vasp_nuke.sh` | Fast no-questions-asked delete of all VASP output files |
| `run-nscf-steps` | `run_nscf_steps.sh` | Hubbard U workflow Step 1: submit NSCF perturbation jobs |
| `run-scf-steps` | `run_scf_steps.sh` | Hubbard U workflow Step 2: submit SCF perturbation jobs |
| `collect-u-data` | `collect_u_data.sh` | Hubbard U workflow Step 3: collect occupations → U_data.dat |
| `vasp-calculate-u` | `vasp_calculate_u.py` | Hubbard U workflow Step 4: linear fit → print U |
| `vasp-plot-fatbandsdos` | `vasp_plot_fatbandsdos.py` | Fat-band + projected DOS figure (pymatgen; `wolfpack_plot/` package) |
| `vasp-quick-plots` | `vasp_quick_plots.sh` | One figure per method (plain/one_orbital/duo/rgb/stacked), projections auto-picked over an energy window |
| `build-supercell` | `build_supercell.py` | Build a plain VASP supercell from a POSCAR |
| `my-shortcuts` | `my_shortcuts.sh` | Print this README |

> Setup commands (run from this folder, not on `$PATH`): `./install.sh` and
> `./uninstall.sh` — see [Installation](#installation).

---

## 1. Dry-run + parallelization workflow

Two paths to a tuned INCAR + SLURM script. Both end in `vasp-recommend-slurm`:

- **Fast / cheap (`vasp-dry-run` → `vasp-recommend-slurm`):** a ~30 s 1-rank dry run
  predicts memory from VASP's own table. No real timing.
- **Calibrated (`vasp-test`):** an 11-min real benchmark on one debug node that
  *measures* peak RAM and parallel efficiency, then calibrates the recommender
  with the measured numbers. Use this when you want the production memory ask
  grounded in reality. See [section 1b](#1b-calibrated-benchmark-vasp-test).

### Step 1: `vasp-dry-run`

Runs a 1-rank VASP `--dry-run` on your **debug** partition (name, modules and
email from your `vasp-configure` profile) to write a memory table to the OUTCAR
without doing any SCF steps. It first **renders a self-contained `slurm_dryrun.sh`**
(resolved `#SBATCH` lines + module loads + the `srun` baked in) into the current
directory, then submits *that* — so the exact job is on disk for inspection even
if it fails.

```bash
# from a directory with valid INCAR, POSCAR, POTCAR, KPOINTS:
vasp-dry-run                  # writes ./slurm_dryrun.sh and submits it (~30 s)
```

### Step 2: `vasp-recommend-slurm`

Reads the dry-run OUTCAR, enumerates (KPAR, NCORE, NPAR) candidates, ranks
them by the VASP-wiki scoring rules and per-rank memory prediction, prints the
recommendation, and **writes it to disk** so the exact job you submit is always
recoverable: `slurm_job.sh` (the SLURM script) and `INCAR.parallel` (the
KPAR/NCORE/NSIM snippet) in the current directory.

```bash
vasp-recommend-slurm dryrun_OUTCAR          # -> ./slurm_job.sh + ./INCAR.parallel
sbatch slurm_job.sh                         # submit the recommended job
vasp-recommend-slurm dryrun_OUTCAR --partition main --max-cores 256 --top 5
vasp-recommend-slurm dryrun_OUTCAR --no-write   # only print, write nothing
vasp-recommend-slurm --help                 # full flag list
```

**Useful flags:**
- `--partition {main,debug,general,largemem}` — default `main`
- `--max-cores N` / `--min-cores N` — rank-count search range
- `--mem-headroom F` — safety multiplier (default 1.15)
- `--write-slurm FILE` / `--write-incar FILE` — output paths (default
  `slurm_job.sh` / `INCAR.parallel`); `--no-write` to disable
- `--calc-type {auto,dft,gw,gw-low,rpa-low}` — override auto-detection
- `--gw-ref-encutgw EV` — anchor for GW memory scaling

---

## 1b. Calibrated benchmark: `vasp-test`

A one-shot alternative to the dry-run path that **measures** real resource use
instead of predicting it. Submit it from a calculation directory:

```bash
# from a directory with valid INCAR, POSCAR, POTCAR, KPOINTS:
vasp-test                      # renders ./slurm_vasptest.sh, submits it, advises
```

Like `vasp-dry-run`, it first writes a self-contained **`slurm_vasptest.sh`**
(resolved `#SBATCH` + module loads) and submits that, so the *benchmark* job
that ran is on disk too — separate from the **`slurm_job.sh`** it writes at the
end (the recommended *production* job).

What it does, all in one SLURM job on **one debug node (48 cores, 360 GB)**:

1. Copies your inputs into an isolated `vasp_test_<jobid>/` folder (your
   existing OUTCAR/WAVECAR/etc. are never touched) and runs **real VASP** with
   your current INCAR parallel settings for `VASP_TEST_MINUTES` (default 11).
2. Reads the **SLURM accounting metrics** (`MaxRSS` per rank, CPU efficiency)
   and the OUTCAR (per-SCF-step wall time, VASP's own memory table).
3. **Calibrates** `vasp-recommend-slurm`'s memory model with the measured `MaxRSS`
   (correction factor → `--mem-headroom`), so the production memory ask matches
   what the job really used.
4. Prints, ready to copy-paste, an **INCAR snippet** (`KPAR` / `NCORE` / `NSIM`)
   and a **`main`-partition SLURM script** tuned for this exact job, and **writes
   them to your submit directory** as `slurm_job.sh` and `INCAR.parallel`
   (so the exact production job is on disk — just `sbatch slurm_job.sh`).

The report and copy-paste blocks also land in the job's `vasp_test-<jobid>.out`.

**Tunables** (export before `sbatch`, or pass with `--export`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `VASP_TEST_MINUTES` | `11` | length of the timed run (≤ ~25 on debug) |
| `VASP_EXE` | `vasp_std` | `vasp_std` / `vasp_gam` / `vasp_ncl` |
| `VASP_TEST_EMAIL` | your email | email written into the emitted script |
| `VASP_TEST_JOBNAME` | `VASP` | `--job-name` written into the emitted script |

The debug partition, cores/node, memory/node and email come from your
`vasp-configure` profile (run `vasp-configure --show` to check them).

> Requires SLURM job accounting (`sacct`/`MaxRSS`) for the calibration step.
> If it is off, `vasp-test` still recommends a layout from VASP's own memory
> table — it just can't ground it in measured RAM.

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
| `stacked` | any | sumo-style circles; area ∝ weight² |

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
energy window (`plain` → `one_orbital` Cu-d → `duo` top-2 → `rgb` top-3 →
`stacked` top-4). Needs the conda env active.

```bash
conda activate wolfpack-dft
vasp-quick-plots --emin -6 --emax 6 --title "CuVS_3"
# writes Plots/{plain,one_orbital,duo,rgb,stacked}.{png,pdf}

vasp-quick-plots --methods plain,one_orbital,rgb   # a subset
vasp-quick-plots --stacked-n 5                     # 5 units in the stacked plot
```

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

### New calculation (fast path)
```bash
vasp-configure                            # once: set up your cluster profile
vasp-dry-run                              # → produces dryrun_OUTCAR
vasp-recommend-slurm dryrun_OUTCAR        # → tuned INCAR + SLURM script
# submit and run the production calculation
vasp-check                                # → sanity-check the result
vasp-clean -n .                           # → preview what to remove
vasp-clean -f .                           # → clean up (no prompt)
```

### New calculation (calibrated path)
```bash
vasp-test                                 # → 11-min benchmark; the .out file
                                          #   holds a measured INCAR + SLURM
                                          #   script for the main partition
# copy the [INCAR SNIPPET] + [SLURM SCRIPT] from vasp_test-<jobid>.out, submit
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
