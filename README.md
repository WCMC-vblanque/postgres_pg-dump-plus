pg_dump_plus
============

A small patch set on top of PostgreSQL's `pg_dump` (`REL_17_STABLE`) that makes
schema-selective dumps **fast on databases bloated with huge numbers of
relations** — where stock `pg_dump` is unusably slow or fails outright
(`out of shared memory` from locking millions of tables). It pushes `-N`
(exclude) and `-n` (include) schema selection **down into the catalog queries**,
so metadata, locks, and dependency edges are never built for schemas that won't
be dumped.

Results on a real DB (~1.5M tables across isolated schemas):

| | stock `pg_dump` | pg_dump_plus |
|---|---|---|
| selective dump | **fails** (out of shared memory) | **completes** |
| fixed catalog overhead | ~26 s | **~2–4 s** |
| `reading dependency data` | ~23 s | **~0.09 s** |
| matview-refresh step (no matviews) | 8+ min hang | **0 s** |

Quick start:

```bash
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
