import runtime
import .mgmt

# ---- fixtures -----------------------------------------------------------------
# Helper names avoid render()'s parameter names (`oxr`, `ocds`): KCL normalizes
# the leading underscore, so `_oxr` would shadow it.
_fxSpec = {
    region = "me-west1"
    prefix = "demo"
    billingAccount = "000000-000000-000000"
    domain = "example.com"
    folders = {platform = "101", dev = "102", staging = "103", network = "104", prod = "105"}
    network = {
        hostProject = "demo-net-mgmt"
        network = "https://www.googleapis.com/compute/v1/projects/demo-net-mgmt/global/networks/mgmt"
        subnetwork = "https://www.googleapis.com/compute/v1/projects/demo-net-mgmt/regions/me-west1/subnetworks/mgmt-me-west1"
    }
    keys = {
        gkeSecrets = "projects/demo-security/locations/me-west1/keyRings/platform/cryptoKeys/gke-secrets"
        cloudsql = "projects/demo-security/locations/me-west1/keyRings/platform/cryptoKeys/cloudsql"
    }
}

_fxXr = lambda _fxOver: {str:} {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Mgmt", metadata.name = "mgmt", spec = {k: v for k, v in _fxSpec if k not in _fxOver} | _fxOver}
}

_fxObs = lambda _fxAt: {str:}, _fxReady: bool {
    {Resource.status = {atProvider = _fxAt, conditions = [{$type = "Ready", status = "True" if _fxReady else "False"}]}}
}

_fxClusterDeps = ["attachment", "subnet-network-user-gke-agent", "subnet-network-user-apis-agent", "host-service-agent-user", "host-firewall-admin", "gke-agent-uses-gke-secrets", "api-container-googleapis-com"]

# The project numbered and every prerequisite of the cluster Ready.
_fxNumbered = {"project" = _fxObs({number = "123456789"}, True)}
_fxDepsReady = _fxNumbered | {d: _fxObs({}, True) for d in _fxClusterDeps}
_fxUp = _fxDepsReady | {
    "gke" = _fxObs({controlPlaneEndpointsConfig.dnsEndpointConfig.endpoint = "gke-abc.me-west1.gke.goog"}, True)
    "node-pool-default" = _fxObs({}, True)
    "node-pool-ci" = _fxObs({}, True)
    "gateway-ip" = _fxObs({address = "34.1.2.3"}, True)
}

_fxRender = lambda _fxOver: {str:}, _fxCds: {str:} {
    mgmt.render(_fxXr(_fxOver), _fxCds)
}

_fxNames = lambda _fxItems {
    [i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for i in _fxItems]
}

_fxNamed = lambda _fxItems, _fxName: str {
    [i for i in _fxItems if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _fxName][0]
}

_fxErr = lambda _fxOver: {str:} {
    runtime.catch(lambda {
        _fxRender(_fxOver, {})
    })
}

# ---- first reconcile: nothing observed ----------------------------------------
test_first_render_holds_back_what_needs_the_project_number = lambda {
    items = _fxRender({}, {})
    names = _fxNames(items)
    p = _fxNamed(items, "project")
    assert p.kind == "Project" and p.metadata.annotations["crossplane.io/external-name"] == "demo-mgmt"
    assert p.spec.forProvider.folderId == "101" and p.spec.forProvider.autoCreateNetwork == False
    assert p.spec.forProvider.deletionPolicy == "PREVENT", "the stack's project deletion policy is the default"
    assert len([n for n in names if n.startswith("api-")]) == len(mgmt.apis)
    assert "attachment" in names and "sa-gke-nodes" in names
    # The agents' emails embed the number; the cluster needs their grants.
    assert all n in ["subnet-network-user-gke-agent", "host-firewall-admin", "gke-agent-uses-gke-secrets", "gke", "node-pool-default", "crossplane-workload-identity", "nx-cache-storage-objectviewer", "cert-manager-dns", "dns-wildcard"] {n not in names}
    s = mgmt.status(_fxXr({}), {}).status
    assert "gke" in s.pending and "subnet-network-user-gke-agent" in s.pending
    assert s.ready == False
}

test_service_agent_grants_use_the_observed_number = lambda {
    items = _fxRender({}, _fxNumbered)
    sub = _fxNamed(items, "subnet-network-user-gke-agent")
    assert sub.spec.forProvider.member == "serviceAccount:service-123456789@container-engine-robot.iam.gserviceaccount.com"
    assert sub.spec.forProvider.subnetwork == "mgmt-me-west1", "a self link is reduced to the subnetwork name"
    assert sub.spec.forProvider.project == "demo-net-mgmt" and sub.spec.forProvider.region == "me-west1"
    assert _fxNamed(items, "subnet-network-user-apis-agent").spec.forProvider.member == "serviceAccount:123456789@cloudservices.gserviceaccount.com"
    assert _fxNamed(items, "cloudsql-agent-uses-cloudsql").spec.forProvider.member == "serviceAccount:service-123456789@gcp-sa-cloud-sql.iam.gserviceaccount.com"
    assert "gke" not in _fxNames(items), "the grants exist but are not Ready yet"
}

# ---- the cluster ----------------------------------------------------------------
test_cluster_waits_for_every_prerequisite = lambda {
    assert all d in _fxClusterDeps {"gke" not in _fxNames(_fxRender({}, _fxDepsReady | {"${d}" = _fxObs({}, False)}))}
    assert "gke" in _fxNames(_fxRender({}, _fxDepsReady))
}

test_cluster_is_private_dns_only_and_encrypted = lambda {
    items = _fxRender({}, _fxDepsReady)
    c = _fxNamed(items, "gke")
    f = c.spec.forProvider
    assert c.metadata.annotations["crossplane.io/external-name"] == "mgmt"
    assert f.location == "me-west1-a", "zone defaults to <region>-a"
    assert f.privateClusterConfig.enablePrivateNodes == True
    assert f.controlPlaneEndpointsConfig.ipEndpointsConfig.enabled == False
    assert f.controlPlaneEndpointsConfig.dnsEndpointConfig.allowExternalTraffic == True
    assert f.databaseEncryption.state == "ENCRYPTED" and f.databaseEncryption.keyName == _fxSpec.keys.gkeSecrets
    assert f.workloadIdentityConfig.workloadPool == "demo-mgmt.svc.id.goog"
    assert f.ipAllocationPolicy.clusterSecondaryRangeName == "pods" and f.ipAllocationPolicy.servicesSecondaryRangeName == "services"
    assert f.binaryAuthorization.evaluationMode == "PROJECT_SINGLETON_POLICY_ENFORCE"
    assert f.deletionProtection == True
    assert c.spec.initProvider.nodeConfig.serviceAccount == "gke-nodes@demo-mgmt.iam.gserviceaccount.com", "the default pool's shape is creation-only"
    assert f?.nodeConfig == Undefined, "a reconciled nodeConfig would force a replacement on edit"
}

test_node_pools_follow_the_spec = lambda {
    items = _fxRender({cluster = {minNodesPerZone = 2, maxNodesPerZone = 6, ciMaxNodesPerZone = 3, ciMachineType = "e2-standard-8"}}, _fxDepsReady)
    d = _fxNamed(items, "node-pool-default").spec.forProvider
    ci = _fxNamed(items, "node-pool-ci").spec.forProvider
    assert d.autoscaling.minNodeCount == 2 and d.autoscaling.maxNodeCount == 6 and d.initialNodeCount == 2
    assert d.nodeConfig?.taint == Undefined and d.nodeConfig?.spot == Undefined, "system pods need an untainted on-demand pool"
    assert ci.autoscaling.minNodeCount == 0 and ci.autoscaling.maxNodeCount == 3
    assert ci.nodeConfig.machineType == "e2-standard-8" and ci.nodeConfig.spot == True
    assert len(ci.nodeConfig.taint) == 1
    assert ci.nodeConfig.taint[0].key == "cloud.google.com/gke-spot" and ci.nodeConfig.taint[0].value == "true" and ci.nodeConfig.taint[0].effect == "NO_SCHEDULE"
    assert ci.clusterSelector.matchControllerRef == True
}

test_min_above_max_is_rejected = lambda {
    assert "exceeds maxNodesPerZone" in _fxErr({cluster = {minNodesPerZone = 6, maxNodesPerZone = 5}})
}

# A composed resource is never dropped because a prerequisite flaps: dropping
# it from the desired state would delete it.
test_existing_cluster_stays_when_a_prerequisite_flaps = lambda {
    cds = _fxNumbered | {"gke" = _fxObs({}, True), "node-pool-default" = _fxObs({}, True)}
    names = _fxNames(_fxRender({}, cds))
    assert "gke" in names and "node-pool-default" in names
    assert "node-pool-ci" not in names, "a pool not composed yet still waits"
}

test_workload_identity_waits_for_the_cluster = lambda {
    assert "crossplane-workload-identity" not in _fxNames(_fxRender({}, _fxDepsReady))
    items = _fxRender({serviceAccounts = {crossplane = "xp"}}, _fxUp)
    wi = _fxNamed(items, "crossplane-workload-identity").spec.forProvider
    assert wi.member == "serviceAccount:demo-mgmt.svc.id.goog[crossplane-system/xp]"
    assert wi.serviceAccountId == "projects/demo-mgmt/serviceAccounts/crossplane@demo-mgmt.iam.gserviceaccount.com"
    nx = _fxNamed(items, "nx-cache-storage-objectcreator").spec.forProvider
    assert nx.member == "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/demo-mgmt.svc.id.goog/subject/ns/nx-cache/sa/butler-cache"
}

# ---- identities -------------------------------------------------------------------
test_folder_grants_only_for_given_folders = lambda {
    all_folders = [n for n in _fxNames(_fxRender({}, {})) if n.startswith("crossplane-dev-") or n.startswith("crossplane-staging-") or n.startswith("crossplane-network-") or n.startswith("crossplane-prod-")]
    # 24 environment roles (+ xpnAdmin on dev and staging), xpnAdmin on network.
    assert len([n for n in all_folders if n.startswith("crossplane-dev-")]) == 25
    assert len([n for n in all_folders if n.startswith("crossplane-network-")]) == 1
    only_platform = _fxRender({folders = {platform = "101"}}, {})
    assert [i for i in only_platform if i.kind == "FolderIAMMember"] == []
    prod = _fxNamed(_fxRender({}, {}), "crossplane-prod-container-admin").spec.forProvider
    assert prod.folder == "folders/105" and prod.member == "serviceAccount:crossplane-prod@demo-mgmt.iam.gserviceaccount.com"
}

test_dev_network_grant_is_optional = lambda {
    assert "crossplane-net-dev-network-user" not in _fxNames(_fxRender({}, {}))
    items = _fxRender({devNetwork = {hostProject = "demo-net-dev", subnetwork = "projects/demo-net-dev/regions/me-west1/subnetworks/dev-me-west1"}}, {})
    g = _fxNamed(items, "crossplane-net-dev-network-user").spec.forProvider
    assert g.project == "demo-net-dev" and g.subnetwork == "dev-me-west1" and g.member == "serviceAccount:crossplane@demo-mgmt.iam.gserviceaccount.com"
}

# ---- Cloud SQL ----------------------------------------------------------------------
test_postgres_off_by_default = lambda {
    assert [i for i in _fxRender({}, _fxUp) if i.apiVersion.startswith("sql.")] == []
}

test_postgres_needs_its_cmek_key = lambda {
    assert "needs spec.keys.cloudsql" in _fxErr({postgres.enabled = True, keys = {gkeSecrets = "k"}})
}

test_postgres_instance_waits_for_its_key_grant = lambda {
    pg = {postgres = {enabled = True, databases = [{name = "keycloak", passwordSecretRef.name = "kc"}, {name = "events"}]}}
    assert "cloud-sql" not in _fxNames(_fxRender(pg, _fxNumbered))
    items = _fxRender(pg, _fxNumbered | {"cloudsql-agent-uses-cloudsql" = _fxObs({}, True)})
    i = _fxNamed(items, "cloud-sql")
    assert i.metadata.annotations["crossplane.io/external-name"] == "mgmt-postgres"
    assert i.spec.forProvider.encryptionKeyName == _fxSpec.keys.cloudsql
    ip = i.spec.forProvider.settings.ipConfiguration
    assert ip.ipv4Enabled == False and ip.privateNetwork == _fxSpec.network.network and ip.sslMode == "ENCRYPTED_ONLY"
    assert "db-keycloak" not in _fxNames(items), "databases wait for the instance"
    up = _fxRender(pg, _fxNumbered | {"cloudsql-agent-uses-cloudsql" = _fxObs({}, True), "cloud-sql" = _fxObs({}, True)})
    names = _fxNames(up)
    assert "db-keycloak" in names and "db-events" in names
    assert "db-keycloak-user" in names and "db-events-user" not in names, "a user needs a password secret"
    ref = _fxNamed(up, "db-keycloak-user").spec.forProvider.passwordSecretRef
    assert ref.name == "kc" and ref.key == "password"
}

# ---- DNS ------------------------------------------------------------------------------
test_wildcard_points_at_the_gateway_once_it_has_an_address = lambda {
    assert "dns-wildcard" not in _fxNames(_fxRender({}, {}))
    w = _fxNamed(_fxRender({}, {"gateway-ip" = _fxObs({address = "34.1.2.3"}, True)}), "dns-wildcard").spec.forProvider
    assert w.name == "*.example.com." and w.rrdatas == ["34.1.2.3"] and w.managedZone == "example-com"
}

test_records_are_fully_qualified = lambda {
    items = _fxRender({dns.records = [{id = "www", name = "www.", type = "CNAME", rrdatas = ["example.com."]}, {id = "mx", type = "MX", rrdatas = ["1 smtp.google.com."]}]}, {})
    assert _fxNamed(items, "dns-www").spec.forProvider.name == "www.example.com."
    assert _fxNamed(items, "dns-mx").spec.forProvider.name == "example.com."
    assert _fxNamed(items, "dns-mx").spec.forProvider.ttl == 3600
}

test_dns_record_ids_are_checked = lambda {
    assert "reserved" in _fxErr({dns.records = [{id = "wildcard", type = "A", rrdatas = ["1.2.3.4"]}]})
    assert "repeats an id" in _fxErr({dns.records = [{id = "a", type = "A", rrdatas = ["1.2.3.4"]}, {id = "a", type = "A", rrdatas = ["1.2.3.5"]}]})
}

test_dns_can_be_turned_off = lambda {
    names = _fxNames(_fxRender({dns.enabled = False}, _fxUp))
    assert all n in ["dns-zone", "gateway-ip", "dns-wildcard", "cert-manager-dns"] {n not in names}
}

# ---- every item ---------------------------------------------------------------------------
test_orphan_and_provider_config_reach_every_resource = lambda {
    items = _fxRender({deletionPolicy = "Orphan", providerConfigName = "org-admin"}, _fxUp)
    assert all i in items {i.spec.managementPolicies == ["Observe", "Create", "Update", "LateInitialize"]}
    assert all i in items {i.spec.providerConfigRef.kind == "ProviderConfig" and i.spec.providerConfigRef.name == "org-admin"}
    plain = _fxRender({}, {})
    # ["*"] is the generated schemas' default: full management.
    assert all i in plain {i.spec.managementPolicies == ["*"] and i.spec?.providerConfigRef == Undefined}
}

test_resource_names_are_unique_with_everything_on = lambda {
    pg = {postgres = {enabled = True, databases = [{name = "keycloak", passwordSecretRef.name = "kc"}]}, devNetwork = {hostProject = "h", subnetwork = "s"}, keys = _fxSpec.keys | {openbaoUnseal = "projects/p/locations/l/keyRings/r/cryptoKeys/k"}}
    cds = _fxUp | {"cloudsql-agent-uses-cloudsql" = _fxObs({}, True), "cloud-sql" = _fxObs({}, True)}
    names = _fxNames(_fxRender(pg, cds))
    assert isunique(names), "two composed resources share a composition-resource-name"
    assert mgmt.status(_fxXr(pg), cds).status.pending == []
}

test_status_reports_the_stack_outputs = lambda {
    s = mgmt.status(_fxXr({}), _fxUp).status
    assert s.ready == True
    assert s.dnsEndpoint == "gke-abc.me-west1.gke.goog"
    assert s.projectNumber == "123456789"
    assert s.gatewayAddress == "34.1.2.3" and s.clusterIdentity.GATEWAY_IP == "34.1.2.3"
    assert s.clusterIdentity.DEV_FOLDER == "folders/102"
    assert s.clusterIdentity.CI_IMAGE_REGISTRY == "me-west1-docker.pkg.dev/demo-mgmt/ci"
    assert s.getCredentials == "gcloud container clusters get-credentials mgmt --location=me-west1-a --project=demo-mgmt --dns-endpoint"
    assert s.pending == []
}

test_invalid_project_id_is_rejected = lambda {
    assert "not a valid GCP project id" in _fxErr({projectId = "Bad_Project"})
}
