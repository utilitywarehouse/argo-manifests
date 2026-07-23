# Data flow: capturing query results and selecting fields between steps

How workflow steps produce structured data, capture it, and let later steps pick out the
full / partial / specific properties they need — without assembling JSON in SQL and without
`jq` in any image.

## The principle

Do the plainest, fastest thing at each stage:

1. **Query flat.** A producer (e.g. `query-pg`) runs a plain `SELECT` and streams the rows to
   a file — no `json_build_object` / `json_agg`, no CSV-quoting. Shaping output _inside_ the
   query pushes serialization and aggregation onto the DB and is a real bottleneck at scale.
2. **Capture the file as an artifact.** The result becomes an Argo artifact (any size) plus a
   small parameter mirror.
3. **Select downstream.** Any later step that needs specific fields runs the **`select`**
   executor — parse → expr → emit — over the captured artifact.

```
query (flat)  ──▶  file/artifact  ──▶  select (expr)  ──▶  fields a step needs
 ndjson rows        the "model"         full/partial/          json array (withParam),
 no SQL JSON        (any size)          specific               a list, a scalar, …
```

Format is the contract; transport stops leaking into the query.

## Capturing a result from a remote Job (`exec-kube`)

Queriers that must reach a DB in another namespace run as **Kubernetes Jobs** dispatched by
`exec-kube` (the `executor-remote-namespace` template). Argo does not manage those Jobs, so
the only channel back is the Job's **log stream**, which `exec-kube` turns into two artifacts
on its own (Argo-managed) pod:

- `result` → `/tmp/result.txt` (also mirrored as a `result` **parameter**)
- `logs` → `/tmp/logs.txt`

### The capture contract

Bracket the result between two marker lines. Send diagnostics to **stderr**; print the
payload between the markers:

```sh
query-pg                 # logs -> stderr; rows -> /tmp/out.ndjson
echo ARGO_RESULT_BEGIN
cat /tmp/out.ndjson      # the result payload
echo ARGO_RESULT_END
```

`exec-kube` captures the content **between** the markers (last complete block) as `result`,
and removes those lines from `logs` — so the result is never duplicated into the logs.

**Why `END` matters.** `kubectl logs` merges stdout and stderr, and the two streams interleave
by arrival at the kubelet, _not_ by program order — a diagnostic flushed late can appear
_after_ the payload. The `END` marker bounds the capture so such a line is excluded. A
`BEGIN` with no `END` yields an empty result and a warning; capture-to-EOF is deliberately not
supported.

**Tiny scalars (back-compat).** For a single value, print one line instead:

```sh
echo "ARGO_RESULT_OUTPUT=$account_id"
```

Only `<value>` is written to `result`. If neither marker is present, `result` is **empty**
(the full logs are never dumped into it).

### Small vs large — where the result rides back

Output **parameters** live in the Workflow object (etcd) — keep them small. Artifacts live in
the S3 artifact repository — any size.

| Result size                      | How it comes back          | How to consume                                                                      |
| -------------------------------- | -------------------------- | ----------------------------------------------------------------------------------- |
| **Small** (id maps, short lists) | the `result` **parameter** | controller expr `{{= jsonpath(...) }}` / `{{= fromJson(...) }}`, or a `select` step |
| **Large** (bulk rows)            | the `result` **artifact**  | a `select` step that mounts the artifact                                            |

## Selecting fields (`select`)

Argo's controller expression engine (`{{= ... }}`) only ever sees **parameters** — never
artifact **files**. So selecting fields out of an artifact file **must run in a step**. That
step is the `select` executor: it reads an input file/artifact, evaluates an
[expr-lang](https://expr-lang.org) expression against `rows`, and emits the result.

| Env var         | Default  | Meaning                                     |
| --------------- | -------- | ------------------------------------------- |
| `INPUT`         | `-`      | Input file (`-` = stdin)                    |
| `FORMAT`        | `ndjson` | Input format: `json`, `ndjson`, `lines`     |
| `SELECT`        | —        | expr-lang expression over `rows` (required) |
| `OUTPUT`        | `-`      | Output file (`-` = stdout)                  |
| `OUTPUT_FORMAT` | `json`   | Output format: `json`, `ndjson`, `lines`    |

The input is parsed into `rows` (a list of objects). `json` output is a **bare** array
(`["J…","K…"]`, not `[{"value":…}]`) so it drops straight into `withParam`; `lines` emits
scalars bare, one per line (readable, shell- and SQL-friendly).

### expr cookbook

`select` and the `call-*` asserts share the same expr engine (expr-lang), whose builtins
include `map, filter, uniq, join, sort, sortBy, concat, flatten, reduce, groupBy, keys,
values`.

| Need                         | `SELECT`                                                                             | `OUTPUT_FORMAT`         |
| ---------------------------- | ------------------------------------------------------------------------------------ | ----------------------- |
| fan-out list for `withParam` | `uniq(map(filter(rows, .gentrack_account_number != nil), .gentrack_account_number))` | `json` → `["J…","K…"]`  |
| readable / shell list        | `map(rows, .mpxn)`                                                                   | `lines`                 |
| SQL `IN (…)`, string ids     | `join(map(uniq(map(rows, .x)), "'" + # + "'"), ",")`                                 | `lines` → `'J…','K…'`   |
| SQL `IN (…)`, numeric ids    | `join(map(rows, string(.id)), ",")`                                                  | `lines` → `31222,31245` |
| specific scalar              | `rows[0].gentrack_customer_id`                                                       | `json` / `lines`        |
| filter, then project         | `map(filter(rows, .gentrack_account_number == "K12345"), .mpxn)`                     | `json`                  |
| partial objects              | `map(rows, {mpxn: .mpxn, agr: .gentrack_agreement_id})`                              | `json` / `ndjson`       |

### expr does not flow across steps

expr-lang runs _inside a step_, over parsed values (hence it is format-agnostic). It does
**not** flow between steps on its own:

- **Inside a step** (a `select` container, or a `call-*` assert): expr over a file or a
  response.
- **Between steps** (the controller): `{{= jsonpath(param, ...) }}` / `{{= fromJson(param) }}`
  — over **parameters only**, never artifact files.

So an artifact from one workflow consumed by another is just an input-artifact **file** to a
step that runs `select`. It translates across steps and workflows — but always _through a step
that does the selection_, never as free-floating controller magic.

## Worked example: resolve → bill an account

**Producer — `resolve-service-identifiers`** (`templates/energy/`). A flat query streamed as
ndjson, bracketed by the markers:

```yaml
env:
  - name: QUERY
    value: >-
      SELECT s.supply_type, s.mpxn, s.gentrack_account_number,
             s.gentrack_account_id, s.gentrack_agreement_id, s.gentrack_customer_id
      FROM service_snapshot s
      WHERE s.customer_account_id = '{{inputs.parameters.account-id}}'
        AND s.energy_billing_platform = '{{inputs.parameters.billing-platform}}'
  - { name: FORMAT, value: ndjson }
  - { name: OUTPUT, value: /tmp/out.ndjson }
args:
  - |
    set -eu
    /bin/executor
    echo ARGO_RESULT_BEGIN
    cat /tmp/out.ndjson
    echo ARGO_RESULT_END
```

The `identifiers` output (artifact + parameter mirror) is now the account's **flat supply
rows** — the account model, unshaped. `account_id` is the input, not repeated per row.

**Composer — `resolve-account`** (`templates/account/`) passes the `identifiers` artifact
through and adds the `account-id` and `account-number` parameters. One artifact + two scalars
_are_ the model, queried selectively downstream.

**Consumer — `bill-account`** (to build) needs different fields at different stages:

```yaml
# Stage 1 — distinct gentrack numbers, as a JSON array, to fan out:
- - name: gentrack-numbers
    template: select-step # a container running the `select` image
    arguments:
      artifacts:
        [
          {
            name: input,
            from: "{{steps.resolve.outputs.artifacts.identifiers}}",
          },
        ]
      parameters:
        - { name: format, value: ndjson }
        - {
            name: select,
            value: "uniq(map(filter(rows, .gentrack_account_number != nil), .gentrack_account_number))",
          }
        - { name: output-format, value: json }
- - name: bill-each
    withParam: "{{steps.gentrack-numbers.outputs.parameters.result}}" # ["J20000032681", …]
    template: bill-one
    arguments:
      parameters: [{ name: gentrack-account-number, value: "{{item}}" }]
# Inside bill-one — Stage 2: the supplies for THIS gentrack number, to drive a query/step:
#   SELECT='filter(rows, .gentrack_account_number == "{{inputs.parameters.gentrack-account-number}}")'
# Stage 3, later — account_id / account_number / mpxns, individually or together:
#   SELECT='rows[0].gentrack_customer_id'                         # specific scalar
#   SELECT='map(rows, .mpxn)'   OUTPUT_FORMAT=lines               # a list
#   SELECT='map(rows, {mpxn: .mpxn, agr: .gentrack_agreement_id})' # partial objects
# account_id / account_number come straight from resolve-account's parameters.
```

One query → one flat artifact → many `select` steps, each pulling exactly what it needs.

## Formats

`select` (and `pkg/dataset`) ship `json`, `ndjson`, `lines`. `csv` and `values` are
deliberately deferred — a comma list for SQL `IN(...)` is a one-line expr
(`join(map(rows, .id), ",")`) emitted as `lines`, so they earn no separate format yet. They
remain a small, local add if a real need appears.

## Pinning executor images

Executor image versions are pinned in one place —
`templates/shared/kustomization.yaml`, the `image-versions` configMap — and injected into the
templates by kustomize `replacements`. Bump a tag there and it propagates to every
environment. `exec-kube` feeds `executor-remote-namespace`; `select` is pinned for when a
template adds a select step (wire a `replacement` at that point). Prefer a commit SHA for
promoted versions; a branch tag (e.g. `chore-redesign-wkflw-data-prop`) is fine while
validating in dev.
