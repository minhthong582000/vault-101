#!/bin/bash

# Generate certificate
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname="vault,vault.default.svc.cluster.local,,vault.default.svc,localhost,127.0.0.1" \
  -profile=default \
  vault-csr.json | cfssljson -bare vault-example

# Get values to make a secret
cat vault-ca.pem | base64 | tr -d '\n'
cat vault.pem | base64 | tr -d '\n'
cat vault-key.pem | base64 | tr -d '\n'

# Linux - make the secret automatically
cat <<EOF > ./server-tls-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-tls-secret
type: Opaque
data:
  vault.pem: $(cat vault.pem | base64 | tr -d '\n')
  vault-key.pem: $(cat vault-key.pem | base64 | tr -d '\n') 
  vault-ca.pem: $(cat vault-ca.pem | base64 | tr -d '\n')
EOF