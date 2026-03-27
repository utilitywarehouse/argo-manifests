# Argo Workflows

Argo Workflows namespaced install from the QE team on `exp-1-merit`.

## Access

UI: https://argo-workflows.exp-1.merit.uw.systems

## Remote Namespace Job Executor

The `remote-namespace-job-executor` WorkflowTemplate allows workflows running in `qe-argo-workflows` to dispatch Kubernetes Jobs to namespaces on remote clusters.

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

# either from the sa secret
kubectl --context <cluster> -n <target-namespace> get secret argo-workflow-job-executor-token \
  -o jsonpath='{.data.ca\.crt}' | base64 -d

# or from
https://kube-ca-cert.<cluster_prefix>.[aws|gcp|merit].uw.systems/

```

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
              name: remote-namespace-job-executor
              template: execute-job
            arguments:
              parameters:
                - name: cluster-name
                  value: "exp-1-aws"
                - name: cluster-server
                  value: "https://elb.master.k8s.exp-1.aws.uw.systems"
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

| Parameter          | Description                                                    | Default  |
| ------------------ | -------------------------------------------------------------- | -------- |
| `cluster-name`     | Name of the target cluster, must match CA cert filename prefix | required |
| `cluster-server`   | API server URL of the target cluster                           | required |
| `target-namespace` | Namespace to run the job in                                    | required |
| `job-template`     | Full Job manifest as a YAML string                             | required |
| `timeout`          | How long to wait for job completion                            | `5m`     |
| `teardown`         | Delete the job after completion                                | `true`   |

### Outputs

| Output               | Description                                       |
| -------------------- | ------------------------------------------------- |
| `result` (artifact)  | Raw output file from the job                      |
| `result` (parameter) | Value of `ARGO_RESULT_OUTPUT=` printed by the job |

To pass a result back from your job, print it in the format:

```sh
echo "ARGO_RESULT_OUTPUT=my-value"
```
