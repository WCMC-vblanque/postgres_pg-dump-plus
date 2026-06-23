# pg_dump_plus — fast dumps of databases polluted with isolated schemas

A small patch to `src/bin/pg_dump/pg_dump.c` that lets `pg_dump` **skip
"isolated" schemas at the catalog-query level**, so it never fetches their
metadata, never takes locks on their tables, and never builds dependency-graph
edges for them.

## Why

Stock `pg_dump` reads metadata for **every** object in the database to build
its internal dependency graph — even objects it will not dump. On a database
that contains a few huge, self-contained ("isolated") schemas, this is slow,
memory-hungry, and can fail outright:

```
pg_dump: error: query failed: ERROR:  out of shared memory
pg_dump: detail: Query was: LOCK TABLE "big_schema_n…"."cell_00001_…", …
```

`pg_dump` tries to `LOCK TABLE` every table it considers, and exhausts
`max_locks_per_transaction` when an isolated schema holds hundreds of
thousands of tables. Even `-N` (exclude schema) does not help, because the
exclusion is applied *after* the catalog reads and locking.

This patch pushes the exclusion **into the catalog SQL itself**, so the heavy
objects are never seen.

## What counts as an "isolated" schema

A schema is treated as isolated (and excluded) when **either**:

1. its name starts with a configured **prefix** (default `__`), or
2. its exact name is listed with **`--exclude-isolated-schema`**.

These compose: prefix-matched schemas *and* explicitly named schemas are all
excluded.

> Assumption: isolated schemas are genuinely self-contained — no object you
> *do* want to dump references an object inside them (no cross-schema
> inheritance, foreign keys, or type usage into an isolated schema). This is
> what makes catalog-level exclusion safe.

## Usage

```bash
# Default: schemas named __* are auto-excluded
pg_dump -d mydb -Fc -f out.dump

# Also exclude two specific isolated schemas by exact name
pg_dump -d mydb \
  --exclude-isolated-schema=staging_big \
  --exclude-isolated-schema=etl_scratch \
  -Fc -f out.dump

# Change the prefix (CLI overrides the env var); empty string disables it
pg_dump -d mydb --isolated-schema-prefix=tmp_ -Fc -f out.dump
PGDUMP_EXCLUDE_SCHEMA_PREFIX='' pg_dump -d mydb ...   # prefix rule off

# Combine with native -n to dump ONLY specific schemas, fast
pg_dump -d mydb -n 01_grid -n 04_stats -n 05_log -n 07_result -Fc -f out.dump
```

### Options added

| Option / variable | Effect |
|---|---|
| `--exclude-isolated-schema=NAME` | Exclude the schema with this exact name at the catalog level. Repeatable. |
| `--isolated-schema-prefix=STR` | Treat schemas whose name starts with `STR` as isolated. Default `__`. Empty string disables the prefix rule. |
| `PGDUMP_EXCLUDE_SCHEMA_PREFIX` (env) | Same as `--isolated-schema-prefix`, but lower precedence (CLI wins). |

Precedence for the prefix: `--isolated-schema-prefix` → `PGDUMP_EXCLUDE_SCHEMA_PREFIX` → `__`.

### Startup notice

Before reading any objects, pg_dump_plus prints to **stderr** (always, even
without `--verbose`) the schemas it is ignoring, so you can confirm exactly
what was left out:

```
pg_dump_plus: ignoring 12 isolated schema(s): big_schema_n2026…, big_schema_g2026…, …
```

If the feature is enabled but nothing matched, it prints
`pg_dump_plus: no schemas matched the isolation rule(s)`. The message is on
stderr, so it never contaminates a dump written to stdout.

## Fast dependency collection (`PGDUMP_PLUS_FAST_DEPS`)

Stock `pg_dump` reads dependency data with a single full scan of `pg_depend`.
On a catalog bloated by millions of isolated-schema objects, that scan alone
costs ~20-25s on every dump, no matter how few objects you select.

pg_dump_plus replaces it (enabled by default) with a query that fetches
dependencies **only for the objects actually loaded**: it snapshots their
CatalogIds and emits them grouped per catalog as
`classid = K AND objid = ANY(ARRAY[...])` clauses, which the planner satisfies
with index/bitmap scans on `pg_depend(classid, objid)` — never scanning the
whole catalog. No temp table is used (pg_dump runs read-only).

This is provably equivalent to the original query: `getDependencies()` already
discards any dependency whose depender is not a loaded object.

- Default: **on**. Disable with `PGDUMP_PLUS_FAST_DEPS=0` to fall back to the
  safe full-scan path (still with isolated-schema filtering).
- Measured (4 schemas, schema-only, ~1.5M `__` tables): `reading dependency
  data` dropped from **~23s to ~0.09s**; total catalog read from **~27s to
  ~4s**. Output is byte-identical to the safe path (verified with `diff`,
  ignoring the random per-run `\restrict` token).

## Phase timing (diagnostics)

Set `PGDUMP_PLUS_TIMING=1` to print, to stderr, how long each metadata-read
phase takes (the `getSchemaData` catalog reads plus `reading dependency data`,
ACL/comment collection, and the object sort). Works regardless of `--verbose`
and does not affect the dump.

```
PGDUMP_PLUS_TIMING=1 pg_dump -d mydb -n some_schema -s -f /dev/null
...
pg_dump_plus[timing] reading user-defined tables                  1.28s  (cum  1.38s)
pg_dump_plus[timing] reading dependency data                     21.99s  (cum 24.84s)
pg_dump_plus[timing] TOTAL catalog read                          26.00s
```

This makes it obvious where time goes. On a catalog bloated by millions of
tables, `reading dependency data` (a full `pg_depend` scan) typically
dominates the fixed per-dump cost, independent of how few objects you select.

## How it works (implementation)

Two layers, kept deliberately separate:

1. **Correctness layer — `selectDumpableNamespace()`**
   Any isolated schema is marked `DUMP_COMPONENT_NONE`, exactly as if it were
   passed to `-N`. Because `getNamespaces()` still loads *all* namespaces,
   `findNamespace()` never fails, so the dump is always clean and never
   crashes — independent of which queries below are short-circuited.

2. **Performance layer — catalog query filters**
   A shared predicate (`appendIsolatedSchemaOidSubquery()`) injects
   `<nspcol> NOT IN (SELECT oid FROM pg_namespace WHERE …)` into the heavy
   catalog queries so their rows are never fetched:
   - `getTables()` — the big one; transitively gates all per-table queries
     (columns, indexes, constraints, triggers, policies, …) and the
     `LOCK TABLE` storm.
   - `getTypes()`, `getFuncs()`, `getAggregates()`.
   - `getDependencies()` — filters `pg_depend` rows whose `pg_class`/`pg_type`
     endpoints live in an isolated schema. This is essential: `pg_depend` has
     an entry for every column/rowtype of every isolated table.

   Schema-name literals are escaped via `appendStringLiteralAH()`.

Helpers: `schema_is_isolated()` (C-side name test) and
`appendIsolatedSchemaOidSubquery()` / `appendExcludedSchemaFilter()` (SQL-side).

## Measured impact

Real database (`REL_17_STABLE` build), ~1.5M tables across 12 `__`-prefixed
schemas, dumping 4 small target schemas (`-s`, schema-only):

| | Stock `pg_dump` | pg_dump_plus |
|---|---|---|
| Result | **fails** — `out of shared memory` | **completes** |
| Wall time | — (died ~42 s) | **~26 s** |
| Peak RSS | 2.3 GB (then died) | **391 MB** |

The `getDependencies` filter alone cut the "reading dependency data" phase from
~54 s to ~24 s and peak memory from ~1.6 GB to ~0.39 GB.

## Building

```bash
# from the source tree root
./configure --with-zlib --with-icu --with-readline
make -C src/backend generated-headers
make -C src/bin/pg_dump -j4
# binary: src/bin/pg_dump/pg_dump
```

`--with-zlib` enables default `-Fc` (custom-format) compression. Add
`--with-lz4 --with-zstd` if those dev libraries are installed and you want
those compression methods.

## Limitations / notes

- Catalog-level exclusion is safe only for genuinely isolated schemas (see the
  assumption above). If a dumped object references an isolated schema, that
  reference will be missing on restore.
- The patch is additive and gated: with no prefix and no
  `--exclude-isolated-schema`, behavior is identical to stock `pg_dump`.
- Custom `pg_dump` must be **≥** the server version, as always.
