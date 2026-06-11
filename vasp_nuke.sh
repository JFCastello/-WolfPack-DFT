#!/bin/bash
###############################################################################
# vasp_nuke.sh
#
# Delete ALL VASP output files from a directory; leave inputs untouched.
# This is a fast, no-questions-asked nuke intended for cleaning up before a
# rerun. For a safer, selective cleanup with dry-run, recursive mode, and
# per-file size reporting, use vasp-clean instead.
#
# FILES REMOVED
#   CHG  CHGCAR  CONTCAR  DOSCAR  EIGENVAL  IBZKPT  OSZICAR  OUTCAR
#   PCDAT  PROCAR  REPORT  vasprun.xml  WAVECAR  XDATCAR  WAVEDER
#   vaspout.h5  LOCPOT  ELFCAR  PROOUT  TMPCAR  HILLSPOT  PENALTYPOT
#   CHGCAR.tmp  WAVECAR.tmp   .wolfpack/ (hidden pipeline scratch + state)
#
# FILES PRESERVED
#   INCAR  POSCAR  POTCAR  KPOINTS  and everything else not listed above.
#
# USAGE
#   vasp-nuke                  # clean the current directory
#   vasp-nuke path/to/calc     # clean a specific directory
#
# SEE ALSO
#   vasp-clean  -- smarter cleanup: safe defaults, --dry-run, --recursive,
#                  --aggressive mode, per-file size report, confirmation prompt
###############################################################################

dir="${1:-.}"

cd "$dir" || exit 1

rm -f CHG CHGCAR CONTCAR DOSCAR EIGENVAL IBZKPT OSZICAR OUTCAR \
      PCDAT PROCAR REPORT vasprun.xml WAVECAR XDATCAR WAVEDER \
      vaspout.h5 LOCPOT ELFCAR PROOUT TMPCAR HILLSPOT PENALTYPOT \
      CHGCAR.tmp WAVECAR.tmp
rm -rf .wolfpack          # hidden pipeline scratch/state + old SLURM logs

echo "VASP output files removed from $dir."
