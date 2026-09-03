# Helm workflow

Notes for working on the charts in `apps/`. `apps/resume` is the reference
chart — every file in it is commented as an explanation of the Helm feature it
uses, so it doubles as the tutorial.

## The local loop

You do not need a cluster to iterate on a chart. `helm template` renders
locally and is the fastest feedback you can get:

```sh
helm lint apps/resume                  # schema + chart structure
helm template resume apps/resume       # render with default values
helm template resume apps/resume --debug   # render, and show WHY on failure
```

The single most useful habit: diff the render against a baseline to see what a
values change actually does.

```sh
diff <(helm template resume apps/resume) \
     <(helm template resume apps/resume --set replicaCount=3)
```

Exercise the optional paths, since defaults leave most of them off:

```sh
helm template resume apps/resume \
  --set ingress.enabled=true \
  --set autoscaling.enabled=true \
  --set nginx.extraServerConfig='add_header X-Test "1";'
```

Render just one file while working on it:

```sh
helm template resume apps/resume -s templates/ingress.yaml --set ingress.enabled=true
```

## Verifying the render is real YAML

Templating produces text, and text can be *plausible* but invalid — especially
indentation. Parse it to be sure:

```sh
helm template resume apps/resume | ruby -ryaml -e \
  'YAML.load_stream($stdin.read).compact.each { |d| puts "#{d["kind"]}/#{d["metadata"]["name"]}" }'
```

Against a live cluster, validate against the real API schemas:

```sh
helm template resume apps/resume | microk8s kubectl apply --dry-run=server -f -
```

## Concept map

Where each Helm idea lives in `apps/resume`, roughly in order of difficulty:

| Concept | File |
| --- | --- |
| chart vs app version | `Chart.yaml` |
| values as public API | `values.yaml` |
| `include` + `nindent` | `templates/service.yaml` |
| named templates (`define`) | `templates/_helpers.tpl` |
| selector vs full labels, and why | `templates/_helpers.tpl` |
| `default`, `required`, `trunc` | `templates/_helpers.tpl` |
| helpers taking arguments (`dict`) | `templates/_helpers.tpl` |
| whole-file `if` | `templates/serviceaccount.yaml` |
| `with` for optional blocks | `templates/deployment.yaml` |
| `toYaml`, `omit` | `templates/deployment.yaml` |
| `checksum/config` restart trick | `templates/deployment.yaml` |
| `$` root context inside loops | `templates/deployment.yaml` |
| prefix-form comparisons (`gt`, `and`) | `templates/deployment.yaml` |
| templating a config file | `templates/configmap.yaml` |
| `range` over a map | `templates/configmap.yaml` |
| multiple docs in one file | `templates/configmap.yaml` |
| nested `range`, capturing variables | `templates/ingress.yaml` |
| `.Capabilities` and its GitOps caveat | `templates/hpa.yaml` |
| schema validation | `values.schema.json` |
| hooks and tests | `templates/tests/test-connection.yaml` |
| post-install output | `templates/NOTES.txt` |

## Gotchas that cost the most time

- **Whitespace.** `{{-` trims before, `-}}` trims after. `nindent N` emits a
  newline then indents; `indent N` does not emit the newline, so it welds onto
  the previous line. Nearly every mangled render is one of these.
- **Context inside `range`/`with`.** `.` is rebound to the loop item. Capture
  what you need into a variable first, or reach the root through `$`.
- **Comment syntax matters.** `{{/* ... */}}` disappears at render time; a `#`
  comment is output. Inside a templated config file, a `#` comment ships to the
  container.
- **Missing values render as empty**, silently. That is what
  `values.schema.json` is for.
- **Deployment selectors are immutable.** Never put a version label in one.

## Helm vs ArgoCD

ArgoCD does not run `helm install`. It runs `helm template` and applies the
output, tracking the resources itself. So in this repo:

- `helm list` shows nothing — there is no release secret in the cluster.
- `NOTES.txt` and `helm test` never run in-cluster; they are for your local loop.
- `helm.sh/hook` annotations are ignored — ArgoCD has its own hook annotations.
- Rollback is `argocd app rollback` or a git revert, never `helm rollback`.

This is worth internalising early, because most Helm documentation assumes the
release-based model that ArgoCD deliberately bypasses.
