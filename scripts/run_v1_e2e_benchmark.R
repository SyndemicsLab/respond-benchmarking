#!/usr/bin/env Rscript
# End-to-end benchmark for RESPONDv1.
#
# Each sample is executed in a fresh Rscript subprocess, mirroring the old
# analyst workflow where a bash loop called:
#   Rscript respond_main.R --input /path/to/folder/$INPUT_NUMBER/data
# for every sample.  This means every sample pays full R + Rcpp startup
# overhead, which is the correct cost model for that workflow.
#
# Output rows are split by scope:
#   cold_start   : first measured batch for each sample_size
#   steady_state : repeated batches after warmup
#
# The "combined" phase wall_ms (harness-measured) includes R startup + Rcpp
# cache load on top of the pipeline phases reported by the worker.
#
# Usage:
#   V1_ROOT=/path/to/RESPONDv1 \
#   OUT_CSV=data/v1_e2e_runtime.csv \
#   WARMUP=3 REPETITIONS=3 SAMPLE_SIZES="1 5 10 25 50" STEPS=52 \
#   Rscript scripts/run_v1_e2e_benchmark.R

suppressWarnings(suppressPackageStartupMessages(library(Rcpp)))

# High-resolution monotonic clock (milliseconds)
cppFunction(
    code = '
#include <time.h>
double monotonic_time_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}
'
)

v1_root <- Sys.getenv("V1_ROOT", unset = "/home/matt/Repos/RESPOND/RESPONDv1")
out_csv <- Sys.getenv(
    "OUT_CSV",
    unset = "/home/matt/Repos/RESPOND/respond-benchmarking/data/v1_e2e_runtime.csv"
)

warmup <- as.integer(Sys.getenv("WARMUP", unset = "3"))
repetitions <- as.integer(Sys.getenv("REPETITIONS", unset = "3"))
sample_sizes <- as.integer(strsplit(
    Sys.getenv("SAMPLE_SIZES", unset = "1 5 10 25 50"),
    "[[:space:]]+"
)[[1]])
duration <- as.integer(Sys.getenv("STEPS", unset = "52"))

if (!dir.exists(v1_root)) {
    stop(sprintf("Missing RESPONDv1 root: %s", v1_root), call. = FALSE)
}
if (!file.exists(file.path(v1_root, "src", "simulation.cpp"))) {
    stop("Missing src/simulation.cpp under V1_ROOT", call. = FALSE)
}

dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)

setup_t0 <- monotonic_time_ms()

orig_wd <- getwd()
setwd(v1_root)
on.exit(setwd(orig_wd), add = TRUE)

suppressWarnings({
    source("src/generate_inputs/check_general_inputs.R")
    source("src/generate_inputs/load_inputs.R")
    source("src/generate_inputs/check_load_or_generated_inputs.R")
    source("src/generate_outputs/generate_output_IDs.R")
})

sourceCpp("src/simulation.cpp")

block <<- c(
    "No_Treatment",
    "Buprenorphine",
    "Naltrexone",
    "Methadone",
    "Detox",
    "Heroin_Assisted",
    "Injectable_Naltrexone",
    "Post-Buprenorphine",
    "Post-Naltrexone",
    "Post-Methadone",
    "Post-Detox",
    "Post-Heroin_Assisted",
    "Post-Injectable_Naltrexone"
)
agegrp <<- c("1_100")
sex <<- c("Male")
oud <<- c(
    "Active_Noninjection",
    "Active_Injection",
    "Nonactive_Noninjection",
    "Nonactive_Injection"
)

simulation_duration <<- duration
cycles_in_age_brackets <<- duration
periods <<- duration
time_varying_entering_cohort_cycles <<- c(duration)
time_varying_blk_trans_cycles <<- c(duration)
time_varying_overdose_cycles <<- c(duration)
cost_analysis <<- "no"
discounting_rate <<- 0.03
print_general_outputs <<- "no"
print_per_blk_output <<- "no"
general_stats_cycles <<- c()

num_active_oud <- length(oud) %/% 2L
trt_block_names <- block[seq_len(ceiling(length(block) / 2))]

tmp_input_dir <- file.path(tempdir(), "v1_e2e_bench_inputs")
dir.create(tmp_input_dir, recursive = TRUE, showWarnings = FALSE)

init_cohort_df <- expand.grid(
    block = trt_block_names,
    agegrp = agegrp,
    sex = sex,
    oud = oud,
    stringsAsFactors = FALSE
)
init_cohort_df$counts <- 1000
write.csv(
    init_cohort_df,
    file.path(tmp_input_dir, "init_cohort.csv"),
    row.names = FALSE
)

ec_col <- paste0("number_of_new_comers_cycle", duration)
entering_cohort_df <- data.frame(
    agegrp = agegrp,
    sex = sex,
    stringsAsFactors = FALSE
)
entering_cohort_df[[ec_col]] <- 10
write.csv(
    entering_cohort_df,
    file.path(tmp_input_dir, "entering_cohort.csv"),
    row.names = FALSE
)

oud_stay <- 0.985
oud_off <- (1 - oud_stay) / (length(oud) - 1L)
oud_row <- c(oud_stay, rep(oud_off, length(oud) - 1L))
oud_trans_df <- expand.grid(
    block = block,
    agegrp = agegrp,
    sex = sex,
    initial_status = oud,
    stringsAsFactors = FALSE
)
for (i in seq_along(oud)) {
    oud_trans_df[[paste0("to_", oud[i])]] <- oud_row[i]
}
write.csv(
    oud_trans_df,
    file.path(tmp_input_dir, "oud_trans.csv"),
    row.names = FALSE
)

n_trt_blocks <- ceiling(length(block) / 2)
stay_p <- 1 - n_trt_blocks * 0.010
off_p <- 0.010
blk_trans_df <- expand.grid(
    agegrp = agegrp,
    sex = sex,
    oud = oud,
    initial_block = block,
    stringsAsFactors = FALSE
)
for (b in trt_block_names) {
    blk_trans_df[[paste0("to_", b, "_cycle", duration)]] <- off_p
}
blk_trans_df[[paste0("to_No_Treatment_cycle", duration)]] <- stay_p
blk_trans_df[[paste0("to_corresponding_post_trt_cycle", duration)]] <- off_p
write.csv(
    blk_trans_df,
    file.path(tmp_input_dir, "block_trans.csv"),
    row.names = FALSE
)

bie_df <- data.frame(initial_oud_state = oud, stringsAsFactors = FALSE)
for (b in block) {
    bie_df[[paste0("to_", b)]] <- 1.0
}
write.csv(
    bie_df,
    file.path(tmp_input_dir, "block_init_effect.csv"),
    row.names = FALSE
)

active_ouds <- oud[seq_len(num_active_oud)]
od_df <- expand.grid(
    block = block,
    agegrp = agegrp,
    sex = sex,
    oud = active_ouds,
    stringsAsFactors = FALSE
)
od_df[[paste0("all_types_overdose_cycle", duration)]] <- 0.002
write.csv(
    od_df,
    file.path(tmp_input_dir, "all_types_overdose.csv"),
    row.names = FALSE
)

fatal_od_df <- setNames(
    data.frame(matrix(0.08, nrow = 1)),
    paste0("fatal_to_all_types_overdose_ratio_cycle", duration)
)
write.csv(
    fatal_od_df,
    file.path(tmp_input_dir, "fatal_overdose.csv"),
    row.names = FALSE
)

bg_mort_df <- data.frame(
    agegrp = agegrp,
    sex = sex,
    death_prob = 0.0008,
    stringsAsFactors = FALSE
)
write.csv(
    bg_mort_df,
    file.path(tmp_input_dir, "background_mortality.csv"),
    row.names = FALSE
)

smr_df <- expand.grid(
    block = block,
    agegrp = agegrp,
    sex = sex,
    oud = oud,
    stringsAsFactors = FALSE
)
smr_df$SMR <- 2.0
write.csv(smr_df, file.path(tmp_input_dir, "SMR.csv"), row.names = FALSE)

set_file_paths <- function(input_dir) {
    initial_cohort_file <<- file.path(input_dir, "init_cohort.csv")
    entering_cohort_file <<- file.path(input_dir, "entering_cohort.csv")
    oud_trans_file <<- file.path(input_dir, "oud_trans.csv")
    block_trans_file <<- file.path(input_dir, "block_trans.csv")
    block_init_effect_file <<- file.path(input_dir, "block_init_effect.csv")
    all_type_overdose_file <<- file.path(input_dir, "all_types_overdose.csv")
    fatal_overdose_file <<- file.path(input_dir, "fatal_overdose.csv")
    background_mortality_file <<- file.path(
        input_dir,
        "background_mortality.csv"
    )
    SMR_file <<- file.path(input_dir, "SMR.csv")
}

set_file_paths(tmp_input_dir)

# Pre-generate one input directory per sample slot so each subprocess worker
# reads from a distinct path, matching the real analyst bash-loop pattern
# (/example/path/to/folder/$INPUT_NUMBER/data).
max_n_samples <- max(sample_sizes)
all_input_dirs <- c(
    tmp_input_dir,
    vapply(seq_len(max_n_samples - 1L), function(i) {
        d <- file.path(tempdir(), sprintf("v1_e2e_bench_inputs_%04d", i))
        dir.create(d, recursive = TRUE, showWarnings = FALSE)
        invisible(file.copy(list.files(tmp_input_dir, full.names = TRUE), d))
        d
    }, character(1))
)

worker_script <- file.path(orig_wd, "scripts", "v1_e2e_worker.R")

# Spawn n fresh Rscript subprocesses (one per sample), faithfully reproducing
# the per-sample process startup overhead of the old bash-loop workflow.
# Phase timings are self-reported by the worker; wall_ms is measured by the
# harness and includes R startup + Rcpp cache load on top of the phase times.
run_n_samples <- function(n, write_dir) {
    wall_t0  <- monotonic_time_ms()
    load_ms  <- 0
    run_ms   <- 0
    write_ms <- 0
    checksum <- NA_real_
    for (s in seq_len(n)) {
        out_dir <- file.path(write_dir, sprintf("s%04d", s))
        lines <- system2(
            "Rscript",
            args = c(
                worker_script,
                v1_root,
                all_input_dirs[s],
                out_dir,
                as.character(duration)
            ),
            stdout = TRUE,
            stderr = FALSE
        )
        status <- attr(lines, "status")
        if (!is.null(status) && status != 0L) {
            stop(sprintf(
                "Worker subprocess failed with status %d (sample %d)",
                status, s
            ), call. = FALSE)
        }
        vals <- as.numeric(strsplit(trimws(lines[length(lines)]), ",")[[1]])
        load_ms  <- load_ms  + vals[1L]
        run_ms   <- run_ms   + vals[2L]
        write_ms <- write_ms + vals[3L]
        checksum <- vals[4L]
    }
    list(
        wall_ms  = monotonic_time_ms() - wall_t0,
        load_ms  = load_ms,
        run_ms   = run_ms,
        write_ms = write_ms,
        checksum = checksum
    )
}

setup_ms <- monotonic_time_ms() - setup_t0

stats_for <- function(x) {
    x <- as.numeric(x)
    n <- length(x)
    s <- sort(x)
    p95_idx <- max(1L, ceiling(0.95 * n))
    list(
        mean = mean(s),
        p50 = median(s),
        p95 = s[p95_idx],
        min = min(s),
        max = max(s),
        std = stats::sd(s)
    )
}

header <- c(
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
writeLines(paste(header, collapse = ","), con = out_csv)

append_row <- function(scope, phase, sample_size, times_ms, checksum) {
    st <- stats_for(times_ms)
    mean_sample_ms <- st$mean / sample_size
    ns_per_step_per_sample <- mean_sample_ms * 1e6 / duration
    row <- c(
        "v1",
        scope,
        phase,
        as.character(sample_size),
        sprintf("%.6f", st$mean),
        sprintf("%.6f", st$p50),
        sprintf("%.6f", st$p95),
        sprintf("%.6f", st$min),
        sprintf("%.6f", st$max),
        sprintf("%.6f", ifelse(is.na(st$std), 0, st$std)),
        sprintf("%.6f", mean_sample_ms),
        sprintf("%.2f", ns_per_step_per_sample),
        sprintf("%.6f", checksum),
        as.character(length(block)),
        as.character(length(agegrp)),
        as.character(length(sex)),
        as.character(length(oud)),
        as.character(duration),
        as.character(warmup),
        as.character(repetitions)
    )
    write(row, file = out_csv, append = TRUE, sep = ",", ncolumns = length(row))
}

# One setup row documents one-time startup cost (includes sourceCpp compile)
append_row("cold_start", "setup", 1L, c(setup_ms), NaN)

for (n_samples in sample_sizes) {
    message(sprintf(
        "v1 e2e benchmark (subprocess): sample_size=%d steps=%d",
        n_samples,
        duration
    ))

    tmp_write_dir <- file.path(tempdir(), sprintf("v1_e2e_write_%d", n_samples))
    dir.create(tmp_write_dir, recursive = TRUE, showWarnings = FALSE)

    # Cold-start pass: each of the n_samples workers is a fresh R process that
    # pays full startup + Rcpp cache load + pipeline overhead.
    cold <- run_n_samples(n_samples, tmp_write_dir)
    append_row("cold_start", "combined", n_samples, c(cold$wall_ms),  cold$checksum)
    append_row("cold_start", "load",     n_samples, c(cold$load_ms),  cold$checksum)
    append_row("cold_start", "run",      n_samples, c(cold$run_ms),   cold$checksum)
    append_row("cold_start", "write",    n_samples, c(cold$write_ms), cold$checksum)

    # Warmup passes
    for (w in seq_len(warmup)) {
        run_n_samples(n_samples, tmp_write_dir)
    }

    steady_wall_ms  <- numeric(0)
    steady_load_ms  <- numeric(0)
    steady_run_ms   <- numeric(0)
    steady_write_ms <- numeric(0)
    checksum <- NA_real_

    for (rep_id in seq_len(repetitions)) {
        r <- run_n_samples(n_samples, tmp_write_dir)
        steady_wall_ms  <- c(steady_wall_ms,  r$wall_ms)
        steady_load_ms  <- c(steady_load_ms,  r$load_ms)
        steady_run_ms   <- c(steady_run_ms,   r$run_ms)
        steady_write_ms <- c(steady_write_ms, r$write_ms)
        checksum <- r$checksum
    }

    append_row("steady_state", "combined", n_samples, steady_wall_ms,  checksum)
    append_row("steady_state", "load",     n_samples, steady_load_ms,  checksum)
    append_row("steady_state", "run",      n_samples, steady_run_ms,   checksum)
    append_row("steady_state", "write",    n_samples, steady_write_ms, checksum)
}

message(sprintf("Wrote v1 e2e runtime data to %s", out_csv))
