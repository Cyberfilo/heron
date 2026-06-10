# heron — reproducible NL→SQL benchmark on a production-scale Postgres schema.
# Quickstart:  make up && make schema && make seed SCALE=small && make verify
#
# Everything is driven by DSN; override to point at any Postgres (e.g. a native
# cluster) instead of the bundled docker one.

DSN   ?= postgresql://heron:heron@127.0.0.1:55432/heron
SCALE ?= small
SEED  ?= 42
PY    ?= python3

PSQL          := psql "$(DSN)" -v ON_ERROR_STOP=1 -q
SCHEMA_FILES  := $(sort $(wildcard schema/[0-9]*_*.sql))
DUMP          := data/heron_$(SCALE).dump

.DEFAULT_GOAL := help
.PHONY: help up down wait schema seed reset dump restore bench audit verify psql sizes clean

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

up: ## start the bundled Postgres 16 (docker)
	docker compose up -d
	@$(MAKE) --no-print-directory wait

down: ## stop Postgres (keeps the volume)
	docker compose down

wait: ## block until Postgres accepts connections
	@echo "waiting for Postgres at $(DSN) ..."
	@for i in $$(seq 1 60); do \
	  pg_isready -d "$(DSN)" >/dev/null 2>&1 && echo "ready." && exit 0; \
	  sleep 1; done; \
	echo "timed out waiting for Postgres" >&2; exit 1

schema: ## load the 14-module schema in order (drops & recreates objects)
	@echo "loading $(words $(SCHEMA_FILES)) schema files..."
	@for f in $(SCHEMA_FILES); do echo "  $$f"; $(PSQL) -f $$f || exit 1; done
	@echo "schema loaded. tables:"; \
	$(PSQL) -c "SELECT count(*) AS tables FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');"

seed: ## generate + COPY deterministic data  (SCALE=tiny|small|bench|large SEED=42)
	cd seed && PYTHONHASHSEED=0 $(PY) generate.py --dsn "$(DSN)" --scale $(SCALE) --seed $(SEED)

reset: ## drop & recreate the public objects (full clean reload prep)
	$(PSQL) -c "DROP SCHEMA IF EXISTS identity,geo,catalog,pricing,inventory,sales,billing,crm,support,marketing,analytics,comms,audit,ops CASCADE;"

verify: ## run referential-integrity + invariants checks on the loaded DB
	$(PY) seed/verify.py --dsn "$(DSN)"

audit: ## run the gold-quality audit checklist over the question suite
	$(PY) harness/audit.py --dsn "$(DSN)"

dump: ## pg_dump the current DB to data/heron_$(SCALE).dump (custom format)
	@mkdir -p data
	pg_dump "$(DSN)" -Fc -Z6 -f $(DUMP)
	@cd data && shasum -a 256 $$(basename $(DUMP)) | tee $$(basename $(DUMP)).sha256
	@ls -lh $(DUMP)

restore: ## restore data/heron_$(SCALE).dump into a fresh DB (exact reproduction)
	pg_restore --no-owner --clean --if-exists -d "$(DSN)" $(DUMP)

bench: ## run a system against the suite  (ADAPTER=raw-llm|promptquery MODEL=...)
	$(PY) harness/run.py --dsn "$(DSN)" --adapter $(ADAPTER) $(if $(MODEL),--model $(MODEL),)

sizes: ## show on-disk size of the biggest tables
	$(PSQL) -c "SELECT schemaname||'.'||relname AS table, pg_size_pretty(pg_total_relation_size(relid)) AS size, n_live_tup AS rows FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 25;"

psql: ## open a psql shell
	psql "$(DSN)"

clean: ## stop Postgres and DELETE the data volume (destroys the DB)
	docker compose down -v
