# Set or rotate the owner API key

The key authorizes `POST /upload`. It's created by a human, never by Terraform: anything Terraform creates is stored in plain text in state.

**Why it's manual:** Owner/Contributor on the subscription has no Key Vault *data* permissions. ci-apply can't grant itself `Key Vault Secrets Officer` either, because that role isn't on its ABAC allowlist (by design).

```bash
KV=$(terraform -chdir=infra/terraform/envs/dev output -raw key_vault_name)
KV_ID=$(az keyvault show -n "$KV" --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

# 1. Temporarily grant yourself write access to secrets in this one vault (IAM change: owner only)
az role assignment create --assignee "$ME" --role "Key Vault Secrets Officer" --scope "$KV_ID"

# 2. Generate a random 32-byte key; the value never touches disk or shell history
az keyvault secret set --vault-name "$KV" --name owner-api-key \
  --value "$(python -c 'import secrets;print(secrets.token_urlsafe(32))')" -o none

# 3. Remove your write access again
az role assignment delete --assignee "$ME" --role "Key Vault Secrets Officer" --scope "$KV_ID"
```

To read it once for ShareX or the web UI:
```bash
az keyvault secret show --vault-name "$KV" -n owner-api-key --query value -o tsv
```
Reading it needs `Key Vault Secrets User`, so grant and remove that the same way. The API pod reads it through its own identity (Secrets User, set by Terraform).

To rotate, repeat step 2: the API picks up the new version on restart (M3: CSI driver rotation).
