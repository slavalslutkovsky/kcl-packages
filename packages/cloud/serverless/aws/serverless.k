# serverless (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-lambda and aws-iam schema packages. The portable
# ServerlessApp maps onto a container-image Lambda Function fronted by a
# Function URL. Unless the claim supplies an existing execution role ARN
# (spec.serviceAccount), a minimal IAM Role with the AWS-managed basic
# execution policy is composed alongside and bound via controller-ref.
import aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_function as fn
import aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_function_url as furl
import aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_permission as perm
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role as iamrole
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy_attachment as rpa

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Lambda hard limits. The XRD allows more so other backends can use it; going
# over Lambda's ceiling would be rejected by AWS, so clamp instead of failing.
_max_memory_mb = 10240
_max_timeout_s = 900

# Trust policy letting the Lambda service assume the composed execution role.
_lambda_trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# AWS-managed policy granting CloudWatch Logs write access — the minimum any
# Lambda needs to be debuggable.
_basic_execution_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

    # Lambda caps memory at 10 GB; the XRD has no ceiling because the other
    # backends go higher.
    _memory = _spec?.memoryMb or 512
    if _memory > _max_memory_mb:
        _memory = _max_memory_mb

    # Lambda caps a single invocation at 15 minutes; the XRD allows up to 3600
    # for backends (Cloud Run) that serve longer requests.
    _timeout = _spec?.timeoutSeconds or 60
    if _timeout > _max_timeout_s:
        _timeout = _max_timeout_s

    _public = _spec?.public
    if _public == Undefined:
        _public = True

    _env = _spec?.env or {}

    # An existing execution role ARN skips composing Role + attachment.
    _existing_role = _spec?.serviceAccount

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Ignored portable fields, deliberately (not silently dropped — see XRD):
    # - port: Lambda container images speak the Lambda Runtime API, they do not
    #   listen on a port.
    # - cpu: Lambda allocates CPU proportionally to memorySize; there is no
    #   independent CPU knob.
    # - minInstances: keeping instances warm needs provisioned concurrency,
    #   which requires published versions and aliases — beyond this XR.
    _items: [any] = [fn.Function {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.packageType = "Image"
        spec.forProvider.imageUri = _spec.image
        spec.forProvider.memorySize = _memory
        spec.forProvider.timeout = _timeout
        if _existing_role:
            spec.forProvider.role = _existing_role
        else:
            spec.forProvider.roleSelector.matchControllerRef = True
        # maxInstances maps to reserved concurrency; leaving it unset keeps the
        # function on the account's unreserved concurrency pool.
        if _spec?.maxInstances:
            spec.forProvider.reservedConcurrentExecutions = _spec.maxInstances
        if _env:
            spec.forProvider.environment.variables = _env
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    if not _existing_role:
        _items += [
            iamrole.Role {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "role"}
                if _mp:
                    spec.managementPolicies = _mp
                # IAM is global — Role has no region field, unlike the Lambda MRs.
                spec.forProvider.assumeRolePolicy = _lambda_trust
                spec.forProvider.description = "ServerlessApp ${_name} execution role (managed by Crossplane)"
                if _spec?.tags:
                    spec.forProvider.tags = _spec.tags
            }
            rpa.RolePolicyAttachment {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "role-policy"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.policyArn = _basic_execution_arn
                spec.forProvider.roleSelector.matchControllerRef = True
            }
        ]

    _items += [furl.FunctionURL {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "url"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.functionNameSelector.matchControllerRef = True
        spec.forProvider.authorizationType = "NONE" if _public else "AWS_IAM"
    }]

    # authorizationType NONE alone is not enough: unauthenticated callers also
    # need a resource policy allowing lambda:InvokeFunctionUrl for principal *.
    if _public:
        _items += [perm.Permission {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "url-permission"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.functionNameSelector.matchControllerRef = True
            spec.forProvider.action = "lambda:InvokeFunctionUrl"
            spec.forProvider.principal = "*"
            spec.forProvider.functionUrlAuthType = "NONE"
            spec.forProvider.statementId = "AllowPublicFunctionUrl"
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _url_at = (ocds["url"]?.Resource?.status?.atProvider) if ("url" in ocds) else Undefined

    _region = (_at?.region) or _spec.region

    # atProvider.functionUrl is "https://<url_id>.lambda-url.<region>.on.aws/";
    # drop the trailing slash for a clean joinable URL and strip the scheme for
    # the bare host.
    _url = (_url_at?.functionUrl or "").rstrip("/")
    _host = _url.split("://")[-1] if _url != "" else ""

    # The Function's atProvider.id is the function name (the console URL wants
    # the name, not the ARN); fall back to the ARN's last segment.
    _fn_name = _at?.id
    if _fn_name == Undefined and _at?.arn:
        _fn_name = _at.arn.split(":")[-1]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "ServerlessApp"
        metadata.name = _name
        status = {
            provider = "aws"
            ready = _url != ""
            if _url != "":
                url = _url
                host = _host
            if _fn_name:
                "cloud-url" = "https://${_region}.console.aws.amazon.com/lambda/home?region=${_region}#/functions/${_fn_name}"
            if _at:
                if _at?.arn:
                    arn = _at.arn
                if _at?.id:
                    id = _at.id
        }
    }
}
