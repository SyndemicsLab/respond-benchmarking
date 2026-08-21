#!/usr/bin/env Rscript
# Combine v1 and v2 end-to-end benchmark CSVs into a single file.
#
# Usage:
#   V1_CSV=data/v1_e2e_runtime.csv \
#   V2_CSV=data/v2_e2e_runtime.csv \
#   OUT_CSV=data/combined_e2e_runtime.csv \
#   Rscript scripts/prepare_e2e_benchmark_data.R

suppressWarnings(suppressPackageStartupMessages({
    library(readr)
    library(dplyr)
}))

v1_path <- Sys.getenv("V1_CSV", unset = "data/v1_e2e_runtime.csv")
v2_path <- Sys.getenv("V2_CSV", unset = "data/v2_e2e_runtime.csv")
out_path <- Sys.getenv("OUT_CSV", unset = "data/combined_e2e_runtime.csv")

required_cols <- c(
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
    "repetitions"
)

assert_file <- function(path) {
    if (!file.exists(path)) {
        stop(sprintf("Missing input file: %s", path), call. = FALSE)
    }
}

assert_cols <- function(df, label) {
    missing <- setdiff(required_cols, colnames(df))
    if (length(missing) > 0) {
        stop(
            sprintf(
                "%s is missing required columns: %s",
                label,
                paste(missing, collapse = ", ")
            ),
            call. = FALSE
        )
    }
}

assert_file(v1_path)
assert_file(v2_path)

v1 <- read_csv(v1_path, show_col_types = FALSE)
v2 <- read_csv(v2_path, show_col_types = FALSE)

assert_cols(v1, "v1 e2e runtime CSV")
assert_cols(v2, "v2 e2e runtime CSV")

combined <- bind_rows(v1, v2) |>
    mutate(
        model = as.character(model),
        scope = as.character(scope),
        phase = as.character(phase),
        sample_size = as.numeric(sample_size),
        mean_job_ms = as.numeric(mean_job_ms),
        p50_job_ms = as.numeric(p50_job_ms),
        p95_job_ms = as.numeric(p95_job_ms),
        min_job_ms = as.numeric(min_job_ms),
        max_job_ms = as.numeric(max_job_ms),
        std_job_ms = as.numeric(std_job_ms),
        mean_sample_ms = as.numeric(mean_sample_ms),
        ns_per_step_per_sample = as.numeric(ns_per_step_per_sample),
        checksum = as.numeric(checksum)
    ) |>
    mutate(model = factor(model, levels = c("v1", "v2"))) |>
    arrange(scope, phase, model, sample_size)

dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
write_csv(combined, out_path)
message(sprintf(
    "Wrote combined e2e runtime (%d rows) to %s",
    nrow(combined),
    out_path
))
