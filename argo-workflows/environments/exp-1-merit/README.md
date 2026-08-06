# Argo Workflows

Argo Workflows namespaced install from the QE team on `exp-1-merit`.

## Access

UI: https://argo-workflows.exp-1.merit.uw.systems

## Remote Namespace Job Executor

The `executor-remote-namespace` WorkflowTemplate allows workflows running in `qe-argo-workflows` to dispatch Kubernetes Jobs to namespaces on remote clusters.

### How it works

Each remote namespace opts in by:

1. Creating an `argo-workflow-job-executor` ServiceAccount, Role, RoleBinding and token Secret in their namespace
2. Sharing the token and their cluster CA cert with the QE team to store in `exp-1-merit`

The WorkflowTemplate uses these to authenticate against the remote cluster and execute Jobs in the target namespace.

### Adding a new remote namespace

#### On the target cluster/namespace

Apply the following manifests in the target namespace:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-workflow-job-executor
  namespace: <target-namespace>
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argo-workflow-job-executor
  namespace: <target-namespace>
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argo-workflow-job-executor
  namespace: <target-namespace>
subjects:
  - kind: ServiceAccount
    name: argo-workflow-job-executor
    namespace: <target-namespace>
roleRef:
  kind: Role
  name: argo-workflow-job-executor
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Secret
metadata:
  name: argo-workflow-job-executor-token
  namespace: <target-namespace>
  annotations:
    kubernetes.io/service-account.name: argo-workflow-job-executor
type: kubernetes.io/service-account-token
```

Then share the token and CA cert:

```bash
# Get the token
kubectl --context <cluster> -n <target-namespace> get secret argo-workflow-job-executor-token \
  -o jsonpath='{.data.token}' | base64 -d

# Get the cluster's CA cert
curl -sS https://kube-ca-cert.exp-1.aws.uw.systems/ > secrets/exp-1-aws-ca.crt

# or from the sa secret
kubectl --context <cluster> -n <target-namespace> get secret argo-workflow-job-executor-token \
  -o jsonpath='{.data.ca\.crt}' | base64 -d
```

The `kube-ca-cert` host is the cluster name with its **last** hyphen swapped for a dot — `exp-1-aws` → `exp-1.aws`, `dev-merit` → `dev.merit`:

```
https://kube-ca-cert.<cluster-prefix>.[aws|gcp|merit].uw.systems/
```

Don't take it from your kubeconfig (`~/.kube/certs/<cluster>/ca.pem`), that's whatever your last login cached, not necessarily current.

### Expired CA certs

An expired pinned CA breaks **every** dispatch to that cluster at TLS, in every namespace, and the error names the namespace of exec-kube's first API call rather than the cert. You should see something like

```
time="2026-08-06T07:40:53 UTC" level=debug msg="connecting to cluster dev-aws at https://elb.master.k8s.dev.uw.systems"
time="2026-08-06T07:40:53 UTC" level=fatal msg="failed to resolve secret/configmap references: failed to list secrets in account-platform: Get \"https://elb.master.k8s.dev.uw.systems/api/v1/namespaces/account-platform/secrets\": tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time 2026-08-06T07:40:53Z is after 2026-08-06T00:04:00Z"
```

The job-executor tokens are legacy `kubernetes.io/service-account-token` Secrets with no `exp` claim, so they are never the cause. Check the certs first

```bash
for f in secrets/*-ca.crt; do
  printf '%-28s %s\n' "$f" "$(openssl x509 -in "$f" -noout -enddate)"
done
```

Or one, with a machine-readable verdict (`-checkend` takes seconds; 30 days shown here):

```bash
openssl x509 -in secrets/exp-1-aws-ca.crt -noout -checkend 2592000 \
  && echo "valid > 30d" || echo "EXPIRING or EXPIRED — re-fetch"
```

To confirm a cert is genuinely the right anchor, verify the cluster's live serving cert against it:

```bash
echo | openssl s_client -connect elb.master.k8s.exp-1.aws.uw.systems:443 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' > /tmp/leaf.pem
openssl verify -CAfile secrets/exp-1-aws-ca.crt /tmp/leaf.pem   # → OK
```

Fixing is a re-fetch from the `kube-ca-cert` URL plus a commit — the tokens, RBAC and `cluster-servers` entries are unaffected by a CA rotation.

#### On exp-1-merit

**1. Add the token** to `secrets/job-executor-tokens.env`:

```dotenv
# pattern: <cluster-name>-<namespace>=<token>
exp-1-aws-sys-k6=<token>
```

**2. Add the CA cert** as `secrets/<cluster-name>-ca.crt` — the filename must match the cluster name exactly as it will be referenced at runtime:

```
secrets/exp-1-aws-ca.crt
```

**3. Register the CA cert** in `kustomization.yaml` under `cluster-ca-certs`:

```yaml
configMapGenerator:
  - name: cluster-ca-certs
    files:
      - secrets/exp-1-aws-ca.crt
      - secrets/exp-1-gcp-ca.crt
```

**4. Register the cluster's API server URL** in `kustomization.yaml` under `cluster-servers`, keyed by `cluster-name` (this is what the executor resolves into `CLUSTER_SERVER`, so callers only pass `cluster-name`):

```yaml
configMapGenerator:
  - name: cluster-servers
    literals:
      - exp-1-aws=https://elb.master.k8s.exp-1.aws.uw.systems
```

### Using the WorkflowTemplate

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: my-workflow
  namespace: qe-argo-workflows
spec:
  entrypoint: main
  templates:
    - name: main
      steps:
        - - name: run-remote-job
            templateRef:
              name: executor-remote-namespace
              template: execute-job
            arguments:
              parameters:
                - name: cluster-name
                  value: "exp-1-aws"
                - name: target-namespace
                  value: "sys-k6"
                - name: job-template
                  value: |
                    apiVersion: batch/v1
                    kind: Job
                    spec:
                      template:
                        spec:
                          restartPolicy: Never
                          containers:
                            - name: my-job
                              image: alpine:latest
                              command: [sh, -c]
                              args: ["echo hello"]
```

### Parameters

| Parameter | Description | Default |
| --- | --- | --- |
| `cluster-name` | Target cluster; resolves the CA cert, token, and API server URL (via the `cluster-servers` ConfigMap) 1:1 | required |
| `target-namespace` | Namespace to run the job in | required |
| `job-template` | Full Job manifest as a YAML string | required |
| `timeout` | How long to wait for job completion | `5m` |
| `teardown` | Delete the job after completion | `true` |

### Outputs

| Output               | Description                                       |
| -------------------- | ------------------------------------------------- |
| `result` (artifact)  | Raw output file from the job                      |
| `result` (parameter) | Value of `ARGO_RESULT_OUTPUT=` printed by the job |

To pass a result back from your job, print it in the format:

```sh
echo "ARGO_RESULT_OUTPUT=my-value"
```
