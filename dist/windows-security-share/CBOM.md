# Configuration Bill of Materials — `windows-security-share` distribution

Version: 1.0 — Elastic Stack 9.5.3 — 2026-10-08

This package provisions a **share space** containing a deduplicated, field-minimised,
1-day-retention copy of Windows Security events. All components are installed via
Kibana Dev Tools console commands (`kbn:` prefix for Kibana APIs, plain paths for
Elasticsearch APIs). No external tooling is required.

## Prerequisites

| # | Component | How to satisfy | Verified at |
|---|-----------|----------------|-------------|
| P1 | Elasticsearch 9.4+ (Workflows GA since 9.4) | Stack version ≥ 9.4 | `GET /` |
| P2 | Kibana reachable, security enabled | Dev Tools console usable | — |
| P3 | Elastic **System** integration ≥ 3.0.0 installed | Fleet → Integrations, or `GET /_ingest/pipeline/logs-system.security-*` returns `logs-system.security-3.0.0*` pipelines | `GET /_ingest/pipeline/logs-system.security-*` |
| P4 | Source data stream `logs-system.security-default` exists and contains docs | Port-1518 route or any real Winlogbeat/Elastic Agent writer | `GET /_data_stream/logs-system.security-default` |
| P5 | Caller has `manage_security`, `manage_ilm`, `manage_index_templates`, `manage_data_stream`, `manage_pipeline`, and Kibana `all` privileges (i.e. run as a superuser like `elastic`) | — | — |

## Bill of materials

| # | Type | Name / ID | Artifact file | Install call (Dev Tools) | Purpose |
|---|------|-----------|---------------|--------------------------|---------|
| 1 | Kibana space | `share` | — (inline body below) | `POST kbn:/api/spaces/space` | Container for share-facing saved objects + the workflow |
| 2 | ILM policy | `windows-security-share-ilm` | `elasticsearch/windows-security-share-ilm.json` | `PUT /_ilm/policy/windows-security-share-ilm` | 12h rollover + delete 12h later ⇒ ≤ ~24h retention |
| 3 | Ingest pipeline | `share-default` | `elasticsearch/share-default.pipeline.json` | `PUT /_ingest/pipeline/share-default` | Single step: `set shared = "shared"` on every doc |
| 4 | Index template | `logs-system.security-share` | `elasticsearch/logs-system.security-share.template.json` | `PUT /_index_template/logs-system.security-share` | Data stream template: 1 primary, 0 replicas, wires ILM policy + default pipeline |
| 5 | Data stream | `logs-system.security-share` | — (implicit via template) | `PUT /_data_stream/logs-system.security-share` | Destination for copied events |
| 6 | Security role | `share_viewer` | `elasticsearch/share_viewer.role.json` | `PUT /_security/role/share_viewer` | `read` on `*-share`; Kibana read-only features scoped to `space:share` |
| 7 | Security user | `share_user` | `elasticsearch/share_user.user.json` | `PUT /_security/user/share_user` | Demo account holding only `share_viewer` |
| 8 | Workflow | `share-windows-security-events` | `kibana/share-windows-security.yaml` | `POST kbn:/s/share/api/workflows` | Scheduled every 10m; `_reindex` of last 70m; `_id` preserved; minimal `_source` whitelist |

## Component relationships

```
logs-system.security-default          (P4 — pre-existing source data stream)
        │
        │  workflow: share-windows-security-events  (#8, space: share #1)
        │  POST /_reindex  every 10m, window now-70m
        ▼
logs-system.security-share            (#5 — data stream)
        │  template: logs-system.security-share     (#4)
        │  ├── settings: shards=1 replicas=0
        │  ├── default_pipeline: share-default      (#3) → adds shared:"shared"
        │  └── lifecycle: windows-security-share-ilm (#2) → 12h rollover / +12h delete
        │
        └── readable by: share_viewer role          (#6) → share_user (#7)
                  (index pattern: *-share ; Kibana space: share)
```

## Install order

P3 → P4 (pre-existing) → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8.

Components 2–5 must be installed in order: the template references the ILM
policy and pipeline; the data stream requires the template.
The workflow (#8) must be created inside the `share` space (#1) — note the
`/s/share/` path prefix in its install call.

## Runtime parameters baked into the artifacts

| Setting | Value | Where |
|---------|-------|-------|
| Schedule | every 10 minutes | `share-windows-security.yaml` → `triggers` |
| Lookback window | `now-70m` (60-min overlap) | `share-windows-security.yaml` → `source.query` |
| Dedup | `_id` preserved + `op_type: create` + `conflicts: proceed` | `share-windows-security.yaml` → `body` |
| Copied fields | `@timestamp`, `event.code`, `event.action`, `event.outcome`, `user.name`, `source.ip`, `winlog.computer_name` | `share-windows-security.yaml` → `source._source` |
| Marker field | `shared: "shared"` | `share-default.pipeline.json` |
| Retention | rollover `12h`, delete `min_age 12h` (max doc age ≈ 24h) | `windows-security-share-ilm.json` |
| Sharding | 1 primary, 0 replicas | `logs-system.security-share.template.json` |
| Share index convention | name suffix `*-share` | `share_viewer.role.json` index pattern |
| Demo user credentials | `share_user` / `changeme` — **change before any real deployment** | `share_user.user.json` |

## Post-install validation

See `README.md` § "Verify". Expected steady state:

- `GET /logs-system.security-share/_count` grows every ~10 minutes.
- A doc has exactly the 7 whitelisted fields plus `shared: "shared"`.
- Re-running the workflow yields `created: 0, version_conflicts: N` — no duplicates.
- `share_user` gets `403` on `logs-system.security-default` and `200` on `logs-system.security-share`.
