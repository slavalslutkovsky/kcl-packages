import file
import yaml
import models.v1alpha1.cloud_example_org_v1alpha1_network_hub as hub

# The shipped example XRs are instances of the generated schema: a field the
# XRD does not declare, or a mistyped one, fails here before it fails on the
# cluster — and proves models/ is in step with xrd.yaml.
test_examples_are_network_hubs = lambda {
    _files = ["examples/hubspoke-aws.yaml", "examples/hubspoke-azure.yaml", "examples/hubspoke-gcp.yaml"]
    _xrs = [hub.NetworkHub {**yaml.decode(file.read(f))} for f in _files]
    assert len(_xrs) == 3
    assert all x in _xrs {x.kind == "NetworkHub" and x.apiVersion == "cloud.example.org/v1alpha1"}
    assert all x in _xrs {x.spec.region != ""}, "region is required on every backend, even where it is ignored"
    assert all x in _xrs {len(x.spec.spokes) == 3}, "each example attaches three spokes"
    assert all x in _xrs {x.spec.crossplane.compositionSelector.matchLabels.provider != ""}, "each example must pick its backend"
}

# Every example keeps exactly one shared-services spoke, which is what an
# isolated topology needs and what a mesh one ignores.
test_examples_have_one_shared_spoke = lambda {
    _files = ["examples/hubspoke-aws.yaml", "examples/hubspoke-azure.yaml", "examples/hubspoke-gcp.yaml"]
    _xrs = [hub.NetworkHub {**yaml.decode(file.read(f))} for f in _files]
    assert all x in _xrs {len([s for s in x.spec.spokes if s.shared]) == 1}
    assert all x in _xrs {x.spec.spokes[0].name == "shared-services" and x.spec.spokes[0].shared}
    assert all x in _xrs {all s in x.spec.spokes[1::] {not s.shared}}, "shared defaults to false"
}

# The AWS-only fields live on the aws example only, and the Azure-only ones on
# the azure example: a backend that reads a field the XR never carries is what
# the per-backend defaulting exists for.
test_backend_specific_fields = lambda {
    a = hub.NetworkHub {**yaml.decode(file.read("examples/hubspoke-aws.yaml"))}
    assert a.spec.summaryCidr == "10.0.0.0/8" and a.spec.amazonSideAsn == 64512
    assert all s in a.spec.spokes {len(s.subnets) >= 1}, "an aws attachment needs a subnet per zone"
    assert len(a.spec.spokes[1].routeTableIds) == 2, "a spoke may point several of its own route tables at the gateway"
    z = hub.NetworkHub {**yaml.decode(file.read("examples/hubspoke-azure.yaml"))}
    assert z.spec.resourceGroup == "platform-rg" and z.spec.hubCidr == "10.200.0.0/23"
    assert z.spec.spokes[0].network.startswith("/subscriptions/"), "azure attaches by ARM id"
    g = hub.NetworkHub {**yaml.decode(file.read("examples/hubspoke-gcp.yaml"))}
    assert g.spec.topology == "mesh" and z.spec.topology == "isolated"
    assert g.spec.spokes[0].network.startswith("projects/"), "gcp attaches by network URI"
    assert all s in g.spec.spokes {s?.subnets == Undefined and s?.routeTableIds == Undefined}, "the gcp example carries no aws-only spoke fields"
}

test_defaults_match_xrd = lambda {
    # XRD defaults come through the generated schema, so a composer that omits a
    # field renders exactly what the API server would have filled in — and each
    # backend re-defaults to the same values for locally rendered XRs.
    h = hub.NetworkHub {
        spec = {region = "eu-west-1", spokes = [{name = "a", network = "vpc-1"}]}
    }
    assert h.spec.topology == "mesh"
    assert h.spec.summaryCidr == "10.0.0.0/8"
    assert h.spec.amazonSideAsn == 64512
    assert h.spec.deletionPolicy == "Delete"
    assert h.spec.spokes[0].shared == False, "a spoke is a workload spoke unless it says otherwise"
}
