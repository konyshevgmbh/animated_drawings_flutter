// ─── ARAP solver selector ────────────────────────────────────────────────────
// Switch implementations by toggling which export is active.
// Both expose the same ArapSolver class with identical API.

export 'arap_solver_ldlt.dart'; // sparse LDL^T — fast init, exact solve
// export 'arap_solver_pcg.dart'; // PCG + Jacobi + warm-start — simpler
