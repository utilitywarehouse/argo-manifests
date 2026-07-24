# Passing data between workflow steps

How a step produces structured data, the next step captures it, and later steps pull the
fields they need — without building JSON in SQL or shipping `jq`.

## The principle

```
query (flat)  →  file / artifact  →  select (expr)  →  the fields a step needs
 ndjson rows       the "model"         full / partial /    json array (withParam),
 no SQL JSON        (any size)          specific            a list, or a scalar
```

1. **Query flat.** A producer (`query-pg`) runs a plain `SELECT` and streams rows to a
   file — no `json_build_object` / `json_agg`, no CSV quoting. Shaping inside the query
   pushes serialisation and aggregation onto the DB and does not scale.
2. **Capture the file** as an Argo artifact (any size), plus a small parameter mirror.
3. **Select downstream.** A later step runs the `select` executor — parse, apply an expr,
   emit — over the captured file.

Format is the contract; the query just streams rows.

## Capturing a result from a remote Job

Queriers reaching a DB in another namespace run as Kubernetes Jobs dispatched by
`exec-kube` (`step-executor-remote-namespace`). Argo does not manage those Jobs, so the
only channel back is the Job's **log stream**, which `exec-kube` turns into two artifacts
on its own pod:

- `result` → `/tmp/result.txt` (also mirrored as a `result` parameter)
- `logs` → `/tmp/logs.txt`

### The capture contract

Bracket the payload between two markers; send diagnostics to stderr:

```sh
query-pg                 # logs → stderr; rows → /tmp/out.ndjson
echo ARGO_RESULT_BEGIN
cat /tmp/out.ndjson      # the payload
echo ARGO_RESULT_END
```

`exec-kube` captures the content between the markers (the last complete block) as
`result` and strips those lines from `logs`, so the result is never duplicated into the
logs.

**Why `END` matters.** `kubectl logs` merges stdout and stderr by arrival at the kubelet,
not by program order, so a late diagnostic can land after the payload. `END` bounds the
capture. `BEGIN` with no `END` yields an empty result and a warning; capture-to-EOF is not
supported.

**Single scalars.** For one value, print one line instead of bracketing:

```sh
echo "ARGO_RESULT_OUTPUT=$account_id"
```

Only `<value>` is written to `result`. With no marker, `result` is empty.

### Where the result rides back

Parameters live in the Workflow object (etcd) — keep them small. Artifacts live in S3 and
can be any size.

| Result size                  | Comes back as              | Consumed by                                                                           |
| ---------------------------- | -------------------------- | ------------------------------------------------------------------------------------- |
| Small (id maps, short lists) | the `result` **parameter** | a controller expr `{{= jsonpath(...) }}` / `{{= fromJson(...) }}`, or a `select` step |
| Large (bulk rows)            | the `result` **artifact**  | a `select` step that mounts the artifact                                              |

## Selecting fields with `select`

The controller expression engine (`{{= ... }}`) only sees **parameters**, never artifact
**files**. Pulling fields from a file has to run in a step: the `select` executor reads an
input file, evaluates an [expr-lang](https://expr-lang.org) expression over `rows`, and
emits.

| Env var         | Default  | Meaning                                     |
| --------------- | -------- | ------------------------------------------- |
| `INPUT`         | `-`      | Input file (`-` = stdin)                    |
| `FORMAT`        | `ndjson` | Input format: `json`, `ndjson`, `lines`     |
| `SELECT`        | —        | expr-lang expression over `rows` (required) |
| `OUTPUT`        | `-`      | Output file (`-` = stdout)                  |
| `OUTPUT_FORMAT` | `json`   | Output format: `json`, `ndjson`, `lines`    |

Input parses into `rows` (a list of objects). `json` output is a **bare** array
(`["J…","K…"]`, not `[{"value":…}]`) so it drops into `withParam`; `lines` emits scalars
bare, one per line (shell- and SQL-friendly).

### expr cookbook

`select` and the `call-*` asserts share the expr engine; builtins include `map, filter,
uniq, join, sort, sortBy, concat, flatten, reduce, groupBy, keys, values`.

| Need                         | `SELECT`                                                                             | `OUTPUT_FORMAT`         |
| ---------------------------- | ------------------------------------------------------------------------------------ | ----------------------- |
| fan-out list for `withParam` | `uniq(map(filter(rows, .gentrack_account_number != nil), .gentrack_account_number))` | `json` → `["J…","K…"]`  |
| readable / shell list        | `map(rows, .mpxn)`                                                                   | `lines`                 |
| SQL `IN (…)`, string ids     | `join(map(uniq(map(rows, .x)), "'" + # + "'"), ",")`                                 | `lines` → `'J…','K…'`   |
| SQL `IN (…)`, numeric ids    | `join(map(rows, string(.id)), ",")`                                                  | `lines` → `31222,31245` |
| specific scalar              | `rows[0].gentrack_customer_id`                                                       | `json` / `lines`        |
| filter, then project         | `map(filter(rows, .gentrack_account_number == "K12345"), .mpxn)`                     | `json`                  |
| partial objects              | `map(rows, {mpxn: .mpxn, agr: .gentrack_agreement_id})`                              | `json` / `ndjson`       |

### expr does not flow between steps

expr-lang runs **inside a step**, over already-parsed values:

- **Inside a step** (a `select` container, or a `call-*` assert): expr over a file or a
  response.
- **Between steps** (the controller): `{{= jsonpath(param, ...) }}` /
  `{{= fromJson(param) }}`, over **parameters only**, never artifact files.

So an artifact produced by one workflow and consumed by another is just an input-artifact
**file** to a `select` step — it carries across steps and workflows, but always through a
step that does the selection.

## Formats

`select` ships `json`, `ndjson`, `lines`. `csv`/`values` are deferred: a comma list for
SQL `IN (...)` is a one-line expr (`join(map(rows, .id), ",")`) emitted as `lines`. Add
locally if a real need appears.

## Worked example: resolve → model → select

`flow-account-select` (`templates/test/account-select.yaml`) is the pattern end to end.

**1. Producers.** `resolve-account` turns an account number into `account_id`;
`resolve-service-identifiers` pipes that in and streams the account's supplies as flat
ndjson (the `identifiers` artifact). This is the workflow-to-workflow data pipe.

**2. Build the model.** A `select` step joins the flat rows into one nested account object
(account scalars with supplies nested under `supplies`), emitted as an ndjson artifact:

```yaml
- - name: build-model
    template: select
    arguments:
      artifacts:
        - { name: input, from: "{{steps.resolve-service-identifiers.outputs.artifacts.identifiers}}" }
      parameters:
        - name: expr
          value: >-
            [{
              account_number: "{{inputs.parameters.account-number}}",
              account_id: "{{steps.resolve-account-id.outputs.parameters.account-id}}",
              supplies: map(rows, ({supply_type: .supply_type, mpxn: .mpxn,
                gentrack_account_number: .gentrack_account_number}))
            }]
        - { name: output, value: /tmp/out }          # emit the model as an artifact
        - { name: output-format, value: ndjson }      # one account object per line
```

**3. Select over the model** at any precision. The account is `rows[0]`; supplies are
always mapped/filtered (never `.supplies[0]`), so a dual-fuel account keeps both fuels:

```yaml
expr: "rows[0]"                                                          output-format: json    # full object
expr: "map(rows[0].supplies, {supply_type: .supply_type, mpxn: .mpxn})" output-format: json    # partial, per supply
expr: "map(rows[0].supplies, .mpxn)"                                    output-format: lines   # flat list for fan-out / SQL IN
expr: "rows[0].account_id"                                              output-format: json    # single scalar
```

One query → one flat artifact → one model → many `select` steps. To fan out, feed a `json`
array straight into `withParam`:

```yaml
- - name: bill-each
    withParam: "{{steps.select-gentrack.outputs.parameters.result}}"   # ["J20000032681", …]
    arguments:
      parameters: [{ name: gentrack-account-number, value: "{{item}}" }]
```

## Pinning executor images

Executor image versions (`query-pg`, `select`, `exec-kube`, ...) are pinned per package by
kustomize `replacements`, not per workflow. See [image-pinning.md](image-pinning.md).
