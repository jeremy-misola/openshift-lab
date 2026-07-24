# GitOps bootstrap

This repository intentionally contains no live credentials. Before applying it,
create a private override or edit the placeholder values locally; do not commit
the pull secret, SSH public key, BMC credentials, or Vault token.

## 1. Set repository and release values

Update the `repoURL` in these files with the Git remote that Argo CD can reach:

- `operators/values/hub.yaml`
- `operators/charts/acm-operator/values/mgmt.yaml`
- `operators/charts/hcp-bootstrap/values/mgmt.yaml`

Set the ACM channel to the channel compatible with the installed SNO release.
Set each `releaseImage` in `operators/charts/managed-cluster/values/` to the
same supported OpenShift payload family as the hub.

## 2. Configure and synchronize hub prerequisites

Before syncing the root Application, update the following GitOps values:

- `operators/charts/lvm-storage/values/mgmt.yaml`: set `lvmCluster.devicePath`
  to the stable `/dev/disk/by-id/...` path of the dedicated, empty SNO data disk.
- `operators/charts/nmstate/values/mgmt.yaml`: confirm the secondary SNO NIC
  connected to Proxmox `vmbr1` (the default is `ens19`).
- `operators/charts/metallb/values/mgmt.yaml`: reserve the configured VIP range
  outside DHCP before synchronization.

The root Application installs ACM (including its MCE dependency), LVMS,
OpenShift Virtualization, NMState, MetalLB, cert-manager, External Secrets,
and CloudNativePG. Hosted clusters are deliberately not enabled by the root
Application yet.

For hosted clusters later: RHACM 2.16 bundles MCE 2.11. It supports an OCP
4.22 hub, but not OCP 4.22 hosted-cluster payloads; use a supported 4.21
payload or wait for an ACM/MCE release whose support matrix includes MCE 2.17
before creating 4.22 hosted clusters.

Verify the prerequisite sync before progressing:

```sh
oc get csv -A
oc get lvmcluster -n openshift-lvm-storage
oc get hyperconverged -n openshift-cnv
oc get nodenetworkconfigurationpolicy tenant-bridge
oc get metallb,ipaddresspool,l2advertisement -n metallb-system
```

## 3. Create hosted-cluster input secrets

The `HostedCluster` manifests refer to secrets in the `clusters` namespace.
Create them on the hub before synchronizing the hosted-cluster Applications:

```sh
oc create namespace clusters
oc -n clusters create secret generic cluster-1-pull-secret --from-file=.dockerconfigjson=PATH_TO_PULL_SECRET --type=kubernetes.io/dockerconfigjson
oc -n clusters create secret generic cluster-1-ssh-key --from-file=id_rsa.pub=PATH_TO_SSH_PUBLIC_KEY
oc -n clusters create secret generic cluster-2-pull-secret --from-file=.dockerconfigjson=PATH_TO_PULL_SECRET --type=kubernetes.io/dockerconfigjson
oc -n clusters create secret generic cluster-2-ssh-key --from-file=id_rsa.pub=PATH_TO_SSH_PUBLIC_KEY
```

You can replace these manual secrets with ExternalSecrets after validating your
Vault authentication path. Keep the secret names stable because the charts use
them as contracts.

## 4. Install GitOps once, then bootstrap the root Application

Argo CD is required to create the root Application, so install the GitOps
Operator once through OLM first. The managed `gitops-operator` Application will
then continuously reconcile the same Subscription.

```sh
oc create namespace openshift-gitops-operator
oc -n openshift-gitops-operator apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Wait until the `openshift-gitops` namespace and the `argoproj.io` APIs exist.
Then bootstrap the root Application.

After OpenShift GitOps is installed, apply this from the repository root after
substituting the Git URL and revision:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hub-platform
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/REPLACE_ME/openshift-lab.git
    targetRevision: main
    path: operators
    helm:
      valueFiles:
        - values/hub.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

The root chart creates `homelab-platform` and its ApplicationSet. The
ApplicationSet creates the hub prerequisite Applications. The hosted-cluster
bootstrap chart remains intentionally excluded until the hub prerequisites are
healthy.

## 5. Enable Cluster 1 before Cluster 2

Synchronize Cluster 1 first. Confirm the KubeVirt storage class and
HyperShift/KubeVirt APIs are available, then set `nodePool.replicas` to `2`.

Do not synchronize Cluster 2 until one Proxmox target can be power-cycled and
booted from virtual media through its Redfish endpoint. HyperShift creates its
Agent control-plane namespace as `clusters-cluster-2`; create a `pull-secret`
in that namespace before its InfraEnv is applied:

```sh
oc create namespace clusters-cluster-2
oc -n clusters-cluster-2 create secret generic pull-secret --from-file=.dockerconfigjson=PATH_TO_PULL_SECRET --type=kubernetes.io/dockerconfigjson
```

Replace all `REPLACE_ME` values in its BMC configuration and its Agent SSH key
using a private Helm override.

## 6. Turn on ACM enforcement carefully

`acm-policies/values.yaml` starts in `inform` mode. Label imported managed
clusters with `homelab.openshift.io/managed=true`, inspect compliance, then
change `remediationAction` to `enforce` when the baseline is confirmed.
