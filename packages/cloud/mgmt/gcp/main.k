import .mgmt

# function-kcl injects option("params"); fall back to an example for local runs.
# Placeholder organization: the example must not carry a real one's ids.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "Mgmt"
    metadata.name = "mgmt"
    spec = {
        region = "me-west1"
        zone = "me-west1-a"
        prefix = "demo"
        billingAccount = "000000-000000-000000"
        domain = "example.com"
        folders = {platform = "100000000001", dev = "100000000002", staging = "100000000003", network = "100000000004", prod = "100000000005"}
        network = {
            hostProject = "demo-net-mgmt"
            network = "https://www.googleapis.com/compute/v1/projects/demo-net-mgmt/global/networks/mgmt"
            subnetwork = "https://www.googleapis.com/compute/v1/projects/demo-net-mgmt/regions/me-west1/subnetworks/mgmt-me-west1"
        }
        devNetwork = {hostProject = "demo-net-dev", subnetwork = "https://www.googleapis.com/compute/v1/projects/demo-net-dev/regions/me-west1/subnetworks/dev-me-west1"}
        keys = {
            gkeSecrets = "projects/demo-security/locations/me-west1/keyRings/platform/cryptoKeys/gke-secrets"
            cloudsql = "projects/demo-security/locations/me-west1/keyRings/platform/cryptoKeys/cloudsql"
            openbaoUnseal = "projects/demo-security/locations/me-west1/keyRings/platform/cryptoKeys/openbao-unseal"
        }
        postgres = {enabled = True, databases = [{name = "keycloak", passwordSecretRef.name = "mgmt-postgres-keycloak"}, {name = "events"}]}
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = mgmt.render(_oxr, _ocds) + [mgmt.status(_oxr, _ocds)]
