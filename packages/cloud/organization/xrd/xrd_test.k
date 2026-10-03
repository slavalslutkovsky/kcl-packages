import file
import yaml
import models.v1alpha1.cloud_example_org_v1alpha1_organization as organization

_examples = ["examples/organization-gcp.yaml", "examples/organization-aws.yaml", "examples/organization-azure.yaml"]

_load = lambda path: str {
    organization.Organization {**yaml.decode(file.read(path))}
}

# Every shipped example is an instance of the generated schema: a field the
# XRD does not declare, or a mistyped one, fails here before it fails on the
# cluster — and proves models/ is in step with xrd.yaml. One example per
# backend, because one XR owns a whole organization.
test_examples_are_organizations = lambda {
    xrs = [_load(f) for f in _examples]
    assert len(xrs) == 3
    assert all o in xrs {o.kind == "Organization" and o.apiVersion == "cloud.example.org/v1alpha1"}
    assert all o in xrs {o.spec.orgId != ""}, "every backend needs the root its hierarchy hangs from"
    assert [o.spec.crossplane.compositionSelector.matchLabels.provider for o in xrs] == ["gcp", "aws", "azure"], "each example must pick its backend"
    assert all o in xrs {o.spec.folders != Undefined}, "an organization XR with no tree has nothing portable to say"
}

# The portable field set is exactly what the neutral API promises: no example
# carries a field its backend refuses, so each one renders as written.
test_examples_respect_backend_support = lambda {
    gcp = _load("examples/organization-gcp.yaml")
    aws = _load("examples/organization-aws.yaml")
    azure = _load("examples/organization-azure.yaml")

    assert gcp.spec.auditLogging != Undefined and gcp.spec.iamBindings != Undefined, "gcp is the only backend that composes audit configs"
    assert all p in gcp.spec.projects {p.services != Undefined}, "per-project API enablement is a gcp concept"

    assert aws.spec.auditLogging == Undefined and aws.spec.iamBindings == Undefined, "aws rejects both: no destination-free org trail, no IAM at OU scope"
    assert aws.spec.owner != "" and aws.spec.owner != Undefined, "an AWS account is created against a root email"
    assert all p in aws.spec.policies {p.deniedValues != Undefined and p.enforce == Undefined}, "an SCP names actions; it has no boolean switch"
    assert all p in aws.spec.projects {p.services == Undefined and p.autoCreateNetwork == False}

    assert azure.spec.projects == Undefined, "no azurerm_subscription in the installed provider family"
    assert azure.spec.auditLogging == Undefined
    assert all p in azure.spec.policies {p.allowedValues == Undefined and p.deniedValues == Undefined}, "an assignment takes definition parameters, not portable value lists"
    assert all b in azure.spec.iamBindings {b.condition == Undefined}, "an Azure ABAC condition is not portable"
}

# Every cross-reference resolves inside its own example: a project, policy or
# binding pointing at an undeclared folder is a fatal render on every backend.
test_examples_reference_declared_folders = lambda {
    _refs = lambda o {
        # Every folder key an example points at, from whichever blocks it uses.
        _p = o.spec.projects or []
        _c = o.spec.policies or []
        _b = o.spec.iamBindings or []
        [f.parent for f in o.spec.folders if f.parent not in [None, Undefined]] + [p.folder for p in _p if p.folder not in [None, Undefined]] + [c.folder for c in _c if c.folder not in [None, Undefined]] + [b.folder for b in _b if b.folder not in [None, Undefined]]
    }
    xrs = [_load(f) for f in _examples]
    dangling = [r for o in xrs for r in _refs(o) if r not in [g.name for g in o.spec.folders]]
    assert all o in xrs {isunique([f.name for f in o.spec.folders])}
    assert dangling == [], "a reference to an undeclared folder is a fatal render on every backend: ${dangling}"
    assert all o in xrs {len(_refs(o)) > 0}, "each example exercises the nesting the tree is for"
}

test_defaults_match_xrd = lambda {
    # XRD defaults come through the generated schema, so a composer that omits
    # a field renders exactly what the API server would have filled in.
    o = organization.Organization {
        spec = {orgId = "1", folders = [{name = "platform"}], projects = [{name = "yk-admin-gke"}], policies = [{constraint = "compute.requireOsLogin"}]}
    }
    assert o.spec.deletionPolicy == "Delete"
    assert o.spec.folders[0].deletionProtection == False, "GCP's API defaults this to true; the XRD does not"
    assert o.spec.projects[0].autoCreateNetwork == False, "the legacy default VPC is opt-in here"
    assert o.spec.projects[0].whenDeleted == "delete"
    assert o.spec.policies[0].dryRun == False

    # An absent OBJECT gets no defaults: the API server only fills fields of a
    # block that is present. That is why the backend re-defaults auditLogging
    # itself instead of trusting the schema.
    assert o.spec.auditLogging == Undefined
    a = organization.Organization {
        spec = {orgId = "1", auditLogging = {}}
    }
    assert a.spec.auditLogging.services == ["allServices"]
    assert a.spec.auditLogging.logTypes == ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
}
