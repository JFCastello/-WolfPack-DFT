#!/usr/bin/env python3
"""
vasp_calculate_u.py  (invoked on PATH as: vasp-calculate-u)
              --  Stage 4 of 4: Cococcioni linear-response Hubbard U
====================================================================
Reads U_data.dat (written by collect_u_data.sh) and computes the
effective Hubbard U parameter by a linear fit of the response functions:

    chi_0 = d(dN_NSCF) / d(alpha)   (non-self-consistent response slope)
    chi   = d(dN_SCF)  / d(alpha)   (self-consistent response slope)
    U     = 1/chi - 1/chi_0         (Cococcioni & de Gironcoli, PRB 2005)

INPUT
    U_data.dat  --  must be in the current working directory.
                    Columns: alpha(eV)  N_NSCF  N_SCF  dN_NSCF  dN_SCF
                    where dN = N(alpha) - N_GS (occupation change from
                    ground state). This file is produced by collect_u_data.sh.

USAGE
    cd <your_U_calculation_directory>
    python vasp_calculate_u.py

OUTPUT
    Prints one line:  U = X.XXX eV

WORKFLOW  (4-step Cococcioni linear-response U on NLHPC)
    Step 1:  run_nscf_steps.sh  --  submit NSCF perturbation jobs
    Step 2:  run_scf_steps.sh   --  submit SCF response jobs
    Step 3:  collect_u_data.sh  --  gather d/f-occupations into U_data.dat
    Step 4:  vasp_calculate_u.py       --  linear fit -> U           <-- THIS STEP

NOTES
    - The fit uses numpy.polyfit (degree 1) with a free intercept, which
      is more honest than forcing the line through zero for finite grids.
    - Columns 2 and 3 of U_data.dat (N_NSCF and N_SCF averages) are read
      but not used here; only columns 4 and 5 (dN_NSCF, dN_SCF) matter.
    - Reference: Cococcioni & de Gironcoli, Phys. Rev. B 71, 035105 (2005).
"""

import numpy as np
alpha, _, _, dN_nscf, dN_scf = np.loadtxt("U_data.dat", unpack=True)
chi0 = np.polyfit(alpha, dN_nscf, 1)[0]
chi  = np.polyfit(alpha, dN_scf,  1)[0]
print(f"U = {1/chi - 1/chi0:.3f} eV")
