# External setup: Cloudflare, Namecheap, 1Password

The manual, outside-git steps needed before the cluster side of public
exposure (`juangar.com`) and cert-manager DNS-01 can work. For what each
piece is and why it's needed, read
[`public-access-explained.md`](public-access-explained.md) first. Everything here
happens in someone else's dashboard — nothing in this repo can create it, and
nothing in this repo will detect it drifting.

Navigation paths were verified against each provider's docs at time of
writing. **Dashboard UIs get reorganised** (Cloudflare's tunnel pages moved
out of "Zero Trust → Networks" to plain **Networking** since this was first
drafted), so treat menu names as a strong hint, not gospel — the underlying
concepts are stable even when the labels move.

Order matters: 1 → 2 → 3 before anything else, because the tunnel and the
API token both need the zone to exist in Cloudflare first.

---

## 1. Add juangar.com to Cloudflare

1. Sign in at [dash.cloudflare.com](https://dash.cloudflare.com).
2. Go to **Domains** → **Onboard a domain**.
3. Enter the apex domain `juangar.com`, choose how to add DNS records, and
   select **Continue**.
4. Choose the **Free** plan.
5. Review the DNS records Cloudflare imported. Namecheap's records do **not**
   follow the nameserver change automatically — anything you rely on today
   (especially MX/email records) must exist here before you switch, or it
   breaks at cutover. Add anything missing, then **Continue**.
6. Cloudflare assigns **two nameservers**. Copy both — step 2 needs them.

Nothing about the resume site needs a public A record. The tunnel provides
reachability; DNS for `juangar.com` gets created by the tunnel route in
step 3.

## 2. Point Namecheap at Cloudflare's nameservers

Registration stays with Namecheap. Only DNS hosting moves, and it's free and
reversible.

1. Sign in at [namecheap.com](https://www.namecheap.com).
2. **Domain List** in the left sidebar → **Manage** next to `juangar.com`.
3. Find the **Nameservers** section and open its dropdown.
4. Select **Custom DNS**.
5. Enter both Cloudflare nameservers from step 1, in `ns1.example.tld` form
   (names, not IPs — Namecheap rejects IPs here).
6. Save with the green checkmark.

Propagation is usually quick but **can take up to 24 hours**. Cloudflare
emails you and flips the zone to **Active** when it sees the change; don't
start step 3 until then.

## 3. Create the tunnel and its public hostname

1. Cloudflare dashboard → **Networking** → **Tunnels** → **Create a tunnel**.
2. Choose the **Cloudflared** connector type and give it a name
   (e.g. `pi-cluster`).
3. Cloudflare shows an install command for various OSes. **Don't run it** —
   we deploy `cloudflared` as a Kubernetes Deployment instead. Copy only the
   **token** out of that command: the long string after `--token`, starting
   `eyJ...`.
4. Store that token in 1Password now (step 5) — it is shown once, and it is
   the credential that lets anything act as this tunnel.
5. Still in **Networking → Tunnels**, select the tunnel → **Routes** tab →
   **Add route** → **Published application**.
   - **Subdomain**: leave empty (we want the apex `juangar.com`)
   - **Domain**: `juangar.com`
   - **Service URL**:
     `http://envoy-envoy-gateway-system-eg-5391c79d.envoy-gateway-system.svc.cluster.local:80`
   - Under the additional application settings, set **HTTP Host Header** to
     `juangar.com`.
6. Save, then confirm the tunnel shows **Healthy** on the Tunnels page (it
   won't until the `cloudflared` pods are running).

### Two things worth knowing about that Service URL

**It's a generated name.** `envoy-envoy-gateway-system-eg-5391c79d` is
derived by Envoy Gateway from the Gateway's namespace, name and a hash. It is
correct as of writing (`kubectl get svc -n envoy-gateway-system`), but if the
Gateway is ever deleted and recreated under a different name, this value
changes and the public site breaks — with **no diff anywhere in this repo**
to explain why, because this field lives in Cloudflare's dashboard. If
`juangar.com` ever 502s for no apparent reason, check this first.

**Why the Host header is pinned.** Envoy Gateway routes by `Host`, and the
HTTPRoute matches `juangar.com`. Cloudflare's origin-parameters documentation
does not state what Host `cloudflared` sends when `httpHostHeader` is unset;
evidence from cloudflared's issue tracker
([#1036](https://github.com/cloudflare/cloudflared/issues/1036), closed)
indicates the original Host is forwarded, which would make this redundant.
It's pinned so routing doesn't depend on undocumented behaviour. If you ever
route a **second** hostname through this same tunnel, that one needs its own
route with its own Host header — do not reuse a hardcoded `juangar.com`.

## 4. Create a Cloudflare API token for cert-manager

Used only for DNS-01 challenges: cert-manager creates a `_acme-challenge` TXT
record to prove domain ownership. It never needs inbound access, which is why
LAN-only hostnames can still get real certificates.

1. [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
   (**My Profile** → **API Tokens**) → **Create Token**.
2. Use the **Edit zone DNS** template.
3. Permissions must include both:
   - `Zone` → `DNS` → **Edit**
   - `Zone` → `Zone` → **Read**
4. Under **Zone Resources**, scope it to **juangar.com specifically** — not
   "all zones".
5. Create it. **The token is displayed once.** Put it straight into 1Password
   (step 5).

## 5. Store both secrets in the `K8S` vault

External Secrets Operator pulls these into the cluster, so the item titles
and field names below must match exactly what the `ExternalSecret` manifests
reference. If you rename either, the manifests must change too.

| 1Password item title    | Field name  | Contents                       |
| ----------------------- | ----------- | ------------------------------ |
| `cloudflare-tunnel-token` | `token`     | tunnel token from step 3       |
| `cloudflare-api-token`    | `api-token` | API token from step 4          |

Both go in the **`K8S`** vault — the same vault the Connect server is granted
access to in step 6.

## 6. Create the 1Password Connect server

Connect is the self-hosted server ESO talks to. You need to be in a group with
permission to manage Secrets Automation.

**Via the web UI:**

1. Sign in at [start.1password.com](https://start.1password.com/signin).
2. Go to
   [start.1password.com/developer-tools/infrastructure-secrets/connect](https://start.1password.com/developer-tools/infrastructure-secrets/connect)
   (or **Developer** → **Directory** → **Other** under Infrastructure Secrets
   Management → **Create a Connect server**).
3. Grant the server access to the **`K8S`** vault.
4. Follow the wizard to create the environment and an access token.
5. It generates **`1password-credentials.json`** — download it and also save
   a copy in 1Password. It is not retrievable later.
6. Copy the **access token** it issues. Also shown once.

**Or via the 1Password CLI:**

```sh
op connect server create pi-cluster --vaults K8S
op connect token create eso --server pi-cluster --vault K8S
```

The first writes `1password-credentials.json` to the working directory; the
second prints the access token.

You now have two artefacts that **must never be committed**:
`1password-credentials.json` and the Connect access token.

## 7. Bootstrap the two Secrets by hand

These are the chicken-and-egg credentials: ESO can't fetch them from
1Password, because they're what lets ESO reach 1Password at all. They live
outside git permanently and must be recreated by hand on any cluster rebuild
— the same category as the items in the kubeadm guide's "before you wipe"
checklist.

Run these yourself (they contain secret material, so they don't belong in
this repo's automation):

```sh
# The Connect server's own credentials file
kubectl create namespace onepassword-connect
kubectl create secret generic op-credentials \
  --namespace onepassword-connect \
  --from-file=1password-credentials.json=./1password-credentials.json

# The access token ESO uses to authenticate to Connect
kubectl create namespace external-secrets
kubectl create secret generic onepassword-connect-token \
  --namespace external-secrets \
  --from-literal=token='<paste the access token>'
```

Names and keys are load-bearing: `op-credentials` and the
`1password-credentials.json` key are the Connect chart's defaults, and
`onepassword-connect-token`/`token` is what the `ClusterSecretStore`
references.

If you paste the token on a shell that records history, clear it afterwards.

## 8. Local DNS for the internal hostnames

`resume.home.juangar.com` and `grafana.home.juangar.com` get real Let's
Encrypt certificates but stay LAN-only — they are deliberately **not** given
public A records in Cloudflare. Map them locally instead:

```sh
sudo tee -a /etc/hosts <<'EOF'
192.168.0.210 resume.home.juangar.com
192.168.0.210 grafana.home.juangar.com
EOF
```

`192.168.0.210` is the Envoy Gateway LoadBalancer IP from MetalLB's pool. If
you run Pi-hole or another LAN resolver, put the records there instead so
every device on the network gets them rather than just this machine.

---

## What lives where, afterwards

| Thing | Lives in | Managed by |
| --- | --- | --- |
| `juangar.com` DNS | Cloudflare | dashboard (outside git) |
| Tunnel + its route/Host header | Cloudflare | dashboard (outside git) |
| Public TLS for `juangar.com` | Cloudflare edge | automatic, no cert-manager |
| Tunnel token, CF API token | 1Password `K8S` vault | pulled in by ESO |
| Connect credentials + access token | Kubernetes Secrets | **hand-created, never in git** |
| Certs for `*.home.juangar.com` | cluster | cert-manager via DNS-01 |
| Everything else | this repo | ArgoCD |
