#!/bin/bash

set -e

TOKEN_B=$(kubectl --context=minikube-b get secret workflow-remote-executor-token \
    -n default \
-o jsonpath='{.data.token}' | base64 -d)

if [ -z "$TOKEN_B" ]; then
    echo "ERROR: Failed to get token for minikube-b"
    exit 1
fi

TOKEN_C=$(kubectl --context=minikube-c get secret workflow-remote-executor-token \
    -n default \
-o jsonpath='{.data.token}' | base64 -d)

if [ -z "$TOKEN_C" ]; then
    echo "ERROR: Failed to get token for minikube-c"
    exit 1
fi

kubectl --context=minikube create secret generic cluster-tokens \
-n sys-argo-workflows \
--from-literal=minikube-b-token="$TOKEN_B" \
--from-literal=minikube-c-token="$TOKEN_C" \
--dry-run=client -o yaml | kubectl --context=minikube apply -f -

if [ $? -eq 0 ]; then
    echo "✓ Tokens stored in secret: cluster-tokens"
else
    echo "ERROR: Failed to store tokens"
    exit 1
fi

echo "Secret keys:"
kubectl --context=minikube get secret cluster-tokens -n sys-argo-workflows \
-o jsonpath='{.data}' | jq -r 'keys[]'

echo "Done"