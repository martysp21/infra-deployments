# Local KSM + Prometheus (listen to a cluster)

Run kube-state-metrics and Prometheus on your laptop. They **list/watch** the
cluster API only — nothing is applied, and nothing is remote-written to RHOBS.

Uses the staging KSM ConfigMap (`staging/custom-resource-state-config.yaml`)
against whichever cluster your current `oc` context points at.

## Prerequisites

- VPN
- [Podman](https://podman.io/) (compose plugin / `podman compose`)
- `oc` and `python3`
- A login that can `oc create token custom-kube-state-metrics -n appstudio-monitoring`
- Repo path under `$HOME` on macOS (Podman machine does not mount `/tmp`)

## Listen to production (stone-prod-p02)

1. Start the Podman machine if needed:

   ```bash
   podman machine start
   ```

2. Log in to prod-p02. Get a token from the
   [Konflux portal](https://konflux.pages.redhat.com/konflux-portal/developer/konflux-clusters.html?env=production&type=multi-tenant)
   (production, stone-prod-p02):

   ```bash
   oc login --token=<token> --server=https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443
   oc whoami --show-server   # must be stone-prod-p02
   ```

3. From the repo root, start the stack:

   ```bash
   components/monitoring/custom-kube-state-metrics/hack/local-prometheus/start.sh
   ```

   This unwraps the staging ConfigMap, mints a 2h token for the in-cluster
   `custom-kube-state-metrics` ServiceAccount (your user cannot list CRDs),
   and runs `podman compose up`.

4. Wait 30–60s on prod (CRD informer + PipelineRun list). Confirm KSM:

   ```bash
   curl -s http://localhost:8080/metrics | grep konflux_pipelinerun_info | head
   podman logs ksm 2>&1 | grep -i 'added metrics'
   ```

   Prometheus target must be **UP**: http://localhost:9090/targets

5. Query in http://localhost:9090 (the Gauge **value** is `metadata.generation`,
   not a count — use `count()`):

   ```promql
   count(kube_customresource_konflux_pipelinerun_info)
   count by (pipeline_type) (kube_customresource_konflux_pipelinerun_info)
   count by (namespace, application, component, pipeline_type) (
     kube_customresource_konflux_pipelinerun_info{pipeline_type="build"}
   )
   ```

   Approximate build starts in 10 minutes (needs ≥10m of local scrape history):

   ```promql
   count(count_over_time(kube_customresource_konflux_pipelinerun_info{pipeline_type="build"}[10m]))
   -
   count(kube_customresource_konflux_pipelinerun_info{pipeline_type="build"} offset 10m)
   ```

6. Stop:

   ```bash
   components/monitoring/custom-kube-state-metrics/hack/local-prometheus/stop.sh
   ```

   Re-run `start.sh` after 2 hours (SA token expiry) or after `oc login` refresh.

## Staging instead of prod

Log in to `stone-stage-p01` (or another staging cluster) and run the same
`start.sh`. It uses the current `oc` context unless you set `KSM_CONTEXT`.

## Notes

- This does **not** deploy the metric to production. Production KSM stays
  unchanged; only your laptop evaluates the staging ConfigMap against prod objects.
- Do not commit `kubeconfig` (gitignored). It contains a bearer token.
- `/tmp` bind-mounts fail on Podman Desktop; keep this directory in the repo
  under `$HOME`.
