# pg_dump_plus — TODO

## Test branch `pg-dump-plus/generic-fast-exclude` on the server

Goal: validate the generic fast schema exclusion/inclusion (`-N` / `-n`
catalog-level pushdown) against the target database on the server.

### 0. Deploy
```bash
# from the build host
scp .../05_pg-dump-plus/src/bin/pg_dump/pg_dump  you@server:~/bin/pg_dump_plus
ssh you@server 'chmod +x ~/bin/pg_dump_plus'
```
(Make sure the build is from this branch: `git branch --show-current` should be
`pg-dump-plus/generic-fast-exclude`, then rebuild `make -C src/bin/pg_dump -j4`
before scp.)

### 1. Confirm safety of target schema(s) first (FEATURE doc: "Correctness model")
For each schema you dump, the two fast-path hazards must be empty:
- cross-schema INHERITANCE check
- cross-schema OWNED-BY sequence check
(see queries in FEATURE_pg_dump_plus.md → "How to know a schema is isolated")

### 2. Functional tests on the server
```bash
export PGPASSWORD='...'        # do NOT hardcode; read from a secrets file
DB=mydb; USER=myuser
# a) dump only one schema (include pushdown)
~/bin/pg_dump_plus -h localhost -U "$USER" -d "$DB" \
  -n my_schema -Fc --compress=gzip:1 -f out.dump
# b) exclude snapshot schemas, keep the rest (exclude pattern)
~/bin/pg_dump_plus -h localhost -U "$USER" -d "$DB" \
  -N 'tmp_*' -s -f rest_schema.sql
```
Watch for: `pg_dump_plus: excluding N schema(s)…` notice; NO `failed sanity
check …` errors; completes in seconds + data copy.

### 3. Correctness spot-check (certify the schema shape once)
```bash
PGDUMP_PLUS_FAST_EXCLUDE=0 PGDUMP_PLUS_FAST_DEPS=0 ~/bin/pg_dump_plus ... -n my_schema -s -f stock.sql
~/bin/pg_dump_plus ... -n my_schema -s -f fast.sql
diff -I 'restrict ' stock.sql fast.sql && echo "SAFE: identical"
```
(The stock run is slow but only needed once per schema shape.)

### Publish to GitHub
- Done: pushed to a fork; binary published as a GitHub Release.
- Keep the README pointing at `FEATURE_pg_dump_plus.md`.
- License/attribution: PostgreSQL License; upstream headers preserved; our
  changes marked with `pg_dump_plus` comments.

### Open items / follow-ups (later)
- Refresh the older sections of FEATURE_pg_dump_plus.md (Usage examples + the
  "Summary of changes" table still mention the removed `--exclude-isolated-schema`
  / `__`-prefix flags; the mechanism is now `-N`/`-n` pushdown).
- Edge case to watch: cross-schema OWNED-BY sequence can still `pg_fatal` in
  getOwnedSeqs() — harden only if it ever shows up.
- Decide whether to make `PGDUMP_PLUS_TIMING` a `--timing` CLI flag.
- Upstream roadmap (matview-guard patch first) — see FEATURE doc.
- If all good, consider merging `pg-dump-plus/generic-fast-exclude` into a clean
  main branch.
