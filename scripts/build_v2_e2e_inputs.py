#!/usr/bin/env python3
"""Build deterministic v2 e2e benchmark inputs (SQLite DB + config file).

This script creates benchmark fixtures with strict parity dimensions:
- interventions: 13
- behaviors: 4

Usage:
    uv run python scripts/build_v2_e2e_inputs.py

Optional environment overrides:
    OUT_DB=data/v2_e2e_input.db
    OUT_CONF=data/v2_e2e_input.conf
    STEPS=52
    MAX_COHORTS=50
"""

from __future__ import annotations

import os
import sqlite3
from configparser import ConfigParser
from pathlib import Path

OUT_DB = Path(
    os.getenv(
        "OUT_DB",
        "/home/matt/Repos/RESPOND/respond-benchmarking/data/v2_e2e_input.db",
    )
)
OUT_CONF = Path(
    os.getenv(
        "OUT_CONF",
        "/home/matt/Repos/RESPOND/respond-benchmarking/data/v2_e2e_input.conf",
    )
)
STEPS = int(os.getenv("STEPS", "52"))
MAX_COHORTS = int(os.getenv("MAX_COHORTS", "50"))

INTERVENTIONS = [
    "no_treatment",
    "buprenorphine",
    "naltrexone",
    "methadone",
    "detox",
    "heroin_assisted",
    "injectable_naltrexone",
    "post_buprenorphine",
    "post_naltrexone",
    "post_methadone",
    "post_detox",
    "post_heroin_assisted",
    "post_injectable_naltrexone",
]

BEHAVIORS = [
    "active_noninjection",
    "active_injection",
    "nonactive_noninjection",
    "nonactive_injection",
]

SCHEMA = """
DROP TABLE IF EXISTS intervention;
CREATE TABLE intervention (
    id   INTEGER NOT NULL UNIQUE,
    name TEXT    NOT NULL UNIQUE,
    PRIMARY KEY(id AUTOINCREMENT)
);
DROP TABLE IF EXISTS behavior;
CREATE TABLE behavior (
    id   INTEGER NOT NULL UNIQUE,
    name TEXT    NOT NULL UNIQUE,
    PRIMARY KEY(id AUTOINCREMENT)
);
DROP TABLE IF EXISTS background_mortality;
CREATE TABLE background_mortality (
    sample      INTEGER NOT NULL,
    time        INTEGER NOT NULL,
    probability REAL    NOT NULL DEFAULT 0.0,
    PRIMARY KEY(sample, time)
);
DROP TABLE IF EXISTS behavior_transition;
CREATE TABLE behavior_transition (
    sample            INTEGER NOT NULL,
    intervention      INTEGER NOT NULL,
    time              INTEGER NOT NULL,
    initial_behavior  INTEGER NOT NULL,
    new_behavior      INTEGER NOT NULL,
    probability       REAL    NOT NULL DEFAULT 0.0,
    PRIMARY KEY(sample, intervention, time, initial_behavior, new_behavior),
    FOREIGN KEY(initial_behavior) REFERENCES behavior(id),
    FOREIGN KEY(intervention)     REFERENCES intervention(id),
    FOREIGN KEY(new_behavior)     REFERENCES behavior(id)
);
DROP TABLE IF EXISTS initial_population;
CREATE TABLE initial_population (
    sample       INTEGER NOT NULL,
    intervention INTEGER NOT NULL,
    behavior     INTEGER NOT NULL,
    count        REAL    NOT NULL DEFAULT 0.0,
    PRIMARY KEY(sample, intervention, behavior)
);
DROP TABLE IF EXISTS intervention_transition;
CREATE TABLE intervention_transition (
    sample                INTEGER NOT NULL,
    behavior              INTEGER NOT NULL,
    time                  INTEGER NOT NULL,
    initial_intervention  INTEGER NOT NULL,
    new_intervention      INTEGER NOT NULL,
    probability           REAL    NOT NULL DEFAULT 0.0,
    PRIMARY KEY(sample, behavior, initial_intervention, new_intervention, time),
    FOREIGN KEY(behavior)             REFERENCES behavior(id),
    FOREIGN KEY(initial_intervention) REFERENCES intervention(id),
    FOREIGN KEY(new_intervention)     REFERENCES intervention(id)
);
DROP TABLE IF EXISTS overdose;
CREATE TABLE overdose (
    intervention INTEGER NOT NULL,
    sample       INTEGER NOT NULL,
    behavior     INTEGER NOT NULL,
    time         INTEGER NOT NULL,
    probability  REAL    NOT NULL DEFAULT 0.0,
    PRIMARY KEY(intervention, sample, behavior, time),
    FOREIGN KEY(behavior)     REFERENCES behavior(id),
    FOREIGN KEY(intervention) REFERENCES intervention(id)
);
DROP TABLE IF EXISTS overdose_fatality;
CREATE TABLE overdose_fatality (
    sample       INTEGER NOT NULL,
    intervention INTEGER NOT NULL,
    behavior     INTEGER NOT NULL,
    time         INTEGER NOT NULL,
    probability  REAL    NOT NULL DEFAULT 0.0,
    PRIMARY KEY(sample, intervention, behavior, time),
    FOREIGN KEY(behavior)     REFERENCES behavior(id),
    FOREIGN KEY(intervention) REFERENCES intervention(id)
);
DROP TABLE IF EXISTS population_change;
CREATE TABLE population_change (
    sample       INTEGER NOT NULL,
    intervention INTEGER NOT NULL,
    behavior     INTEGER NOT NULL,
    time         INTEGER NOT NULL,
    count        REAL    NOT NULL DEFAULT 0.0,
    PRIMARY KEY(sample, intervention, behavior, time),
    FOREIGN KEY(behavior)     REFERENCES behavior(id),
    FOREIGN KEY(intervention) REFERENCES intervention(id)
);
DROP TABLE IF EXISTS smr;
CREATE TABLE smr (
    sample       INTEGER NOT NULL,
    intervention INTEGER NOT NULL,
    behavior     INTEGER NOT NULL,
    time         INTEGER NOT NULL,
    ratio        REAL    NOT NULL DEFAULT 1.0,
    PRIMARY KEY(sample, time, behavior, intervention),
    FOREIGN KEY(behavior)     REFERENCES behavior(id),
    FOREIGN KEY(intervention) REFERENCES intervention(id)
);
DROP TABLE IF EXISTS cohort;
CREATE TABLE cohort (
    id                              INTEGER NOT NULL UNIQUE,
    description                     TEXT,
    background_mortality_sample     INTEGER NOT NULL,
    behavior_transition_sample      INTEGER NOT NULL,
    initial_population_sample       INTEGER NOT NULL,
    intervention_transition_sample  INTEGER NOT NULL,
    overdose_sample                 INTEGER NOT NULL,
    overdose_fatality_sample        INTEGER NOT NULL,
    population_change_sample        INTEGER NOT NULL,
    smr_sample                      INTEGER NOT NULL,
    PRIMARY KEY(id AUTOINCREMENT)
);
"""


def _prob_row(n: int, stay_prob: float) -> list[float]:
    off = (1.0 - stay_prob) / (n - 1)
    return [stay_prob] + [off] * (n - 1)


def build_db(db_path: Path, max_cohorts: int) -> None:
    if max_cohorts < 1:
        raise ValueError("MAX_COHORTS must be >= 1")

    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        db_path.unlink()

    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.executescript(SCHEMA)

    # Dimension tables.
    cur.executemany(
        "INSERT INTO intervention (id, name) VALUES (?, ?)",
        [(i + 1, name) for i, name in enumerate(INTERVENTIONS)],
    )
    cur.executemany(
        "INSERT INTO behavior (id, name) VALUES (?, ?)",
        [(i + 1, name) for i, name in enumerate(BEHAVIORS)],
    )

    # Single sample row set reused by all cohorts.
    sample = 1
    t = 1

    init_rows = []
    pop_change_rows = []
    smr_rows = []
    od_rows = []
    odf_rows = []
    bt_rows = []
    it_rows = []

    behavior_row = _prob_row(len(BEHAVIORS), stay_prob=0.985)
    inter_row = _prob_row(len(INTERVENTIONS), stay_prob=0.96)

    for i_id in range(1, len(INTERVENTIONS) + 1):
        for b_id in range(1, len(BEHAVIORS) + 1):
            is_active = b_id in (1, 2)
            base_count = 1000.0 if i_id <= 7 else 250.0
            count = base_count if is_active else base_count * 0.5

            init_rows.append((sample, i_id, b_id, count))
            pop_change_rows.append((sample, i_id, b_id, t, count * 0.1))
            smr_rows.append((sample, i_id, b_id, t, 2.0))
            od_rows.append(
                (i_id, sample, b_id, t, 0.002 if is_active else 0.0005))
            odf_rows.append(
                (sample, i_id, b_id, t, 0.08 if is_active else 0.04))

            for b2_id, p in enumerate(behavior_row, start=1):
                bt_rows.append((sample, i_id, t, b_id, b2_id, p))

            for i2_id, p in enumerate(inter_row, start=1):
                it_rows.append((sample, b_id, t, i_id, i2_id, p))

    cur.executemany(
        "INSERT INTO initial_population (sample, intervention, behavior, count) VALUES (?, ?, ?, ?)",
        init_rows,
    )
    cur.executemany(
        "INSERT INTO population_change (sample, intervention, behavior, time, count) VALUES (?, ?, ?, ?, ?)",
        pop_change_rows,
    )
    cur.executemany(
        "INSERT INTO smr (sample, intervention, behavior, time, ratio) VALUES (?, ?, ?, ?, ?)",
        smr_rows,
    )
    cur.executemany(
        "INSERT INTO overdose (intervention, sample, behavior, time, probability) VALUES (?, ?, ?, ?, ?)",
        od_rows,
    )
    cur.executemany(
        "INSERT INTO overdose_fatality (sample, intervention, behavior, time, probability) VALUES (?, ?, ?, ?, ?)",
        odf_rows,
    )
    cur.executemany(
        "INSERT INTO behavior_transition (sample, intervention, time, initial_behavior, new_behavior, probability) VALUES (?, ?, ?, ?, ?, ?)",
        bt_rows,
    )
    cur.executemany(
        "INSERT INTO intervention_transition (sample, behavior, time, initial_intervention, new_intervention, probability) VALUES (?, ?, ?, ?, ?, ?)",
        it_rows,
    )

    cur.execute(
        "INSERT INTO background_mortality (sample, time, probability) VALUES (?, ?, ?)",
        (sample, t, 0.0008),
    )

    cohort_rows = [
        (
            f"bench_cohort_{i}",
            sample,
            sample,
            sample,
            sample,
            sample,
            sample,
            sample,
            sample,
        )
        for i in range(1, max_cohorts + 1)
    ]
    cur.executemany(
        """INSERT INTO cohort (
            description,
            background_mortality_sample,
            behavior_transition_sample,
            initial_population_sample,
            intervention_transition_sample,
            overdose_sample,
            overdose_fatality_sample,
            population_change_sample,
            smr_sample
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        cohort_rows,
    )

    con.commit()
    con.close()


def build_config(conf_path: Path, steps: int) -> None:
    if steps < 1:
        raise ValueError("STEPS must be >= 1")

    conf_path.parent.mkdir(parents=True, exist_ok=True)
    cfg = ConfigParser()
    cfg["simulation"] = {
        "duration": str(steps),
        "parameter_change_times": "1",
        "stratify_entering_cohort": "false",
    }
    cfg["output"] = {
        "build_summary_stats": "true",
        "save_state_history": "true",
        "timesteps_to_report": str(steps),
    }
    with conf_path.open("w", encoding="utf-8") as f:
        cfg.write(f)


def main() -> None:
    build_db(OUT_DB, MAX_COHORTS)
    build_config(OUT_CONF, STEPS)

    print(f"Created DB: {OUT_DB}")
    print(f"Created config: {OUT_CONF}")
    print(
        f"Dimensions: interventions={len(INTERVENTIONS)} behaviors={len(BEHAVIORS)}")
    print(f"Cohorts: {MAX_COHORTS}")


if __name__ == "__main__":
    main()
