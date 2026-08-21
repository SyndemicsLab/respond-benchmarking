#!/usr/bin/env python3

################################################################################
# File: run_model_with_cohorts.py                                              #
# Project: scripts                                                             #
# Created Date: 2026-05-28                                                     #
# Author: Matthew Carroll                                                      #
# -----                                                                        #
# Last Modified: 2026-05-28                                                    #
# Modified By: Matthew Carroll                                                 #
# -----                                                                        #
# Copyright (c) 2026 Your Company                                              #
################################################################################

from pathlib import Path

import polars as pl

from respondpy import Simulation, build_simulation


def _write_histories(sim: Simulation, out_dir: Path) -> None:
    """Write each model's densified state histories to CSV files."""
    histories = sim.get_model_histories()
    for model_name, model_hist in histories.items():
        rows: list[dict] = []
        for hist_name, state_vectors in model_hist.items():
            for t, vec in enumerate(state_vectors):
                row = {"history_name": hist_name, "timestep": t}
                row.update({f"state_{i}": float(v) for i, v in enumerate(vec)})
                rows.append(row)
        if rows:
            pl.DataFrame(rows).write_csv(
                out_dir / f"{model_name}_histories.csv"
            )


def main():
    # Build Simulation
    sim = build_simulation(cohort_ids, db_path, cfg)
    sim.run()
