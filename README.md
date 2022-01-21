# Vault with Kubernetes

These are the artifacts for the [Vault Installation to Minikube via
Helm](https://learn.hashicorp.com/vault/kubernetes/minikube) tutorial. Visit the
learn site for detail.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
```

## 1. (Optional) Delete old installation

```bash
helm delete consul

helm delete vault
```

## 2. Install consul

```bash
helm install consul hashicorp/consul --values helm-consul-values.yml
```

## 3. Install vault

```bash
helm install vault hashicorp/vault --values helm-vault-values.yml
```

## 4. Unseal vault

```bash
kubectl exec vault-0 -- vault status

kubectl exec vault-0 -- vault operator init -format=json > cluster-keys.json

cat cluster-keys.json | jq -r ".unseal_keys_b64[]"

hHE9RtL+wB2Qf4LGVhKtcOZy0Jnu6FZZWET9e/7715pO
9CF7oB/dDRsF3o03f3IkfPHrfuciJeJWc6EZg7WmKf+q
p4ua8kFPkKh4djWgUqPYqnZo/+VQc124urIKtp4vQF1Y
ShRkX8ix/8ChwWvQsLYSDdqThOQidRhY13N/4jPl1duk
ahLCi8lYEvocHofOojFDoTGWcvwYcD6f7X1c8xqVBHF6

KEY_1=hHE9RtL+wB2Qf4LGVhKtcOZy0Jnu6FZZWET9e/7715pO
KEY_2=9CF7oB/dDRsF3o03f3IkfPHrfuciJeJWc6EZg7WmKf+q
KEY_3=ahLCi8lYEvocHofOojFDoTGWcvwYcD6f7X1c8xqVBHF6

kubectl exec vault-0 -- vault operator unseal $KEY_1
kubectl exec vault-0 -- vault operator unseal $KEY_2
kubectl exec vault-0 -- vault operator unseal $KEY_3

kubectl exec vault-1 -- vault operator unseal $KEY_1
kubectl exec vault-1 -- vault operator unseal $KEY_2
kubectl exec vault-1 -- vault operator unseal $KEY_3

kubectl exec vault-2 -- vault operator unseal $KEY_1
kubectl exec vault-2 -- vault operator unseal $KEY_2
kubectl exec vault-2 -- vault operator unseal $KEY_3
```

## 5. Vault login

```bash
cat cluster-keys.json | jq -r ".root_token"

ROOT_TOKEN=s.GxBQlvt99odueHlQmT6fTe36

kubectl exec --stdin=true --tty=true vault-0 -- /bin/sh

vault login $ROOT_TOKEN

exit
```

### Enable kv

```bash
kubectl exec --stdin=true --tty=true vault-0 -- /bin/sh

vault secrets enable -path=secret kv-v2

vault kv put secret/webapp/config username="static-user" password="static-password"

vault kv get secret/webapp/config

exit
```

## 6. Enable the Kubernetes authentication method

```bash
kubectl exec --stdin=true --tty=true vault-0 -- /bin/sh

vault auth enable kubernetes

vault write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    issuer="https://kubernetes.default.svc.cluster.local"

vault policy write webapp - <<EOF
path "secret/data/webapp/config" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/webapp \
    bound_service_account_names=vault \
    bound_service_account_namespaces=default \
    policies=webapp \
    ttl=24h

exit
```

```bash
kubectl apply --filename deployment-01-webapp.yml

kubectl port-forward \
    $(kubectl get pod -l app=webapp -o jsonpath="{.items[0].metadata.name}") \
    8080:8080

curl http://localhost:8080
```

## 7. Vault Injector service via annotations

```bash
kubectl exec -it vault-0 -- /bin/sh

vault secrets enable -path=internal kv-v2

vault kv put internal/database/config username="db-readonly-username" password="db-secret-password"

vault kv get internal/database/config

vault auth enable kubernetes

vault write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    issuer="https://kubernetes.default.svc.cluster.local"

vault policy write internal-app - <<EOF
path "internal/data/database/config" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/internal-app \
    bound_service_account_names=internal-app \
    bound_service_account_namespaces=default \
    policies=internal-app \
    ttl=24h

exit
```

Create service account 'internal-app'

```bash
kubectl create sa internal-app

kubectl get serviceaccounts
```

```bash
kubectl apply --filename deployment-orgchart.yaml

kubectl exec \
    $(kubectl get pod -l app=orgchart -o jsonpath="{.items[0].metadata.name}") \
    --container orgchart -- ls /vault/secrets
ls: /vault/secrets: No such file or directory
command terminated with exit code 1
```

patch-inject-secrets.yaml

```bash
kubectl patch deployment orgchart --patch "$(cat patch-inject-secrets.yaml)"
```

This new pod now launches two containers. The application container, named orgchart, and the Vault Agent container, named vault-agent.

Display the logs of the vault-agent.

```bash
kubectl logs \
    $(kubectl get pod -l app=orgchart -o jsonpath="{.items[0].metadata.name}") \
    --container vault-agent
```

Display the secret written to the orgchart container.

```bash
kubectl exec \
    $(kubectl get pod -l app=orgchart -o jsonpath="{.items[0].metadata.name}") \
    --container orgchart -- cat /vault/secrets/database-config.txt
```

### Apply a template to the injected secrets

patch-inject-secrets-as-template.yaml

```bash
kubectl patch deployment orgchart --patch "$(cat patch-inject-secrets-as-template.yaml)"

kubectl exec \
    $(kubectl get pod -l app=orgchart -o jsonpath="{.items[0].metadata.name}") \
    -c orgchart -- cat /vault/secrets/database-config.txt
postgresql://db-readonly-user:db-secret-password@postgres:5432/wizard
```

## 8. Mount Vault Secrets through CSI volume

Delete old examples:

```bash
kubectl delete -f deployment-01-webapp.yml
kubectl delete -f deployment-orgchart.yaml
```

Edit helm-vault-values.yml, enable csi and disable injector:

```yaml
server:
  affinity: ""
  ha:
    enabled: true
injector:
  enabled: false
csi:
  enabled: true
```

Run:

```bash
helm upgrade vault hashicorp/vault --values helm-vault-values.yml
```

```bash
kubectl exec -it vault-0 -- /bin/sh

vault kv put secret/db-pass password="db-secret-password"

vault auth enable kubernetes

vault write auth/kubernetes/config \
    issuer="https://kubernetes.default.svc.cluster.local" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault policy write internal-app - <<EOF
path "secret/data/db-pass" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/database \
    bound_service_account_names=webapp-sa \
    bound_service_account_namespaces=default \
    policies=internal-app \
    ttl=24h

exit
```

### Install the secrets store CSI driver

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver
```

Fix mount empty issue on microk8s:

```bash
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set linux.kubeletRootDir=/var/snap/microk8s/common/var/lib/kubelet
```

### Define a SecretProviderClass resource

```bash
kubectl apply --filename spc-vault-database.yaml
```

### Create a pod with secret mounted

```bash
kubectl create serviceaccount webapp-sa

kubectl apply --filename webapp-pod.yaml
```

## 9. Vault Best Practice

### 9.1. Restrict the use of root policy, and write fine-grained policies to practice least privileged

An admin user must be able to:

- Read system health check

- Create and manage ACL policies broadly across Vault

- Enable and manage authentication methods broadly across Vault

- Manage the Key-Value secrets engine enabled at secret/ path

```bash
kubectl exec -it vault-0 -- /bin/sh

tee /vault/admin-policy.hcl <<EOF
# Read system health check
path "sys/health"
{
  capabilities = ["read", "sudo"]
}

# Create and manage ACL policies broadly across Vault

# List existing policies
path "sys/policies/acl"
{
  capabilities = ["list"]
}

# Create and manage ACL policies
path "sys/policies/acl/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Enable and manage authentication methods broadly across Vault

# Manage auth methods broadly across Vault
path "auth/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Create, update, and delete auth methods
path "sys/auth/*"
{
  capabilities = ["create", "update", "delete", "sudo"]
}

# List auth methods
path "sys/auth"
{
  capabilities = ["read"]
}

# Enable and manage the key/value secrets engine at `secret/` path

# List, create, update, and delete key/value secrets
path "secret/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Manage secrets engines
path "sys/mounts/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# List existing secrets engines.
path "sys/mounts"
{
  capabilities = ["read"]
}
EOF

vault policy write admin admin-policy.hcl

# Check token capabilities
vault policy read admin

# Generate admin token
vault token create -format=json -policy="admin"
ADMIN_TOKEN=s.hFSdR7TSsXdZmeWsjuBL6gG2
vault login $ADMIN_TOKEN

# Revoke root token (Can be generate using unseal keys)
vault token revoke $ROOT_TOKEN
```
