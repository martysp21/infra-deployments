#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

CONFIGMAP="${KSM_CONFIGMAP:-$DIR/../../staging/custom-resource-state-config.yaml}"
CONTEXT="${KSM_CONTEXT:-$(oc config current-context)}"
SA_NS="${KSM_SA_NS:-appstudio-monitoring}"
SA_NAME="${KSM_SA_NAME:-custom-kube-state-metrics}"

if ! command -v oc >/dev/null || ! command -v podman >/dev/null || ! command -v python3 >/dev/null; then
  echo "Need oc, podman, and python3 on PATH."
  exit 1
fi

if [[ ! -f "$CONFIGMAP" ]]; then
  echo "KSM ConfigMap not found: $CONFIGMAP"
  exit 1
fi

if ! oc --context="$CONTEXT" whoami >/dev/null 2>&1; then
  echo "Not logged in (context: $CONTEXT)."
  echo "oc login to the target cluster (VPN + Konflux portal token), then re-run: $0"
  exit 1
fi

echo "Using context: $CONTEXT ($(oc --context="$CONTEXT" whoami))"
echo "API: $(oc --context="$CONTEXT" whoami --show-server)"
echo "Unwrapping $CONFIGMAP"
python3 - "$CONFIGMAP" "$DIR/custom-resource-state.yaml" <<'PY'
from pathlib import Path
import sys

src, dest = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text()
marker = "custom-resource-state.yaml: |\n"
i = text.find(marker)
if i < 0:
    raise SystemExit(f"marker not found in {src}")
lines = []
for line in text[i + len(marker):].splitlines():
    if line.startswith("    "):
        lines.append(line[4:])
    elif not line.strip():
        lines.append("")
    else:
        break
dest.write_text("\n".join(lines).rstrip() + "\n")
PY

echo "Minting 2h token for ${SA_NS}/${SA_NAME} (KSM needs CRD list/watch; user tokens usually cannot)"
python3 - "$CONTEXT" "$SA_NS" "$SA_NAME" "$DIR/kubeconfig" <<'PY'
import json, subprocess, sys
from pathlib import Path

context, sa_ns, sa_name, out = sys.argv[1:]
flatten = subprocess.check_output(
    ["oc", "--context", context, "config", "view", "--minify", "--flatten", "-o", "json"]
)
token = subprocess.check_output(
    ["oc", "--context", context, "create", "token", sa_name, "-n", sa_ns, "--duration=2h"],
    text=True,
).strip()
cfg = json.loads(flatten)
cluster = cfg["clusters"][0]
cfg["users"] = [{"name": "ksm-sa", "user": {"token": token}}]
cfg["contexts"] = [{
    "name": "ksm-sa",
    "context": {
        "cluster": cluster["name"],
        "user": "ksm-sa",
        "namespace": sa_ns,
    },
}]
cfg["current-context"] = "ksm-sa"
Path(out).write_text(json.dumps(cfg, indent=2) + "\n")
PY
chmod 600 "$DIR/kubeconfig"

podman compose -f "$DIR/compose.yaml" up -d --force-recreate
echo
echo "KSM metrics:    http://localhost:8080/metrics"
echo "Prometheus UI:  http://localhost:9090"
echo "Wait ~30-60s on prod for CRD + PipelineRun list, then:"
echo "  curl -s http://localhost:8080/metrics | grep konflux_pipelinerun_info | head"
echo "  open http://localhost:9090"
echo
echo "SA token lasts 2h. Re-run this script to refresh. Stop with ./stop.sh"
