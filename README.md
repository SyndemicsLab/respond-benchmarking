# RESPOND Comparative Benchmarking (v1 vs v2)

This folder contains a reproducible benchmarking workflow that compares RESPOND v1 and v2 in R/Quarto.

## Files

- `scripts/run_v2_benchmark_grid.sh`: Runs the v2 C++ benchmark over a sample-size grid and writes `data/v2_runtime.csv`.
- `scripts/prepare_benchmark_data.R`: Combines v1 and v2 runtime CSV files into `data/combined_runtime.csv`.
- `benchmark_report.qmd`: Quarto report with:
  - A direct v1 vs v2 comparison table.
  - A runtime-over-sample-size line plot.

## Expected CSV Schema for v1 and v2

Both `data/v1_runtime.csv` and `data/v2_runtime.csv` must contain:

- `model`
- `sample_size`
- `mean_ms`
- `p50_ms`
- `p95_ms`
- `min_ms`
- `max_ms`
- `std_ms`
- `ns_per_step`
- `checksum`

## Run (v2)

```bash
uv sync
bash scripts/run_v2_benchmark_grid.sh
```

## Run (v2 respondpy end-to-end benchmark)

```bash
uv run python scripts/build_v2_e2e_inputs.py

DB_PATH=/path/to/input.db \
CONF_PATH=/path/to/config.conf \
uv run python scripts/run_v2_e2e_benchmark.py
```

The input builder creates default fixtures at:

- `data/v2_e2e_input.db`
- `data/v2_e2e_input.conf`

So a typical run is:

```bash
uv run python scripts/build_v2_e2e_inputs.py
DB_PATH=data/v2_e2e_input.db CONF_PATH=data/v2_e2e_input.conf uv run python scripts/run_v2_e2e_benchmark.py
```

This Python benchmark uses the local editable `../respondpy` checkout, so it
tests the currently selected local `respondpy` branch. The v1 benchmark remains
managed separately and is not installed by this project.

For trustworthiness, this v2 e2e benchmark enforces strict parity with the v1
state-space dimensions used in this repo:

- `N_INTERVENTIONS=13`
- `N_BEHAVIORS=4`
- `STRICT_PARITY=1`

This benchmark measures workflow throughput by timing each v2 run at process
scope (process launch to process exit), while still emitting diagnostic load/run/write
phase rows.

v2 benchmark state sizing is derived from decomposed dimensions:

- `N_INTERVENTIONS` (default `13`)
- `N_AGE` (default `1`)
- `N_GENDER` (default `1`)
- `N_OUD` (default `4`)
- `STRICT_PARITY` (default `1`, enforces `13 x 1 x 1 x 4`)

Derived benchmark state size is:

- `state_size = N_INTERVENTIONS * N_AGE * N_GENDER * N_OUD`

Example override (only if parity enforcement is disabled):

```bash
STRICT_PARITY=0 N_INTERVENTIONS=13 N_AGE=2 N_GENDER=2 N_OUD=4 bash scripts/run_v2_benchmark_grid.sh
```

## Combine

```bash
Rscript scripts/prepare_benchmark_data.R
```

## Render Report

```bash
quarto render benchmark_report.qmd
```

## Notes

- v2 benchmark sample size maps to `--samples` in `respond_benchmark`.
- v1 runtime CSV should be produced using an equivalent benchmark procedure over the same sample-size grid to enable valid direct comparison.
