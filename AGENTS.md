# AGENTS.md - KubeDB mssqlserver_exporter

This file provides instructions for AI coding agents working in this Prometheus SQL exporter repository.

## Project Overview

KubeDB fork of [burningalchemist/sql_exporter](https://github.com/burningalchemist/sql_exporter) (itself a fork of `free/sql_exporter`), a configuration-driven Prometheus exporter that runs SQL queries against DBMSs and exposes results as metrics. Out of the box it supports MySQL, PostgreSQL, Microsoft SQL Server, Oracle, ClickHouse, Snowflake, and Vertica. KubeDB packages it specifically for monitoring KubeDB-managed Microsoft SQL Server instances, shipping curated collector configs under `kubedb/` and a custom `Dockerfile` that bakes those configs into `/etc/sql-exporter/`.

- Go module path: `github.com/burningalchemist/sql_exporter` (preserved upstream, not renamed)
- Binary name: `sql_exporter` (built from `./cmd/sql_exporter`)
- Default listen address: `:9399`, metrics at `/metrics`, exporter self-metrics at `/sql_exporter_metrics`
- Current version: see `VERSION` (e.g. `0.18.6`)
- Go: `1.24.0`

## Build & Development Commands

```bash
# Default: format, build, test (uses promu)
make all

# Build the binary with promu (installs promu v0.17.0 to $GOPATH/bin if needed)
make build

# Run unit tests (short mode)
make test

# go fmt all packages
make format

# Check gofmt formatting (fails on diff)
make style

# go vet all packages
make vet

# Build the Docker image (tag = current git branch)
make docker

# Cross-build for linux/darwin/windows amd64+arm64 and linux/armv7
make crossbuild
make crossbuild-tarballs
make crossbuild-checksum
make crossbuild-release   # runs all three above

# Build release tarball for current platform
make tarball
```

### Driver Selection

The set of compiled-in SQL drivers is generated into `drivers.go` by `drivers_gen.go` (a `//go:build ignore` program using `github.com/dave/jennifer/jen`). Three driver groups are defined in `drivers_gen.go`: `minimal` (mysql, lib/pq, mssql/azuread), `extra` (clickhouse, pgx, snowflake, vertica, oracle), and `custom` (csvq).

```bash
# Regenerate drivers.go with all default drivers (minimal + extra)
make drivers-all

# Regenerate with only the minimal driver set, then build
make drivers-minimal
make build

# Use the `custom` group
make drivers-custom
```

### Running Locally

```bash
# Run with default config path ./sql_exporter.yml
./sql_exporter

# Common flags
./sql_exporter -config.file kubedb/sql_exporter.yml \
               -web.listen-address :9399 \
               -web.metrics-path /metrics \
               -config.check                # validate config and exit
               -web.enable-reload            # expose /reload HTTP endpoint
               -web.config.file web.yml      # TLS/BasicAuth/rate-limit config

# Override DSN from CLI (single-target mode only)
./sql_exporter -config.data-source-name 'sqlserver://user:pass@host:1433/master'
```

Environment variables: `SQLEXPORTER_CONFIG` overrides `-config.file`; `SQLEXPORTER_DEBUG` enables block/mutex profiling; further `SQLEXPORTER_*` vars map into the YAML config via `sethvargo/go-envconfig` (prefixes `GLOBAL_`, `TARGET_`). `SIGHUP` triggers a reload.

## Project Structure

```
cmd/sql_exporter/         # main package: flag parsing, HTTP handlers, signal handling
  main.go                 # entrypoint, flag definitions, server setup
  content.go              # / and /config HTML handlers
  promhttp.go             # /metrics handler wrapper
  log.go                  # slog setup (logfmt/json, file/stderr)
  util.go

config/                   # YAML config types and loader
  config.go               # top-level Config + Load(); env var processing
  global_config.go        # GlobalConfig (scrape_timeout, max_connections, ...)
  target_config.go        # TargetConfig (single-target mode + AWS secret)
  job_config.go           # JobConfig (multi-target mode, static_configs)
  collector_config.go     # CollectorConfig (metrics + queries grouping)
  metric_config.go        # MetricConfig (gauge/counter, labels, values)
  query_config.go         # QueryConfig (raw SQL + name)
  secret_config.go        # Secret type (redacted in YAML output)
  util.go                 # resolveCollectorRefs (glob expansion), checkOverflow
  config_test.go

errors/errors.go          # WithContext error type used throughout

# Top-level package github.com/burningalchemist/sql_exporter
exporter.go               # Exporter interface, prometheus.Gatherer impl, scrape_errors_total
collector.go              # Collector + cachingCollector (min_interval cache)
target.go                 # Target: ping + collect; emits up/scrape_duration_seconds
job.go                    # Job: expands static_configs into Targets
query.go                  # Query execution + row-to-metric mapping
metric.go                 # MetricFamily / MetricDesc / NewMetric
sql.go                    # OpenConnection, PingDB, DSN handling via xo/dburl
reload.go                 # Reload(): hot-reload of collectors and targets
drivers.go                # generated: blank-imports of SQL driver packages
drivers_gen.go            # (build ignore) generator for drivers.go

kubedb/                   # KubeDB-shipped config baked into Docker image
  sql_exporter.yml        # MSSQL target template; DSN points at KubeDB pod
  mssql_standard.collector.yml

examples/                 # Reference configs for mssql, postgres, azure-sql-mi
documentation/sql_exporter.yml  # Fully annotated reference config
helm/                     # Helm chart (Chart.yaml, values.yaml, templates/)
packaging/                # nfpm config + systemd/sysv files for deb/rpm
Dockerfile                # KubeDB image: copies kubedb/ to /etc/sql-exporter/
Dockerfile.multi-arch     # Upstream multi-arch image (no kubedb/ overlay)
.promu.yml                # promu build config: ldflags, crossbuild targets
```

## Key Packages / APIs

- **`sql_exporter.Exporter`** (`exporter.go`): `prometheus.Gatherer` over a slice of `Target`s. Constructed via `NewExporter(configFile string)`. Methods: `Gather`, `WithContext`, `Config`, `UpdateTarget`, `SetJobFilters`, `DropErrorMetrics`. Maintains a `scrape_errors_total{job,target,collector,query}` counter on the package-level `SvcRegistry`.
- **`sql_exporter.Target`** (`target.go`): one DSN + many `Collector`s. `Collect()` pings the DB (gated by `enable_ping`), emits synthetic `up` and `scrape_duration_seconds` metrics when `target.name` is set, then fans out to collectors. Connections opened lazily via `OpenConnection` in `sql.go`.
- **`sql_exporter.Job`** (`job.go`): expands `static_configs[].targets` map into one `Target` per DSN with `job` and `target` const labels.
- **`sql_exporter.Collector`** (`collector.go`): groups `Query`s and `MetricFamily`s. Wrapped in `cachingCollector` when `min_interval > 0`.
- **`sql_exporter.Query`** (`query.go`): executes a SQL statement and converts rows into `Metric`s, honouring `key_labels`, `static_labels`, `values`, `static_value`, `timestamp_value`, and `no_prepared_statement`.
- **`sql_exporter.Reload`** (`reload.go`): re-reads the config file and atomically swaps targets. Triggered by `SIGHUP` or the `/reload` HTTP endpoint when `-web.enable-reload` is set.
- **`config.Load(path)`** (`config/config.go`): parses YAML, applies env-var overrides (`SQLEXPORTER_*`), loads collector globs from `collector_files`, resolves collector refs (supports glob patterns). Requires exactly one of `target` or `jobs`.
- **`config.TargetConfig`** supports AWS Secrets Manager via `aws_secret_name` (single-target mode only); secret JSON must contain `data_source_name`.
- **Driver registration**: `drivers.go` blank-imports SQL drivers; the actual DSN parsing uses `github.com/xo/dburl`, so the URL scheme (`mysql://`, `sqlserver://`, `postgresql://`, `clickhouse://`, `oracle://`, `snowflake://`, `vertica://`) selects the driver.

## Configuration

Two YAML schemas:

1. **Exporter config** (`-config.file`, default `sql_exporter.yml`): `global`, plus exactly one of `target` (single DSN) or `jobs` (multi-DSN with `static_configs`). May embed `collectors` inline or reference external files via `collector_files` glob.
2. **Collector files** (each matched by `collector_files` glob): a single top-level collector object with `collector_name`, `metrics:` (each with `metric_name`, `type`, `help`, `key_labels`, `static_labels`, `values`/`static_value`, `query`), and optional `queries:`. A `collectors:` list at the top is rejected - one collector per file.

KubeDB's shipped config (`kubedb/sql_exporter.yml`) uses single-target mode with `data_source_name: sqlserver://...` pointing at a KubeDB MSSQL pod and `collectors: [mssql_*]` matched against `kubedb/mssql_standard.collector.yml`.

A separate web-config file (`-web.config.file`) controls TLS, BasicAuth, and `rate_limit` (interval+burst); format documented at `prometheus/exporter-toolkit`.

## Testing

```bash
# Unit tests (short mode, all packages)
make test

# Or directly
go test -short ./...

# Validate a config file without starting the server
./sql_exporter -config.file path/to/sql_exporter.yml -config.check
```

Test coverage is sparse; only `config/config_test.go` exists in this tree (covers `resolveCollectorRefs` glob matching and unknown-collector errors). CI (`.github/workflows/build.yml`) runs `make style`, `make vet`, `make test`, `make build` on push/PR to `master`.

## Dependencies

Direct dependencies (`go.mod`):

- `github.com/prometheus/client_golang`, `client_model`, `common`, `exporter-toolkit` - Prometheus instrumentation, version stamping, TLS/auth web server
- `github.com/xo/dburl` - unified DSN parser across drivers
- `github.com/sethvargo/go-envconfig` - `SQLEXPORTER_*` env-var binding into structs
- `github.com/kardianos/minwinsvc` - lets the binary run as a Windows service
- SQL drivers: `microsoft/go-mssqldb`, `go-sql-driver/mysql`, `lib/pq`, `jackc/pgx/v5`, `ClickHouse/clickhouse-go/v2`, `sijms/go-ora/v2`, `snowflakedb/gosnowflake`, `vertica/vertica-sql-go`
- AWS SDK v2 (`config`, `secretsmanager`) - for `aws_secret_name`
- `gopkg.in/yaml.v3`, `google.golang.org/protobuf`

`go.mod` pins `ClickHouse/clickhouse-go/v2` to a specific pseudo-version via `replace`.

## CI / Release

- `.github/workflows/build.yml` - PR/push validation on `master` (Go 1.24, style/vet/test/build); skips commits whose message starts with `docs:`
- `.github/workflows/release.yml` - on tag `*.*.*` or `workflow_dispatch`: `make crossbuild`, tarballs, `nfpm` deb/rpm via `burningalchemist/action-gh-nfpm`, GitHub release upload, then multi-arch Docker push to `burningalchemist/sql_exporter` (Dockerfile.multi-arch, linux/amd64+arm64) using `DOCKER_USERNAME`/`DOCKER_TOKEN` secrets. Go version pulled from `.promu.yml` via `yq`.
- `.github/workflows/helm-workflow.yaml` - Helm chart lint/release
- `.github/workflows/codeql-analysis.yml` - security scanning

Note: the upstream release workflow builds and pushes the upstream image, not a KubeDB-specific one. The `Dockerfile` at the repo root (not `Dockerfile.multi-arch`) is the KubeDB variant that overlays `kubedb/` into `/etc/sql-exporter/`.

## Code Conventions

- Style enforced by `gofmt`; `make style` fails on any unformatted file
- Logging uses `log/slog` (set up in `cmd/sql_exporter/log.go`); format selected by `-log.format=logfmt|json`, level by `-log.level`
- Errors that need scrape context use `errors.WithContext` from the local `errors/` package; helpers `errors.Wrap(logContext, err)` and `errors.Errorf` thread `job=...,target=...,collector=...,query=...` labels into `scrape_errors_total`
- All exported types use Go-doc comments; package docs live at the top of `exporter.go` and `config/config.go`
- YAML structs use strict parsing: an `XXX map[string]any \`yaml:",inline"\`` field plus `checkOverflow()` rejects unknown keys
- Concurrency: each `Target` collects in its own goroutine, each `Collector` runs its `Query`s in parallel goroutines, all coordinated through buffered `chan Metric` (capacity `capMetricChan = 1000`)
- The package name is `sql_exporter` (underscore), not the conventional Go lowercase-no-underscore - matches the module path and binary name
- Don't rename the Go module path; downstream KubeDB tooling and the upstream fork relationship depend on `github.com/burningalchemist/sql_exporter`
