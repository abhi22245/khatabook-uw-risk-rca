#!/usr/bin/env python3
"""Run a .sql file against Snowflake. Prints TSV, or writes CSV with --csv.

    python3 tools/run_query.py queries/Q1_cohort_disbursals_ecl.sql
    python3 tools/run_query.py queries/Q6_overrule_bucket_b_loan_level.sql --csv data/out.csv

AUTH: RSA key-pair. Snowflake deprecated password auth (~10 Sep 2026), so any
`password=` connection now fails with:

    250001 (08001): ... Incorrect username or password was specified.

That error almost never means a wrong password — it means the code is still on
password auth. Do NOT "fix" it by rotating the password. See
~/Desktop/SNOWFLAKE_KEYPAIR_AUTH_README.md.

The key is read from $SNOWFLAKE_PRIVATE_KEY_FILE, defaulting to
~/.snowflake/rsa_key_sf_ds.p8 (chmod 600). Never commit or print the key.
"""
import argparse
import csv
import os
import sys
from pathlib import Path

import snowflake.connector

ACCOUNT = "ao58354.ap-south-1.aws"
USER = "datascience"          # service user the key is registered to
ROLE = "DATA_SCIENCE"
WAREHOUSE = os.getenv("SF_WH", "DS_FREQUENT_LOAD_WH")   # fallback: DS_ADHOC_LOAD_CLUSTER_WH


def private_key_bytes():
    path = os.getenv(
        "SNOWFLAKE_PRIVATE_KEY_FILE",
        os.path.expanduser("~/.snowflake/rsa_key_sf_ds.p8"),
    )
    if not os.path.exists(path):
        sys.exit(f"Snowflake private key not found at {path}. See SNOWFLAKE_KEYPAIR_AUTH_README.md")
    from cryptography.hazmat.primitives import serialization
    with open(path, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sql_file")
    ap.add_argument("--csv", metavar="OUT", help="write results to this CSV instead of printing")
    ap.add_argument("--limit", type=int, default=500, help="max rows to print (ignored with --csv)")
    args = ap.parse_args()

    sql = Path(args.sql_file).read_text()

    conn = snowflake.connector.connect(
        account=ACCOUNT, user=USER, private_key=private_key_bytes(),
        role=ROLE, warehouse=WAREHOUSE, database="analytics", schema="MODEL",
        network_timeout=900,
        session_parameters={"STATEMENT_TIMEOUT_IN_SECONDS": 900},
    )
    try:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [c[0].lower() for c in cur.description]

        if args.csv:
            n = 0
            with open(args.csv, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(cols)
                while True:
                    rows = cur.fetchmany(5000)
                    if not rows:
                        break
                    for r in rows:
                        w.writerow(["" if v is None else v for v in r])
                        n += 1
            print(f"wrote {n} rows x {len(cols)} cols -> {args.csv}")
        else:
            rows = cur.fetchmany(args.limit)
            print("\t".join(cols))
            for r in rows:
                print("\t".join("" if v is None else str(v) for v in r))
            print(f"\n[{len(rows)} rows]", file=sys.stderr)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
