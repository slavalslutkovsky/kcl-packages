# workflow (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-sfn and aws-iam schema packages. The portable Workflow
# maps onto a STANDARD Step Functions StateMachine carrying the Amazon States
# Language definition verbatim. Unless the claim supplies an existing execution
# role ARN (spec.serviceAccount), an IAM Role trusted by states.amazonaws.com is
# composed alongside and bound via controller-ref — with NO permissions: what a
# state machine may call depends entirely on its Task states, so there is no
# safe default to attach. resourceGroup is Azure-only and ignored here.
import aws_sfn.models.v1beta1.sfn_awsm_upbound_io_v1beta1_state_machine as sm
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role as iamrole

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Trust policy letting Step Functions assume the composed execution role.
_states_trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

    # An existing execution role ARN skips composing the Role.
    _existing_role = _spec?.serviceAccount

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [sm.StateMachine {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            # The state machine name IS the upjet external name (the ARN is
            # templated from it); pin it to the XR name instead of Crossplane's
            # generated one.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.definition = _spec.definition
        if _existing_role:
            spec.forProvider.roleArn = _existing_role
        else:
            spec.forProvider.roleArnSelector.matchControllerRef = True
        if _spec?.encryptionKmsKeyId:
            spec.forProvider.encryptionConfiguration = {
                $type = "CUSTOMER_MANAGED_KMS_KEY"
                kmsKeyId = _spec.encryptionKmsKeyId
            }
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    if not _existing_role:
        _items += [iamrole.Role {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "role"}
            if _mp:
                spec.managementPolicies = _mp
            # IAM is global — Role has no region field, unlike the StateMachine.
            spec.forProvider.assumeRolePolicy = _states_trust
            spec.forProvider.description = "Workflow ${_name} execution role (managed by Crossplane)"
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _region = (_at?.region) or _spec.region
    _arn = _at?.arn

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Workflow"
        metadata.name = _name
        status = {
            provider = "aws"
            # DELETING is the only other state machine status.
            ready = _at?.status == "ACTIVE"
            # Deterministic from spec: the name is chosen here, not by AWS.
            name = _name
            if _arn:
                arn = _arn
                id = _arn
                "cloud-url" = "https://${_region}.console.aws.amazon.com/states/home?region=${_region}#/statemachines/view/${_arn}"
            if _at?.revisionId:
                revision = _at.revisionId
            if _at?.roleArn:
                identity = _at.roleArn
        }
    }
}
