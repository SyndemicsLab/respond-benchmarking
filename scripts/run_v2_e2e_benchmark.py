#!/usr/bin/env python3
"""End-to-end workflow-throughput benchmark for RESPONDv2 via respondpy.

Objective:
    Report user workflow throughput (process launch -> process exit), where
    v2 runs all requested samples/cohorts in a single process invocation.

Design choices:
    - Strict parity lock: interventions=13 and behaviors=4.
    - User supplies input DB and config paths (no internal DB/config generation).
    - Combined timing is measured by a parent harness that launches subprocesses,
      so startup/import/teardown are included in the measured wall-clock.

Usage:
    DB_PATH=/path/to/input.db CONF_PATH=/path/to/config.conf \
    OUT_CSV=data/v2_e2e_runtime.csv \
    WARMUP=3 REPETITIONS=3 SAMPLE_SIZES="1 5 10 25 50" STEPS=52 \
    uv run python scripts/run_v2_e2e_benchmark.py
"""

from __future__ import annotations

import csv
import json
import math
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from respondpy import Simulation, build_simulation
from respondpy.data import Input

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

OUT_CSV = Path(
    os.getenv(
        "OUT_CSV",
        "/home/matt/Repos/RESPOND/respond-benchmarking/data/v2_e2e_runtime.csv",
    )
)

DB_PATH = Path(os.getenv("DB_PATH", "")).expanduser()
CONF_PATH = Path(os.getenv("CONF_PATH", "")).expanduser()

WARMUP = int(os.getenv("WARMUP", "3"))
REPETITIONS = int(os.getenv("REPETITIONS", "3"))
SAMPLE_SIZES = [
    int(x)
    for x in os.getenv("SAMPLE_SIZES", "1 5 10 25 50").split()
]
DURATION = int(os.getenv("STEPS", "52"))

# Strict parity lock for trustworthiness.
N_INTERVENTIONS = int(os.getenv("N_INTERVENTIONS", "13"))
N_BEHAVIORS = int(os.getenv("N_BEHAVIORS", "4"))
STRICT_PARITY = int(os.getenv("STRICT_PARITY", "1"))


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

def _require_paths() -> None:
    if not DB_PATH:
        raise ValueError("DB_PATH is required and must point to a SQLite DB file.")
    if not CONF_PATH:
        raise ValueError("CONF_PATH is required and must point to a config file.")
    if not DB_PATH.exists():
        raise FileNotFoundError(f"DB_PATH does not exist: {DB_PATH}")
    if not CONF_PATH.exists():
        raise FileNotFoundError(f"CONF_PATH does not exist: {CONF_PATH}")


def _validate_requested_parity() -> None:
    if STRICT_PARITY != 1:
        raise ValueError(
            "STRICT_PARITY must be 1 for this benchmark policy."
        )
    if N_INTERVENTIONS != 13 or N_BEHAVIORS != 4:
        raise ValueError(
            "Parity lock requires N_INTERVENTIONS=13 and N_BEHAVIORS=4."
        )


def _validate_db_parity(db_path: Path) -> None:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("SELECT COUNT(*) FROM intervention")
    interventions = int(cur.fetchone()[0])
    cur.execute("SELECT COUNT(*) FROM behavior")
    behaviors = int(cur.fetchone()[0])
    con.close()

    if interventions != N_INTERVENTIONS or behaviors != N_BEHAVIORS:
        raise ValueError(
            "DB parity mismatch: expected "
            f"interventions={N_INTERVENTIONS}, behaviors={N_BEHAVIORS}; got "
            f"interventions={interventions}, behaviors={behaviors}."
        )


def _cohort_ids_for_n(db_path: Path, n: int) -> list[int]:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("SELECT id FROM cohort ORDER BY id LIMIT ?", (n,))
    ids = [int(row[0]) for row in cur.fetchall()]
    con.close()

    if len(ids) != n:
        raise ValueError(
            f"DB has insufficient cohorts for sample_size={n}: found {len(ids)}"
        )
    return ids


# ---------------------------------------------------------------------------
# Simulation internals
# ---------------------------------------------------------------------------

def _build_simulation(input_data: Input, cohort_ids: list[int]) -> Simulation:
    return build_simulation(input_data, cohort_ids=cohort_ids)


def _write_histories(sim: Simulation, out_dir: Path) -> None:
    """Write each model's densified state histories to CSV files."""
    import polars as pl

    for model_index, model_name in enumerate(sim.get_model_names()):
        model_hist = sim.get_model_history(model_index)
        rows: list[dict] = []
        for hist_name, history in model_hist.items():
            for t, vec in zip(
                history.get_recorded_timesteps(),
                history.get_recorded_states(),
            ):
                row = {"history_name": hist_name, "timestep": t}
                row.update({f"state_{i}": float(v) for i, v in enumerate(vec)})
                rows.append(row)
        if rows:
            pl.DataFrame(rows).write_csv(out_dir / f"{model_name}_histories.csv")


def _checksum(sim: Simulation) -> float:
    return sum(
        float(value)
        for model_index in range(len(sim.get_models()))
        for history in sim.get_model_history(model_index).values()
        for state in history.get_recorded_states()
        for value in state
    )


def _run_single_job(sample_size: int, write_dir: Path) -> dict[str, float]:
    """Run one v2 job in-process and return phase timings.

    This worker is called in a separate process by the harness; therefore,
    process-level timing is captured by the parent and phase timing here remains
    diagnostic.
    """
    input_data = Input(db_path=DB_PATH, conf_path=CONF_PATH)
    cohort_ids = _cohort_ids_for_n(DB_PATH, sample_size)

    t0 = time.perf_counter()
    sim = _build_simulation(input_data, cohort_ids)
    load_ms = (time.perf_counter() - t0) * 1000

    t0 = time.perf_counter()
    sim.run()
    run_ms = (time.perf_counter() - t0) * 1000

    checksum = _checksum(sim)

    t0 = time.perf_counter()
    _write_histories(sim, write_dir)
    write_ms = (time.perf_counter() - t0) * 1000

    return {
        "load_ms": load_ms,
        "run_ms": run_ms,
        "write_ms": write_ms,
        "checksum": checksum,
    }


# ---------------------------------------------------------------------------
# Stats/row formatting
# ---------------------------------------------------------------------------

def _stats(times_ms: list[float]) -> dict[str, float]:
    n = len(times_ms)
    s = sorted(times_ms)
    p95_idx = max(0, math.ceil(0.95 * n) - 1)
    mean = sum(s) / n
    variance = sum((x - mean) ** 2 for x in s) / max(n - 1, 1)
    return {
        "mean_ms": mean,
        "p50_ms": s[n // 2],
        "p95_ms": s[p95_idx],
        "min_ms": s[0],
        "max_ms": s[-1],
        "std_ms": math.sqrt(variance),
    }


def _phase_row(
    model: str,
    scope: str,
    phase: str,
    sample_size: int,
    times_ms: list[float],
    checksum: float,
) -> list[str | int]:
    st = _stats(times_ms)
    mean_sample_ms = st["mean_ms"] / sample_size
    ns_per_step_per_sample = mean_sample_ms * 1e6 / DURATION
    return [
        model,
        scope,
        phase,
        sample_size,
        f"{st['mean_ms']:.6f}",
        f"{st['p50_ms']:.6f}",
        f"{st['p95_ms']:.6f}",
        f"{st['min_ms']:.6f}",
        f"{st['max_ms']:.6f}",
        f"{st['std_ms']:.6f}",
        f"{mean_sample_ms:.6f}",
        f"{ns_per_step_per_sample:.2f}",
        f"{checksum:.6f}",
        N_INTERVENTIONS,
        1,
        1,
        N_BEHAVIORS,
        DURATION,
        WARMUP,
        REPETITIONS,
    ]


# ---------------------------------------------------------------------------
# Parent harness (process launch -> exit timing)
# ---------------------------------------------------------------------------

def _run_worker_subprocess(sample_size: int, write_dir: Path) -> tuple[float, dict[str, float]]:
    """Launch worker subprocess and capture full process wall-clock."""
    env = os.environ.copy()
    env["V2_E2E_WORKER"] = "1"
    env["SAMPLE_SIZE"] = str(sample_size)
    env["WRITE_DIR"] = str(write_dir)

    t0 = time.perf_counter()
    proc = subprocess.run(
        [sys.executable, __file__],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        check=False,
    )
    wall_ms = (time.perf_counter() - t0) * 1000

    if proc.returncode != 0:
        raise RuntimeError(
            "v2 worker subprocess failed.\n"
            f"exit_code={proc.returncode}\n"
            f"stdout:\n{proc.stdout}\n"
            f"stderr:\n{proc.stderr}"
        )

    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("Worker produced no stdout payload.")

    payload = json.loads(lines[-1])
    return wall_ms, {
        "load_ms": float(payload["load_ms"]),
        "run_ms": float(payload["run_ms"]),
        "write_ms": float(payload["write_ms"]),
        "checksum": float(payload["checksum"]),
    }


def _worker_entrypoint() -> None:
    _require_paths()
    _validate_requested_parity()
    _validate_db_parity(DB_PATH)

    sample_size = int(os.getenv("SAMPLE_SIZE", "0"))
    if sample_size < 1:
        raise ValueError("SAMPLE_SIZE must be >= 1 in worker mode.")

    write_dir = Path(os.getenv("WRITE_DIR", "")).expanduser()
    if not write_dir:
        raise ValueError("WRITE_DIR is required in worker mode.")
    write_dir.mkdir(parents=True, exist_ok=True)

    payload = _run_single_job(sample_size=sample_size, write_dir=write_dir)
    print(json.dumps(payload), flush=True)


def _parent_entrypoint() -> None:
    _require_paths()
    _validate_requested_parity()
    _validate_db_parity(DB_PATH)

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)

    header = [
        "model",
        "scope",
        "phase",
        "sample_size",
        "mean_job_ms",
        "p50_job_ms",
        "p95_job_ms",
        "min_job_ms",
        "max_job_ms",
        "std_job_ms",
        "mean_sample_ms",
        "ns_per_step_per_sample",
        "checksum",
        "interventions",
        "age_brackets",
        "genders",
        "oud_behaviors",
        "steps",
        "warmup",
        "repetitions",
    ]

    with OUT_CSV.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(header)

        for n in SAMPLE_SIZES:
            print(f"v2 throughput benchmark: sample_size={n}", flush=True)
            sample_write_root = Path(tempfile.mkdtemp(prefix=f"v2_e2e_write_{n}_"))

            # Cold-start: first user-visible run (includes process startup+shutdown).
            cold_write_dir = sample_write_root / "cold_start"
            cold_wall_ms, cold_payload = _run_worker_subprocess(n, cold_write_dir)

            writer.writerow(
                _phase_row("v2", "cold_start", "combined", n, [cold_wall_ms], cold_payload["checksum"])
            )
            writer.writerow(
                _phase_row("v2", "cold_start", "load", n, [cold_payload["load_ms"]], cold_payload["checksum"])
            )
            writer.writerow(
                _phase_row("v2", "cold_start", "run", n, [cold_payload["run_ms"]], cold_payload["checksum"])
            )
            writer.writerow(
                _phase_row("v2", "cold_start", "write", n, [cold_payload["write_ms"]], cold_payload["checksum"])
            )

            # Warmup runs (not measured), matching v1 behavior of warmup before steady-state reps.
            for warm_idx in range(WARMUP):
                warm_write_dir = sample_write_root / f"warmup_{warm_idx + 1}"
                _run_worker_subprocess(n, warm_write_dir)

            combined_ms: list[float] = []
            load_ms: list[float] = []
            run_ms: list[float] = []
            write_ms: list[float] = []
            checksum = float("nan")

            for rep_idx in range(REPETITIONS):
                rep_write_dir = sample_write_root / f"rep_{rep_idx + 1}"
                wall_ms, payload = _run_worker_subprocess(n, rep_write_dir)
                combined_ms.append(wall_ms)
                load_ms.append(payload["load_ms"])
                run_ms.append(payload["run_ms"])
                write_ms.append(payload["write_ms"])
                checksum = payload["checksum"]

            writer.writerow(_phase_row("v2", "steady_state", "combined", n, combined_ms, checksum))
            writer.writerow(_phase_row("v2", "steady_state", "load", n, load_ms, checksum))
            writer.writerow(_phase_row("v2", "steady_state", "run", n, run_ms, checksum))
            writer.writerow(_phase_row("v2", "steady_state", "write", n, write_ms, checksum))
            fh.flush()

    print(f"Wrote v2 e2e runtime data to {OUT_CSV}")


def main() -> None:
    if os.getenv("V2_E2E_WORKER", "0") == "1":
        _worker_entrypoint()
    else:
        _parent_entrypoint()


if __name__ == "__main__":
    main()
