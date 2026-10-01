import file
import yaml
import models.v1alpha1.cloud_example_org_v1alpha1_workflow as workflow

# The shipped example XRs are instances of the generated schema: a field the
# XRD does not declare, or a mistyped one, fails here before it fails on the
# cluster — and proves models/ is in step with xrd.yaml.
test_examples_are_workflows = lambda {
    _files = ["examples/workflow-aws.yaml", "examples/workflow-azure.yaml", "examples/workflow-gcp.yaml"]
    _xrs = [workflow.Workflow {**yaml.decode(file.read(f))} for f in _files]
    assert all x in _xrs {x.kind == "Workflow" and x.apiVersion == "cloud.example.org/v1alpha1"}
    assert all x in _xrs {x.spec.region != "" and x.spec.definition != ""}, "region and definition are required"
    assert [x.spec.crossplane.compositionSelector.matchLabels.provider for x in _xrs] == ["aws", "azure", "gcp"], "each example selects its own backend"
}
