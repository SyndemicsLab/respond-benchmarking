#!/usr/bin/env Rscript

suppressWarnings({
    suppressPackageStartupMessages({
        library(Rcpp)
    })
})

v1_sim_cpp <- Sys.getenv(
    "V1_SIM_CPP",
    unset = "/home/matt/Repos/RESPOND/RESPONDv1/src/simulation.cpp"
)
out_csv <- Sys.getenv(
    "OUT_CSV",
    unset = paste0(
        "/home/matt/Repos/RESPOND/respond-benchmarking/data",
        "/v1_runtime_52_steps.csv"
    )
)

warmup <- as.integer(Sys.getenv("WARMUP", unset = "5"))
repetitions <- as.integer(Sys.getenv("REPETITIONS", unset = "3"))
sample_sizes <- as.integer(strsplit(
    Sys.getenv("SAMPLE_SIZES", unset = "5 25 50 100 200 400"),
    "[[:space:]]+"
)[[1]])

# Align step semantics with the v2 benchmark where possible.
duration <- as.integer(Sys.getenv("STEPS", unset = "52"))
per_sample_runs <- as.integer(Sys.getenv("PER_SAMPLE_RUNS", unset = "5"))

if (!file.exists(v1_sim_cpp)) {
    stop(sprintf("Missing v1 simulation.cpp: %s", v1_sim_cpp), call. = FALSE)
}

dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)
sourceCpp(v1_sim_cpp)

# Decomposed dimensions for v1-aligned parity semantics.
n_interventions <- as.integer(Sys.getenv("N_INTERVENTIONS", unset = "13"))
n_age <- as.integer(Sys.getenv("N_AGE", unset = "1"))
n_gender <- as.integer(Sys.getenv("N_GENDER", unset = "1"))
n_oud <- as.integer(Sys.getenv("N_OUD", unset = "4"))

strict_parity <- as.integer(Sys.getenv("STRICT_PARITY", unset = "1"))

if (any(c(n_interventions, n_age, n_gender, n_oud) < 1L)) {
    stop("All dimension counts must be >= 1.", call. = FALSE)
}

if (strict_parity == 1L) {
    if (
        n_interventions != 13L || n_age != 1L || n_gender != 1L || n_oud != 4L
    ) {
        stop(
            "STRICT_PARITY=1 requires N_INTERVENTIONS=13, N_AGE=1, N_GENDER=1, N_OUD=4",
            call. = FALSE
        )
    }
}

imax <- n_interventions
jmax <- n_age
kmax <- n_gender
lmax <- n_oud
semantic_state_points <- imax * jmax * kmax * lmax
num_trts <- (imax - 1L) %/% 2L
num_active_oud <- lmax %/% 2L

# Deterministic synthetic inputs for reproducible timing.
init_demographics_vec <- rep(1000, (num_trts + 1L) * jmax * kmax * lmax)
entering_cohort_matrix <- matrix(2, nrow = jmax * kmax, ncol = 1)
entering_cohort_cycles <- c(duration)

# One row per compartment cell (imax * jmax * kmax * lmax), lmax destination OUD states.
# Spread the 0.015 transition probability evenly across all non-staying states so rows sum to 1.
oud_stay_prob <- 0.985
oud_trans_row <- c(
    oud_stay_prob,
    rep((1 - oud_stay_prob) / (lmax - 1L), lmax - 1L)
)
OUD_trans_matrix <- matrix(
    rep(oud_trans_row, imax * jmax * kmax * lmax),
    ncol = lmax,
    byrow = TRUE
)

block_trans_cycles <- c(duration)
# Each row covers destinations: no_trt, trt_1 .. trt_n, post_trt (num_trts + 2 columns).
# Row count must equal imax * jmax * kmax * lmax (the it-counter stride in simulation.cpp).
block_trans_row <- c(1 - (num_trts + 1L) * 0.010, rep(0.010, num_trts + 1L))
block_trans_matrix_all <- matrix(
    rep(block_trans_row, imax * jmax * kmax * lmax),
    ncol = num_trts + 2L,
    byrow = TRUE
)

block_init_eff_matrix <- matrix(1.0, nrow = lmax, ncol = imax)

overdose_cycles <- c(duration)
overdose_matrix <- matrix(
    rep(0.002, imax * jmax * kmax * num_active_oud),
    ncol = 1
)
fatal_overdose_vec <- c(0.08)

mort_vec <- rep(0.0008, imax * jmax * kmax * lmax)

# Use -1 sentinel to skip the cost branch in v1 simulation.
healthcare_utilization_cost <- matrix(-1, nrow = 1, ncol = 1)
treatment_utilization_cost <- matrix(-1, nrow = 1, ncol = 1)
pharmaceutical_cost <- matrix(-1, nrow = 1, ncol = 1)
overdose_cost <- matrix(-1, nrow = 1, ncol = 1)
util <- matrix(-1, nrow = 1, ncol = 1)
discounting_rate <- 0.03
periods <- 1L
cycles_in_age_brackets <- 520L

run_one <- function() {
    sim(
        init_demographics_vec,
        entering_cohort_matrix,
        entering_cohort_cycles,
        OUD_trans_matrix,
        block_trans_cycles,
        block_trans_matrix_all,
        block_init_eff_matrix,
        overdose_cycles,
        overdose_matrix,
        fatal_overdose_vec,
        mort_vec,
        imax,
        jmax,
        kmax,
        lmax,
        duration,
        cycles_in_age_brackets,
        periods,
        healthcare_utilization_cost,
        treatment_utilization_cost,
        pharmaceutical_cost,
        overdose_cost,
        util,
        discounting_rate
    )
}

compute_stats <- function(x_ms) {
    x_ms <- as.numeric(x_ms)
    n <- length(x_ms)
    x_sorted <- sort(x_ms)
    p95_idx <- max(1, ceiling(0.95 * n))

    list(
        mean_ms = mean(x_ms),
        p50_ms = median(x_ms),
        p95_ms = x_sorted[p95_idx],
        min_ms = min(x_ms),
        max_ms = max(x_ms),
        std_ms = stats::sd(x_ms)
    )
}

header <- c(
    "model",
    "sample_size",
    "mean_ms",
    "p50_ms",
    "p95_ms",
    "min_ms",
    "max_ms",
    "std_ms",
    "ns_per_step",
    "checksum",
    "interventions",
    "age_brackets",
    "genders",
    "oud_behaviors",
    "semantic_state_points",
    "state_size",
    "steps",
    "warmup",
    "repetitions"
)
writeLines(paste(header, collapse = ","), con = out_csv)

for (n_samples in sample_sizes) {
    message(sprintf(
        "Running v1 benchmark with samples=%d state_size=%d (i=%d, j=%d, k=%d, l=%d)",
        n_samples,
        semantic_state_points,
        imax,
        jmax,
        kmax,
        lmax
    ))
    all_samples_ms <- numeric(0)
    checksum <- NA_real_

    for (rep_id in seq_len(repetitions)) {
        if (warmup > 0) {
            for (w in seq_len(warmup)) {
                invisible(run_one())
            }
        }

        rep_samples <- numeric(n_samples)
        for (s in seq_len(n_samples)) {
            t0 <- Sys.time()
            out <- NULL
            for (iter in seq_len(per_sample_runs)) {
                out <- run_one()
            }
            t1 <- Sys.time()

            elapsed_ms <- as.numeric(difftime(t1, t0, units = "secs")) * 1000.0
            rep_samples[s] <- elapsed_ms / per_sample_runs
            checksum <- sum(out$general_outputs)
        }
        all_samples_ms <- c(all_samples_ms, rep_samples)
    }

    st <- compute_stats(all_samples_ms)
    mean_ns <- st$mean_ms * 1e6
    ns_per_step <- mean_ns / duration

    row <- c(
        "v1",
        as.character(n_samples),
        sprintf("%.3f", st$mean_ms),
        sprintf("%.3f", st$p50_ms),
        sprintf("%.3f", st$p95_ms),
        sprintf("%.3f", st$min_ms),
        sprintf("%.3f", st$max_ms),
        sprintf("%.3f", st$std_ms),
        sprintf("%.1f", ns_per_step),
        sprintf("%.4f", checksum),
        as.character(imax),
        as.character(jmax),
        as.character(kmax),
        as.character(lmax),
        as.character(semantic_state_points),
        as.character(semantic_state_points),
        as.character(duration),
        as.character(warmup),
        as.character(repetitions)
    )

    write(row, file = out_csv, append = TRUE, sep = ",", ncolumns = length(row))
}

message(sprintf("Wrote v1 runtime data to %s", out_csv))
