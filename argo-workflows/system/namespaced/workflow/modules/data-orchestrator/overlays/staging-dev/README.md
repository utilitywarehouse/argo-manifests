# staging overlay

Used to distribute `secrets/`, a data-orchestrator DB DSN, temporarily.

Only consumer of this overlay should be dev-merit/staging-ept, so `secrets/` is encrypted with
that namespace's strongbox recipient. This only works because it's delivered via ArgoCD (+strongbox) into that one namespace, so decryption happens in-cluster out of the box.

> [!CAUTION]
> This is a one-off, not a pattern. It is **not** a way to distribute secrets across namespaces, as handy as that would be, it isn't safe. This project can't manage cross-namespace encryption, because a single path can only be encrypted to one strongbox recipient, and different namespaces have different keys. This works by a happy coincidence and should not be replicated or used else where
