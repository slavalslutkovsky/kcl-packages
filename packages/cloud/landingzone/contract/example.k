# Example specs, one per cloud: the address plan of shluviza/infra's network
# stack (hub 10.0/16, mgmt 10.10/16, dev 10.20/16, prod 10.30/16). main.k
# validates `azure` when no spec file is given; the tests and both
# Compositions' main.k start from these.
_common = {
  prefix = "shl"
  labels = {"managed-by" = "landing-zone"}
  addressSpace = "10.0.0.0/8"
  network = {
    hub = {topology = "isolated"}
    mgmt = {cidr = "10.10.0.0/16", nodes = "10.10.0.0/24", pods = "10.10.32.0/19", services = "10.10.16.0/22"}
  }
  environments = [
    {name = "dev", cidr = "10.20.0.0/16", nodes = "10.20.0.0/22", pods = "10.20.64.0/18", services = "10.20.16.0/20", cluster = {nodeSize = "medium", minNodes = 1, maxNodes = 3}}
    {name = "prod", cidr = "10.30.0.0/16", nodes = "10.30.0.0/22", pods = "10.30.64.0/18", services = "10.30.16.0/20"}
  ]
  keys = [
    {name = "cluster-secrets", purpose = "cluster-secrets"}
    {name = "audit", purpose = "audit", rotationDays = 365}
    {name = "openbao-unseal", purpose = "unseal"}
  ]
  registry = {name = "platform"}
  audit = {retentionDays = 400}
}

gcp = _common | {
  provider = "gcp"
  organization = {id = "231525148429", domain = "shluviza.com", billingAccount = "0127E8-28899E-CC1469"}
  region = "me-west1"
  backupRegion = "europe-west4"
  controlPlane = {
    admins = "gke-security-groups@shluviza.com"
    nodePools = [
      {name = "default", machineType = "e2-highmem-4", minNodes = 1, maxNodes = 3}
      {name = "ci", machineType = "e2-highmem-4", minNodes = 0, maxNodes = 2, spot = True, taints = ["workload=ci:NoSchedule"]}
    ]
  }
}

azure = _common | {
  provider = "azure"
  organization = {
    id = "11111111-2222-3333-4444-555555555555"
    domain = "shluviza.com"
    tenantId = "11111111-2222-3333-4444-555555555555"
    subscriptions = {platform = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
  }
  region = "israelcentral"
  backupRegion = "westeurope"
  network = _common.network | {
    hub = {cidr = "10.0.0.0/23", topology = "isolated"}
  }
  controlPlane = {
    admins = "99999999-8888-7777-6666-555555555555"
    nodePools = [
      {name = "system", machineType = "Standard_D4s_v5", minNodes = 1, maxNodes = 3}
      {name = "ci", machineType = "Standard_D4s_v5", minNodes = 0, maxNodes = 2, spot = True, taints = ["workload=ci:NoSchedule"]}
    ]
  }
}

# What Pulumi writes into spec.foundation once tier 0 exists.
foundation = {
  gcp = {
    scopes = {root = "folders/10", platform = "folders/1", dev = "folders/2", prod = "folders/3"}
    containers = {platform = "shl-lz-mgmt", network = "shl-lz-net", security = "shl-lz-security", workloads = "shl-lz-workloads", dev = "shl-lz-workloads", prod = "shl-lz-workloads"}
    network = {
      mgmt = {id = "projects/shl-lz-net/global/networks/mgmt", subnet = "projects/shl-lz-net/regions/me-west1/subnetworks/mgmt-me-west1", pods = "pods", services = "services"}
    }
    keys = {"cluster-secrets" = "projects/shl-lz-security/locations/me-west1/keyRings/platform/cryptoKeys/cluster-secrets"}
    controlPlane = {clusterName = "mgmt", oidcIssuer = "https://container.googleapis.com/v1/projects/shl-lz-mgmt/locations/me-west1/clusters/mgmt"}
  }
  azure = {
    scopes = {root = "/providers/Microsoft.Management/managementGroups/shl", platform = "/providers/Microsoft.Management/managementGroups/shl-platform", dev = "/providers/Microsoft.Management/managementGroups/shl-dev", prod = "/providers/Microsoft.Management/managementGroups/shl-prod"}
    containers = {platform = "shl-platform", network = "shl-network", security = "shl-security", dev = "shl-dev", prod = "shl-prod"}
    network = {
      mgmt = {id = "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/shl-network/providers/Microsoft.Network/virtualNetworks/shl-mgmt", subnet = "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/shl-network/providers/Microsoft.Network/virtualNetworks/shl-mgmt/subnets/nodes", pods = "10.10.32.0/19", services = "10.10.16.0/22"}
    }
    controlPlane = {clusterName = "mgmt", oidcIssuer = "https://israelcentral.oic.prod-aks.azure.com/11111111-2222-3333-4444-555555555555/00000000-0000-0000-0000-000000000000/"}
  }
}
