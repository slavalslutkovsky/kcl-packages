import file
import runtime
import yaml
import .regions
import .residency

_anno = "krm.kcl.dev/composition-resource-name"

# ---- helpers ----------------------------------------------------------------
# Helpers never reuse a lambda parameter name from residency.k (KCL normalizes
# the leading underscore, so `_spec` would shadow `spec` over there).
_build = lambda _s {
    {apiVersion = "platform.example.org/v1alpha1", kind = "Residency", metadata.name = "shl", spec = _s}
}

_two_locations = lambda _provider: str {
    {
        provider = _provider
        locations = [{name = "il"}, {name = "gb"}]
        keys = [{name = "audit", locations = ["il"]}, {name = "app-data"}]
    }
}

_by_res = lambda _items, _res: str {
    [i for i in _items if i.metadata.annotations[_anno] == _res][0]
}

_wrap = lambda _st {
    {
        Resource = {status = _st}
    }
}

# ---- catalog ----------------------------------------------------------------
test_il_resolves_to_israel_on_every_cloud = lambda {
    _il = {name = "il"}
    assert regions.resolve(_il, "aws") == "il-central-1"
    assert regions.resolve(_il, "gcp") == "me-west1"
    assert regions.resolve(_il, "azure") == "israelcentral"
    assert regions.resolve(_il, "oci") == "il-jerusalem-1"
    assert regions.resolve(_il, "openbao") == regions.in_cluster, "openbao has no regions"
}

test_catalog_never_crosses_a_border = lambda {
    # AWS has no Dutch region; the catalog must refuse rather than pick Frankfurt.
    _err = runtime.catch(lambda {
        regions.resolve({name = "nl"}, "aws")
    })
    assert "no aws region" in _err, "nl on aws must fail the render, got: ${_err}"
    _unknown = runtime.catch(lambda {
        regions.resolve({name = "mars"}, "gcp")
    })
    assert "no gcp region" in _unknown, "an id outside the catalog needs an explicit region"
}

test_explicit_region_wins = lambda {
    assert regions.resolve({name = "nl", region = "eu-central-1"}, "aws") == "eu-central-1", "crossing a border on purpose"
    assert regions.resolve({name = "il", region = "me-central2"}, "gcp") == "me-central2", "override beats the catalog"
    assert regions.resolve({name = "lab"}, "openbao") == regions.in_cluster, "openbao accepts ids outside the catalog"
}

# ---- render: which keys exist where -----------------------------------------
test_one_key_per_location_pair = lambda {
    items = residency.render(_build(_two_locations("gcp")))
    # audit is narrowed to il; app-data is in both locations.
    assert [i.metadata.annotations[_anno] for i in items] == ["il-audit", "il-app-data", "gb-app-data"]
    assert [i.metadata.name for i in items] == ["shl-il-audit", "shl-il-app-data", "shl-gb-app-data"]
    assert all i in items {i.kind == "EncryptionKey" and i.apiVersion == "cloud.example.org/v1alpha1"}
    assert all i in items {i.metadata?.namespace == Undefined}, "children inherit the XR namespace"
    assert _by_res(items, "il-audit").spec.region == "me-west1"
    assert _by_res(items, "gb-app-data").spec.region == "europe-west2"
    assert all i in items {i.spec.crossplane.compositionSelector.matchLabels.provider == "gcp"}
}

test_residency_defaults_override_key_defaults = lambda {
    k = residency.render(_build(_two_locations("aws")))[0]

    # EncryptionKey defaults to no rotation and Delete; a Residency sends
    # rotation and Orphan explicitly so the child never falls back.
    assert k.spec.rotationDays == 90
    assert k.spec.deletionPolicy == "Orphan"
    assert k.spec.deletionWindowDays == 30 and k.spec.purpose == "encrypt-decrypt" and k.spec.algorithm == "symmetric"
    assert k.spec.tags == {"residency-location" = "il"}
}

test_key_settings_and_tags_forwarded = lambda {
    _s = _two_locations("gcp") | {
        keys = [{name = "signing", purpose = "sign-verify", algorithm = "ec-p384", protectionLevel = "hsm", rotationDays = 30, deletionWindowDays = 7}]
        deletionPolicy = "Delete"
        tags = {team = "platform"}
    }
    items = residency.render(_build(_s))
    assert len(items) == 2
    k = items[1]
    assert k.spec.purpose == "sign-verify" and k.spec.algorithm == "ec-p384" and k.spec.protectionLevel == "hsm"
    assert k.spec.rotationDays == 30 and k.spec.deletionWindowDays == 7 and k.spec.deletionPolicy == "Delete"
    assert k.spec.tags == {team = "platform", "residency-location" = "gb"}, "the location tag is added, user tags kept"
}

test_cloud_specific_fields_only_on_their_cloud = lambda {
    _az = _two_locations("azure") | {resourceGroup = "shl-security", tenantId = "t-1", compartmentId = "ocid1.compartment.oc1..x"}
    az = residency.render(_build(_az))[0]
    assert az.spec.resourceGroup == "shl-security" and az.spec.tenantId == "t-1"
    assert az.spec?.compartmentId == Undefined, "OCI field never reaches an Azure key"
    _oc = _two_locations("oci") | {compartmentId = "ocid1.compartment.oc1..x", resourceGroup = "rg"}
    oc = residency.render(_build(_oc))[0]
    assert oc.spec.compartmentId == "ocid1.compartment.oc1..x" and oc.spec.region == "il-jerusalem-1"
    assert oc.spec?.resourceGroup == Undefined
}

test_invalid_specs_fail_the_render = lambda {
    _no_rg = runtime.catch(lambda {
        residency.render(_build(_two_locations("azure")))
    })
    assert "requires spec.resourceGroup" in _no_rg
    _no_comp = runtime.catch(lambda {
        residency.render(_build(_two_locations("oci")))
    })
    assert "requires spec.compartmentId" in _no_comp
    _stray = runtime.catch(lambda {
        residency.render(_build(_two_locations("gcp") | {keys = [{name = "audit", locations = ["de"]}]}))
    })
    assert "may only name entries of spec.locations" in _stray
    _long = runtime.catch(lambda {
        residency.render(_build(_two_locations("azure") | {resourceGroup = "rg", tenantId = "t"}) | {metadata.name = "organizations"})
    })
    assert "at most 24 characters" in _long, "organizations-il-app-data (25) exceeds the Key Vault limit"
}

# ---- status -----------------------------------------------------------------
test_status_before_keys_exist = lambda {
    st = residency.status(_build(_two_locations("oci") | {compartmentId = "c"}), {}).status
    assert st.provider == "oci" and st.ready == False and st.keysReady == "0/3"
    assert st.locations.il.region == "il-jerusalem-1" and st.locations.il.jurisdiction == "Israel"
    assert st.locations.il.ready == False and st.locations.il.keys == {}
}

test_status_copies_key_coordinates = lambda {
    _uri = lambda _loc: str, _key: str {
        "projects/shl-security/locations/${_loc}/keyRings/shl-${_key}/cryptoKeys/shl-${_key}"
    }
    ocds = {
        "il-audit" = _wrap({ready = True, region = "me-west1", keyUri = _uri("me-west1", "il-audit")})
        "il-app-data" = _wrap({ready = True, region = "me-west1", keyUri = _uri("me-west1", "il-app-data")})
        "gb-app-data" = _wrap({ready = False, region = "europe-west2"})
    }
    st = residency.status(_build(_two_locations("gcp")), ocds).status
    assert st.keysReady == "2/3" and st.ready == False, "one key still coming up"
    assert st.locations.il.ready == True and st.locations.gb.ready == False
    assert st.locations.il.keys == {audit = _uri("me-west1", "il-audit"), "app-data" = _uri("me-west1", "il-app-data")}
    assert st.locations.gb.keys == {}, "no keyUri until the key exists"
    assert st.locations.gb.region == "europe-west2"
}

test_status_reports_observed_region = lambda {
    # A region override the backend normalized is reported as the key saw it.
    ocds = {"il-app-data" = _wrap({ready = True, region = "ME-WEST1", keyUri = "k"})}
    st = residency.status(_build({provider = "gcp", locations = [{name = "il"}], keys = [{name = "app-data"}]}), ocds).status
    assert st.locations.il.region == "ME-WEST1" and st.ready == True and st.keysReady == "1/1"
}

# ---- examples ---------------------------------------------------------------
test_every_example_renders_on_its_backend = lambda {
    _counts = {aws = 4, gcp = 4, azure = 4, oci = 4, openbao = 2}
    _checked = [_p for _p, _n in _counts if len(residency.render(yaml.decode(file.read("../xrd/examples/residency-${_p}.yaml")))) == _n]
    assert len(_checked) == 5, "examples rendering the expected key count: ${_checked}"
    aws = residency.render(yaml.decode(file.read("../xrd/examples/residency-aws.yaml")))
    assert [i.spec.region for i in aws] == ["il-central-1", "il-central-1", "eu-central-1", "il-central-1"]
    bao = residency.render(yaml.decode(file.read("../xrd/examples/residency-openbao.yaml")))
    assert all i in bao {i.spec.region == regions.in_cluster and i.spec.deletionPolicy == "Delete"}
}
