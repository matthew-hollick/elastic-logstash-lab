# windows-security-share — distribution package

A self-contained bundle that provisions a **"share" data space** in an Elastic
deployment: a Kibana space, a managed data stream holding a minimal copy of
Windows Security events, a scheduled Workflow that keeps it populated, and a
read-only user that can only see the shared data.

Everything below is a **Kibana Dev Tools console command** — paste each block
into **Management → Dev Tools → Console** and run it in order. Kibana API calls
use the `kbn:` path prefix; Elasticsearch API calls are plain paths.

See `CBOM.md` for the component inventory and design rationale.

## Step 0 — Prerequisites check

```console
GET /
GET /_ingest/pipeline/logs-system.security-*
GET /_data_stream/logs-system.security-default
```

- Elasticsearch must be 9.4+ (Workflows GA).
- The System integration's `logs-system.security-*` pipelines must exist
  (install the `system` integration package via Fleet first if missing).
- `logs-system.security-default` must exist and contain events.

## Step 1 — Create the `share` Kibana space

```console
POST kbn:/api/spaces/space
{
  "id": "share",
  "name": "share",
  "description": "Shared data products derived from internal indexes",
  "color": "#54B399",
  "initials": "s"
}
```

Expected: `{"id":"share", ...}`. (409 response = already exists, safe to continue.)

## Step 2 — ILM policy (≈1 day retention)

Rollover each backing index after 12h; delete it 12h later — no document is
kept longer than ~24h.

```console
PUT /_ilm/policy/windows-security-share-ilm
```

Body — paste the contents of `elasticsearch/windows-security-share-ilm.json`.

## Step 3 — Ingest pipeline (one step: adds `shared` marker)

```console
PUT /_ingest/pipeline/share-default
```

Body — paste `elasticsearch/share-default.pipeline.json`.

## Step 4 — Index template (data stream, 1 primary / 0 replicas)

Wires the ILM policy and `share-default` as the default pipeline for every
write to the stream.

```console
PUT /_index_template/logs-system.security-share
```

Body — paste `elasticsearch/logs-system.security-share.template.json`.

## Step 5 — Create the data stream

```console
PUT /_data_stream/logs-system.security-share
```

Expected: `{"acknowledged":true}`.

## Step 6 — Read-only share role

`read` + `view_index_metadata` on `*-share` indices only; Kibana read-only
Discover/Dashboard/data-view features scoped to `space:share` only.

```console
PUT /_security/role/share_viewer
```

Body — paste `elasticsearch/share_viewer.role.json`.

## Step 7 — Demo user

```console
PUT /_security/user/share_user
```

Body — paste `elasticsearch/share_user.user.json`.

> **Change the password** (`changeme`) before using this anywhere real, or
> provision users through your own identity system with the `share_viewer` role.

## Step 8 — Scheduled copy workflow (in the `share` space)

The workflow definition lives in `kibana/share-windows-security.yaml`. Create it
via the workflows API — the `yaml` field must contain the file's contents as a
JSON string, so paste the file into the value below (Dev Tools accepts a JSON
string; escape newlines or use the one-line curl alternative at the bottom):

```console
POST kbn:/s/share/api/workflows
{
  "workflows": [
    {
      "yaml": "<contents of kibana/share-windows-security.yaml, JSON-escaped>"
    }
  ]
}
```

Easier alternative — from a shell with `KIBANA_URL` set:

```sh
WF_YAML=$(python3 -c 'import sys,json; print(json.dumps(open("kibana/share-windows-security.yaml").read()))')
curl -u 'elastic:<password>' -X POST "$KIBANA_URL/s/share/api/workflows" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d "{\"workflows\":[{\"yaml\":${WF_YAML}}]}"
```

Or import the YAML directly in **Kibana → Workflows → Create workflow → YAML editor**.

Then trigger one immediate run (also verifies it works):

```console
POST kbn:/s/share/api/workflows/workflow/share-windows-security-events/run
{
  "inputs": {}
}
```

Expected: `{"workflowExecutionId":"<uuid>"}`.

## Verify

```console
GET /logs-system.security-share/_count
GET /logs-system.security-share/_search?size=1
```

Each `_source` should contain only:

```json
{
  "@timestamp": "...",
  "shared": "shared",
  "event":   { "code": "...", "action": "...", "outcome": "..." },
  "user":    { "name": "..." },
  "source":  { "ip": "..." },
  "winlog":  { "computer_name": "..." }
}
```

Check the access boundary:

```sh
# as share_user:changeme
curl -u share_user:changeme 'http://<es>:9200/logs-system.security-share/_count'     # 200
curl -u share_user:changeme 'http://<es>:9200/logs-system.security-default/_count'   # 403
```

Watch the workflow's scheduled runs:

```console
GET kbn:/s/share/api/workflows/workflow/share-windows-security-events/executions
```

## How it works

- Every **10 minutes** the workflow calls `_reindex` from
  `logs-system.security-default`, filtered to `@timestamp >= now-70m`.
- The 10-minute cadence plus 70-minute window gives a **60-minute overlap**;
  `_id` is preserved and the destination accepts only `create` ops, so
  re-copied events surface as `version_conflicts` and are skipped
  (`conflicts: proceed`). No duplicates, no lost late arrivals.
- Only 7 fields are copied — no `agent.*`, `ecs.*`, `data_stream.*`, or other
  collector/ingest metadata — enforced by the `_source` whitelist in the
  reindex body.
- The `share-default` pipeline stamps `shared: "shared"` on every doc on the
  way in; it is attached as the stream's `default_pipeline`, so it applies to
  any writer, not just the workflow.
- ILM rolls the write index every 12h and deletes each rolled index 12h later,
  capping retention at ~24h.

## Conventions

- **Sharing marker**: any index/data stream meant for the share space must be
  named `*-share` — that is exactly what `share_viewer` can read. Do not widen
  the role pattern; create new share products with matching names instead.
- **Spaces ≠ security**: the `share` space organises saved objects; the
  `share_viewer` role is what actually blocks reads of internal indices.
