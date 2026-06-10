"""Introspection-driven, deterministic, tenant-aware data generator.

The engine reads the LIVE schema (so it never hardcodes columns), generates each
table in FK-topological order, and lets Postgres' GENERATED ALWAYS identity assign
ids 1..n in COPY order — so a child FK is just an integer in [1, parent_n], sampled
*within the child's tenant* to preserve multi-tenant isolation by construction.

Per-table realism (status mixes, money math, temporal coherence) is layered on top
by recipes.py, which post-processes the generic column arrays before COPY.

Determinism: one numpy SeedSequence tree keyed by a stable crc32 of the stream name,
plus PYTHONHASHSEED=0 (set by the Makefile) and pinned deps. See DATA-REALISM.md.
"""
from __future__ import annotations

import datetime as dt
import uuid as uuidlib
import zlib

import numpy as np
import psycopg
from mimesis import Address, Finance, Person, Text

import config

SCHEMAS = [
    "identity", "geo", "catalog", "pricing", "inventory", "sales", "billing",
    "crm", "support", "marketing", "analytics", "comms", "audit", "ops",
]

REF = dt.datetime.fromisoformat(config.REF_DATE).replace(tzinfo=dt.timezone.utc)
START = REF - dt.timedelta(days=config.HISTORY_DAYS)
WINDOW_S = (REF - START).total_seconds()


# --------------------------------------------------------------------------- #
# Deterministic RNG tree + precomputed string pools
# --------------------------------------------------------------------------- #
class Rng:
    def __init__(self, seed: int):
        self.seed = int(seed)
        self._c: dict[str, np.random.Generator] = {}

    def s(self, name: str) -> np.random.Generator:
        """A stable, order-independent generator stream for `name`."""
        g = self._c.get(name)
        if g is None:
            ss = np.random.SeedSequence([self.seed, zlib.crc32(name.encode()) & 0xFFFFFFFF])
            g = np.random.default_rng(ss)
            self._c[name] = g
        return g


class Pools:
    """Precompute Mimesis string pools once, then sample with numpy (fast + deterministic)."""
    def __init__(self, seed: int, n: int = 3000):
        p = Person("en", seed=seed)
        t = Text("en", seed=seed)
        a = Address("en", seed=seed)
        f = Finance(seed=seed)
        self.first = [p.first_name() for _ in range(n)]
        self.last = [p.last_name() for _ in range(n)]
        self.full = [f"{self.first[i % n]} {self.last[(i * 7) % n]}" for i in range(n)]
        self.companies = list({f.company() for _ in range(n)})
        self.cities = list({a.city() for _ in range(min(n, 1500))})
        self.words = list({t.word() for _ in range(n)})
        self.sentences = [t.sentence() for _ in range(800)]
        self.domains = ["example.com", "acme.io", "globex.co", "umbrella.dev",
                        "initech.com", "hooli.xyz", "piedpiper.io", "wayne.co"]
        self.streets = list({a.street_name() for _ in range(min(n, 1000))})


# --------------------------------------------------------------------------- #
# Schema introspection
# --------------------------------------------------------------------------- #
def introspect(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT table_schema, table_name FROM information_schema.tables
           WHERE table_schema = ANY(%s) AND table_type='BASE TABLE'""", (SCHEMAS,))
    tables = [f"{s}.{t}" for s, t in cur.fetchall()]

    cols: dict[str, list[dict]] = {t: [] for t in tables}
    cur.execute(
        """SELECT table_schema, table_name, column_name, data_type, udt_name,
                  is_nullable, is_identity, is_generated,
                  numeric_precision, numeric_scale, character_maximum_length
           FROM information_schema.columns
           WHERE table_schema = ANY(%s)
           ORDER BY table_schema, table_name, ordinal_position""", (SCHEMAS,))
    for r in cur.fetchall():
        fq = f"{r[0]}.{r[1]}"
        cols[fq].append(dict(
            name=r[2], dtype=r[3], udt=r[4], nullable=(r[5] == "YES"),
            identity=(r[6] == "YES"), generated=(r[7] == "ALWAYS"),
            nprec=r[8], nscale=r[9], maxlen=r[10],
        ))

    # single-column foreign keys: (fqtn, col) -> (ref_fqtn, ref_col)
    fks: dict[str, dict[str, tuple[str, str]]] = {t: {} for t in tables}
    cur.execute("""
        SELECT con.conrelid::regclass::text, att.attname,
               con.confrelid::regclass::text, fatt.attname
        FROM pg_constraint con
        JOIN pg_attribute att  ON att.attrelid = con.conrelid  AND att.attnum  = con.conkey[1]
        JOIN pg_attribute fatt ON fatt.attrelid = con.confrelid AND fatt.attnum = con.confkey[1]
        WHERE con.contype = 'f' AND array_length(con.conkey, 1) = 1""")
    for tbl, col, ftbl, fcol in cur.fetchall():
        tbl = _norm(tbl); ftbl = _norm(ftbl)
        if tbl in fks:
            fks[tbl][col] = (ftbl, fcol)

    # unique indexes, grouped & ordered by index, so we know composite groups.
    uniq: dict[str, set[str]] = {t: set() for t in tables}          # any unique-indexed col
    groups_by_idx: dict[int, tuple[str, list[tuple[int, str]]]] = {}
    cur.execute("""
        SELECT (i.indrelid::regclass)::text AS tbl, i.indexrelid AS idxoid, a.attname, k.ord
        FROM pg_index i
        CROSS JOIN LATERAL unnest(string_to_array(i.indkey::text, ' ')::int[])
             WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE i.indisunique AND k.attnum > 0""")
    for tbl, idxoid, col, ordn in cur.fetchall():
        tbl = _norm(tbl)
        if tbl not in uniq:
            continue
        uniq[tbl].add(col)
        groups_by_idx.setdefault(idxoid, (tbl, []))[1].append((ordn, col))
    uniq_groups: dict[str, list[tuple[str, ...]]] = {t: [] for t in tables}
    single_unique: dict[str, set[str]] = {t: set() for t in tables}
    for _idx, (tbl, grpcols) in groups_by_idx.items():
        ordered = tuple(c for _, c in sorted(grpcols))
        uniq_groups[tbl].append(ordered)
        if len(ordered) == 1:
            single_unique[tbl].add(ordered[0])

    # enum labels: udt_name -> [labels]
    enums: dict[str, list[str]] = {}
    cur.execute("""
        SELECT t.typname, e.enumlabel
        FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
        ORDER BY e.enumsortorder""")
    for typ, label in cur.fetchall():
        enums.setdefault(typ, []).append(label)

    order = _toposort(tables, fks)
    return dict(tables=tables, cols=cols, fks=fks, uniq=uniq, enums=enums, order=order,
                uniq_groups=uniq_groups, single_unique=single_unique)


def _norm(regclass_text: str) -> str:
    # regclass text is already schema-qualified for our non-public schemas
    return regclass_text.replace('"', "")


def _b26(i: int, width: int) -> str:
    """Deterministic unique fixed-width uppercase code (base-26, A=0).
    Bijective for i in [0, 26**width): i=0->AA, 1->AB, ... 26->BA (width=2)."""
    s = ""
    for _ in range(width):
        i, r = divmod(i, 26)
        s = chr(65 + r) + s
    return s


def _toposort(tables, fks):
    """Order tables so every FK parent precedes its children. Self-FKs and
    cycles are broken (the offending edge is deferred to in-table sampling)."""
    deps = {t: set() for t in tables}
    for t in tables:
        for col, (ref, _) in fks[t].items():
            if ref != t and ref in deps:
                deps[t].add(ref)
    order, placed = [], set()
    # Kahn-ish with deterministic tie-break by name; break cycles by frequency.
    while len(order) < len(tables):
        ready = sorted(t for t in tables if t not in placed and deps[t] <= placed)
        if not ready:
            # cycle: place the remaining table with the fewest unmet deps
            rem = sorted((len(deps[t] - placed), t) for t in tables if t not in placed)
            ready = [rem[0][1]]
        for t in ready:
            order.append(t); placed.add(t)
    return order


# --------------------------------------------------------------------------- #
# The engine
# --------------------------------------------------------------------------- #
MONEY_NAMES = ("amount", "total", "subtotal", "price", "balance", "cost", "fee",
               "revenue", "mrr", "arr", "tax", "discount", "credit", "debit",
               "paid", "due", "value", "rate")


class Engine:
    def __init__(self, conn, scale: str, seed: int, recipes_mod=None):
        self.conn = conn
        self.scale = scale
        self.rng = Rng(seed)
        self.pools = Pools(seed)
        self.S = introspect(conn)
        self.recipes = recipes_mod
        self.n: dict[str, int] = {}                 # fqtn -> row count
        self.tenant_of: dict[str, np.ndarray] = {}  # fqtn -> tenant_id per row (or None)
        self.by_tenant: dict[str, dict[int, np.ndarray]] = {}  # fqtn -> {tenant: ids}
        self.natural: dict[str, dict[str, np.ndarray]] = {}    # fqtn -> {col: values} for non-id FK targets
        self.n_tenants = 0
        self.fallbacks = 0

    # ---- row counts -------------------------------------------------------- #
    def _rows(self, fqtn: str, tenant_scoped: bool) -> int:
        r = config.rows_for(fqtn, self.scale)
        return r if r >= 0 else config.rows_for_default(self.scale, tenant_scoped)

    # ---- public entry ------------------------------------------------------ #
    def run(self, log=print):
        # which non-id columns are FK targets (we must retain their values)
        targets: dict[str, set[str]] = {}
        for t in self.S["tables"]:
            for col, (ref, rcol) in self.S["fks"][t].items():
                if rcol != "id":
                    targets.setdefault(ref, set()).add(rcol)
        self._targets = targets
        # tables that are referenced by an id-FK (the only ones whose per-tenant id
        # index + tenant map a child will ever need). Skipping the rest keeps the big
        # leaf fact tables (events, audit_log, ...) from materializing 10M-row indexes.
        self._id_ref_targets = {ref for t in self.S["tables"]
                                for (ref, rcol) in self.S["fks"][t].values() if rcol == "id"}

        # Drop CHECK constraints during load so an unforeseen bound never aborts the
        # run mid-way; re-add + validate afterwards (any that genuinely fail are
        # re-added NOT VALID and reported, so we know which recipe to harden).
        checks = self._drop_checks()
        for fqtn in self.S["order"]:
            self._gen_table(fqtn, log)
        self._readd_checks(checks, log)
        log(f"done. tenant-isolation fallbacks: {self.fallbacks}")

    def _drop_checks(self):
        rows = []
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT n.nspname, t.relname, c.conname, pg_get_constraintdef(c.oid)
                FROM pg_constraint c
                JOIN pg_class t ON t.oid = c.conrelid
                JOIN pg_namespace n ON n.oid = t.relnamespace
                WHERE c.contype = 'c' AND n.nspname = ANY(%s)""", (SCHEMAS,))
            rows = cur.fetchall()
            for ns, tb, con, _defn in rows:
                cur.execute(f'ALTER TABLE {ns}.{tb} DROP CONSTRAINT "{con}"')
        self.conn.commit()
        return rows

    def _readd_checks(self, rows, log):
        notvalid = 0
        for ns, tb, con, defn in rows:
            try:
                with self.conn.cursor() as cur:
                    cur.execute(f'ALTER TABLE {ns}.{tb} ADD CONSTRAINT "{con}" {defn}')
                self.conn.commit()
            except Exception:
                self.conn.rollback()
                with self.conn.cursor() as cur:
                    cur.execute(f'ALTER TABLE {ns}.{tb} ADD CONSTRAINT "{con}" {defn} NOT VALID')
                self.conn.commit()
                notvalid += 1
                log(f"  ! CHECK re-added NOT VALID (data violates it): {ns}.{tb}.{con}")
        if notvalid:
            log(f"  {notvalid} CHECK constraint(s) re-added NOT VALID — harden a recipe to fix")

    # ---- per-table --------------------------------------------------------- #
    def _gen_table(self, fqtn: str, log):
        cols = self.S["cols"][fqtn]
        fks = self.S["fks"][fqtn]
        uniq = self.S["uniq"][fqtn]
        colnames = {c["name"] for c in cols}
        tenant_scoped = "tenant_id" in colnames
        n = self._rows(fqtn, tenant_scoped)
        if fqtn == "identity.tenants":
            self.n_tenants = n

        # 1) tenant assignment + anchor FK pre-resolution
        tenant_arr = None
        prefilled: dict[str, np.ndarray] = {}
        if tenant_scoped and fqtn != "identity.tenants":
            anchor = self._pick_anchor(fqtn, fks)
            if anchor:
                aref = fks[anchor][0]
                ag = self.rng.s(f"{fqtn}.{anchor}.anchor")
                if anchor in self.S["single_unique"][fqtn] and n <= self.n.get(aref, 0):
                    a_ids = self._distinct_ids(ag, aref, n)          # 1:1 child
                else:
                    a_ids = self._sample_ids(aref, n, "", skew="customer_activity", g=ag)
                tenant_arr = self.tenant_of[aref][a_ids - 1]
                prefilled[anchor] = a_ids
            else:
                g = self.rng.s(f"{fqtn}.tenant")
                tenant_arr = self._zipf_choice(g, self.n_tenants, n, config.ZIPF_A["tenant_size"]) + 1

        # 2) generate every insertable column
        sunq = self.S["single_unique"][fqtn]
        data: dict[str, object] = {}
        insert_cols = []
        for c in cols:
            if c["identity"] or c["generated"]:
                continue
            insert_cols.append(c["name"])
            data[c["name"]] = self._gen_col(fqtn, c, n, tenant_arr, fks, uniq, sunq, prefilled)

        # 3) recipe post-processing (coherence, distributions, money math)
        if self.recipes:
            self.recipes.apply(fqtn, n, data, self, tenant_arr)

        # 3b) drop rows that violate composite-unique constraints (junctions, etc.)
        n, tenant_arr = self._dedup(fqtn, n, data, insert_cols, tenant_arr)

        # 4) retain state for children (only if this table is an id-FK parent)
        self.n[fqtn] = n
        is_parent = fqtn in self._id_ref_targets
        self.tenant_of[fqtn] = tenant_arr if is_parent else None
        if is_parent and tenant_scoped and tenant_arr is not None:
            bt: dict[int, np.ndarray] = {}
            ids = np.arange(1, n + 1)
            order = np.argsort(tenant_arr, kind="stable")
            st = tenant_arr[order]
            uniq_t, starts = np.unique(st, return_index=True)
            for i, tv in enumerate(uniq_t):
                e = starts[i + 1] if i + 1 < len(starts) else n
                bt[int(tv)] = ids[order[starts[i]:e]]
            self.by_tenant[fqtn] = bt
        for rcol in self._targets.get(fqtn, ()):
            if rcol in data and data[rcol] is not None:
                self.natural.setdefault(fqtn, {})[rcol] = np.asarray(data[rcol], dtype=object)

        # 5) COPY
        self._copy(fqtn, insert_cols, data, n)
        log(f"  {fqtn:<34} {n:>10,} rows")

    def _pick_anchor(self, fqtn, fks):
        """Choose the FK whose parent's tenant this row inherits."""
        cands = []
        for col, (ref, rcol) in fks.items():
            if rcol == "id" and ref != fqtn and self.tenant_of.get(ref) is not None:
                cands.append((col, ref))
        if not cands:
            return None
        # prefer a NOT NULL anchor to a "spine" parent
        pref = ("identity.users", "sales.orders", "billing.invoices", "crm.accounts",
                "catalog.products", "support.tickets", "analytics.web_sessions")
        for p in pref:
            for col, ref in cands:
                if ref == p:
                    return col
        return sorted(cands)[0][0]

    # ---- column value generation ------------------------------------------ #
    def _gen_col(self, fqtn, c, n, tenant_arr, fks, uniq, sunq, prefilled):
        name = c["name"]
        if name == "tenant_id":
            return tenant_arr
        if name in prefilled:
            return prefilled[name]
        if name in fks:
            return self._resolve_fk(fqtn, name, fks[name], n, tenant_arr,
                                    c["nullable"], name in sunq)

        g = self.rng.s(f"{fqtn}.{name}")
        udt, dtype = c["udt"], c["dtype"]
        is_unique = name in uniq
        gi = np.arange(n)  # global-ish index for uniqueness salting

        # enums
        if udt in self.S["enums"]:
            labels = self.S["enums"][udt]
            return np.array(labels, dtype=object)[g.integers(0, len(labels), n)]
        # uuid (two 63-bit halves -> a valid 126-bit UUID int, no int64 overflow)
        if dtype == "uuid":
            hi = g.integers(0, 2**63, n, dtype=np.int64)
            lo = g.integers(0, 2**63, n, dtype=np.int64)
            return [uuidlib.UUID(int=(int(hi[i]) << 64) | int(lo[i])) for i in range(n)]
        # booleans
        if dtype == "boolean":
            # "one X per parent" partial-unique flags -> all false to never violate it
            if name.startswith(("is_default", "is_primary", "is_preferred", "is_main")):
                return np.zeros(n, dtype=bool)
            p = 0.5
            if name.startswith(("is_active", "is_enabled", "succeeded", "is_public")): p = 0.85
            elif name.startswith("is_"): p = 0.4
            return g.random(n) < p
        # timestamps / dates
        if dtype.startswith("timestamp"):
            return self._times(g, n)
        if dtype == "date":
            base = self._times(g, n)
            return [d.date() for d in base]
        if dtype == "inet":
            quad = g.integers(1, 254, (n, 4))
            return [f"{a}.{b}.{c2}.{d}" for a, b, c2, d in quad]
        # numerics
        if dtype in ("numeric", "double precision", "real"):
            nscale = c["nscale"] if c["nscale"] is not None else 2
            nprec = c["nprec"]
            cap = 10.0 ** (nprec - nscale) if nprec else 1e12   # fits the declared precision
            if "prob" in name:
                vals = g.random(n)
            elif any(k in name for k in ("percent", "pct")):
                vals = g.random(n) * 100
            elif "rate" in name or "ratio" in name:
                vals = g.random(n)
            elif nscale == 4 or any(k in name for k in MONEY_NAMES):
                vals = g.lognormal(3.0, 1.1, n)                 # skewed positive money
            else:
                vals = g.lognormal(2.0, 1.0, n)
            vals = np.clip(vals, 0.0, cap - 10.0 ** (-nscale))
            return np.round(vals, nscale)
        if dtype in ("integer", "bigint", "smallint"):
            if any(k in name for k in ("quantity", "qty", "count", "units", "seats")):
                return g.integers(1, 12, n)
            if any(k in name for k in ("percent", "pct", "rollout", "progress")):
                return g.integers(0, 101, n)
            if name in ("position", "sort_order", "ordinal", "depth", "step", "rank"):
                return gi % 50
            if name.endswith("_days"):
                return g.integers(1, 90, n)
            if "score" in name or "rating" in name:
                return g.integers(1, 6, n)
            return g.integers(0, 1000, n)
        # arrays
        if dtype == "ARRAY":
            return ["{}" for _ in range(n)]
        if udt == "jsonb" or dtype == "jsonb":
            return self._jsonb(g, name, n)
        # textual (text, citext, char, varchar, ...)
        return self._text(g, name, c, n, is_unique, gi)

    def _text(self, g, name, c, n, is_unique, gi):
        P = self.pools
        maxlen = c["maxlen"]
        def pick(pool):
            arr = np.array(pool, dtype=object)
            return arr[g.integers(0, len(arr), n)]
        # short fixed-width codes (iso2, locale, char(n) ...): must fit maxlen
        if maxlen is not None and maxlen <= 8 and "email" not in name and "url" not in name:
            if is_unique or name in ("iso2", "iso3", "code", "key", "sku", "symbol"):
                return np.array([_b26(i, maxlen) for i in range(n)], dtype=object)
            letters = np.array(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
            w = min(maxlen, 3)
            return np.array(["".join(g.choice(letters, w)) for _ in range(n)], dtype=object)
        # any other UNIQUE unbounded text: guarantee uniqueness with an index salt
        if is_unique and "email" not in name:
            base = pick(P.words)
            return np.array([f"{str(base[i]).title()} {i}" for i in range(n)], dtype=object)
        if "email" in name:
            fn = pick([s.lower() for s in P.first]); ln = pick([s.lower() for s in P.last])
            dom = pick(P.domains)
            return np.array([f"{fn[i]}.{ln[i]}{i}@{dom[i]}" for i in range(n)], dtype=object)
        if name in ("first_name",): return pick(P.first)
        if name in ("last_name",): return pick(P.last)
        if name in ("full_name", "name", "contact_name", "display_name") and "file" not in name:
            return pick(P.full) if name == "full_name" else pick(P.companies)
        if name.endswith("_url") or name in ("url", "avatar_url", "website", "target_url", "endpoint"):
            w = pick(P.words); return np.array([f"https://{P.domains[i % len(P.domains)]}/{w[i]}" for i in range(n)], dtype=object)
        if name == "slug" or name.endswith("_slug"):
            w = pick(P.words); return np.array([f"{w[i]}-{i}" for i in range(n)], dtype=object)
        if is_unique or name in ("sku", "code", "key", "prefix", "token_hash", "hashed_key",
                                  "hashed_token", "secret_hash", "public_id"):
            w = pick(P.words)
            return np.array([f"{w[i][:6].upper()}-{i:07d}" for i in range(n)], dtype=object)
        if name in ("city",): return pick(P.cities)
        if name in ("line1", "line2", "street", "address"):
            s = pick(P.streets); num = g.integers(1, 9999, n)
            return np.array([f"{num[i]} {s[i]}" for i in range(n)], dtype=object)
        if name in ("phone", "phone_number"):
            d = g.integers(1000000000, 9999999999, n)
            return np.array([f"+1{x}" for x in d], dtype=object)
        if any(k in name for k in ("description", "bio", "note", "body", "message", "content",
                                    "comment", "summary", "subject", "title", "text", "reason")):
            return pick(P.sentences)
        if name in ("iso2",) or (maxlen == 2):
            letters = np.array(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
            return np.array(["".join(g.choice(letters, 2)) for _ in range(n)], dtype=object)
        if maxlen == 3:
            letters = np.array(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
            return np.array(["".join(g.choice(letters, 3)) for _ in range(n)], dtype=object)
        # default: a short word, salted if it must be unique
        w = pick(P.words)
        return w

    def _times(self, g, n):
        offs = g.random(n) * WINDOW_S
        return [START + dt.timedelta(seconds=float(s)) for s in offs]

    def _jsonb(self, g, name, n):
        keys = ["source", "channel", "device", "version", "country", "plan"]
        vals = ["web", "mobile", "api", "ios", "android", "v1", "v2", "us", "eu"]
        out = []
        kk = g.integers(0, len(keys), n); vv = g.integers(0, len(vals), n)
        for i in range(n):
            out.append(f'{{"{keys[kk[i]]}": "{vals[vv[i]]}"}}')
        return out

    # ---- FK resolution ----------------------------------------------------- #
    def _resolve_fk(self, fqtn, col, ref_rcol, n, tenant_arr, nullable, is_sunique=False):
        ref, rcol = ref_rcol
        g = self.rng.s(f"{fqtn}.{col}.fk")
        # natural-key FK (currency code, plan code, iso2, sku, ...)
        if rcol != "id":
            vals = self.natural.get(ref, {}).get(rcol)
            if vals is None or len(vals) == 0:
                return [None] * n
            out = np.asarray(vals, dtype=object)[g.integers(0, len(vals), n)]
            return self._maybe_null(g, out, nullable, col, 0.1)
        # id FK
        ref_n = self.n.get(ref, 0)
        if ref_n == 0:
            return [None] * n
        if is_sunique and ref_n >= n:                       # 1:1 / unique FK
            ids = self._distinct_ids(g, ref, n)
        elif self.tenant_of.get(ref) is not None and tenant_arr is not None:
            ids = self._sample_within_tenant(g, ref, tenant_arr, n)
        else:
            ids = self._sample_ids(ref, n, f"{fqtn}.{col}", g=g)
        return self._maybe_null(g, ids, nullable, col, 0.15)

    def _distinct_ids(self, g, ref, n):
        """n distinct parent ids (for 1:1 / unique FK columns). Requires n <= ref_n."""
        ref_n = self.n[ref]
        if n >= ref_n:
            ids = np.arange(1, ref_n + 1)
            g.shuffle(ids)
            return ids
        return g.choice(ref_n, size=n, replace=False) + 1

    def _dedup(self, fqtn, n, data, insert_cols, tenant_arr):
        """Drop rows violating any composite-unique constraint (junctions, etc.)."""
        groups = [grp for grp in self.S["uniq_groups"][fqtn]
                  if len(grp) > 1 and all(col in data for col in grp)]
        if not groups or n == 0:
            return n, tenant_arr
        keep = np.ones(n, dtype=bool)
        for grp in groups:
            colvals = [np.asarray(data[c], dtype=object) for c in grp]
            seen = set()
            for i in range(n):
                if not keep[i]:
                    continue
                key = tuple(cv[i] for cv in colvals)
                if key in seen:
                    keep[i] = False
                else:
                    seen.add(key)
        if keep.all():
            return n, tenant_arr
        idx = np.where(keep)[0]
        for c in insert_cols:
            v = data[c]
            data[c] = v[idx] if isinstance(v, np.ndarray) else [v[i] for i in idx]
        if tenant_arr is not None:
            tenant_arr = np.asarray(tenant_arr)[idx]
        return len(idx), tenant_arr

    def _maybe_null(self, g, arr, nullable, col, base):
        if not nullable:
            return arr
        p = base
        if col.startswith(("parent_", "assignee", "assigned", "manager", "related")):
            p = 0.5
        mask = g.random(len(arr)) < p
        arr = np.array(arr, dtype=object)
        arr[mask] = None
        return arr

    def _sample_ids(self, ref, n, stream, skew=None, g=None):
        ref_n = self.n[ref]
        g = g or self.rng.s(stream)
        if skew:
            return self._zipf_choice(g, ref_n, n, config.ZIPF_A[skew]) + 1
        return g.integers(1, ref_n + 1, n)

    def _sample_within_tenant(self, g, ref, tenant_arr, n):
        bt = self.by_tenant.get(ref, {})
        out = np.empty(n, dtype=np.int64)
        for tv in np.unique(tenant_arr):
            idx = np.where(tenant_arr == tv)[0]
            pool = bt.get(int(tv))
            if pool is None or len(pool) == 0:
                pool = np.arange(1, self.n[ref] + 1)  # cross-tenant fallback (rare)
                self.fallbacks += len(idx)
            out[idx] = pool[g.integers(0, len(pool), len(idx))]
        return out

    @staticmethod
    def _zipf_choice(g, k, size, a):
        """Sample `size` ints in [0,k) with a Zipf-like skew over rank."""
        w = 1.0 / np.power(np.arange(1, k + 1), a)
        w /= w.sum()
        return g.choice(k, size=size, p=w)

    # ---- COPY -------------------------------------------------------------- #
    def _copy(self, fqtn, insert_cols, data, n):
        collist = ", ".join(f'"{c}"' for c in insert_cols)
        # materialize columns as python lists once
        mats = []
        for c in insert_cols:
            v = data[c]
            if isinstance(v, np.ndarray):
                mats.append(v.tolist())
            elif isinstance(v, list):
                mats.append(v)
            else:  # scalar (shouldn't happen) -> broadcast
                mats.append([v] * n)
        with self.conn.cursor() as cur:
            with cur.copy(f"COPY {fqtn} ({collist}) FROM STDIN") as cp:
                for i in range(n):
                    cp.write_row(tuple(m[i] for m in mats))
        self.conn.commit()
