# Vault with Kubernetes

These are the artifacts for the [Vault Installation to Minikube via
Helm](https://learn.hashicorp.com/vault/kubernetes/minikube) tutorial. Visit the
learn site for detail.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
```

Run vault command line without exec into vault pods:

```bash
# On CentOS
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum -y install vault

export VAULT_ADDR='https://vault-address:port'
export VAULT_TOKEN='vault-token'

# Verify connection
vault status
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

https://www.vaultproject.io/docs/concepts/seal

https://learn.hashicorp.com/tutorials/vault/kubernetes-minikube?in=vault/kubernetes#initialize-and-unseal-vault

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

https://learn.hashicorp.com/tutorials/vault/kubernetes-minikube?in=vault/kubernetes#set-a-secret-in-vault

```bash
kubectl exec --stdin=true --tty=true vault-0 -- /bin/sh

vault secrets enable -path=secret kv-v2

vault kv put secret/webapp/config username="static-user" password="static-password"

vault kv get secret/webapp/config

exit
```

## 6. Enable the Kubernetes authentication method

https://learn.hashicorp.com/tutorials/vault/kubernetes-minikube?in=vault/kubernetes#configure-kubernetes-authentication

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
kubectl apply --filename example/01-kubernetes-auth/deployment-01-webapp.yml

kubectl port-forward \
    $(kubectl get pod -l app=webapp -o jsonpath="{.items[0].metadata.name}") \
    8080:8080

curl http://localhost:8080
```

## 7. Vault Injector service via annotations

https://learn.hashicorp.com/tutorials/vault/kubernetes-sidecar?in=vault/kubernetes

https://secrets-store-csi-driver.sigs.k8s.io/introduction.html

Edit helm-vault-values.yml, disable csi and enable injector:

```yaml
injector:
  enabled: true
csi:
  enabled: false
```

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
kubectl apply --filename example/02-vault-injector/deployment-orgchart.yaml

kubectl exec \
    $(kubectl get pod -l app=orgchart -o jsonpath="{.items[0].metadata.name}") \
    --container orgchart -- ls /vault/secrets
ls: /vault/secrets: No such file or directory
command terminated with exit code 1
```

patch-inject-secrets.yaml

```bash
kubectl patch deployment orgchart --patch "$(cat example/02-vault-injector/patch-inject-secrets.yaml)"
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
kubectl patch deployment orgchart --patch "$(cat example/02-vault-injector/patch-inject-secrets-as-template.yaml)"

kubectl exec \
    $(kubectl get pod -l app=orgchart -o jsonpath="{.items[0].metadata.name}") \
    -c orgchart -- cat /vault/secrets/database-config.txt
postgresql://db-readonly-user:db-secret-password@postgres:5432/wizard
```

## 8. Mount Vault Secrets through CSI volume

https://learn.hashicorp.com/tutorials/vault/kubernetes-secret-store-driver?in=vault/kubernetes

Delete old examples:

```bash
kubectl delete -f example/01-kubernetes-auth/deployment-01-webapp.yml

kubectl delete -f example/02-vault-injector/deployment-orgchart.yaml
```

Edit helm-vault-values.yml, enable csi and disable injector:

```yaml
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
helm upgrade csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set linux.kubeletRootDir=/var/snap/microk8s/common/var/lib/kubelet
```

### Define a SecretProviderClass resource

```bash
kubectl apply --filename example/03-vault-csi-mount/spc-vault-database.yaml
```

### Create a pod with secret mounted

```bash
kubectl create serviceaccount webapp-sa

kubectl apply --filename example/03-vault-csi-mount/webapp-pod.yaml
```

## 9. Vault Best Practice

https://learn.hashicorp.com/tutorials/vault/production-hardening

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

# Manage tokens for verification
path "auth/token/create" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
}

# Configure the database secrets engine and create roles
path "database/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}

# Manage the leases
path "sys/leases/+/database/creds/readonly/*" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
}

path "sys/leases/+/database/creds/readonly" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
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

### 9.2 Edit your password on first login

```bash
vault write auth/userpass/users/your-username password=your-new-password
```

## 10. Database Secrets Engine

https://learn.hashicorp.com/tutorials/vault/database-secrets

### 10.1. Install postgreSQL using Bitnami helm chart:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami

helm install postgresql bitnami/postgresql

# To get the password for "postgres" run:

export POSTGRES_PASSWORD=$(kubectl get secret --namespace default postgresql -o jsonpath="{.data.postgresql-password}" | base64 --decode)

# To connect to your database run the following command:

kubectl run postgresql-client --rm --tty -i --restart='Never' --namespace default --image docker.io/bitnami/postgresql:11.14.0-debian-10-r28 --env="PGPASSWORD=$POSTGRES_PASSWORD" --command -- psql --host postgresql -U postgres -d postgres -p 5432
```

After connecting to your database, run:

```sql
CREATE ROLE ro NOINHERIT;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ro;
```

### 10.2. The end-to-end scenario described in this tutorial involves two personas

- admin with privileged permissions to configure secrets engines
- apps read the secrets from Vault

Admin policy:

```bash
# Mount secrets engines
path "sys/mounts/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}

# Configure the database secrets engine and create roles
path "database/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}

# Manage the leases
path "sys/leases/+/database/creds/readonly/*" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
}

path "sys/leases/+/database/creds/readonly" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
}

# Write ACL policies
path "sys/policies/acl/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}

# Manage tokens for verification
path "auth/token/create" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
}
```

Apps policy:

```bash
# Get credentials from the database secrets engine 'readonly' role.
path "database/creds/readonly" {
  capabilities = [ "read" ]
}
```

```bash
vault secrets enable database

vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgresql:5432/postgres?sslmode=disable" \
  allowed_roles=readonly \
  username="postgres" \
  password=$POSTGRES_PASSWORD
```

In the above step, you configured the PostgreSQL secrets engine with the allowed role named "readonly". A role is a logical name within Vault that maps to database credentials. These credentials are expressed as SQL statements and assigned to the Vault role.

Define the SQL used to create credentials:

```bash
cat example/04-database-secret-engine/readonly.sql
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT ro TO "{{name}}";

cd example/04-database-secret-engine && \
vault write database/roles/readonly \
    db_name=postgresql \
    creation_statements=@readonly.sql \
    default_ttl=1h \
    max_ttl=24h && \
cd -
```

Request PostgreSQL credentials:

```bash
vault read database/creds/readonly

Key                Value
---                -----
lease_id           database/creds/readonly/nzfqnlKwah0JSD9ashda0
lease_duration     1h
lease_renewable    true
password           abcDEFGhiKML@!ABC
username           v-root-readonly-ABCXYZ-123456789
```

Connect to the Postgres database and list all database users:

```bash
kubectl run postgresql-client --rm --tty -i --restart='Never' --namespace default --image docker.io/bitnami/postgresql:11.14.0-debian-10-r28 --env="PGPASSWORD=$POSTGRES_PASSWORD" --command -- psql --host postgresql -U postgres -d postgres -p 5432

postgres=# SELECT usename, valuntil FROM pg_user;
                     usename                     |        valuntil
-------------------------------------------------+------------------------
 postgres                                        |
 v-root-readonly-ABCXYZ-123456789                | 2022-01-23 14:57:50+00
(2 rows)
```

### 10.3. Manage leases

The credentials are managed by the lease ID and remain valid for the lease duration (TTL) or until revoked. Once revoked the credentials are no longer valid.

```bash
vault list sys/leases/lookup/database/creds/readonly

LEASE_ID=$(vault list -format=json sys/leases/lookup/database/creds/readonly | jq -r ".[0]")
```

Renew the lease for the database credential by passing its lease ID.

```bash
vault lease renew database/creds/readonly/$LEASE_ID
```

Revoke the lease without waiting for its expiration.

```bash
vault lease revoke database/creds/readonly/$LEASE_ID

vault list sys/leases/lookup/database/creds/readonly
No value found at sys/leases/lookup/database/creds/readonly/
```

Read new credentials from the readonly database role.

```bash
vault read database/creds/readonly
```

Revoke all the leases with the prefix database/creds/readonly.

```bash
vault lease revoke -prefix database/creds/readonly

vault list sys/leases/lookup/database/creds/readonly
No value found at sys/leases/lookup/database/creds/readonly/
```

### 10.4. Define a password policy

The passwords you want to generate adhere to these requirements.

- length of 20 characters

- at least 1 uppercase character

- at least 1 lowercase character

- at least 1 number

- at least 1 symbol

```bash
cat example/04-database-secret-engine/password_policy.hcl
length=20

rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}

rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 1
}

rule "charset" {
  charset = "0123456789"
  min-chars = 1
}

rule "charset" {
  charset = "!@#$%^&*"
  min-chars = 1
}

# Create a Vault password policy named example
cd example/04-database-secret-engine && \
vault write sys/policies/password/example policy=@password_policy.hcl && \
cd -

vault read sys/policies/password/example/generate

# Apply the password policy
vault write database/config/postgresql \
  password_policy="example"

# Read credentials from the readonly database role.
vault read database/creds/readonly
```

### 10.5. Define a username template

```bash
vault write database/config/postgresql \
  username_template="thongdepzai-{{.RoleName}}-{{unix_time}}-{{random 8}}"

vault read database/creds/readonly
```

## 11. Database Secrets Engine (Continue) - Database Static Roles and Credential Rotation

https://learn.hashicorp.com/tutorials/vault/database-creds-rotation?in=vault/db-credentials

Database secrets engine enables organizations to automatically rotate the password for existing database users. This makes it easy to integrate the existing applications with Vault and leverage the database secrets engine for better secret management.

Connect to your database and run:

```sql
CREATE ROLE "vault-edu" WITH LOGIN PASSWORD 'mypassword';
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "vault-edu";

# Confirm role attributes.
\du
```

First, create a file named, "rotation.sql" with following SQL statements.

```sql
ALTER USER "{{name}}" WITH PASSWORD '{{password}}';
```

Execute the following command to create a static role, education.

```bash
vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgresql:5432/postgres?sslmode=disable" \
  allowed_roles="*" \
  username="postgres" \
  password=$POSTGRES_PASSWORD

cd example/04-database-secret-engine && \
vault write database/static-roles/education \
  db_name=postgresql \
  rotation_statements=@rotation.sql \
  username="vault-edu" \
  rotation_period=86400 && \
cd -

vault read database/static-roles/education
```

Validation:

```bash
vault read database/static-creds/education

# Re-run the command and verify that returned password is the same with updated TTL.
vault read database/static-creds/education
```

Verify that you can connect to the psql with username "vault-edu".

```bash
POSTGRES_PASSWORD="7TaVjS0O&0xQcR3uZQ%Z"

kubectl run postgresql-client --rm --tty -i --restart='Never' --namespace default --image docker.io/bitnami/postgresql:11.14.0-debian-10-r28 --env="PGPASSWORD=$POSTGRES_PASSWORD" --command -- psql --host postgresql -U vault-edu -d postgres -p 5432
```

Manually rotate the password

```bash
vault write -f database/rotate-role/education

vault read database/static-creds/education
```

Dynamic Database Credentials with Vault and Kubernetes

```bash
kubectl exec vault-0 -- vault status

vault write auth/kubernetes/config \
    issuer="https://kubernetes.default.svc.cluster.local" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault policy write internal-app - <<EOF
path "secret/data/db-pass" {
  capabilities = ["read"]
}
path "database/static-creds/education" {
  capabilities = [ "read" ]
}
EOF

vault write auth/kubernetes/role/education \
  bound_service_account_names=webapp-sa \
  bound_service_account_namespaces=default \
  policies=internal-app \
  ttl=24h

exit
```

Enable sync secret on csi-secrets-store driver

```bash
helm upgrade csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
--set enableSecretRotation=true \
--set rotationPollInterval=1m \
--set syncSecret.enabled=true \
--set linux.kubeletRootDir=/var/snap/microk8s/common/var/lib/kubelet # Set this value only if you are running on microk8s cluster
```

(Optional) Install "Reloader": A Kubernetes controller to watch changes in ConfigMap and Secrets and do rolling upgrades on Pods with their associated Deployment, StatefulSet, DaemonSet and DeploymentConfig.

It will watch for changes in our database creds secret.

```bash
helm repo add stakater https://stakater.github.io/stakater-charts

helm install reloader stakater/reloader \
--set reloader.watchGlobally=false \
--namespace default
```

```bash
kubectl create sa webapp-sa

kubectl apply -f example/04-database-secret-engine/spc-vault-database.yaml

kubectl apply -f example/04-database-secret-engine/webapp-deployment.yaml
```

## Documentations

https://www.vaultproject.io/docs/configuration/storage

https://www.vaultproject.io/api/auth/userpass
