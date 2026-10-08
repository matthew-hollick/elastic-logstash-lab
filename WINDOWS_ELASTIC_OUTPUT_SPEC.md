# Implementation Specification: Elastic-Compatible Windows Security Output for `logsim-windows`

## Agent instructions

Implement this specification in the upstream `log-simulators` project, not in the Logstash demonstration repository where this document currently lives.

Upstream repository:

```text
https://github.com/matthew-hollick/log-simulators
```

Primary implementation files:

```text
src/log_simulators/windows/cli.py
tests/test_windows.py
README.md
```

Before changing code:

1. Read the repository instructions and contribution guidance.
2. Inspect the current implementation and tests.
3. Preserve all existing XML and NDJSON behavior.
4. Verify the current Elastic System integration contract rather than assuming it is stable.
5. Pin and record the Elastic System integration version used for compatibility testing.

## Objective

Add a new output format to `logsim-windows` that emits documents shaped like events produced by Elastic Agent or Winlogbeat's Windows Event Log input.

The output must be suitable for:

1. Decoding as JSON by Logstash.
2. Setting the destination dataset to `system.security`.
3. Writing to the `logs-system.security-default` data stream.
4. Passing through the Elastic System integration's Security ingest pipeline.
5. Producing ECS fields such as:
   - `event.code`
   - `event.category`
   - `event.type`
   - `event.action`
   - `event.outcome`
   - `source.ip`
   - `source.port`
   - `user.name`
   - `user.domain`
   - `process.executable`
   - `process.command_line`
   - `related.user`
   - `related.ip`

The simulator must not attempt to reproduce fields owned by a real collector, such as `agent.id`, `elastic_agent.id`, or cloud and container metadata.

## Background

The simulator currently supports:

```text
--format xml
--format ndjson
```

The XML format produces realistic Windows Security Event XML. The existing NDJSON format produces a convenient flattened representation, but that representation does not match the event contract expected by the Elastic System integration's `system.security` ingest pipeline.

The System integration expects a Windows event to have already been decoded into fields including:

```text
event.code
winlog.event_id
winlog.provider_name
winlog.channel
winlog.computer_name
winlog.record_id
winlog.time_created
winlog.event_data.*
```

Its ingest pipeline enriches those fields into ECS. It does not decode raw XML stored in `message`.

The new format must therefore represent the document that an Elastic Windows event collector would hand to the System integration pipeline, not the final ECS document produced by that pipeline.

## Scope

### In scope

- Add a third Windows output format named `elastic`.
- Emit compact, newline-delimited JSON.
- Preserve original Windows manifest field names under `winlog.event_data`.
- Populate the minimum reliable `event.*` and `winlog.*` input fields required by the System Security pipeline.
- Preserve deterministic behavior under `--seed`.
- Add unit tests covering all currently generated event IDs.
- Add compatibility verification against a pinned Elastic System integration version.
- Update project documentation.

### Out of scope

- Adding new Windows event IDs.
- Adding Kerberos event generation.
- Changing the semantics or distributions of existing events.
- Changing existing XML output.
- Changing existing flattened NDJSON output.
- Emitting data-stream routing fields from the simulator.
- Fabricating Elastic Agent identity or deployment metadata.
- Producing the final ECS document directly in the simulator.
- Modifying the Logstash demonstration project as part of the upstream simulator change.

## Supported event IDs

The new output must support every Windows Security event currently generated:

| Event ID | Meaning |
| --- | --- |
| `4624` | Successful logon |
| `4625` | Failed logon |
| `4672` | Special privileges assigned to a new logon |
| `4688` | Process creation |
| `4720` | User account created |
| `4740` | User account locked out |

## CLI requirements

Extend the current format argument from:

```python
choices=["xml", "ndjson"]
```

to:

```python
choices=["xml", "ndjson", "elastic"]
```

Example:

```bash
logsim-windows \
  --format elastic \
  --output tcp://127.0.0.1:1518 \
  --rate 20 \
  --count 0
```

Use the name `elastic` rather than `ecs` or `winlogbeat`:

- `ecs` would imply the simulator has already produced the final ECS document. The System integration pipeline still performs enrichment and ECS mapping.
- `winlogbeat` could imply complete compatibility with every Winlogbeat version.
- `elastic` describes the intended use without making an excessively broad compatibility claim.

The help text should communicate:

```text
--format {xml,ndjson,elastic}

Output format:
  xml      Single-line Windows Event XML.
  ndjson   Compact flattened JSON.
  elastic  Elastic Winlog-compatible JSON for the system.security
           integration data stream.
```

The existing default must remain `xml` for backward compatibility.

`--pretty` must continue to affect only XML output.

## Output framing

Each event must be serialized as exactly one compact JSON object followed by one newline.

Use compact serialization:

```python
json.dumps(record, separators=(",", ":"))
```

Do not provide multiline or pretty JSON output. The shared simulator runner and TCP/file sinks treat one line as one event.

## Output schema

A representative event should have this shape:

```json
{
  "@timestamp": "2026-10-07T19:24:09.809Z",
  "event": {
    "code": "4625",
    "outcome": "failure",
    "kind": "event",
    "module": "system"
  },
  "winlog": {
    "api": "wineventlog",
    "channel": "Security",
    "computer_name": "WIN-DC01.CORP.EXAMPLE.COM",
    "event_id": "4625",
    "keywords": [
      "Audit Failure"
    ],
    "process": {
      "pid": 575,
      "thread": {
        "id": 4138
      }
    },
    "provider_guid": "{54849625-5478-4994-A5BA-3E3B0328C30D}",
    "provider_name": "Microsoft-Windows-Security-Auditing",
    "record_id": "3652855",
    "time_created": "2026-10-07T19:24:09.809Z",
    "version": 0,
    "event_data": {
      "SubjectUserSid": "S-1-5-18",
      "SubjectUserName": "WIN-DC01$",
      "SubjectDomainName": "CORP",
      "SubjectLogonId": "0x3E7",
      "TargetUserSid": "S-1-0-0",
      "TargetUserName": "anthony08",
      "TargetDomainName": "CORP",
      "Status": "0xC000006D",
      "FailureReason": "%%2313",
      "SubStatus": "0xC000006A",
      "LogonType": "2",
      "LogonProcessName": "User32",
      "AuthenticationPackageName": "Negotiate",
      "WorkstationName": "WIN-DC01",
      "IpAddress": "127.0.0.1",
      "IpPort": "0"
    }
  }
}
```

The actual serialized output must be compact and remain on one line.

## Field requirements

### `@timestamp`

Type:

```text
ISO-8601 UTC string
```

Example:

```json
"@timestamp": "2026-10-07T19:24:09.809Z"
```

Use the generated event timestamp, not the wall-clock time at which serialization occurs.

Milliseconds are sufficient for this output format. Preserve the existing seven-digit FILETIME-like timestamp behavior in XML output.

### `event.code`

Type:

```text
string
```

Example:

```json
"event": {
  "code": "4624"
}
```

The System integration compares event codes to string values. Do not emit an integer here.

### `event.outcome`

Derive the outcome from the audit keywords:

| Internal keywords | Outcome |
| --- | --- |
| `KEYWORDS_SUCCESS` | `success` |
| `KEYWORDS_FAILURE` | `failure` |

For the current event set:

| Event ID | Outcome |
| --- | --- |
| `4624` | `success` |
| `4625` | `failure` |
| `4672` | `success` |
| `4688` | `success` |
| `4720` | `success` |
| `4740` | `success` |

### `event.kind`

Set:

```json
"kind": "event"
```

### `event.module`

Set:

```json
"module": "system"
```

Do not set `event.dataset` in the simulator. The receiving pipeline must own data-stream routing so the same simulator output can be used with Logstash, Elastic Agent, or another test harness.

### `winlog.api`

Set:

```json
"api": "wineventlog"
```

### `winlog.event_id`

Set the event ID as a string:

```json
"event_id": "4624"
```

### `winlog.provider_name`

Always set:

```json
"provider_name": "Microsoft-Windows-Security-Auditing"
```

This is mandatory. The System integration conditionally invokes its standard Windows Security pipeline based on this provider name.

### `winlog.provider_guid`

Set from the existing `PROVIDER_GUID` constant:

```json
"provider_guid": "{54849625-5478-4994-A5BA-3E3B0328C30D}"
```

### `winlog.channel`

Always set:

```json
"channel": "Security"
```

### `winlog.computer_name`

Set the existing fully qualified generated computer name:

```json
"computer_name": "WIN-DC01.CORP.EXAMPLE.COM"
```

Do not retain the flattened root key `computer` in the new format.

### `winlog.record_id`

Set the per-computer event record ID as a string:

```json
"record_id": "3652855"
```

The System integration converts this field to a string. Emitting a string initially aligns with the final mapping and avoids large-integer compatibility issues.

### `winlog.time_created`

Set the generated event timestamp:

```json
"time_created": "2026-10-07T19:24:09.809Z"
```

It must describe the same instant as `@timestamp`.

### `winlog.version`

Use the existing version from `EVENT_META`:

| Event ID | Version |
| --- | ---: |
| `4624` | 2 |
| `4625` | 0 |
| `4672` | 0 |
| `4688` | 2 |
| `4720` | 0 |
| `4740` | 0 |

Emit it as an integer.

### `winlog.event_data`

This is the most important compatibility field.

Preserve the original Windows manifest names and string values exactly as generated internally:

```json
"event_data": {
  "TargetUserName": "anthony08",
  "TargetDomainName": "CORP",
  "IpAddress": "127.0.0.1",
  "IpPort": "49152"
}
```

Do not use the flattened NDJSON names such as:

```text
target_user
target_domain
source_ip
source_port
```

The System integration accesses exact keys such as:

```text
winlog.event_data.TargetUserName
winlog.event_data.SubjectUserName
winlog.event_data.IpAddress
winlog.event_data.IpPort
winlog.event_data.NewProcessName
winlog.event_data.CommandLine
```

Changing capitalization or translating names will prevent its processors from producing expected ECS fields.

Build the map directly from the existing ordered event-data pairs:

```python
event_data = dict(data)
```

Retain Windows sentinel values such as `"-"` and the null GUID. The official integration pipeline removes empty or sentinel values where appropriate. Removing them in the simulator would make this output less faithful to collector input.

### `winlog.process`

The current XML renderer generates process and thread IDs. Refactor those values so the Elastic renderer can use the same metadata:

```json
"process": {
  "pid": 575,
  "thread": {
    "id": 4138
  }
}
```

The generated values must remain deterministic under `--seed`.

### `winlog.keywords`

Translate the raw audit keyword bitmask into a Winlog-style label:

| Internal value | Output |
| --- | --- |
| `0x8020000000000000` | `["Audit Success"]` |
| `0x8010000000000000` | `["Audit Failure"]` |

Do not emit the hexadecimal bitmask as though it were a human-readable keyword.

If the raw value is retained, place it in a clearly named auxiliary field and verify that doing so matches an actual Elastic collector contract. It is not required for the initial implementation.

### `winlog.task` and `winlog.opcode`

Do not fabricate human-readable values.

The current `EVENT_META` contains a numeric Windows task identifier. Keep using that value for XML output. For Elastic output:

- Emit `winlog.task` only if its expected type and value are verified against actual Winlogbeat or Elastic Agent output.
- Omit `winlog.opcode` unless verified.

These fields are not required for the System integration to categorize the six supported event IDs.

## Fields that must not be generated

Do not fabricate collector or deployment metadata:

```text
agent.id
agent.ephemeral_id
agent.name
agent.type
agent.version
elastic_agent.id
elastic_agent.snapshot
elastic_agent.version
host.id
host.mac
host.os.*
cloud.*
container.*
input.type
```

These fields belong to the collection agent or runtime environment. Fake values could interfere with dashboards, agent status, and detection logic.

Do not directly emit final enrichment fields that the System integration is responsible for deriving:

```text
event.category
event.type
event.action
source.*
user.*
process.*
related.*
ecs.version
```

`event.outcome` is an allowed exception because audit success or failure is already unambiguous in the source event.

## Event-specific requirements

### Event 4624: successful logon

Preserve fields including:

```text
SubjectUserSid
SubjectUserName
SubjectDomainName
SubjectLogonId
TargetUserSid
TargetUserName
TargetDomainName
TargetLogonId
LogonType
LogonProcessName
AuthenticationPackageName
WorkstationName
LogonGuid
TransmittedServices
LmPackageName
KeyLength
ProcessId
ProcessName
IpAddress
IpPort
ImpersonationLevel
RestrictedAdminMode
TargetOutboundUserName
TargetOutboundDomainName
VirtualAccount
TargetLinkedLogonId
ElevatedToken
```

Expected System integration enrichment includes:

```text
event.category: authentication
event.type: start
event.action: logged-in
event.outcome: success
source.ip
source.port
user.name or user.target.name
user.domain or user.target.domain
process.executable
related.user
related.ip
```

### Event 4625: failed logon

Preserve:

```text
SubjectUserSid
SubjectUserName
SubjectDomainName
SubjectLogonId
TargetUserSid
TargetUserName
TargetDomainName
Status
FailureReason
SubStatus
LogonType
LogonProcessName
AuthenticationPackageName
WorkstationName
IpAddress
IpPort
```

Expected enrichment includes:

```text
event.category: authentication
event.type: start
event.action: logon-failed
event.outcome: failure
source.ip
source.port
user.target.name
user.target.domain
```

### Event 4672: special privileges assigned

Preserve:

```text
SubjectUserSid
SubjectUserName
SubjectDomainName
SubjectLogonId
PrivilegeList
```

Expected categorization:

```text
event.category: iam
event.type: admin
event.action: logged-in-special
```

Keep the simulator's existing comma-separated privilege representation. Do not introduce a format-specific behavior change unless compatibility tests prove it is required.

### Event 4688: process creation

Preserve:

```text
SubjectUserSid
SubjectUserName
SubjectDomainName
SubjectLogonId
NewProcessId
NewProcessName
TokenElevationType
ProcessId
CommandLine
TargetUserSid
TargetUserName
TargetDomainName
TargetLogonId
MandatoryLabel
ParentProcessName
```

Expected enrichment includes:

```text
event.category: process
event.type: start
event.action: created-process
process.pid
process.executable
process.command_line
process.parent.pid
process.parent.executable
user.name
related.user
```

### Event 4720: user account created

Preserve:

```text
SubjectUserSid
SubjectUserName
SubjectDomainName
SubjectLogonId
TargetUserSid
TargetUserName
TargetDomainName
SamAccountName
UserPrincipalName
```

Expected categorization:

```text
event.category: iam
event.type: [user, creation]
event.action: added-user-account
```

### Event 4740: account lockout

Preserve:

```text
TargetUserName
TargetDomainName
TargetSid
CallerComputerName
SubjectUserSid
SubjectUserName
SubjectDomainName
SubjectLogonId
```

Expected enrichment must identify an IAM user-account lockout and populate target-user information.

## Original XML preservation

### Initial implementation

Do not include `event.original` by default in `--format elastic`.

Reasons:

- Building XML and JSON for every event increases work and document size.
- Canonical structured content already exists under `winlog`.
- The primary requirement is integration compatibility.

### Optional enhancement

A later change may add:

```text
--preserve-original
```

When used with `--format elastic`, render the equivalent XML and store it in:

```json
"event": {
  "original": "<Event ...>...</Event>"
}
```

Also add:

```json
"tags": ["preserve_original_event"]
```

The XML and structured JSON must be generated from the same event parts, record ID, timestamp, process ID, and thread ID.

Do not enable preservation by default.

## Internal implementation design

### Preserve existing `EventParts`

Continue using:

```python
EventParts = tuple[int, str, str, list[tuple[str, str]]]
```

The existing event-generation functions should remain the semantic source of truth.

### Introduce a shared rendering context

The current XML renderer receives metadata separately, and some metadata is generated only on the XML path. Introduce an immutable rendering context or otherwise calculate all shared metadata before format dispatch.

Recommended shape:

```python
from dataclasses import dataclass
from datetime import datetime

@dataclass(frozen=True)
class RenderEvent:
    parts: EventParts
    timestamp: datetime
    system_time: str
    record_id: int
    process_id: int
    thread_id: int
```

A dataclass is recommended but not mandatory. The required outcome is that XML, flattened NDJSON, and Elastic renderers operate on the same semantic event and do not independently consume random values.

### Add `_render_elastic`

Suggested signature:

```python
def _render_elastic(
    parts: EventParts,
    ts: datetime,
    record_id: int,
    process_id: int,
    thread_id: int,
) -> str:
```

Responsibilities:

1. Extract `event_id`, `keywords`, `computer`, and `data`.
2. Read version metadata from `EVENT_META`.
3. Format the timestamp.
4. Convert `data` directly into `winlog.event_data` without renaming keys.
5. Construct the `event` and `winlog` objects.
6. Serialize compactly.

### Keep renderers independent

Maintain separate renderer functions:

```python
_render_xml(...)
_render_ndjson(...)
_render_elastic(...)
```

Do not modify the existing NDJSON schema to serve the new use case. Existing consumers may depend on it.

### Dispatch

Update the format dispatch approximately as follows:

```python
if args.format == "ndjson":
    return _render_ndjson(...)

if args.format == "elastic":
    return _render_elastic(...)

return _render_xml(...)
```

Generate all metadata required by any renderer before dispatch when necessary.

### Determinism

Adding a format must not accidentally change event selection, entities, correlations, or scenario behavior.

Requirements:

- The same seed, count, and start time produce byte-identical output within each format.
- Event IDs and event-specific values correspond across formats.
- Selecting `elastic` does not consume random values in an order that changes semantic event generation.
- Render functions should not call RNG directly.

## Unit tests

Add a new test class to `tests/test_windows.py`:

```python
class TestElasticFormat:
    ...
```

### Valid JSON and framing

Generate at least 300 records:

```python
lines = generate(
    main,
    count=300,
    extra=["--format", "elastic"],
)
```

For every line:

- `json.loads` succeeds.
- The parsed value is an object.
- The serialized event contains no embedded newline.
- There is exactly one event per generated line.

### Required objects and fields

Every record must contain:

```text
@timestamp
event
winlog
```

Every `event` object must contain:

```text
code
kind
module
outcome
```

Every `winlog` object must contain:

```text
api
channel
computer_name
event_id
provider_name
provider_guid
record_id
time_created
version
event_data
```

If process/thread metadata is included, validate its shape and types.

### Type assertions

Assert:

```python
isinstance(record["@timestamp"], str)
isinstance(record["event"]["code"], str)
isinstance(record["winlog"]["event_id"], str)
isinstance(record["winlog"]["record_id"], str)
isinstance(record["winlog"]["version"], int)
isinstance(record["winlog"]["event_data"], dict)
```

### Constant values

Assert:

```python
record["event"]["kind"] == "event"
record["event"]["module"] == "system"
record["winlog"]["api"] == "wineventlog"
record["winlog"]["channel"] == "Security"
record["winlog"]["provider_name"] == "Microsoft-Windows-Security-Auditing"
record["winlog"]["provider_guid"] == PROVIDER_GUID
```

### Event-code consistency

Assert:

```python
record["event"]["code"] == record["winlog"]["event_id"]
```

The code must be in:

```python
{"4624", "4625", "4672", "4688", "4720", "4740"}
```

### Outcomes

Assert:

```text
4625 -> failure
all other currently supported IDs -> success
```

### Event-data names

For each event ID, assert representative manifest names exist:

```text
4624:
  TargetUserName
  AuthenticationPackageName
  IpAddress
  ElevatedToken

4625:
  TargetUserName
  Status
  SubStatus
  IpAddress

4672:
  SubjectUserName
  PrivilegeList

4688:
  NewProcessName
  CommandLine
  ParentProcessName
  MandatoryLabel

4720:
  TargetUserName
  SamAccountName
  UserPrincipalName

4740:
  TargetUserName
  CallerComputerName
```

Assert that flattened NDJSON names do not appear at the root:

```text
target_user
source_ip
computer
event_id
```

### Per-computer record IDs

Reuse the existing invariant:

- IDs increase strictly and without gaps per `winlog.computer_name`.
- Different computers have distinct counter bases.
- The merged stream does not look like one global counter.

### Timestamps

Validate both:

```text
@timestamp
winlog.time_created
```

They must be valid UTC ISO-8601 timestamps and represent the same generated instant.

### Brute-force scenario

Run:

```text
--format elastic --scenario brute-force
```

Assert the scenario produces:

- Multiple `4625` events.
- Occasional `4740` events.
- A later attacker-originated `4624` event.
- Failure events containing `Status`, `SubStatus`, and attacker `IpAddress`.
- Stable user, domain, and source relationships.

### Seed determinism

Run the same command twice:

```text
--format elastic --seed 42 --count 100
```

Assert byte-identical output.

### Cross-format semantic equivalence

For a fixed seed and start time, generate XML and Elastic output separately.

Assert the same sequence of:

```text
event ID
computer
record ID
event-data names and values
timestamps
```

If renderer-specific RNG currently prevents this, refactor metadata generation so renderers do not consume random values independently.

### Backward compatibility

Run all existing XML and NDJSON tests unchanged.

Add explicit fixture or snapshot checks if necessary to prove the existing NDJSON structure has not changed.

## Elastic integration compatibility test

Unit tests are not sufficient. Add an optional integration test or a documented verification procedure against an Elastic Stack.

### Package selection

Install a pinned version of the Elastic System integration package. Record the tested version in one of:

- Integration-test configuration.
- Test documentation.
- A compatibility note in the README.

Do not test only against an unpinned `latest` package.

### Destination

Send representative records into:

```text
logs-system.security-default
```

The receiving pipeline, not the simulator, must add:

```json
"data_stream": {
  "type": "logs",
  "dataset": "system.security",
  "namespace": "default"
}
```

### Pipeline simulation

Before indexing, run one fixture for each supported event ID through Elasticsearch's ingest pipeline simulation API.

Use the actual installed System Security pipeline. Avoid duplicating its implementation in test code.

Pipeline simulation must demonstrate:

- No processor exception.
- No `event.kind: pipeline_error`.
- No unexpected `error.message`.
- Correct ECS categorization.

### End-to-end indexing

Index one representative document for every supported event ID into `logs-system.security-default`.

Verify the documents land in:

```text
.ds-logs-system.security-default-*
```

Every final document must contain:

```text
event.code
event.kind
event.category
event.type
event.action
winlog.provider_name
winlog.channel
winlog.computer_name
```

Event-specific assertions:

| Event ID | Required final behavior |
| --- | --- |
| `4624` | `event.action=logged-in`; authentication category; user and source fields |
| `4625` | `event.action=logon-failed`; `event.outcome=failure`; user and source fields |
| `4672` | `event.action=logged-in-special`; IAM/admin categorization |
| `4688` | `event.action=created-process`; process executable and command line |
| `4720` | `event.action=added-user-account`; IAM/user/creation categorization |
| `4740` | Account-lockout action and target-user fields |

Also verify:

- The official package mapping accepts all emitted field types.
- Raw flattened NDJSON keys do not leak into the root.
- `source.ip` and `source.port` are populated where the source event contains them.
- User and process fields are populated where expected.
- `related.user` and `related.ip` are populated where expected.

## Documentation requirements

Update the simulator table in the README to state that `logsim-windows` supports:

```text
Windows Security Event XML, flattened NDJSON, and Elastic
system.security-compatible JSON
```

Add examples:

```bash
# Emit Elastic-compatible Windows events to stdout
uvx --from git+https://github.com/matthew-hollick/log-simulators \
  logsim-windows --format elastic --count 5

# Stream continuously to Logstash
uvx --from git+https://github.com/matthew-hollick/log-simulators \
  logsim-windows \
  --format elastic \
  --output tcp://127.0.0.1:1518 \
  --rate 20 \
  --count 0

# Simulate a password spray
uvx --from git+https://github.com/matthew-hollick/log-simulators \
  logsim-windows \
  --format elastic \
  --scenario brute-force \
  --output tcp://127.0.0.1:1518 \
  --rate 20
```

Document explicitly:

- This format is intended as input to the Elastic System integration's `system.security` pipeline.
- It does not add data-stream routing fields.
- The receiver must route the event to `logs-system.security-<namespace>`.
- It does not fabricate Elastic Agent identity fields.
- Compatibility is tested against a named System integration package version.
- It emits the pre-ingest `winlog.*` contract, not a fully enriched final ECS document.

## Downstream Logstash design note

This section is informational and must not be implemented in the simulator repository.

After the simulator feature exists, the Logstash demonstration project should add a dedicated Windows JSON route. Reusing port `1517` is not recommended because that port deliberately stores raw input in `logs-mysyslog`.

Recommended route:

```text
Port 1518
  -> Logstash TCP input with JSON codec
  -> mark event as Windows Security
  -> set data_stream.dataset to system.security
  -> Elasticsearch data-stream output
  -> logs-system.security-default
  -> System integration Security ingest pipeline
```

Conceptual input:

```ruby
tcp {
  port => 1518
  codec => json
  add_field => {
    "[@metadata][windows_security]" => "true"
  }
}
```

Conceptual filter:

```ruby
if [@metadata][windows_security] == "true" {
  mutate {
    add_field => {
      "[data_stream][type]" => "logs"
      "[data_stream][dataset]" => "system.security"
      "[data_stream][namespace]" => "default"
    }
  }
}
```

The System integration package must be installed before sending events to this data stream.

## Verification commands

Run the upstream project's standard checks:

```bash
uv sync
uv run pytest
uv run ruff check .
uv run ruff format --check .
uv run mypy src tests
```

If the repository's documented commands differ, follow repository documentation and update this list accordingly.

Manual format verification:

```bash
uv run logsim-windows --format elastic --seed 42 --count 5
```

Continuous TCP verification:

```bash
uv run logsim-windows \
  --format elastic \
  --output tcp://127.0.0.1:1518 \
  --rate 20 \
  --count 0
```

## Acceptance criteria

The work is complete only when all of the following are true:

1. `logsim-windows --format elastic` is accepted.
2. Existing `xml` and `ndjson` behavior remains unchanged.
3. Every output event is one valid compact JSON line.
4. All event IDs are strings under both `event.code` and `winlog.event_id`.
5. `winlog.provider_name` is `Microsoft-Windows-Security-Auditing`.
6. `winlog.channel` is `Security`.
7. Original Windows manifest names and values appear under `winlog.event_data`.
8. No fake Elastic Agent identity fields are emitted.
9. Data-stream routing fields are not emitted by the simulator.
10. Seeded output is deterministic.
11. Existing tests pass without weakening assertions.
12. New format-specific tests cover every supported event ID.
13. Cross-format tests prove semantic consistency.
14. Representative events pass through a pinned System integration Security pipeline without `pipeline_error`.
15. Final indexed documents contain the expected ECS categorization and event-specific fields.
16. Documentation explains the input contract, routing requirement, and tested package version.

## Recommended implementation sequence

1. Read the current Windows simulator implementation and tests.
2. Verify the current System integration's input expectations using its source and installed ingest pipeline.
3. Record the System package version selected for compatibility testing.
4. Refactor semantic event metadata so renderers do not independently consume RNG values.
5. Add `_render_elastic`.
6. Add `elastic` to the CLI format choices and help.
7. Add schema, type, event-ID, scenario, and determinism unit tests.
8. Add cross-format semantic-equivalence tests.
9. Run all existing tests and static checks.
10. Install the pinned System package in a disposable Elastic test environment.
11. Simulate one fixture for every supported event ID through the installed Security pipeline.
12. Adjust only fields proven necessary by pipeline simulation.
13. Run end-to-end data-stream indexing tests.
14. Update the README and compatibility documentation.
15. Review the final change for backward compatibility and unnecessary collector metadata.

## Design principle

The new output must emit the document that Elastic's Windows event collector would hand to the System integration pipeline. It must not duplicate the System integration's ECS enrichment logic inside the simulator.
