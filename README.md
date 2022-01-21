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

8dWtFhkJG2c9bTKe0R1oDSYW24oW1YH5FvqQu5U/A9p4
h3b+V+MdsZWEehFH6V/uezwV0b3y8VcxMbplDPRK6DJ+
KKqZGJ8I7bTVij/u0PCyZX4csIgKdg2LDse7tYXqmeoy
72aps31CzcCl3bi6ON2WhTnqU3rUzGBjZX2a0LrAsNOJ
GsPOuHm989uzaTWlKGcePcOkSy9822QtcaGOqcbXz5AL

KEY_1=8dWtFhkJG2c9bTKe0R1oDSYW24oW1YH5FvqQu5U/A9p4
KEY_2=h3b+V+MdsZWEehFH6V/uezwV0b3y8VcxMbplDPRK6DJ+
KEY_3=KKqZGJ8I7bTVij/u0PCyZX4csIgKdg2LDse7tYXqmeoy

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

ROOT_TOKEN=s.vgAgajvk4oDm27xJkz3J4bqj

kubectl exec --stdin=true --tty=true vault-0 -- /bin/sh

vault login

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

Edit helm-vault-values.yml

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
