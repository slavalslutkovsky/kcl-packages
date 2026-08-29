import .serverless

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "ServerlessApp", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The Function forProvider block from a render() of the given spec.
_fp = lambda _spec {
    serverless.render(_build(_spec))[0].spec.forProvider
}

_minimal = {image = "123.dkr.ecr.us-east-1.amazonaws.com/app:v1", region = "us-east-1"}

# ---- render: shape ----------------------------------------------------------

# Minimal spec (public defaults true): Function + composed execution role pair
# + FunctionURL + public invoke Permission, in that order.
test_render_minimal = lambda {
    items = serverless.render(_build(_minimal))
    assert len(items) == 5, "minimal render must emit five MRs"
    assert [_i.kind for _i in items] == ["Function", "Role", "RolePolicyAttachment", "FunctionURL", "Permission"], "kinds must be ordered Function, Role, RolePolicyAttachment, FunctionURL, Permission"
    assert items[0].apiVersion == "lambda.aws.m.upbound.io/v1beta1", "wrong Function apiVersion"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "Function must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.region == "us-east-1", "region must be carried"
    assert fp.packageType == "Image", "only container images are supported"
    assert fp.imageUri == "123.dkr.ecr.us-east-1.amazonaws.com/app:v1", "image must map to imageUri"
    assert fp.memorySize == 512, "memoryMb must default to 512"
    assert fp.timeout == 60, "timeoutSeconds must default to 60"
}

# ---- render: clamps ---------------------------------------------------------

# Lambda caps memory at 10 GB and a request at 900 s; the XRD allows more for
# other backends, so over-asks must clamp rather than be rejected by AWS.
test_lambda_clamps = lambda {
    assert _fp(_minimal | {memoryMb = 16384}).memorySize == 10240, "memory must clamp to Lambda's 10 GB ceiling"
    assert _fp(_minimal | {memoryMb = 10240}).memorySize == 10240, "an exact ceiling must not clamp"
    assert _fp(_minimal | {memoryMb = 1024}).memorySize == 1024, "memory below the ceiling must be carried"
    assert _fp(_minimal | {timeoutSeconds = 3600}).timeout == 900, "timeout must clamp to Lambda's 900 s max"
    assert _fp(_minimal | {timeoutSeconds = 120}).timeout == 120, "timeout below the cap must be carried"
}

# ---- render: environment and tags -------------------------------------------
test_env_and_tags = lambda {
    fp = _fp(_minimal | {env = {LOG_LEVEL = "info"}, tags = {team = "platform"}})
    assert fp.environment.variables == {LOG_LEVEL = "info"}, "env must map to environment.variables"
    assert fp.tags == {team = "platform"}, "tags must be carried"
    bare = _fp(_minimal)
    assert bare?.environment == Undefined, "no environment block without env"
    assert bare?.tags == Undefined, "no tags block without tags"
}

# ---- render: concurrency -----------------------------------------------------

# Unset maxInstances must keep Lambda concurrency unreserved (field absent).
test_max_instances = lambda {
    assert _fp(_minimal | {maxInstances = 20}).reservedConcurrentExecutions == 20, "maxInstances must map to reservedConcurrentExecutions"
    assert _fp(_minimal)?.reservedConcurrentExecutions == Undefined, "unset maxInstances must leave concurrency unreserved"
}

# ---- render: execution role --------------------------------------------------

# No serviceAccount: compose a Role with the Lambda trust policy plus the
# basic-execution attachment, both bound by controller-ref.
test_composed_role = lambda {
    items = serverless.render(_build(_minimal))
    assert items[0].spec.forProvider.roleSelector.matchControllerRef == True, "Function must select the composed role"
    _role = _by_kind(items, "Role")
    assert _role.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "role", "role must have a stable resource name"
    assert "lambda.amazonaws.com" in _role.spec.forProvider.assumeRolePolicy, "trust policy must allow the Lambda service"
    assert "sts:AssumeRole" in _role.spec.forProvider.assumeRolePolicy, "trust policy must grant sts:AssumeRole"

    # (IAM is global — the Role schema has no region attribute at all, so a
    # region assert is not expressible; the typed model enforces it.)
    _att = _by_kind(items, "RolePolicyAttachment")
    assert _att.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "role-policy", "attachment must have a stable resource name"
    assert _att.spec.forProvider.policyArn == "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole", "attachment must bind the basic execution policy"
    assert _att.spec.forProvider.roleSelector.matchControllerRef == True, "attachment must select the composed role"
}

# An existing role ARN is an escape hatch: use it verbatim and compose no IAM.
test_existing_role = lambda {
    items = serverless.render(_build(_minimal | {serviceAccount = "arn:aws:iam::1:role/existing"}))
    assert len(items) == 3, "an existing role must drop the Role and attachment"
    assert _by_kind(items, "Role") == Undefined, "no Role when serviceAccount is set"
    assert _by_kind(items, "RolePolicyAttachment") == Undefined, "no attachment when serviceAccount is set"
    fp = items[0].spec.forProvider
    assert fp.role == "arn:aws:iam::1:role/existing", "the existing role ARN must be used verbatim"
    assert fp?.roleSelector == Undefined, "no role selector when the ARN is given"
}

# ---- render: function URL and exposure ----------------------------------------
test_public_url = lambda {
    items = serverless.render(_build(_minimal))
    _url = _by_kind(items, "FunctionURL")
    assert _url.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "url", "url must have a stable resource name"
    assert _url.spec.forProvider.region == "us-east-1", "url must carry the region"
    assert _url.spec.forProvider.functionNameSelector.matchControllerRef == True, "url must select the composed function"
    assert _url.spec.forProvider.authorizationType == "NONE", "public must use authType NONE"
    _perm = _by_kind(items, "Permission")
    assert _perm.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "url-permission", "permission must have a stable resource name"
    assert _perm.spec.forProvider.action == "lambda:InvokeFunctionUrl", "permission must allow URL invocation"
    assert _perm.spec.forProvider.principal == "*", "public must allow any principal"
    assert _perm.spec.forProvider.functionUrlAuthType == "NONE", "permission must match the URL auth type"
    assert _perm.spec.forProvider.statementId == "AllowPublicFunctionUrl", "statement id must be stable"
    assert _perm.spec.forProvider.functionNameSelector.matchControllerRef == True, "permission must select the composed function"
}

# public=false gates the URL behind IAM and needs no resource policy.
test_private_url = lambda {
    items = serverless.render(_build(_minimal | {public = False}))
    assert _by_kind(items, "FunctionURL").spec.forProvider.authorizationType == "AWS_IAM", "private must use authType AWS_IAM"
    assert _by_kind(items, "Permission") == Undefined, "no public invoke permission when private"
}

# ---- render: deletion policy ---------------------------------------------------

# Orphan must reach every MR, or deleting the XR still drops the role and URL.
test_deletion_policy_orphan = lambda {
    items = serverless.render(_build(_minimal | {deletionPolicy = "Orphan"}))
    assert len([_i for _i in items if _i.spec.managementPolicies == _orphan]) == len(items), "Orphan must reach every composed MR"
}

test_deletion_policy_delete_default = lambda {
    items = serverless.render(_build(_minimal))
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = serverless.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "ServerlessApp", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status?.url == Undefined, "no url before the function URL exists"
    assert dxr.status?.host == Undefined, "no host before the function URL exists"
    assert dxr.status?["cloud-url"] == Undefined, "the console URL needs the observed function name"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:lambda:us-east-1:1:function:demo"
                        id = "demo"
                        region = "us-east-1"
                    }
                }
            }
        }
        url = {
            Resource = {
                status = {
                    atProvider = {
                        functionUrl = "https://abc123.lambda-url.us-east-1.on.aws/"
                    }
                }
            }
        }
    }
    dxr = serverless.status(_build(_minimal), ocds)
    assert dxr.status.ready == True, "an observed URL must mark the app ready"
    assert dxr.status.url == "https://abc123.lambda-url.us-east-1.on.aws", "the trailing slash must be stripped"
    assert dxr.status.host == "abc123.lambda-url.us-east-1.on.aws", "host must drop the scheme"
    assert dxr.status.arn == "arn:aws:lambda:us-east-1:1:function:demo", "arn must be surfaced"
    assert dxr.status.id == "demo", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/lambda/home?region=us-east-1#/functions/demo", "the console URL must target the function by name"
}

# The function can exist before its URL does; the console link must not wait.
test_status_function_only = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:lambda:us-east-1:1:function:demo"
                        region = "us-east-1"
                    }
                }
            }
        }
    }
    dxr = serverless.status(_build(_minimal), ocds)
    assert dxr.status.ready == False, "no URL yet must stay not ready"
    assert dxr.status["cloud-url"].endswith("#/functions/demo"), "the function name must fall back to the ARN's last segment"
}

test_render_minimal()
test_lambda_clamps()
test_env_and_tags()
test_max_instances()
test_composed_role()
test_existing_role()
test_public_url()
test_private_url()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
test_status_function_only()
