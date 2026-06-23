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
pg_dump: detail: Query was: LOCK TABLE "big_schema"."cell_00001", "big_schema"."cell_00002", …
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
pg_dump_plus: excluding 12 schema(s) at catalog level: big_schema_1, big_schema_2, …
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

## Skipping matview refresh dependencies

`buildMatViewRefreshDependencies()` runs a *recursive* scan of `pg_depend` (for
data dumps) to order materialized-view refreshes. On a `pg_depend` bloated by
isolated schemas this can hang for many minutes -- even when the database has
**no materialized views at all**. pg_dump_plus skips this step unless a
materialized view is actually being dumped. Always-on and safe (the step
produces nothing when there are no matviews).

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

## Correctness model & limitations

The fast path skips *fetching catalog metadata* for schemas pg_dump has already
decided not to dump (via `-N` excludes or `-n` includes). Stock pg_dump instead
fetches **everything** and uses the full picture for (a) ordering and (b)
computing derived details of the kept objects. Skipping is correct **only when
what you keep does not structurally need what you skipped.**

**Does a schema have to be "isolated"?**
- The schema you **ignore/exclude** must be isolated in the *inheritance/ownership*
  sense (see hazard below).
- The schema you **keep/include** does **not** need to be isolated — it is dumped
  normally and may reference anything.

### Plain references — safe (no worse than stock `-N`/`-n`)
A kept object that *references* an excluded object **by name** is fine, and
behaves exactly like stock `-N`/`-n`:
- FK from a kept table to a table in an ignored schema
- a kept table column whose **type** lives in an ignored schema
- a kept **view**/function whose body reads an ignored schema

In all these, pg_dump emits the reference by qualified name regardless of the
fast path; it does **not** recreate the ignored object, so **restore requires
that object to already exist in the target**. This limitation is inherent to
`-N`/`-n`, not introduced here.

### The real hazard the pushdown adds: cross-schema **inheritance/ownership**
Stock pg_dump fetches *all* tables specifically to compute inherited columns and
owned sequences. With the pushdown, an ignored parent isn't loaded, so:
- A **kept child table that `INHERITS` from a parent in an ignored schema** can
  get its inherited-column handling **wrong** — the one case where output may
  differ from stock.
- A kept sequence **`OWNED BY`** a column in an ignored schema (rare, manual
  cross-schema ownership) can trigger a `failed sanity check` abort.

So: **the ignored schema must not be inherited-from or owned-across by anything
you keep.**

### What stays correct automatically
- System schemas (`pg_catalog`, `pg_toast`, `information_schema`) are **never**
  pushed down, so built-in/array/column type resolution is unaffected.
- Dependency *ordering among dumped objects* is preserved (the fast
  `getDependencies` fetches all deps whose depender is a loaded object; deps to
  non-dumped objects are irrelevant).
- Global catalog reads that assume all tables are loaded are filtered to match
  (`getRules`, `getPartitioningInfo`); others (`getConstraints`, `getPolicies`,
  `getPublicationTables`) already tolerate missing tables.
- The matview-refresh step is skipped only when no materialized view is dumped.

### Escape hatch (guaranteed-stock correctness)
If unsure whether a given dump is "isolated enough", run with both
`PGDUMP_PLUS_FAST_EXCLUDE=0` and `PGDUMP_PLUS_FAST_DEPS=0`: this reverts to
stock pg_dump behavior — correct for every case, just slow. Diff the fast vs
stock output once for a given schema set; if identical, the fast path is safe
for that shape.

### Other notes
- With no `-N`/`-n`, behavior is identical to stock `pg_dump` (nothing is
  excluded).
- Custom `pg_dump` must be **≥** the server version, as always.

---

## Upstream / generality assessment (TODO: work on this later)

Root problem this addresses: **`pg_dump` degrades badly on databases with a very
large number of relations** (here ~1.5M tables across isolated schemas). This is
a recognized, recurring topic on `pgsql-hackers`; incremental fixes have landed
over recent versions. Our case is an extreme but legitimate instance.

### Summary of changes and measured impact

| # | Change | Problem | Impact |
|---|---|---|---|
| 1 | Catalog-level schema exclusion pushed into `getTables/getTypes/getFuncs/getAggregates` | stock reads metadata + `LOCK TABLE`s excluded schemas → OOM crash | stock **crashes** → completes |
| 2 | Fast `getDependencies` (`PGDUMP_PLUS_FAST_DEPS`): fetch deps only for loaded objects via indexed `classid/objid` lookups | full `pg_depend` scan is O(whole catalog), not O(what you dump) | **23 s → 0.09 s** |
| 3 | Skip `buildMatViewRefreshDependencies` when no matview is dumped | recursive `pg_depend` walk for matviews that may not exist | **8+ min hang → 0 s** |
| 4 | `--exclude-isolated-schema`, `--isolated-schema-prefix`, env vars | configurable exclusion | usability |
| 5 | Startup notice of ignored schemas | transparency | — |
| 6 | `PGDUMP_PLUS_TIMING` per-phase chronometer | diagnose bottlenecks | — |

Net: fixed per-dump overhead **~26 s → ~2–4 s**; crash → working dump.

### Generality tiers

**🟢 Genuinely general (upstreamable):**
- **#3 — matview guard.** Any DB with a large `pg_depend` and few/no matviews
  pays for that recursive scan today. Clean, safe, general. *The clearest win.*
- **#2 — smarter dependency fetch.** Scanning all of `pg_depend` for a small
  `-n` dump is a real algorithmic inefficiency. The "fetch only deps of loaded
  objects" idea is general (correctness rests on: `getDependencies` already
  ignores deps whose depender isn't a loaded object).

**🟡 General idea, needs design work to be safe for everyone:**
- **#1 — `-N`/`-n` catalog pushdown.** It's a real, known inefficiency that
  `-N`/`-n` don't prevent metadata reads/locks. Helping everyone with large DBs.
  *But* our version assumes excluded schemas are truly isolated; the general
  case (cross-schema FKs, inherited columns, shared types) would break silently.
  Upstreaming requires skipping objects only when provably unreferenced, or an
  explicit opt-in flag with documented caveats.

**🔴 Specific to this deployment (a convenience layer, not upstream material):**
- The hardcoded **`__` prefix** default and "assume isolation" behavior — our
  naming scheme, not universal.

### Contribution roadmap (later)

1. **Extract #3 (matview guard) as a standalone patch** against `master`, with a
   minimal reproducer. Small, safe, likely well-received → start here.
2. **Post a performance report to `pgsql-hackers`**: the `LOCK TABLE` storm and
   the `pg_depend` full scan on partial dumps, with before/after benchmark
   numbers. Reproducible numbers drive real fixes even if our patches aren't
   merged verbatim.
3. **Propose the `-N`/`-n` pushdown as a design discussion**, not a finished
   patch — the correctness design is the hard part; let the community own it.
4. Do **not** propose the `__`-prefix default upstream; keep it as our layer.

Caveat to state honestly upstream: a 1.5M-table database is itself an
anti-pattern; some maintainers will (fairly) say "fix the schema design." Both
are true — `pg_dump` should be more robust to it, *and* the ETL creating
millions of `__` tables is worth revisiting.

### Open items / ideas to explore
- Make #2 (fast deps) handle the case where `buildMatViewRefreshDependencies`
  *is* needed (matviews present) — currently that path still does the recursive
  scan; could apply the same isolated-schema filter to it.
- Trim the remaining ~2–4 s fixed cost: `getTables`/`getTypes`/ACL phases still
  use `NOT IN` subqueries over the bloated `pg_class`/`pg_type`.
- Decide whether `--exclude-isolated-schema` should accept glob patterns (it is
  currently exact-name).
