# Flux Monitoring

The monitoring stack is built on **kube-prometheus-stack** (Prometheus, Grafana, Alertmanager) with **Loki** for log aggregation and **Fluent Bit** for log shipping. Flux CD resource status is exposed as Prometheus metrics via kube-state-metrics custom resource state.

## Architecture

```
Flux Controllers (flux-system)
  └─ gotk_reconcile_duration_seconds    ← scraped via PodMonitor

Flux CRDs (all namespaces)
  └─ gotk_resource_info                 ← read by kube-state-metrics
       └─ customResourceState config    ← exposed as Prometheus metrics

Prometheus ──────────────────────────── scrapes both
  └─ Grafana                            ← dashboards (Flux, cluster, logs)
       └─ Loki datasource              ← log queries via Fluent Bit
```

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Prometheus + Alertmanager | `monitoring` | Metrics storage and alerting |
| Grafana | `monitoring` | Dashboards — exposed at `grafana.kschamer.info` |
| kube-state-metrics | `monitoring` | Exposes Flux CRD status as `gotk_resource_info` metrics |
| Loki | `monitoring` | Log aggregation |
| Fluent Bit | DaemonSet, `monitoring` | Ships pod logs to Loki |

## Flux Metrics

Flux CD metrics come from two sources:

### 1. Controller metrics (PodMonitor)

The Flux controllers expose runtime metrics on port `http-prom` (8080). These are scraped by the PodMonitor in [flux/monitoring/config/podmonitors.yaml](../flux/monitoring/config/podmonitors.yaml), which targets all six controllers in the `flux-system` namespace:

- `gotk_reconcile_duration_seconds` — reconciliation latency histogram per resource kind/name
- `gotk_token_cache_evictions_total`, `gotk_token_cached_items` — internal token cache counters

### 2. Resource status metrics (kube-state-metrics)

`gotk_resource_info` is **not** emitted by the Flux controllers themselves in recent versions. Instead, kube-state-metrics is configured with a custom resource state mapping that reads Flux CRD objects from the Kubernetes API and exposes their status as gauge metrics.

This is configured in [flux/monitoring/kube-state-metrics-config.yaml](../flux/monitoring/kube-state-metrics-config.yaml) and loaded into the kube-prometheus-stack HelmRelease via `valuesFrom`. The config covers all Flux resource types:

| CRD | Key labels on `gotk_resource_info` |
|-----|------------------------------------|
| `Kustomization` | `ready`, `suspended`, `revision`, `source_name` |
| `HelmRelease` | `ready`, `suspended`, `revision`, `chart_name`, `chart_app_version` |
| `GitRepository` | `ready`, `suspended`, `revision`, `url` |
| `HelmRepository` | `ready`, `suspended`, `revision`, `url` |
| `HelmChart` | `ready`, `suspended`, `revision`, `chart_name`, `chart_version` |
| `OCIRepository` | `ready`, `suspended`, `revision`, `url` |
| `Alert` / `Provider` | `suspended` |
| `Receiver` | `ready`, `suspended`, `webhook_path` |
| `ImageRepository` / `ImagePolicy` / `ImageUpdateAutomation` | `ready`, `suspended` |

kube-state-metrics runs with `--custom-resource-state-only=true` and `collectors: []` so it only emits the Flux custom metrics — standard Kubernetes metrics are already covered by the kube-prometheus-stack default scrape jobs.

### Why kube-state-metrics instead of controller metrics

`gotk_resource_info` was removed from the Flux controller metric endpoints in Flux v2.x. The controllers now only expose operational metrics (reconcile duration, cache stats). Resource status (Ready condition, suspended flag, current revision) must be obtained by reading the CRD objects directly — which is what kube-state-metrics custom resource state does.

## Manifests

```
flux/monitoring/
├── kustomization.yaml                  # Kustomize entry point + configMapGenerator
├── kustomizeconfig.yaml                # nameReference so ConfigMap hash is resolved in valuesFrom
├── kube-state-metrics-config.yaml      # Helm values fragment: Flux CRD → gotk_resource_info mapping
├── prometheus-release.yaml             # kube-prometheus-stack HelmRelease (references ConfigMap via valuesFrom)
├── loki-release.yaml                   # Loki HelmRelease
├── fluent-bit-release.yaml             # Fluent Bit HelmRelease
├── ingress.yaml                        # Traefik IngressRoute for Grafana
├── network-policies.yaml               # Cilium policies (Traefik → Grafana ingress, Grafana → Prometheus/Loki egress)
├── namespace.yaml
├── repositories.yaml
├── admin-secret.yaml                   # SealedSecret for Grafana admin credentials
└── config/
    ├── kustomization.yaml
    ├── flux-kustomization.yaml
    └── podmonitors.yaml                # PodMonitor targeting flux-system controllers
```

### How valuesFrom works

The `kube-state-metrics-config.yaml` file contains plain Helm values YAML. Kustomize's `configMapGenerator` wraps it into a ConfigMap (`flux-kube-state-metrics-config`) with a content-hash suffix. The `kustomizeconfig.yaml` `nameReference` transformer rewrites the hash-suffixed name into `spec.valuesFrom[].name` on the HelmRelease, so Helm Operator picks it up correctly.

## Useful Commands

### Check Flux resource status via metrics

```bash
# Verify gotk_resource_info is being emitted
kubectl port-forward -n monitoring svc/prometheus-release-kube-state-metrics 8080:8080
curl -s http://localhost:8080/metrics | grep gotk_resource_info

# Query in Prometheus: all non-ready Flux resources
# gotk_resource_info{ready!="True"}
```

### Check controller metrics directly

```bash
kubectl port-forward -n flux-system deploy/kustomize-controller 8080:8080
curl -s http://localhost:8080/metrics | grep gotk_
```

### Check Prometheus targets

```bash
kubectl port-forward -n monitoring svc/prometheus-release-prometheus 9090:9090
# Open http://localhost:9090/targets — look for flux-system and kube-state-metrics
```

### Grafana dashboards

Grafana is accessible at `https://grafana.kschamer.info` (Authentik SSO). Import dashboards from the [flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example/tree/main/monitoring/configs/dashboards) repository — they use `gotk_resource_info` and `gotk_reconcile_duration_seconds`.

### Log queries in Grafana (Loki)

```logql
# All logs from flux-system
{namespace="flux-system"}

# Reconciliation errors
{namespace="flux-system"} |= "error"

# Specific controller
{namespace="flux-system", app="kustomize-controller"}
```
