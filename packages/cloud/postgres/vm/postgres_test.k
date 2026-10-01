import .postgres

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "PostgresInstance", metadata = {name = "demo", namespace = "team-a"}, spec = {region = "us-central1", passwordSecret.name = "demo-pg", vm.provider = "gcp"} | _spec}
}

# requiredResources carrying the fetched Secret; "cGFzcw==" is "pass".
_fetched = lambda _data {
    {
        requiredResources = {"password-secret" = [{
            Resource = {apiVersion = "v1", kind = "Secret", metadata.name = "demo-pg", data = _data}
        }]}
    }
}

# The single VirtualMachine child spec from a render().
_vs = lambda _spec {
    postgres.render(_build(_spec), "md5x")[0].spec
}

# ---- password round trip ----------------------------------------------------

# The request names the Secret in the XR's own namespace: a Secret is
# namespaced, and the requirement must not fall back to a cluster-scoped lookup.
test_request = lambda {
    r = postgres.request(_build({}))
    assert r.kind == "RequiredResources", "must be the required-resources meta item"
    sel = r.requirements[postgres.password_requirement]
    assert sel == {apiVersion = "v1", kind = "Secret", name = "demo-pg", namespace = "team-a"}, "wrong selector: ${sel}"
}

# PostgreSQL's pre-hashed md5 form is "md5" + md5(password + username); the
# username is part of the salt, so a different owner must hash differently.
test_password_hash = lambda {
    assert postgres.password_hash({}, _build({})) == "", "no answer yet must render nothing, not fail"
    h = postgres.password_hash(_fetched({password = "cGFzcw=="}), _build({}))
    assert h == "md50d06d8eb2a5f36ab73d83481186543d5", "must be md5 + md5('pass' + 'app'), got ${h}"
    assert h != postgres.password_hash(_fetched({password = "cGFzcw=="}), _build({username = "svc"})), "username salts the hash"
    assert postgres.password_hash(_fetched({token = "cGFzcw=="}), _build({
        passwordSecret = {name = "demo-pg", key = "token"}
    })) == h, "passwordSecret.key picks the Secret key"
}

# ---- render: child shape ----------------------------------------------------
test_render_shape = lambda {
    items = postgres.render(_build({}), "md5x")
    assert len(items) == 1, "the vm backend composes exactly one child"
    c = items[0]
    assert c.apiVersion == "cloud.example.org/v1alpha1" and c.kind == "VirtualMachine", "must be the portable VirtualMachine XR"
    assert c.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "vm", "status() reads the child under this key"
    assert c.spec.crossplane.compositionSelector.matchLabels.provider == "gcp", "spec.vm.provider must select the VM backend"
    assert _vs({vm.provider = "aws", vm.imageId = "ami-1"}).imageId == "ami-1", "imageId must reach the machine (AWS requires it)"
}

# memoryGb picks the smallest abstract size that fits; instanceClass wins.
test_sizing = lambda {
    assert _vs({}).size == "small", "the 2 GiB default fits small"
    assert _vs({memoryGb = 8}).size == "medium", "8 GiB is medium"
    assert _vs({memoryGb = 9}).size == "large", "just over medium rounds up"
    assert _vs({memoryGb = 32}).size == "xlarge", "32 GiB is xlarge"
    assert _vs({instanceClass = "n2-highmem-8"}).machineType == "n2-highmem-8", "instanceClass is the native machine type"
    assert _vs({}).diskGb == 30, "root disk = storageGb (20) + 10 GiB for the OS"
    assert _vs({storageGb = 100}).diskGb == 110, "storageGb must grow the root disk"
}

test_network = lambda {
    n = _vs({publicAccess = True, network.securityGroupIds = ["sg-1"], vm.subnetId = "subnet-1"}).network
    assert n.publicIp == True, "publicAccess must request a public address"
    assert n.subnetId == "subnet-1", "vm.subnetId places the machine"
    assert n.securityGroupIds == ["sg-1"], "network.securityGroupIds is shared with the RDS backend"
    assert _vs({}).network.publicIp == False, "private by default"
}

test_boot_script = lambda {
    s = _vs({engineVersion = "17", database = "orders", username = "svc", vm.allowedCidr = "172.16.0.0/12", parameters = {max_connections = "300", search_path = "'$user', public"}}).userData
    assert s.startswith("#!/bin/bash\n"), "GCP startup-script runs only scripts, so this must not be #cloud-config"
    assert "apt-get install -y postgresql-17" in s, "engineVersion picks the PGDG package"
    assert "host all all 172.16.0.0/12 md5" in s, "allowedCidr is the pg_hba client range"
    assert "CREATE DATABASE \"orders\" OWNER \"svc\"" in s, "database owned by username"
    assert "max_connections = '300'\n" in s, "parameters land in postgresql.conf"
    assert "search_path = '''$user'', public'\n" in s, "single quotes are doubled"
    assert "\\gexec" in s, "psql must receive a literal \\gexec"
}

# ---- status -----------------------------------------------------------------
_ocds = {
    vm.Resource.status = {ready = True, privateIp = "10.0.0.5", publicIp = "34.1.2.3", id = "i-1", "cloud-url" = "https://console"}
}

test_status = lambda {
    st = postgres.status(_build({}), _ocds).status
    assert st.provider == "vm", "provider must name the backend"
    assert st.ready == True, "machine up with an address -> ready"
    assert st.host == "10.0.0.5", "private address unless publicAccess"
    assert st.url == "postgresql://10.0.0.5:5432/app", "credential-free URI"
    assert st.authSecret == "demo-pg" and st.authSecretKey == "password", "the caller's Secret is the auth secret"
    assert postgres.status(_build({publicAccess = True}), _ocds).status.host == "34.1.2.3", "publicAccess publishes the public address"
    pending = postgres.status(_build({}), {}).status
    assert pending.ready == False and pending?.host == Undefined, "no machine yet -> not ready, no endpoint"
}
