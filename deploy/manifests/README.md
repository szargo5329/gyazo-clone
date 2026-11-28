# deploy/manifests: first M3 slice (raw Kubernetes)

API and worker on AKS with workload identity, the owner key from Key Vault, and
network policy. Applied with `kubectl apply -k deploy/manifests`. Helm replaces this in
M5, and ArgoCD applies it in M6.

| File | What it is |
|---|---|
| `namespace.yaml` | `gyazo` namespace, Pod Security Admission `restricted` (enforce pinned to v1.36, audit/warn `latest`) |
| `serviceaccounts.yaml` | `api` and `worker` service accounts with their identity client IDs (federated credentials in `infra/terraform/modules/identity`) |
| `secretproviderclass.yaml` | SecretProviderClass `owner-api-key` (names the secret, holds no value; allowlisted in the `block_secrets` hook). Key Vault `owner-api-key` mounted as a file through the Secrets Store CSI add-on, as the api identity. Never synced to a Kubernetes Secret |
| `api.yaml` | API Deployment (1 replica) + ClusterIP Service `api:80` → 8000 |
| `worker.yaml` | Worker Deployment (1 replica, no Service, no probes; see the header comment) |
| `networkpolicy.yaml` | Default deny in and out; API ingress only from the Envoy proxy pods of Gateway `edge/public` (namespace `envoy-gateway-system` + proxy pod labels, `deploy/edge`); egress DNS + TCP 443 |
| `kustomization.yaml` | File list, common labels, `images:` pinned by digest (hand-pinned now; CI later) |

## Prerequisites
1. Terraform applied (cluster, identities, federated credentials, role assignments).
2. **Owner** sets the Key Vault secret (at least 16 characters, or the API refuses to start):
   `az keyvault secret set --vault-name kv-gyazo-dev-px0x8 --name owner-api-key --value <key>`.
   Without it the api pod stays in `ContainerCreating` with a CSI mount error.
3. Images pushed to `acrgyazodevpx0x8.azurecr.io/gyazo-api` and `/gyazo-worker` and
   pinned by digest in `kustomization.yaml` (currently from build.yml run 46086388811,
   main commit 24db8af). To repin: `cd deploy/manifests && kustomize edit set image gyazo-api=acrgyazodevpx0x8.azurecr.io/gyazo-api@sha256:<digest>`
   (and the same for `gyazo-worker`).
4. Your IP is in the API server's authorized ranges (D-021).

## Apply
```sh
kubectl kustomize deploy/manifests            # render and review
kubectl apply -k deploy/manifests --dry-run=server
kubectl apply -k deploy/manifests
```
The order is handled by kubectl (Namespace and ServiceAccounts go first). The very first
server dry run fails for namespaced objects because `gyazo` doesn't exist yet. Apply the
namespace first if you need a full server dry run.

## Verify
```sh
kubectl -n gyazo get pods,svc,networkpolicy
kubectl -n gyazo get pod -l app.kubernetes.io/name=gyazo-api -o yaml | grep -A3 azure-identity-token   # webhook injected the token volume
kubectl -n gyazo logs deploy/api
kubectl -n gyazo logs deploy/worker
kubectl -n gyazo port-forward svc/api 8000:80
curl -s localhost:8000/healthz; curl -s localhost:8000/readyz   # readyz = storage reachable as the api identity
OWNER_API_KEY=<key> PUBLIC_BASE_URL=https://gyazo-dev-px0x8.centralus.cloudapp.azure.com uv run python scripts/smoke.py http://localhost:8000
```
Port-forward goes through the kubelet, so the network policy doesn't block it. Note
that `PUBLIC_BASE_URL` is the public hostname, so links in responses point there even
when you test through port-forward. Set `PUBLIC_BASE_URL` for the smoke test, or its link check fails.

## Not here yet
- Gateway (Envoy Gateway, HTTPRoute, rate limit) and TLS (cert-manager): see `deploy/edge`.
- Monitoring (ServiceMonitor, scrape network policy): M3 observability.
- Digest pinning in CI (`kustomize edit set image`) and image scanning.
- 2 API replicas + PodDisruptionBudget: when the node pool has room.
- KEDA scaling of the worker on queue length, and worker hang detection: M4.
- Owner key rotation: the CSI add-on refreshes the file, but the API reads it once at
  startup, so a new key needs `kubectl -n gyazo rollout restart deploy/api`.
