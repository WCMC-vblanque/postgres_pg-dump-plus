# pg_dump_plus — patch

`pg_dump_plus-REL_17_STABLE.patch` is the complete pg_dump_plus change as a diff
against PostgreSQL `REL_17_STABLE`. It touches only `src/bin/pg_dump/`
(`common.c`, `pg_dump.c`, `pg_dump.h`) — about +465 / −58 lines.

This is the portable, reviewable form of the change: apply it on top of a clean
PostgreSQL source checkout and build. (`pg_dump` cannot be built on its own; it
needs the full PostgreSQL source tree.)

## Apply and build

```bash
git clone --branch REL_17_STABLE --depth 1 https://github.com/postgres/postgres.git
cd postgres
git apply /path/to/pg_dump_plus-REL_17_STABLE.patch     # or: patch -p1 < ...

./configure --with-zlib --with-icu --with-readline
make -C src/backend generated-headers
make -C src/bin/pg_dump -j4                              # -> src/bin/pg_dump/pg_dump
```

## What it does

See the top-level `README.md` and `FEATURE_pg_dump_plus.md` for the full design,
measured impact, and the correctness model / limitations.

## Regenerate

```bash
# from the pg_dump_plus tree, against the base tag
git diff REL_17_STABLE -- src/bin/pg_dump > patches/pg_dump_plus-REL_17_STABLE.patch
```

For the upstream (`pgsql-hackers`) route, prefer a `git format-patch` series so
each logical change is a separate, attributed patch.
