storage "raft" {
  path    = "/vault/data"
  node_id = "node1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
  # Use the container's internal IP or service name for cluster addr
  cluster_address = "0.0.0.0:8201"
}

api_addr     = "http://192.168.0.201:8200"
# The address other Vault nodes use to talk to this one
cluster_addr = "http://192.168.0.201:8201"

disable_mlock = true

ui = true