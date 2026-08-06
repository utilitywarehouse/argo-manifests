# AWS credentials for artifacts

Steps pass data as artifacts in S3. Argo loads a step's input artifacts in an **init** container and saves its outputs in a **wait** container — both need bucket credentials.

## Problem

Vault provides AWS credentials two ways:

- **Sidecar** (`vault-sidecar-aws`) — serves credentials over a localhost endpoint (`:8098`), started alongside the main containers. Consumers poll it (`until nc 127.0.0.1 8098`) until it is ready.
- **Init container** (`vault-init-container-aws`) — writes a static credentials file and exits before the pod's other containers start.

Input artifacts load in the **init phase**, before the main containers run. The sidecar is not serving yet then, so it cannot supply credentials to the download.

## Solution

Use the init-container variant. Vault injects its credentials container as the **first** init container, ahead of Argo's artifact `init`:

```
vault-credentials   injected first   fetch creds → /etc/aws/credentials, then exit
init                Argo             download input artifacts
main                                 the step runs
wait                Argo             upload output artifacts
```

The credentials file is on disk before `init` runs, so the download authenticates immediately and nothing polls an endpoint. Ordering is the point: a credentials container placed after `init` would be too late.

Both variants and the service-account role they draw from are set up as in the platform Vault docs: [infra/vault](https://github.com/utilitywarehouse/documentation/tree/master/infra/vault).

## Wiring

Three defaults, so workflows need no per-template config (`workflow-controller-configmap`):

```yaml
# workflowDefaults — request the init-container variant
podMetadata:
  annotations:
    uw.systems/kyverno-inject-sidecar-request: vault-init-container-aws

# artifactRepository — read the file via the AWS SDK chain
s3:
  bucket: uw-dev-qe-argo-workflows
  region: eu-west-1
  useSDKCreds: true

# executor — mount the creds onto Argo's init + wait containers
env:
  - name: AWS_SHARED_CREDENTIALS_FILE
    value: /etc/aws/credentials
volumeMounts:
  - name: vault-aws-credentials
    mountPath: /etc/aws
```

The Vault injection sets the file and volume on the main containers only; the `executor` block adds them to `init` and `wait`, which the injection does not cover.

## Scope

Credentials are fetched once at pod start and not rotated — fine for short-lived step pods. The long-running remote Jobs the workflows dispatch into other namespaces request the sidecar variant themselves, independent of this default.
