#!/usr/bin/env Rscript
# v1_e2e_worker.R
#
# Single-sample v1 pipeline worker, spawned as a fresh Rscript subprocess by
# run_v1_e2e_benchmark.R for every sample in a job.
#
# This mirrors the old analyst workflow where a bash loop called:
#   Rscript respond_main.R --input /path/to/folder/$INPUT_NUMBER/data
# for each sample, paying full R + Rcpp startup overhead on every iteration.
#
# Usage:
#   Rscript scripts/v1_e2e_worker.R <v1_root> <input_dir> <output_dir> <steps>
#
# Stdout: exactly one CSV line — load_ms,run_ms,write_ms,checksum
# Stderr: suppressed (warnings discarded to keep stdout clean for parsing)

suppressWarnings(suppressPackageStartupMessages(library(Rcpp)))

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

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L) {
    stop(
        "Usage: v1_e2e_worker.R <v1_root> <input_dir> <output_dir> <steps>",
        call. = FALSE
    )
}

v1_root <- args[1L]
input_dir <- args[2L]
output_dir <- args[3L]
duration <- as.integer(args[4L])

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

initial_cohort_file <<- file.path(input_dir, "init_cohort.csv")
entering_cohort_file <<- file.path(input_dir, "entering_cohort.csv")
oud_trans_file <<- file.path(input_dir, "oud_trans.csv")
block_trans_file <<- file.path(input_dir, "block_trans.csv")
block_init_effect_file <<- file.path(input_dir, "block_init_effect.csv")
all_type_overdose_file <<- file.path(input_dir, "all_types_overdose.csv")
fatal_overdose_file <<- file.path(input_dir, "fatal_overdose.csv")
background_mortality_file <<- file.path(input_dir, "background_mortality.csv")
SMR_file <<- file.path(input_dir, "SMR.csv")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# ---- timed phases ----

t_load0 <- monotonic_time_ms()
suppressWarnings({
    check_general_inputs()
    load_inputs()
    check_load_gen_inputs()
    generate_output_IDs()
})
load_ms <- monotonic_time_ms() - t_load0

t_run0 <- monotonic_time_ms()
out <- sim(
    init_demographics_vec,
    entering_cohort_matrix,
    time_varying_entering_cohort_cycles,
    oud_trans_matrix,
    time_varying_blk_trans_cycles,
    block_trans_matrix,
    block_init_effect_matrix,
    time_varying_overdose_cycles,
    all_types_overdose_matrix,
    fatal_overdose_vec,
    mort_vec,
    imax,
    jmax,
    kmax,
    lmax,
    simulation_duration,
    cycles_in_age_brackets,
    periods,
    healthcare_utilization_cost,
    treatment_utilization_cost,
    pharmaceutical_cost,
    overdose_cost,
    util,
    discounting_rate
)
run_ms <- monotonic_time_ms() - t_run0

t_write0 <- monotonic_time_ms()
write.table(
    out$general_outputs,
    file = file.path(output_dir, "general_outputs.csv"),
    sep = ",",
    row.names = FALSE,
    quote = FALSE
)
write_ms <- monotonic_time_ms() - t_write0

checksum <- sum(out$general_outputs)

cat(sprintf("%.6f,%.6f,%.6f,%.6f\n", load_ms, run_ms, write_ms, checksum))
