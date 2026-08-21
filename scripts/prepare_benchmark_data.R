#!/usr/bin/env Rscript

suppressWarnings({
    suppressPackageStartupMessages({
        library(readr)
        library(dplyr)
    })
})

v1_path <- Sys.getenv("V1_CSV", unset = "data/v1_runtime_52_steps.csv")
v2_path <- Sys.getenv("V2_CSV", unset = "data/v2_runtime_52_steps.csv")
out_path <- Sys.getenv("OUT_CSV", unset = "data/combined_runtime.csv")

required_cols <- c(
    "model",
    "sample_size",
    "mean_ms",
    "p50_ms",
    "p95_ms",
    "min_ms",
    "max_ms",
    "std_ms",
    "ns_per_step",
    "checksum"
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

assert_cols(v1, "v1 runtime CSV")
assert_cols(v2, "v2 runtime CSV")

combined <- bind_rows(v1, v2) |>
    mutate(
        model = as.character(model),
        sample_size = as.numeric(sample_size),
        mean_ms = as.numeric(mean_ms),
        p95_ms = as.numeric(p95_ms),
        std_ms = as.numeric(std_ms)
    ) |>
    arrange(sample_size, model)

write_csv(combined, out_path)
cat(sprintf("Wrote combined benchmark data to %s\n", out_path))
