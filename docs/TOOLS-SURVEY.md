# NL-to-SQL Tools Survey — what we can benchmark on heron

> **Purpose.** Survey every notable open-source NL-to-SQL / text-to-SQL tool as of **June 2026** and decide
> which can be benchmarked **locally, in-process, headless** against the heron schema (PostgreSQL,
> **211 tables across 14 schemas**, production-shaped multi-tenant SaaS). Every benchmarked system runs on
> the **same model: OpenAI `gpt-4o`, temperature 0**, so the only variable is the tool's retrieval /
> schema-handling pipeline.
>
> **Buckets** (each tool gets exactly one):
> - **(A) PIP-INSTALLABLE library** that generates SQL with an OpenAI model, runnable in-process/headless → **we benchmark these.**
> - **(B) SERVER / DOCKER / UI app** (needs a running backend or web UI) → deferred; reason noted.
> - **(C) MODEL-ONLY / needs-GPU** (a fine-tuned weight set, not a pipeline) → deferred; reason noted.
>
> **The key differentiator for heron is multi-schema scale.** Most tools assume a single `public` schema and
> either (a) dump the whole schema into the prompt, (b) reflect one schema via SQLAlchemy, (c) RAG/retrieve
> tables, or (d) require a manual table list. heron has 211 tables in 14 schemas; how each tool copes is the
> column that matters.
>
> **API drift warning.** These libraries' APIs move fast. Signatures below were verified against current
> (June 2026) PyPI metadata, GitHub READMEs, vendor docs, and Context7-served docs. URLs cited inline.
> Re-verify before a publication run.

---

## Summary comparison table

| Tool | Repo | License | ~Stars | Bucket | Latest (PyPI/release) | Multi-schema handling | One-line positioning |
|---|---|---|---:|:---:|---|---|---|
| **LangChain** `create_sql_query_chain` | [langchain-ai/langchain](https://github.com/langchain-ai/langchain) | MIT | ~138.9k | **A** | `langchain` 1.3.4, `langchain-classic` 1.0.7 | SQLAlchemy reflection; **single schema unless you pass `include_tables` / `schema=`**; dumps reflected DDL into prompt → blows context at 211 tables unless you subset | Composable chain that reflects a `SQLDatabase` and emits one SQL string |
| **LlamaIndex** `NLSQLTableQueryEngine` | [run-llama/llama_index](https://github.com/run-llama/llama_index) | MIT | ~50k | **A** | `llama-index` 0.14.22 | Dumps all `include_tables` DDL into the prompt — needs an explicit table list | Query engine that renders table schemas into the prompt and returns SQL in `response.metadata['sql_query']` |
| **LlamaIndex** `SQLTableRetrieverQueryEngine` | [run-llama/llama_index](https://github.com/run-llama/llama_index) | MIT | ~50k | **A** | `llama-index` 0.14.22 | **RAG over table schemas** via `ObjectIndex` + embeddings; `similarity_top_k` picks the relevant N of 211 — the only built-in tool that genuinely *retrieves* tables | Retrieval-augmented variant: embeds 211 `SQLTableSchema` objects, retrieves top-k, then generates |
| **Vanna (legacy 0.7.x)** | [vanna-ai/vanna](https://github.com/vanna-ai/vanna) *(archived)* | MIT | ~23.6k | **A** | `vanna` last legacy = **0.7.9** | **RAG over trained DDL** in a vector store (ChromaDB); retrieves ~10 most-relevant DDL chunks per question — multi-schema works if you `train(ddl=...)` per table | RAG text-to-SQL: train on DDL/docs/SQL, `generate_sql()` retrieves + prompts |
| **Vanna 2.0** | [vanna-ai/vanna](https://github.com/vanna-ai/vanna) | MIT | ~23.6k | **B** | `vanna` 2.0.2 | Agent + tool-registry + web component; meant for deployed user-aware agents | Full rewrite: agent architecture, RLS/audit, `<vanna-chat>` web component |
| **premsql** | [premAI-io/premsql](https://github.com/premAI-io/premsql) | Apache-2.0* | ~0.46k | **A** | `premsql` 0.2.10 (last release Feb 2025) | DB connector reflects schema; built around a fixed schema string fed to a generator — no built-in retrieval-at-scale | Local-first NL2SQL pipeline (datasets/executors/evaluators/generators); OpenAI is one generator backend |
| **MindSQL** | [Mindinventory/MindSQL](https://github.com/Mindinventory/MindSQL) | **GPL-3.0** | ~0.44k | **A** | `mindsql` 0.2.1 (Mar 2024) | RAG over indexed DDL (ChromaDB/Faiss), à la Vanna; `index_all_ddls` then `ask_db` | Vanna-style RAG library; **GPL-3.0 (viral)**, stale |
| **WrenAI** | [Canner/WrenAI](https://github.com/Canner/WrenAI) | AGPL-3.0 (NOASSERTION) | ~15.5k | **B** | Docker-compose stack | Semantic/"context" layer (MDL modeling) over the DB; designed for governed multi-source | GenBI platform: UI + engine + AI service via docker-compose |
| **DB-GPT** | [eosphoros-ai/DB-GPT](https://github.com/eosphoros-ai/DB-GPT) | MIT | ~18.9k | **B** | `dbgpt` 0.8.0 | RAG knowledge + multi-agent (AWEL); schema RAG exists but bundled in an app framework | Agentic AI-native data app platform (AWEL workflows, web app + setup wizard) |
| **Dataherald (engine)** | [Dataherald/dataherald](https://github.com/Dataherald/dataherald) | Apache-2.0 | ~3.6k | **B** | engine = docker-compose; `dataherald` PyPI 0.20.0 is only the **API client** | Server stores "golden SQL" + schema scans in Mongo; FastAPI engine | Self-hosted NL2SQL **engine** (FastAPI + Mongo); repo last touched Jul 2024 |
| **Defog / SQLCoder** | [defog-ai/sqlcoder](https://github.com/defog-ai/sqlcoder) | Apache-2.0 (code) | ~4k | **C** | weights on HF; repo stale (2024) | A *model*, not a pipeline; you feed it schema + question | Fine-tuned SQL LLM (StarCoder/CodeLlama/Llama-3 lineage) — needs a GPU; **not an OpenAI pipeline** |
| **XiYan-SQL** | [XGenerationLab/XiYan-SQL](https://github.com/XGenerationLab/XiYan-SQL) | Apache-2.0 | ~1k | **C** | research code + HF weights | Multi-generator ensemble + schema linker; research repo, GPU-oriented | SOTA-leaderboard multi-generator framework; not a clean pip-install OpenAI lib |
| **SQLChat** | [sqlchat/sqlchat](https://github.com/sqlchat/sqlchat) | MIT | ~5.8k | **B** | Next.js web app | Chat UI; per-conversation schema context | Browser chat-based SQL client (TypeScript web app) |
| **DBHub (MCP)** | [bytebase/dbhub](https://github.com/bytebase/dbhub) | MIT | ~2k | **B** | MCP server | Exposes DB over MCP; the LLM client does retrieval | Universal database MCP server (needs an MCP host) |
| **pgMagic / postgres.new / Postgres MCP** | various | mixed | — | **B** | browser/MCP | In-browser WASM PG or MCP server | "Talk to your Postgres" UIs / MCP servers, no headless lib |
| **Instructor** (baseline scaffold) | [567-labs/instructor](https://github.com/567-labs/instructor) | MIT | ~13.1k | **A**† | `instructor` (current) | None built-in — *you* build the schema prompt + retrieval | Structured-output wrapper over OpenAI; useful to build a **raw OpenAI structured-output baseline** |
| **OpenAI structured-output baseline** (DIY) | — (stdlib `openai`) | — | — | **A**† | `openai` SDK | Whatever you implement; heron already ships `raw-llm` (full-schema dump) | Direct `openai` call: this is exactly heron's existing `raw-llm` adapter |

\* premsql ships no SPDX license tag on GitHub; the repo/blog describe it as open-source (PremAI uses Apache-2.0 elsewhere) — **verify the LICENSE file before redistribution.**
† Instructor and the DIY OpenAI baseline are bucket-A *scaffolds*, not turn-key NL2SQL libraries — they have **no schema retrieval of their own**. heron's existing `raw-llm` adapter already covers the DIY baseline; Instructor only adds typed extraction on top.

---

## Bucket (A) — pip-installable, headless, OpenAI gpt-4o → **benchmarkable**

All snippets assume the heron Postgres is reachable via a Unix-socket DSN and that the multi-schema
`search_path` is set on the connection. SQLAlchemy URL form used throughout:

```python
DB_URI = "postgresql+psycopg://user@/db?host=/tmp/heron_pg&port=55432"
# multi-schema search_path is set per-connection (see each snippet)
import os; os.environ["OPENAI_API_KEY"] = "sk-..."  # required by every tool below
```

> **psycopg gotcha:** these libraries use SQLAlchemy under the hood and expect **psycopg3** for the
> `postgresql+psycopg://` driver (`pip install "psycopg[binary]"`). If a tool pins `psycopg2`, use
> `postgresql+psycopg2://` instead. heron itself uses psycopg3.

### A1. LangChain — `create_sql_query_chain`

**Install (the #1 gotcha is the package split):**
```bash
pip install -U langchain langchain-classic langchain-community langchain-openai "psycopg[binary]" SQLAlchemy
```

> **GOTCHA — `langchain_classic`.** In LangChain **1.x**, `create_sql_query_chain` was moved out of the core
> `langchain` package into **`langchain_classic.chains`**. `SQLDatabase` lives in
> **`langchain_community.utilities`**. Old tutorials importing `from langchain.chains import
> create_sql_query_chain` **fail on 1.x**. Source:
> [reference.langchain.com create_sql_query_chain (langchain-classic)](https://reference.langchain.com/python/langchain-classic/chains/sql_database/query/create_sql_query_chain),
> [LangChain SQLDatabase toolkit docs](https://python.langchain.com/docs/integrations/toolkits/sql_database/).

> **GOTCHA — multi-schema.** `SQLDatabase.from_uri(...)` reflects **only one schema at a time** (the `schema=`
> kwarg, default the connection's first search_path entry / `public`). Reflecting **all 211 tables** and
> dumping them into the prompt will overflow context, and cross-schema reflection requires either setting
> `schema=` per call or pre-selecting `include_tables=[...]`. For heron you **must** subset tables (e.g. feed
> heron's own retriever output as `include_tables`) — LangChain does no table retrieval itself.

```python
from langchain_classic.chains import create_sql_query_chain        # 1.x location!
from langchain_community.utilities import SQLDatabase
from langchain_openai import ChatOpenAI

DB_URI = "postgresql+psycopg://user@/db?host=/tmp/heron_pg&port=55432"

# Reflect a bounded set of tables. SQLDatabase reflects ONE schema per object;
# to cross 14 schemas, either build one SQLDatabase per schema, or set the
# connection search_path and pass schema-qualified include_tables.
db = SQLDatabase.from_uri(
    DB_URI,
    schema="sales",                       # pick a schema; repeat per schema if needed
    include_tables=["orders", "order_items", "customers"],  # subset → keeps prompt small
    sample_rows_in_table_info=0,          # don't dump sample rows (smaller prompt)
)

llm = ChatOpenAI(model="gpt-4o", temperature=0)
chain = create_sql_query_chain(llm, db)

sql = chain.invoke({"question": "How many orders were placed last month?"})
print(sql)   # -> the generated SQL string (LangChain prefixes 'SQLQuery:' on some versions; strip it)
```

- **SQL out:** `chain.invoke(...)` returns the SQL string directly (strip a leading `SQLQuery:` if present).
- **Tables it selected:** none — LangChain uses whatever you reflected. To report a retrieved-table set you
  must wire heron's retriever in front and pass it as `include_tables`. (Treat LangChain as
  "given a table list, write SQL" — pair it with heron's selector for an apples-to-apples retrieval run.)

### A2. LlamaIndex — `NLSQLTableQueryEngine` (explicit table list)

**Install:**
```bash
pip install -U llama-index llama-index-llms-openai llama-index-embeddings-openai "psycopg[binary]" SQLAlchemy
```

> **GOTCHA — multi-schema.** LlamaIndex's `SQLDatabase` wraps a SQLAlchemy engine and reflects the
> **connection's default schema**. For 14 schemas, set the engine's `search_path` (or pass
> `schema=`/qualified names) so reflection sees all target tables. `NLSQLTableQueryEngine` renders the **full
> DDL of every table in `tables=[...]` into the prompt**, so you must pass a *bounded* list — at 211 tables
> the prompt overflows. This engine is "I already know the ~5 tables."

```python
from sqlalchemy import create_engine, event
from llama_index.core import SQLDatabase
from llama_index.core.query_engine import NLSQLTableQueryEngine
from llama_index.llms.openai import OpenAI

DB_URI = "postgresql+psycopg://user@/db?host=/tmp/heron_pg&port=55432"
engine = create_engine(DB_URI)

# make every connection see all 14 schemas
@event.listens_for(engine, "connect")
def _set_search_path(dbapi_conn, _):
    with dbapi_conn.cursor() as c:
        c.execute("SET search_path TO identity, sales, billing, crm, support, public")  # all 14

llm = OpenAI(model="gpt-4o", temperature=0)
sql_database = SQLDatabase(engine, include_tables=["orders", "order_items", "customers"])

qe = NLSQLTableQueryEngine(sql_database=sql_database,
                           tables=["orders", "order_items", "customers"],
                           llm=llm)
resp = qe.query("How many orders were placed last month?")
print(resp.metadata["sql_query"])   # <-- the generated SQL
```

- **SQL out:** `resp.metadata["sql_query"]` (verified format:
  `Response(..., metadata={'result': [...], 'sql_query': 'SELECT ...'})`). Source: Context7 / LlamaIndex
  `SQLIndexDemo` + `duckdb_sql_query` cookbooks ([run-llama/llama_index docs](https://github.com/run-llama/llama_index/blob/main/docs/examples/index_structs/struct_indices/SQLIndexDemo.ipynb)).
- **Tables it selected:** you supplied them in `tables=[...]`.

### A3. LlamaIndex — `SQLTableRetrieverQueryEngine` (RAG over schemas — the heron-shaped one)

This is the **only off-the-shelf engine that genuinely retrieves tables** out of 211 via embeddings, so it's
the most direct external comparator to heron's own TF-IDF+FK retriever.

**Install:** same as A2.

```python
from sqlalchemy import create_engine, event, inspect
from llama_index.core import SQLDatabase, VectorStoreIndex
from llama_index.core.indices.struct_store.sql_query import SQLTableRetrieverQueryEngine
from llama_index.core.objects import SQLTableNodeMapping, ObjectIndex, SQLTableSchema
from llama_index.llms.openai import OpenAI
from llama_index.embeddings.openai import OpenAIEmbedding

DB_URI = "postgresql+psycopg://user@/db?host=/tmp/heron_pg&port=55432"
SCHEMAS = ["identity", "sales", "billing", "crm", "support", "public"]  # all 14

engine = create_engine(DB_URI)
@event.listens_for(engine, "connect")
def _sp(dbapi_conn, _):
    with dbapi_conn.cursor() as c:
        c.execute(f"SET search_path TO {', '.join(SCHEMAS)}")

# enumerate ALL 211 tables across 14 schemas and register each as a SQLTableSchema
insp = inspect(engine)
all_tables = []
for sch in SCHEMAS:
    for t in insp.get_table_names(schema=sch):
        all_tables.append(t)            # use schema-qualified names if you hit collisions

sql_database = SQLDatabase(engine, include_tables=all_tables)
node_mapping = SQLTableNodeMapping(sql_database)
table_schema_objs = [SQLTableSchema(table_name=t) for t in all_tables]   # 211 objects

obj_index = ObjectIndex.from_objects(
    table_schema_objs, node_mapping, VectorStoreIndex,
    embed_model=OpenAIEmbedding(model="text-embedding-3-small"),
)
qe = SQLTableRetrieverQueryEngine(
    sql_database,
    obj_index.as_retriever(similarity_top_k=5),   # retrieve 5 of 211
    llm=OpenAI(model="gpt-4o", temperature=0),
)
resp = qe.query("How many orders were placed last month?")
print(resp.metadata["sql_query"])                 # the generated SQL
# retrieved tables (the retrieval axis heron measures):
retrieved = [n.table_name for n in obj_index.as_retriever(similarity_top_k=5)
             .retrieve("How many orders were placed last month?")]
print(retrieved)
```

- **SQL out:** `resp.metadata["sql_query"]`.
- **Tables it selected:** re-run the retriever (shown) — these are the top-k tables, the direct analogue to
  heron's Set-Recall metric. Source: Context7 / LlamaIndex `SQLIndexDemo` + `advanced_text_to_sql` cookbooks.
- **GOTCHA — collisions:** `SQLTableSchema(table_name=...)` is unqualified; across 14 schemas you can have
  duplicate table names. Pass schema-qualified names (or per-schema `SQLDatabase` objects) to disambiguate,
  or you'll silently retrieve the wrong table.

### A4. Vanna (legacy 0.7.x) — RAG over trained DDL

**Install (PIN AWAY FROM 2.0):**
```bash
pip install "vanna[chromadb,openai,postgres]==0.7.9"
```

> **GOTCHA #1 — `pip install vanna` now gives you 2.0.x**, a complete rewrite with an **agent / tool-registry
> API** (no `VannaBase`, no `vn.train()`, no `OpenAI_Chat`/`ChromaDB_VectorStore`). The repo is **archived**
> (Feb 2026) and the README documents 2.0. To benchmark the familiar headless `generate_sql()` flow you
> **must pin `vanna==0.7.9`** (last legacy release). Sources:
> [vanna-ai/vanna repo (archived)](https://github.com/vanna-ai/vanna),
> [PyPI vanna versions](https://pypi.org/project/vanna/) (0.7.9 → 2.0.0 jump),
> [legacy Postgres+OpenAI+ChromaDB doc](https://ask.vanna.ai/docs/postgres-openai-standard-chromadb/).

> **GOTCHA #2 — multi-schema:** Vanna has no notion of schemas; it RAGs over whatever DDL **you trained**.
> Feed it `CREATE TABLE` DDL for all 211 tables (schema-qualified), and at query time it retrieves the ~10
> most-relevant DDL chunks. So multi-schema "just works" *iff* your trained DDL uses qualified names.
> chromadb is a heavy dep and pulls its own onnxruntime — see dependency conflicts below.

```python
from vanna.openai import OpenAI_Chat
from vanna.chromadb import ChromaDB_VectorStore

class HeronVanna(ChromaDB_VectorStore, OpenAI_Chat):
    def __init__(self, config=None):
        ChromaDB_VectorStore.__init__(self, config=config)
        OpenAI_Chat.__init__(self, config=config)

vn = HeronVanna(config={"api_key": "sk-...", "model": "gpt-4o", "temperature": 0})

# Vanna's connect_to_postgres takes discrete params, not a URI:
vn.connect_to_postgres(host="/tmp/heron_pg", dbname="db", user="user",
                       password="", port=55432)

# train on schema-qualified DDL for ALL 211 tables (pull DDL from pg_catalog/your dump):
for ddl in heron_all_table_ddls():        # e.g. "CREATE TABLE sales.orders (...)"
    vn.train(ddl=ddl)
# optionally: vn.train(documentation="..."), vn.train(sql="...gold examples...")

sql = vn.generate_sql(question="How many orders were placed last month?")
print(sql)
# retrieved context (the DDL chunks it pulled) — the closest thing to a retrieved-table set:
related = vn.get_related_ddl("How many orders were placed last month?")
print(related)
```

- **SQL out:** `vn.generate_sql(question=...)` returns the SQL string (`vn.ask(...)` also runs+plots; use
  `generate_sql` for a headless benchmark).
- **Tables it selected:** `vn.get_related_ddl(question)` returns the retrieved DDL chunks → parse table names
  from them for a Set-Recall analogue.

### A5. premsql — local-first pipeline with an OpenAI generator (lower priority)

**Install:**
```bash
pip install premsql
```

premsql supports an OpenAI generator backend (it benchmarks gpt-4o on BIRD in its own docs), but the project
is **oriented around local SLMs** (`prem-1B-SQL`), its **last release was Feb 2025** (effectively
unmaintained), it has **no built-in retrieval-at-scale** (it feeds a fixed schema string to the generator),
and the newer "PremSQL Agents/API/Playground" pieces are a **self-hosted API + UI** (bucket-B-ish). The
generator API has churned across versions, so the exact `gpt-4o` call must be re-verified against the
installed version's `premsql.generators` before use. **Recommend: include only if time permits, low
priority.** Sources: [premAI-io/premsql](https://github.com/premAI-io/premsql),
[PremSQL blog](https://blog.premai.io/premsql-end-to-end-local-text-to-sql-pipelines/).

### A6. MindSQL — Vanna-style RAG (DEFER on license grounds)

**Install:** `pip install mindsql` (0.2.1).

MindSQL is technically bucket-A (headless `index_all_ddls` + `ask_db`, ChromaDB RAG like Vanna), **but**:
(1) it is **GPL-3.0** — viral copyleft, awkward to vendor into an MIT/CC-BY benchmark harness; (2) **last
release March 2024**, ~49 commits, effectively abandoned; (3) the OpenAI LLM class name and `model=gpt-4o`
config path are **undocumented** in the current README (examples only show `GoogleGenAi`). **Recommend:
exclude** — Vanna-legacy covers the same RAG-over-DDL pattern with a permissive license and better docs.
Sources: [Mindinventory/MindSQL](https://github.com/Mindinventory/MindSQL), [mindsql on PyPI](https://pypi.org/project/mindsql/).

### A7. OpenAI structured-output / Instructor baseline (already covered by heron's `raw-llm`)

A direct `openai` call that dumps the schema and asks for SQL **is** heron's existing `raw-llm` adapter
(`harness/adapters/raw_llm.py`). [Instructor](https://github.com/567-labs/instructor) (`pip install
instructor`) only adds Pydantic-typed extraction on top — it has **no schema retrieval**. These are the
"naive baseline" tier, not new tools to integrate. Keep `raw-llm` as the floor; optionally add an
Instructor-typed variant if you want a structured-output baseline, but it won't change the retrieval story.

---

## Bucket (B) — server / docker / UI apps → **deferred**

| Tool | Why deferred (B) |
|---|---|
| **WrenAI** | Multi-container **docker-compose stack** (UI + `wren-engine` + `wren-ai-service` + ibis-server) requiring an `OPENAI_API_KEY` in `.env` and a running semantic/MDL layer. No headless `generate_sql()` Python entrypoint that fits the adapter contract; you'd benchmark its HTTP API, not a library. AGPL-3.0. [Canner/WrenAI](https://github.com/Canner/WrenAI), [self-host docs](https://docs.getwren.ai/oss/overview/cloud_vs_self_host). |
| **DB-GPT** | `pip install "dbgpt[agent]"` exists, but DB-GPT is a heavyweight **agentic AI-native data app platform** (AWEL workflows, multi-model proxy, web app + interactive setup wizard). Getting a single deterministic SQL string out of it headlessly is fighting the framework. Treat as a deployed app. [eosphoros-ai/DB-GPT](https://github.com/eosphoros-ai/DB-GPT), `dbgpt` 0.8.0. |
| **Dataherald (engine)** | The NL2SQL **engine** is a **FastAPI + Mongo docker-compose** server (stores golden-SQL + schema scans in Mongo). The `dataherald` PyPI package (0.20.0) is just the **REST API client**, not the engine. Repo last touched **Jul 2024**. [Dataherald/dataherald](https://github.com/Dataherald/dataherald). |
| **Vanna 2.0** | New agent + tool-registry architecture aimed at **deployed, user-aware agents** with a `<vanna-chat>` web component, RLS, audit logging. Not a drop-in headless `generate_sql()`. (Use legacy 0.7.9 for benchmarking — see A4.) [PyPI vanna 2.0.2](https://pypi.org/project/vanna/). |
| **SQLChat** | TypeScript **Next.js web app** (chat-based SQL client). No Python library surface. [sqlchat/sqlchat](https://github.com/sqlchat/sqlchat). |
| **DBHub / postgres.new / pgMagic / Postgres MCP** | **MCP servers** or **browser/WASM** "talk to your Postgres" UIs. The LLM client (an MCP host) drives them; there's no in-process SQL-generation library to call. [bytebase/dbhub](https://github.com/bytebase/dbhub). |

---

## Bucket (C) — model-only / needs-GPU → **deferred** (incompatible with "same model = gpt-4o")

| Tool | Why deferred (C) |
|---|---|
| **Defog / SQLCoder** | A **fine-tuned model** (SQLCoder-7B/15B/70B; Llama-3/StarCoder lineage), not a pipeline. You self-host the weights on a GPU and prompt it with schema+question. It is **not** an OpenAI pipeline, so it violates the "everyone runs gpt-4o" control. (Defog's newer `defog` Python package is a thin agent shim, ~55 stars, repo active but tiny — still points at self-hosted/Defog models, not a gpt-4o NL2SQL lib.) [defog-ai/sqlcoder](https://github.com/defog-ai/sqlcoder). |
| **XiYan-SQL / XiYanSQL-QwenCoder** | Leaderboard-topping **multi-generator + schema-linker research framework** shipping **HF model weights** (Qwen-based). GPU-oriented research code, not a clean pip-installable gpt-4o library. Could be adapted but is out of scope for a same-model comparison. [XGenerationLab/XiYan-SQL](https://github.com/XGenerationLab/XiYan-SQL). |
| **premsql `prem-1B-SQL`** | The library's flagship is a **local 1B SLM** (GPU/CPU local inference). Only relevant to us via its *OpenAI generator* backend (see A5) — the model itself is bucket-C. |
| **StructLM, CodeS, NSQL, SQL-Llama, etc.** | Academic **fine-tuned weight sets** on HuggingFace. Model-only, GPU-bound, not gpt-4o pipelines. |

---

## Dependency-conflict gotchas (read before building the benchmark env)

These libraries do **not** coexist happily in one venv. Use **isolated venvs per adapter** (heron's harness
shells out per adapter anyway, so this is natural).

1. **LangChain vs LlamaIndex `pydantic` / `openai` pins.** Both pull `openai`, `pydantic` v2, `tiktoken`,
   `tenacity` — but pin different ranges across releases. Co-installing often downgrades one. **Separate
   venvs.**
2. **`langchain` 1.x package split.** You need `langchain` **and** `langchain-classic` **and**
   `langchain-community` **and** `langchain-openai`. Installing only `langchain` will `ImportError` on
   `create_sql_query_chain`. (Verified: `langchain` 1.3.4, `langchain-classic` 1.0.7 on PyPI.)
3. **Vanna legacy + chromadb.** `vanna[chromadb]==0.7.9` pulls **chromadb**, which drags **onnxruntime** and
   an embedding model download on first use, and pins older `pydantic`/`numpy` that fight LlamaIndex/LangChain.
   Strongly prefer an isolated venv. Also: `pip install vanna` **without** the `==0.7.9` pin silently gives
   you the incompatible 2.0 API.
4. **psycopg2 vs psycopg3.** heron uses **psycopg3** (`postgresql+psycopg://`). Some tool docs assume
   `psycopg2` (`postgresql+psycopg2://`). Pick the matching driver string per tool; don't install both
   blindly.
5. **`tiktoken` / `gpt-4o` tokenizer.** All OpenAI-path tools assume current `tiktoken` knows `gpt-4o`'s
   encoding; an old pinned `tiktoken` can mis-count and silently truncate the 211-table prompt. Use current
   `tiktoken`.
6. **OpenAI SDK major version.** Vanna-legacy was written against `openai>=1.x` chat-completions; the modern
   `openai` SDK is fine, but if any tool pins `openai<1` (none of the recommended set do) it will break.

---

## Recommended benchmark set

Run these **bucket-(A)** systems, each in its own venv, all on **OpenAI `gpt-4o`, temperature 0**, against the
211-table / 14-schema heron Postgres. Listed in priority order.

| # | System | Install | Multi-schema strategy | Retrieval axis? |
|---|---|---|---|---|
| 1 | **LlamaIndex `SQLTableRetrieverQueryEngine`** | `pip install -U llama-index llama-index-llms-openai llama-index-embeddings-openai "psycopg[binary]"` | **Embeds all 211 `SQLTableSchema`, retrieves top-k.** The true external comparator to heron's retriever. | **YES** — top-k tables = Set-Recall analogue. |
| 2 | **LlamaIndex `NLSQLTableQueryEngine`** | same as #1 | Full-DDL-in-prompt; needs a bounded `tables=[...]`. Pair with heron's selector or run as "oracle-tables." | No (given a list). |
| 3 | **LangChain `create_sql_query_chain`** | `pip install -U langchain langchain-classic langchain-community langchain-openai "psycopg[binary]"` | SQLAlchemy reflection of a **subset**; pass `include_tables` (e.g. heron's retriever output). | No (given a list). |
| 4 | **Vanna (legacy)** | `pip install "vanna[chromadb,openai,postgres]==0.7.9"` | **RAG over trained schema-qualified DDL**; retrieves ~10 chunks/question. | YES-ish — `get_related_ddl()`. |
| 5 | **heron `raw-llm`** *(existing baseline, keep)* | n/a (in-repo) | Dumps the entire 211-table schema in the prompt. The strawman heron exists to beat. | n/a (end-to-end). |
| — | premsql (#A5) | `pip install premsql` | No retrieval-at-scale; unmaintained. **Optional, low priority.** | No. |

**Two "ground-truth" framings** make the comparison fair:
- **Retrieval-on (end-to-end):** systems that retrieve themselves (LlamaIndex Retriever, Vanna) run as-is and
  are scored on **both** Set-Recall (did they find the ~5 tables) and EX (did the SQL run correctly).
- **Oracle-tables (SQL-only):** for "given-a-list" engines (LangChain, LlamaIndex `NLSQLTableQueryEngine`),
  feed the **gold table set** as `include_tables`/`tables=` to isolate pure SQL-writing skill from retrieval.
  Optionally also feed **heron's retriever output** to measure heron-retriever + tool-generator combos.

**Excluded and why (one line each):**
- WrenAI, DB-GPT, Dataherald-engine, Vanna 2.0, SQLChat, DBHub — **(B)** servers/UIs; no headless
  `generate_sql()` matching the adapter contract.
- SQLCoder, XiYan-SQL, prem-1B-SQL, StructLM/CodeS/NSQL — **(C)** fine-tuned models; can't run on gpt-4o, so
  they break the same-model control.
- MindSQL — bucket-A in theory but **GPL-3.0 + abandoned + undocumented OpenAI path**; Vanna-legacy covers
  the same pattern with MIT.

---

## Source index

- LangChain — [github.com/langchain-ai/langchain](https://github.com/langchain-ai/langchain) · [create_sql_query_chain (langchain-classic ref)](https://reference.langchain.com/python/langchain-classic/chains/sql_database/query/create_sql_query_chain) · [SQLDatabase toolkit docs](https://python.langchain.com/docs/integrations/toolkits/sql_database/) · PyPI: langchain 1.3.4, langchain-classic 1.0.7
- LlamaIndex — [github.com/run-llama/llama_index](https://github.com/run-llama/llama_index) · [SQLIndexDemo notebook](https://github.com/run-llama/llama_index/blob/main/docs/examples/index_structs/struct_indices/SQLIndexDemo.ipynb) · [advanced_text_to_sql workflow](https://github.com/run-llama/llama_index/blob/main/docs/examples/workflow/advanced_text_to_sql.ipynb) · PyPI: llama-index 0.14.22
- Vanna — [github.com/vanna-ai/vanna (archived)](https://github.com/vanna-ai/vanna) · [legacy Postgres+OpenAI+ChromaDB doc](https://ask.vanna.ai/docs/postgres-openai-standard-chromadb/) · [PyPI vanna](https://pypi.org/project/vanna/) (0.7.9 legacy → 2.0.2 current)
- premsql — [github.com/premAI-io/premsql](https://github.com/premAI-io/premsql) · [PremSQL blog](https://blog.premai.io/premsql-end-to-end-local-text-to-sql-pipelines/)
- MindSQL — [github.com/Mindinventory/MindSQL](https://github.com/Mindinventory/MindSQL) · [PyPI mindsql](https://pypi.org/project/mindsql/)
- WrenAI — [github.com/Canner/WrenAI](https://github.com/Canner/WrenAI) · [self-host docs](https://docs.getwren.ai/oss/overview/cloud_vs_self_host)
- DB-GPT — [github.com/eosphoros-ai/DB-GPT](https://github.com/eosphoros-ai/DB-GPT)
- Dataherald — [github.com/Dataherald/dataherald](https://github.com/Dataherald/dataherald)
- Defog/SQLCoder — [github.com/defog-ai/sqlcoder](https://github.com/defog-ai/sqlcoder)
- XiYan-SQL — [github.com/XGenerationLab/XiYan-SQL](https://github.com/XGenerationLab/XiYan-SQL)
- SQLChat — [github.com/sqlchat/sqlchat](https://github.com/sqlchat/sqlchat)
- Instructor — [github.com/567-labs/instructor](https://github.com/567-labs/instructor)
- Tools roundup — [Bytebase: Top Text-to-SQL tools (2026)](https://www.bytebase.com/blog/top-text-to-sql-query-tools/) · [eosphoros-ai/Awesome-Text2SQL](https://github.com/eosphoros-ai/Awesome-Text2SQL)

*Compiled June 2026. Star counts, PyPI versions, and license tags verified against GitHub API + PyPI at
compile time; API signatures verified against current docs (Context7 + vendor docs). Re-verify before a
publication run — these APIs drift monthly.*
