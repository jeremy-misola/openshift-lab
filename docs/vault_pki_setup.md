# Homelab Documentation: Vault PKI & HTTPS Setup

## 1. Objective
To establish a private **Root Certificate Authority (CA)** using HashiCorp Vault to secure the `jeremymr.dev` domain. This is required because the `.dev` TLD is part of the HSTS Preload list, meaning browsers (Chrome/Firefox) refuse to connect to it over plain HTTP.

## 2. Architecture Context
*   **Hypervisor:** Proxmox VE
*   **DNS:** BIND9 (Running in LXC) mapping `vault.jeremymr.dev` to `192.168.0.201`.
*   **Vault:** Running in a Docker container on the same IP.
*   **PKI:** A 2-tier hierarchy (Root CA -> Intermediate CA -> Server Certificate).

---

## 3. Phase 1: Vault PKI Engine Setup
We initialized Vault and enabled the **Public Key Infrastructure (PKI)** secrets engine at two different paths to separate the Root from the daily signing operations.

### Enable Engines
```bash
# Enable the Root path
vault secrets enable -path=pki_root pki
vault secrets tune -max-lease-ttl=87600h pki_root

# Enable the Intermediate path
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int
```

### Generate the Root CA
```bash
vault write -field=certificate pki_root/root/generate/internal \
    common_name="Homelab Root CA" \
    ttl=87600h > homelab_root_ca.crt
```

### Generate the Intermediate CA
1.  **Generate CSR:** `vault write -format=json pki_int/intermediate/generate/internal common_name="Homelab Intermediate CA" | jq -r '.data.csr' > pki_intermediate.csr`
2.  **Sign CSR with Root:** `vault write -format=json pki_root/root/sign-intermediate csr=@pki_intermediate.csr format=pem_bundle ttl="43800h" | jq -r '.data.certificate' > intermediate.cert.pem`
3.  **Import back to Vault:** `vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem`

---

## 4. Phase 2: Issuing the Server Certificate
We created a **Role** in Vault to allow the issuance of certificates for the `jeremymr.dev` domain and then generated the ID for the Vault server itself.

### Create Role
```bash
vault write pki_int/roles/homelab-cert-role \
    allowed_domains="jeremymr.dev" \
    allow_subdomains=true \
    allow_ip_sans=true \
    max_ttl="8760h"
```

### Issue Certificate
```bash
vault write -format=json pki_int/issue/homelab-cert-role \
    common_name="vault.jeremymr.dev" \
    ip_sans="192.168.0.201" \
    ttl="8760h" > vault_cert.json
```

---

## 5. Phase 3: Bundling and Extraction
Browsers require the "Full Chain" to trust a certificate. We extracted the raw data from the JSON output and bundled the files.

### Extracting with `jq`
```bash
# Server Cert
jq -r '.data.certificate' vault_cert.json > vault.jeremymr.dev.crt

# Private Key
jq -r '.data.private_key' vault_cert.json > vault.jeremymr.dev.key

# The Chain (Intermediate + Root)
jq -r '.data.ca_chain[]' vault_cert.json > homelab-ca-chain.pem
```

### Creating the Full Chain
**Crucial Step:** We combined the server certificate with its parents so Vault can show the entire "Family Tree" to the browser.
```bash
cat vault.jeremymr.dev.crt homelab-ca-chain.pem > fullchain.pem
```

---

## 6. Phase 4: Vault Configuration
We updated the `vault.hcl` and `docker-compose.yml` to move from HTTP to HTTPS.

### `vault.hcl`
```hcl
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "false"
  tls_cert_file = "/vault/certs/fullchain.pem"
  tls_key_file  = "/vault/certs/vault.jeremymr.dev.key"
}
api_addr = "https://192.168.0.201:8200"
```

### `docker-compose.yml`
Mapped the host folder containing the certs to the container:
```yaml
volumes:
  - ./config/vault.hcl:/vault/config/vault.hcl
  - ./data:/vault/data
  - ./certs:/vault/certs
```

---

## 7. Phase 5: Establishing Client Trust
Finally, we told the browser to trust the "King" (Root CA).

1.  **Firefox Settings:** Imported `homelab_root_ca.crt` into **Authorities**.
2.  **Trust Bit:** Checked the box **"Trust this CA to identify websites."**
3.  **URL:** Accessed via `https://vault.jeremymr.dev:8200` (Port 8200 is mandatory).

---

## 8. Verification Commands
To troubleshoot future issues, use these commands:

### Check the Network Handshake
```bash
openssl s_client -connect vault.jeremymr.dev:8200 -showcerts
```
*Successful result shows a chain with 3 certificates (0, 1, and 2).*

### Verify Certificate SANs
```bash
openssl x509 -in fullchain.pem -text -noout | grep -A 1 "Subject Alternative Name"
```

### Check Vault Logs
```bash
docker logs vault
```
*Look for "TLS handshake error" to see if the browser or server is rejecting the connection.*