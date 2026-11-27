# deploy/edge: public gateway and TLS (M3)

The public entry point for the app (D-008, D-011, D-028):

```
client ──► pip-gyazo-dev (static, DNS label) ──► Azure LB ──► Envoy proxy pod ──► api Service (gyazo)
          gyazo-dev-px0x8.centralus.cloudapp.azure.com     (envoy-gateway-system)
```

- **Envoy Gateway v1.10.0** implements the Gateway API (the successor to Ingress). The AWS
  analogue is an ALB plus the AWS Load Balancer Controller, but here the proxy runs inside
  the cluster and Azure only provides a layer-4 load balancer in front of it.
- **cert-manager v1.21.3** gets a Let's Encrypt certificate through an HTTP-01 challenge
  served by the same Gateway (the analogue of ACM, except we run the issuer ourselves).
- At the gateway, `/upload` gets a request-body cap (10 MiB + 64 KiB, buffered) and a
  per-client-IP rate limit (10/minute). Every HTTP request is redirected to HTTPS (308).
- **Clients must use `https://`.** The redirect is for browsers. ShareX and any other API
  client must be configured with the https URL: a plain-http upload has already sent the
  `X-API-Key` header in cleartext by the time the 308 comes back.
- The AKS managed Gateway API add-on is deliberately **not** enabled: it would install its
  own copy of the Gateway API CRDs and fight the ones installed here (D-008).

| File | What it is |
|---|---|
| `namespaces.yaml` | `envoy-gateway-system` (PSA enforce baseline, warn/audit restricted), `cert-manager` and `edge` (enforce restricted). All enforce versions pinned to v1.36 |
| `gatewayclass.yaml` | EnvoyProxy `public-proxy` (1 replica, resources, LoadBalancer Service bound to `pip-gyazo-dev`, `externalTrafficPolicy: Local`) and GatewayClass `eg` |
| `gateway.yaml` | Gateway `edge/public` (listeners http:80 and https:443, TLS from Secret `gyazo-tls`), ClientTrafficPolicy (header size, timeouts), HTTP→HTTPS redirect route |
| `clusterissuers.yaml` | ClusterIssuers `letsencrypt-staging` and `letsencrypt-prod`, HTTP-01 via the Gateway's http listener |
| `routes.yaml` | HTTPRoutes `gyazo/api` (everything) and `gyazo/api-upload` (exact `/upload`) |
| `policies.yaml` | BackendTrafficPolicy on `api-upload`: body limit + per-IP rate limit |
| `values/envoy-gateway.yaml`, `values/cert-manager.yaml` | Helm values (not part of the kustomization) |
| `kustomization.yaml` | The manifests above, common labels |

The matching NetworkPolicy (only these proxy pods may reach the api) is in
`deploy/manifests/networkpolicy.yaml`.

## Pinned versions

| Component | Chart (OCI) | Version | Chart digest (from `helm pull`, 2026-11-27) |
|---|---|---|---|
| Gateway API + Envoy Gateway CRDs | `oci://docker.io/envoyproxy/gateway-crds-helm` | v1.10.0 (Gateway API v1.6.1, standard channel) | `sha256:475c39aad3a05e3974a29fb80cfefe882b743e45e2ec0f751790ff0cb83bfa5d` |
| Envoy Gateway | `oci://docker.io/envoyproxy/gateway-helm` | v1.10.0 | `sha256:dcb82a14c04b426615a71d97222c7edf9f5ff58b800d241e71ac5784ae6dc7b7` |
| cert-manager | `oci://quay.io/jetstack/charts/cert-manager` | v1.21.3 | `sha256:e482675aec32862d323a9218293ff7de81192337998615e4378c56498473f240` |

Bump the CRDs chart and the Envoy Gateway chart together, always to the same version.
`helm pull <chart> --version <v>` prints the digest; compare before an upgrade.

## Prerequisites
1. The cluster is running and your IP is in the API server's authorized ranges (D-021).
2. `deploy/manifests` is applied (namespace `gyazo`, api Service, network policy).
3. Terraform created `pip-gyazo-dev` in `rg-gyazo-dev`, with the DNS label, and gave the
   AKS control-plane identity Network Contributor on it (D-021).
4. **Owner approval**: steps 0-4 change the cluster and create an Azure load-balancer
   rule on the public IP (CLAUDE.md guardrails).
5. **Before step 4 (public exposure):** CI has built the api image from the current
   `app/api/Dockerfile` (with `--forwarded-allow-ips`), `deploy/manifests/kustomization.yaml`
   is repinned to that digest, and `kubectl apply -k deploy/manifests` has been run. Without
   it the api sees every request as coming from the proxy pod: wrong client IPs in logs and
   `http` instead of `https` as the request scheme.

## Install (in this order)
Run from the repo root. Each step is idempotent.

```sh
# 0. Namespaces first, so Pod Security Admission applies to the very first pods.
kubectl apply -f deploy/edge/namespaces.yaml

# 1. Gateway API (standard channel) + Envoy Gateway CRDs, server-side apply (the CRDs are
#    too large for client-side apply's last-applied annotation). Not owned by a Helm
#    release, so uninstalling Envoy Gateway can't delete every Gateway and route.
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version v1.10.0 \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

# 2. Envoy Gateway controller (its chart's own CRDs are disabled in the values file).
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 \
  -n envoy-gateway-system -f deploy/edge/values/envoy-gateway.yaml --wait

# 3. cert-manager (its CRDs come with the chart, kept on uninstall).
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.3 \
  -n cert-manager -f deploy/edge/values/cert-manager.yaml --wait

# 4. GatewayClass, Gateway, issuers, routes, policies. Only after prerequisite 5 (api image
#    with --forwarded-allow-ips deployed): this step makes the app public.
kubectl apply -k deploy/edge --dry-run=server
kubectl apply -k deploy/edge
```

Upgrades: `helm upgrade` with the same arguments; for the CRDs, rerun step 1 with the new
version **before** upgrading the controller.

## Verify
```sh
# Controllers
kubectl -n envoy-gateway-system get pods
kubectl -n cert-manager get pods

# GatewayClass Accepted, Gateway Programmed with the public IP as its address
kubectl get gatewayclass eg
kubectl -n edge get gateway public
az network public-ip show -g rg-gyazo-dev -n pip-gyazo-dev --query ipAddress -o tsv   # read-only; must match

# If the Gateway has no address: the LoadBalancer Service events show whether the cloud
# provider could use the PIP (the PIP-scoped Network Contributor grant, D-021)
kubectl -n envoy-gateway-system describe svc -l gateway.envoyproxy.io/owning-gateway-name=public

# Routes and policies attached
kubectl -n gyazo get httproute,backendtrafficpolicy
kubectl -n edge get httproute,clienttrafficpolicy
kubectl -n gyazo get httproute api-upload -o jsonpath='{.status.parents[*].conditions}'

# Proxy pod labels must match the api NetworkPolicy's podSelector
kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=public --show-labels

# Pod Security: would anything in envoy-gateway-system violate "restricted"? (no warnings = ready to tighten)
kubectl label --dry-run=server --overwrite ns envoy-gateway-system pod-security.kubernetes.io/enforce=restricted

# Certificate: watch the ACME order and challenge (staging first)
kubectl -n edge get certificate,certificaterequest,order,challenge
kubectl -n edge describe challenge        # while pending: self-check / reachability errors show here

H=gyazo-dev-px0x8.centralus.cloudapp.azure.com
curl -sI http://$H/i/x                      # 308, Location: https://$H/i/x
curl -svk https://$H/healthz 2>&1 | grep -E "issuer|HTTP/"   # staging issuer name contains "(STAGING)"

# Rate limit: no API key needed, the limit runs before the app (expect 10x 401, then 429)
for i in $(seq 1 12); do curl -sk -o /dev/null -w "%{http_code} " -X POST https://$H/upload; done; echo

# Body limit: chunked, no Content-Length, one byte over 10304Ki (expect 413 from Envoy)
head -c 10551297 /dev/zero | curl -sk -o /dev/null -w "%{http_code}\n" -X POST \
  -H "Transfer-Encoding: chunked" --data-binary @- https://$H/upload

# Client IP: the api access log should show your public IP, not a 10.244.x.x address.
# Depends on prerequisite 5: with an older api image (no --forwarded-allow-ips) this shows
# the proxy pod's 10.244.x.x address, and that is the image, not the gateway.
kubectl -n gyazo logs deploy/api --tail=5

# End to end once the production certificate is in place (smoke.py verifies TLS):
OWNER_API_KEY=<key> PUBLIC_BASE_URL=https://$H uv run python scripts/smoke.py https://$H
```

## Troubleshooting
- **Gateway has no address, Envoy Service stays `<pending>`:** run
  `kubectl -n envoy-gateway-system describe svc -l gateway.envoyproxy.io/owning-gateway-name=public`.
  If the events show `403 AuthorizationFailed` on reading or listing public IPs in
  `rg-gyazo-dev`, the PIP-scoped Network Contributor grant from D-021 is not enough for the
  cloud provider. Widening it is an **owner IAM decision** (a Terraform change in
  `modules/aks` + apply, reviewed against the D-021 review rule). Do not work around it
  (no manual role assignment, no switching to an auto-created IP, which would lose the DNS label).
- **Certificate stuck pending:** `kubectl -n edge describe challenge`. A failing self-check
  usually means the http listener or the solver route isn't reachable from the cluster.

## Public health endpoints
`/healthz` and `/readyz` are reachable through the Gateway (catch-all route). They return
only `{"status": "ok"}` and `{"status": "ready"}` or `{"status": "unavailable"}` with a 503.
The failure reason is logged (`log.exception`), never returned (`app/api/gyazo_api/main.py`).
They leak nothing but up/down. Each `/readyz` call does one storage ping, so an anonymous
caller can generate storage calls at the general request rate (not rate-limited; fine at
demo scale, revisit with the M4 threat review).

## Staging to production (once)
`*.cloudapp.azure.com` is not on the Public Suffix List, so Let's Encrypt counts our
certificate against `azure.com` as a whole: 50 new certificates per week, shared with every
Azure customer using such a name (D-011, D-028). Request production once, then keep the
Secret.

1. Confirm staging works end to end: `kubectl -n edge get certificate gyazo-tls` shows
   `READY=True`, and the redirect, rate limit and body limit checks above pass.
2. In `gateway.yaml`, change the annotation to `cert-manager.io/cluster-issuer: letsencrypt-prod`
   (PR, review), then `kubectl apply -k deploy/edge`.
3. cert-manager updates the Certificate's issuer and re-issues. Watch
   `kubectl -n edge get certificate,order,challenge -w`. If it hasn't re-issued after a few
   minutes, delete the staging Secret (`kubectl -n edge delete secret gyazo-tls`) to force it.
4. Check: `curl -sv https://$H/healthz 2>&1 | grep issuer` shows a Let's Encrypt
   production issuer (no "STAGING"), and no `-k` is needed.
5. From now on, don't delete namespace `edge` or Secret `gyazo-tls`: each new issuance
   counts against the shared limit. If production issuance fails with a rate-limit error,
   switch back to staging and use the D-011 fallback (own domain + Azure DNS zone).

## Rollback and uninstall
- **Take the app off the internet, keep everything else:** `kubectl -n gyazo delete httproute api api-upload`.
  The Gateway keeps its IP; requests get 404.
- **Remove the edge configuration:** delete the objects one by one rather than
  `kubectl delete -k deploy/edge`, which would also delete the three namespaces (and with
  `edge`, the TLS Secret):
  ```sh
  kubectl delete -f deploy/edge/routes.yaml -f deploy/edge/policies.yaml
  kubectl delete -f deploy/edge/gateway.yaml          # removes the LoadBalancer Service
  kubectl delete -f deploy/edge/gatewayclass.yaml -f deploy/edge/clusterissuers.yaml
  ```
  Deleting the Service releases the public IP from the load balancer but does not delete it
  (Terraform owns `pip-gyazo-dev`; the cloud provider only deletes IPs it created).
- **Uninstall the controllers:** `helm uninstall cert-manager -n cert-manager`, then
  `helm uninstall envoy-gateway -n envoy-gateway-system`. Both leave the CRDs.
- **Remove the CRDs** (deletes every Gateway API, Envoy Gateway or cert-manager object in the
  cluster): rerun the step 1 `helm template ... | kubectl delete -f -`, and
  `kubectl delete crd -l app.kubernetes.io/name=cert-manager` (check the list first with `get`).

## Operational notes
- **One proxy replica.** A proxy restart (node image upgrade, eviction) briefly takes the
  public endpoint down. Two replicas + a PodDisruptionBudget when the node pool has room.
- **Nightly stop (D-025).** cert-manager's webhooks only match cert-manager resources, and
  the Envoy Gateway topology-injector webhook is disabled, so neither should block
  `az aks stop`. Not yet observed across a real stop/start cycle.
- **No NetworkPolicy** in `envoy-gateway-system`, `cert-manager` or `edge` yet (known gap).
- **Client IP.** `externalTrafficPolicy: Local` keeps the client's source IP. Envoy uses it
  for the rate limit and appends it to `X-Forwarded-For`; the api trusts that header only
  from the pod CIDR (`--forwarded-allow-ips 10.244.0.0/16`).
