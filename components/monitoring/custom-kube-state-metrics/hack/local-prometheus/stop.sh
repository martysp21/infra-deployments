#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
podman compose -f "$DIR/compose.yaml" down
rm -f "$DIR/kubeconfig" "$DIR/custom-resource-state.yaml"
echo "Stopped KSM + Prometheus."
