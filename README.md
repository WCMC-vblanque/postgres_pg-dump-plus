# pg_dump_plus

**pg_dump_plus — schema-selective pg_dump that doesn't choke on million-table catalogs.**

pg_dump_plus is a small patch set on PostgreSQL 17's `pg_dump` for databases
polluted with huge numbers of relations (e.g. millions of auto-generated
tables), where stock `pg_dump` is unusably slow or fails outright with
*out of shared memory*. It pushes `-N` (exclude) and `-n` (include) schema
selection down into the catalog queries, so metadata, table locks, and
dependency-graph edges are never built for schemas that won't be dumped. On a
real ~1.5M-table database, a selective dump that stock `pg_dump` couldn't
complete now finishes in seconds.

> Forked from the **postgres/postgres GitHub mirror**. That mirror doesn't take
> pull requests; upstream contributions go through the patch process —
> https://wiki.postgresql.org/wiki/Submitting_a_Patch

## Feature highlights
- 🚀 **Catalog-level `-N`/`-n` pushdown** — excluded/non-included schemas are never fetched, locked, or graphed (not just filtered after the fact like stock `pg_dump`).
- 🧱 **Survives catalog bloat** — turns stock's *out of shared memory* `LOCK TABLE` storm into a working dump.
- ⚡ **Fast dependency collection** — fetches `pg_depend` edges only for loaded objects via indexed lookups instead of scanning the whole catalog (~23 s → ~0.09 s).
- ⏭️ **Skips needless work** — no recursive matview-refresh scan when no materialized view is dumped (was an 8-min hang).
- 🎛️ **Drop-in & reversible** — no new flags; reuses native `-N`/`-n`. Env toggles `PGDUMP_PLUS_FAST_EXCLUDE=0` / `PGDUMP_PLUS_FAST_DEPS=0` restore exact stock behavior.
- 🔎 **Built-in diagnostics** — `PGDUMP_PLUS_TIMING=1` prints per-phase timing to find bottlenecks.
- 📋 **Honest correctness model** — documented limitations (cross-schema inheritance/ownership) and a guaranteed-correct escape hatch.

## Measured impact (real DB: ~1.5M tables across isolated schemas)

| | stock `pg_dump` | pg_dump_plus |
|---|---|---|
| selective dump | **fails** (out of shared memory) | **completes** |
| fixed catalog overhead | ~26 s | **~2–4 s** |
| `reading dependency data` | ~23 s | **~0.09 s** |
| matview-refresh step (no matviews) | 8+ min hang | **0 s** |

## Install

**Option A — prebuilt binary (Linux x86_64, glibc ≥ 2.39 / Ubuntu 24.04).**
Download the tarball from the repo's **Releases**, then (no root):
```bash
tar -xzf pg_dump_plus-17-*-linux-x86_64.tar.gz
cd pg_dump_plus-17-*/ && ./install.sh        # -> ~/.local/bin/pg_dump_plus
pg_dump_plus --version                        # pg_dump (PostgreSQL) 17.10
```

**Option B — build from source (any platform).** From a checkout of this repo:
```bash
scripts/install-from-source.sh                # -> ~/pgdumpplus/bin/pg_dump
# needs: git gcc make bison flex zlib1g-dev libicu-dev libreadline-dev
```

The custom `pg_dump` must be **≥** your server's PostgreSQL version.

## Quick start

```bash
# build manually (alternative to the installers above)
./configure --with-zlib --with-icu --with-readline
make -C src/backend generated-headers
make -C src/bin/pg_dump -j4            # -> src/bin/pg_dump/pg_dump

pg_dump -h HOST -U USER -d DB -n my_schema   -Fc -f out.dump   # include (fast)
pg_dump -h HOST -U USER -d DB -N 'tmp_*'     -Fc -f out.dump   # exclude (fast)
```

Runtime toggles (env vars; all default on except timing):
`PGDUMP_PLUS_FAST_EXCLUDE=0`, `PGDUMP_PLUS_FAST_DEPS=0`, `PGDUMP_PLUS_TIMING=1`.

**Before relying on it, read [FEATURE_pg_dump_plus.md](FEATURE_pg_dump_plus.md)**
— full design, measured impact, and the *Correctness model & limitations*
(when a schema is safe to fast-exclude; cross-schema inheritance/ownership
caveats; the guaranteed-correct escape hatch). See [TODO.md](TODO.md) for the
test plan and upstream roadmap.

Branches: `pg-dump-plus/generic-fast-exclude` (current, generic `-N`/`-n`),
`pg-dump-plus/exclude-prefixed-schemas` (earlier, `__`-prefix auto-exclude).

Derived from PostgreSQL; the PostgreSQL License applies (see `COPYRIGHT`).
Upstream headers are preserved; pg_dump_plus changes are marked with
`pg_dump_plus` comments.

---

PostgreSQL Database Management System
=====================================

This directory contains the source code distribution of the PostgreSQL
database management system.

PostgreSQL is an advanced object-relational database management system
that supports an extended subset of the SQL standard, including
transactions, foreign keys, subqueries, triggers, user-defined types
and functions.  This distribution also contains C language bindings.

Copyright and license information can be found in the file COPYRIGHT.

General documentation about this version of PostgreSQL can be found at
<https://www.postgresql.org/docs/17/>.  In particular, information
about building PostgreSQL from the source code can be found at
<https://www.postgresql.org/docs/17/installation.html>.

The latest version of this software, and related software, may be
obtained at <https://www.postgresql.org/download/>.  For more information
look at our web site located at <https://www.postgresql.org/>.
