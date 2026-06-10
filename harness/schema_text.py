"""Render the full live schema as text — the input the naive baseline dumps into
its prompt. (The whole heron thesis is that this doesn't scale to 211 tables.)"""
from __future__ import annotations

SCHEMAS = ("identity", "geo", "catalog", "pricing", "inventory", "sales", "billing",
           "crm", "support", "marketing", "analytics", "comms", "audit", "ops")


def render_schema(conn, only: set[str] | None = None) -> str:
    """Render the schema as DDL-ish text. If `only` is given (a set of
    `schema.table` names), render just those tables + their FKs — used by the
    schema-pruning adapters (MAC-SQL selector, DIN-SQL schema-linking) to build
    the reduced downstream prompt."""
    cur = conn.cursor()
    cur.execute("""
        SELECT table_schema, table_name, column_name,
               CASE WHEN data_type='USER-DEFINED' THEN udt_name ELSE data_type END,
               is_nullable
        FROM information_schema.columns
        WHERE table_schema = ANY(%s)
        ORDER BY table_schema, table_name, ordinal_position""", (list(SCHEMAS),))
    cols: dict[str, list[str]] = {}
    for s, t, c, dt, nn in cur.fetchall():
        qn = f"{s}.{t}"
        if only is not None and qn not in only:
            continue
        cols.setdefault(qn, []).append(
            f"{c} {dt}{'' if nn == 'YES' else ' NOT NULL'}")

    cur.execute("""
        SELECT con.conrelid::regclass::text, att.attname,
               con.confrelid::regclass::text, fatt.attname
        FROM pg_constraint con
        JOIN pg_attribute att  ON att.attrelid=con.conrelid  AND att.attnum=con.conkey[1]
        JOIN pg_attribute fatt ON fatt.attrelid=con.confrelid AND fatt.attnum=con.confkey[1]
        WHERE con.contype='f' AND array_length(con.conkey,1)=1""")
    fks: dict[str, list[str]] = {}
    for tbl, col, ftbl, fcol in cur.fetchall():
        tbl = tbl.replace('"', ""); ftbl = ftbl.replace('"', "")
        fks.setdefault(tbl, []).append(f"{col} -> {ftbl}({fcol})")

    out = []
    for t in sorted(cols):
        out.append(f"TABLE {t} (")
        out.append("  " + ", ".join(cols[t]))
        if t in fks:
            out.append("  FK: " + "; ".join(fks[t]))
        out.append(")")
    return "\n".join(out)
