# Resume site

Static `index.html` + `styles.css` (design tokens). No build step, no framework.

This directory is the **image source**. How it gets deployed lives elsewhere:

| What | Where |
| --- | --- |
| Container image build | `Dockerfile` here, built by `.github/workflows/build-site.yml` |
| Deployment / Service / Ingress | `apps/resume` (Helm chart) |
| nginx config actually used in-cluster | `apps/resume/templates/configmap.yaml` |
| Prometheus | pre-existing `monitoring` namespace (not managed by this repo) |

`k8s.yaml` here is superseded and applies to nothing — see the header in it.

## Run locally

```sh
python3 -m http.server 8080     # panels show cached values; no proxy
```

Closer to production, with the real nginx and security context:

```sh
docker build -t resume-web:test .
docker run --rm -p 8080:8080 --user 101:101 --read-only \
  --tmpfs /tmp --tmpfs /var/cache/nginx resume-web:test
```

`/api/v1/query` returns 502 without a Prometheus to reach, and the page falls
back to its cached values — that's the intended degradation, not a failure.

## Live panel data

The page polls Prometheus through a **same-origin proxy** at `/api/v1/query`,
so there's no CORS and Prometheus needs no Ingress of its own.

**The in-cluster proxy config is `apps/resume/templates/configmap.yaml`, not
`nginx.conf` here.** The chart mounts a ConfigMap over `/etc/nginx/conf.d`,
replacing the file baked into the image. `nginx.conf` here is the local-dev
copy; keep the two roughly in sync.

Change the upstream in `apps/resume/values.yaml`:

```yaml
prometheus:
  proxy:
    url: http://prometheus.monitoring.svc.cluster.local:9090
```

That is the cluster's pre-existing Prometheus, which this repo does not
manage. Confirm against the cluster with
`microk8s kubectl get svc -n monitoring`.

### Exact PromQL

All of it lives in the `QUERIES` object at the top of the `<script>` block, so
you can paste any of it straight into Prometheus's expression browser.

| Panel | Query |
| --- | --- |
| CPU per node | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)` |
| Memory per node | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |
| Pod count | `count(kube_pod_info)` |
| Node roles | `kube_node_role` |
| Deployment ready | `kube_deployment_status_replicas_ready` |
| Deployment desired | `kube_deployment_spec_replicas` |
| Restarts per deployment | `sum by (namespace, deployment) (label_replace(kube_pod_container_status_restarts_total * on (namespace, pod) group_left(owner_name) kube_pod_owner{owner_kind="ReplicaSet"}, "deployment", "$1", "owner_name", "(.+)-[^-]+"))` |

`node_*` needs **node-exporter**; `kube_*` needs **kube-state-metrics**.

⚠️ In this cluster node-exporter is running but **kube-state-metrics is not
deployed at all**, so every `kube_*` row above returns nothing today. The page
falls back to its hardcoded values for the pod count, deployments table and
node roles; the CPU and memory panels work.

To make them live, the existing (unmanaged) monitoring stack needs
kube-state-metrics deployed and a matching scrape job added to its
`prometheus-config` ConfigMap.

Two notes on the last two rows:

- The restarts query walks pod → owning ReplicaSet → Deployment, stripping the
  ReplicaSet's pod-template hash with `label_replace`. It is best-effort: pods
  not owned by a ReplicaSet aren't counted.
- Node names currently read as IPs (`192.168.0.42`), because the existing
  `node-exporter` scrape job does not relabel `instance` to the node name.
  The page splits `instance` on `:` so it degrades to an IP rather than
  breaking. Adding an `instance` relabeling to `prometheus-config` would show
  `master`/`worker1`/`worker2` instead.

### What's exposed

Worth being clear-eyed about: the proxy makes Prometheus's **instant-query API
reachable by anyone who can reach the site**. They can run arbitrary PromQL
and read every metric in the cluster. The config narrows the blast radius —

- `location = /api/v1/query` is an exact match, so `query_range`, `series`,
  `federate` and the admin endpoints are *not* proxied
- `limit_except GET` rejects writes
- `limit_req` rate-limits per client IP

— but it is not authentication. If this site is ever reachable from the
internet, put auth in front of the proxy or set
`prometheus.proxy.enabled: false` and let the page show cached values.

## Things to edit

- `CONFIG` at the top of the `<script>` — `promBase`, `refreshSeconds`,
  `maxDeployments`.
- `SKILLS` / `ROLES` — resume content.
- `nodes` / `deployments` arrays — the fallback shown before the first
  successful scrape, and whenever Prometheus is unreachable. Both are replaced
  wholesale once a scrape succeeds.
- Ingress hostname — `apps/resume/values.yaml`, not here. Currently
  `resume.lan`.

Theme choice persists in `localStorage` under `jgm-theme`.
