storage "raft" {
  path    = "/vault/data"
  node_id = "node1"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true" # Enable TLS later once you've generated certs
}
ui = true