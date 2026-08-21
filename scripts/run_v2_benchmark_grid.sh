#!/usr/bin/env bash
set -euo pipefail

# Run RESPOND v2 benchmark across a grid of sample sizes and save one row per run.
# Sample size here maps to --samples in the v2 benchmark harness.

RESPOND_ROOT="${RESPOND_ROOT:-/home/matt/Repos/RESPOND/respond}"
# RESPOND_TAG="${RESPOND_TAG:-v2.5.1}"
# We utilize v2.5.1 tag but had to make a small change to the benchmark harness to support --history-capture-interval. This means we can't use the tag directly until a new patch is released (e.g. v2.5.2), but we can still check out the tag and then apply our local change.
V2_BENCH_BIN="${V2_BENCH_BIN:-$RESPOND_ROOT/build/shared/bin/respond_benchmark}"
OUT_CSV="${OUT_CSV:-/home/matt/Repos/RESPOND/respond-benchmarking/data/v2_runtime_52_steps.csv}"

# Decomposed dimensions for v1-aligned parity semantics.
N_INTERVENTIONS="${N_INTERVENTIONS:-13}"
N_AGE="${N_AGE:-1}"
N_GENDER="${N_GENDER:-1}"
N_OUD="${N_OUD:-4}"

STRICT_PARITY="${STRICT_PARITY:-1}"

if [[ "$N_INTERVENTIONS" -lt 1 || "$N_AGE" -lt 1 || "$N_GENDER" -lt 1 || "$N_OUD" -lt 1 ]]; then
  echo "All dimension counts must be >= 1." >&2
  exit 1
fi

if [[ "$STRICT_PARITY" == "1" ]]; then
  if [[ "$N_INTERVENTIONS" -ne 13 || "$N_AGE" -ne 1 || "$N_GENDER" -ne 1 || "$N_OUD" -ne 4 ]]; then
    echo "STRICT_PARITY=1 requires N_INTERVENTIONS=13, N_AGE=1, N_GENDER=1, N_OUD=4" >&2
    exit 1
  fi
fi

SEMANTIC_STATE_POINTS=$((N_INTERVENTIONS * N_AGE * N_GENDER * N_OUD))
STATE_SIZE="$SEMANTIC_STATE_POINTS"
STEPS="${STEPS:-52}"
HISTORY_CAPTURE_INTERVAL="${HISTORY_CAPTURE_INTERVAL:-1}"
WARMUP="${WARMUP:-5}"
REPETITIONS="${REPETITIONS:-3}"
SAMPLE_SIZES="${SAMPLE_SIZES:-5 25 50 100 200 400}"

if [[ ! -d "$RESPOND_ROOT" ]]; then
  echo "RESPOND checkout not found: $RESPOND_ROOT" >&2
  exit 1
fi

if [[ ! -x "$V2_BENCH_BIN" ]]; then
  echo "Configuring RESPOND benchmark preset in $RESPOND_ROOT"
  (
    cd "$RESPOND_ROOT"
    cmake --preset benchmark
    cmake --build --preset benchmark
  )
fi

if [[ ! -x "$V2_BENCH_BIN" ]]; then
  echo "v2 benchmark binary not found or not executable: $V2_BENCH_BIN" >&2
  echo "Expected the v2.5.1 benchmark preset to produce build/shared/bin/respond_benchmark." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_CSV")"

echo "model,sample_size,mean_ms,p50_ms,p95_ms,min_ms,max_ms,std_ms,ns_per_step,checksum,interventions,age_brackets,genders,oud_behaviors,semantic_state_points,state_size,steps,warmup,repetitions" > "$OUT_CSV"

for n in $SAMPLE_SIZES; do
  echo "Running v2 benchmark with samples=$n state_size=$STATE_SIZE (i=$N_INTERVENTIONS, j=$N_AGE, k=$N_GENDER, l=$N_OUD)"

  tmp_out="$(mktemp)"
  "$V2_BENCH_BIN" \
    --state-size "$STATE_SIZE" \
    --steps "$STEPS" \
    --history-capture-interval "$HISTORY_CAPTURE_INTERVAL" \
    --warmup "$WARMUP" \
    --samples "$n" \
    --repetitions "$REPETITIONS" > "$tmp_out"

  overall_line="$(awk '/^overall[[:space:]]/{print; exit}' "$tmp_out")"
  if [[ -z "$overall_line" ]]; then
    echo "Could not parse overall row for samples=$n" >&2
    cat "$tmp_out" >&2
    rm -f "$tmp_out"
    exit 1
  fi

  # Benchmark output includes state_pts before checksum; parse checksum position safely.
  parsed_overall="$(awk '
    /^overall[[:space:]]/ {
      if (NF >= 10) {
        printf "%s,%s,%s,%s,%s,%s,%s,%s\n", $2, $3, $4, $5, $6, $7, $8, $10
      } else if (NF >= 9) {
        printf "%s,%s,%s,%s,%s,%s,%s,,%s\n", $2, $3, $4, $5, $6, $7, $8, $9
      }
      exit
    }
  ' "$tmp_out")"

  if [[ -z "$parsed_overall" ]]; then
    echo "Could not parse overall metrics columns for samples=$n" >&2
    cat "$tmp_out" >&2
    rm -f "$tmp_out"
    exit 1
  fi

  IFS=',' read -r mean_ms p50_ms p95_ms min_ms max_ms std_ms ns_per_step checksum <<< "$parsed_overall"

  echo "v2,$n,$mean_ms,$p50_ms,$p95_ms,$min_ms,$max_ms,$std_ms,$ns_per_step,$checksum,$N_INTERVENTIONS,$N_AGE,$N_GENDER,$N_OUD,$SEMANTIC_STATE_POINTS,$STATE_SIZE,$STEPS,$WARMUP,$REPETITIONS" >> "$OUT_CSV"
  rm -f "$tmp_out"
done

echo "Wrote v2 runtime data to $OUT_CSV"
