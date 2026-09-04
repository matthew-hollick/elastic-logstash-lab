# Standalone Logstash + Elasticsearch + Kibana

Run a minimal Elastic stack locally in Docker: Elasticsearch, Logstash and Kibana, with Logstash configured to send syslog input to Elasticsearch.

This is a local-development setup only, based on Elastic's [`start-local`](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/local-development-installation-quickstart) quickstart.

## Requirements

- Docker Engine or Docker Desktop
- Docker Compose v2 (`docker-compose`)
- [Task](https://taskfile.dev/) (`mise install` or `mise use task`)
- [uv](https://docs.astral.sh/uv/) (managed by mise)

All dependencies are managed with mise via `mise.toml`.

## Initial setup

```sh
mise install    # install docker-cli, docker-compose, task, uv, etc.
task setup      # creates .env from .env.example
```

Edit `.env` and set secure passwords for `ELASTIC_PASSWORD` and `KIBANA_PASSWORD`. The example file uses `changeme`. `KIBANA_ENCRYPTION_KEY` must be at least 32 characters.

## Start the stack

```sh
task start
```

This starts Elasticsearch, then Kibana, and finally Logstash once Elasticsearch is healthy.

Endpoints:
- Elasticsearch: `http://localhost:9200`
- Kibana: `http://localhost:5601`
- Logstash monitoring API: `http://localhost:9600`

The stack exposes three syslog inputs:

- Port `1514` — `syslog` input for plain syslog (written to `logs-generic-default`).
- Port `1515` — raw `tcp` input tagged for the `syslog_router` integration; the Elasticsearch `logs-syslog_router.log@custom` ingest pipeline routes Cisco ASA/FTD/IOS events to the correct integration data stream.
- Port `1516` — raw `tcp` input for source-IP-based routing using the dictionary file `config/ip_to_integration.csv`. Matched events are written to the corresponding integration data stream; unmatched events fall back to `logs-generic-default`.

Tail the logs:

```sh
task logs
```

Stop the stack:

```sh
task stop
```

## Test the pipeline

Send a single test syslog line:

```sh
task send
```

Run a smoke test that starts the stack, sends a test syslog event, and stops:

```sh
task smoke
```

## Stream log simulator data

The [log-simulators](https://github.com/matthew-hollick/log-simulators) repo can stream realistic syslog into Logstash on TCP port `1514` (plain syslog) or `1515` (syslog-router tagged events for integration routing).

```sh
LOGSIM_DURATION=10s task logsim-asa      # Cisco ASA firewall syslog
LOGSIM_DURATION=10s task logsim-ftd      # Cisco FTD security syslog
LOGSIM_DURATION=10s task logsim-syslog   # Linux syslog
```

These tasks start the stack and wait for Elasticsearch and Logstash to be ready before streaming. The default rate is 10 events/sec and the default duration is 30s.

You can override the rate and duration:

```sh
LOGSIM_RATE=50 LOGSIM_DURATION=5m task logsim-asa
```

## Install integration packages

Before routing events to the Cisco integration data streams, install the required packages into Kibana:

```sh
task install-integrations
```

This installs the `tcp`, `syslog_router`, `cisco_asa`, `cisco_ios`, and `cisco_ftd` integration packages, and also installs the `logs-syslog_router.log@custom` ingest pipeline that performs the Cisco syslog routing in Elasticsearch.

## Use a custom pipeline

Edit or add `.conf` files under `pipeline/`. Logstash checks for pipeline changes every three seconds and reloads them automatically. All files in the directory are combined into the main pipeline in lexical order:

- `01-input.conf` — syslog input on port `1514` and raw TCP inputs on ports `1515` and `1516`
- `20-filter.conf` — adds `syslog_router` data_stream fields and performs source-IP dictionary lookup for port `1516` events
- `99-output.conf` — Elasticsearch output

To load pipeline files from another directory, set `PIPELINE_DIR` to an absolute path:

```sh
PIPELINE_DIR=/absolute/path/to/pipelines task start
```

Validate the selected pipeline without starting the stack:

```sh
task validate
```

## Common tasks

| Task | Description |
| --- | --- |
| `task setup` | Create `.env` from `.env.example` |
| `task start` | Start Elasticsearch and Logstash |
| `task stop` | Stop and remove the containers |
| `task restart` | Restart the stack |
| `task logs` | Tail container logs |
| `task status` | Show running container status |
| `task wait` | Wait until Logstash is ready |
| `task send` | Send a test syslog line to the TCP input |
| `task validate` | Validate pipeline configuration without starting the stack |
| `task smoke` | Start, send a test syslog event, stop |
| `task logsim-asa` | Stream Cisco ASA syslog into Logstash |
| `task logsim-ftd` | Stream Cisco FTD syslog into Logstash |
| `task logsim-syslog` | Stream Linux syslog into Logstash |
| `task install-integrations` | Install Elastic integration packages and the syslog_router routing pipeline |
| `task exec` | Open an interactive shell inside the running Logstash container |
| `task clean` | Remove containers, networks, and volumes |

## Configuration

Environment variables are read from `.env` automatically by Docker Compose. They can be overridden in the shell before running `task`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `ELASTIC_VERSION` | `9.5.3` | Version tag for all Elastic images |
| `ELASTIC_PASSWORD` | `changeme` (required) | `elastic` superuser password |
| `KIBANA_PASSWORD` | `changeme` (required) | `kibana_system` user password |
| `KIBANA_ENCRYPTION_KEY` | `changeme-change-me-...` (required) | Saved objects encryption key, >= 32 chars |
| `ES_JAVA_OPTS` | `-Xms128m -Xmx2g` | Elasticsearch JVM options |
| `LS_JAVA_OPTS` | `-Xms512m -Xmx512m` | Logstash JVM options |
| `ES_PORT` | `9200` | Host port for Elasticsearch |
| `KIBANA_PORT` | `5601` | Host port for Kibana |
| `SYSLOG_TIMEZONE` | `UTC` | Timezone used when generating syslog timestamps in tasks and pipelines |
| `LOGSTASH_SYSLOG_PORT` | `1514` | Host port for the plain syslog TCP input |
| `LOGSTASH_SYSLOG_ROUTER_PORT` | `1515` | Host port for the syslog-router tagged TCP input |
| `LOGSTASH_SYSLOG_DICT_PORT` | `1516` | Host port for the source-IP dictionary-routed TCP input |
| `LOGSTASH_API_PORT` | `9600` | Host port for the Logstash monitoring API |
| `PIPELINE_DIR` | `./pipeline` | Host directory containing pipeline `.conf` files |
| `LOGSIM` | `git+https://github.com/matthew-hollick/log-simulators` | Git URL for log-simulators |
| `LOGSIM_RATE` | `10` | Average events per second for simulator tasks |
| `LOGSIM_DURATION` | `30s` | How long simulator tasks run |

Port `1514` is used for syslog instead of the standard `514` so Logstash does not need root privileges inside the container. Point simulators at `tcp://127.0.0.1:1514`.

The pipeline in `pipeline/*.conf` sends events to the `elastic` user at `http://elasticsearch:9200`. Events received on port `1515` are tagged for the `syslog_router` data stream; the `logs-syslog_router.log@custom` ingest pipeline inspects the message content and sets `_conf.dataset` so the syslog_router integration reroutes Cisco ASA/FTD/IOS events to the correct data stream. Events that do not match any pattern remain in the `logs-syslog_router.log-default` catch-all data stream. Events received on port `1516` are routed by source IP using `config/ip_to_integration.csv`; matched events are written to the corresponding integration data stream and unmatched events fall through to `logs-generic-default`. Configure filters and outputs as needed after the connection is working.

## Security notes

This is a local development stack. Elasticsearch has security enabled and requires the `ELASTIC_PASSWORD`. Do not commit `.env` or pipeline files containing credentials. `.env` is already ignored by `.gitignore`.
