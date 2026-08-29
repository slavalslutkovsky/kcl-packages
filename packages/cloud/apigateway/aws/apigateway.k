# apigateway (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-apigatewayv2 schema package. The portable ApiGateway
# maps onto a single HTTP API via AWS quick create: setting forProvider.target
# to the backend URL makes AWS itself produce the HTTP_PROXY integration, the
# catch-all $default route, and an auto-deploying $default stage (the schema's
# own target doc says so), so composing Integration/Route/Stage resources
# separately would only duplicate what the API resource already owns.
import aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_api as api

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _cors = _spec?.cors

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Ignored portable fields, deliberately (not silently dropped — see XRD):
    # - resourceGroup, publisherEmail, publisherName: Azure API Management
    #   concepts with no AWS counterpart.
    # - project, hostname, apigeeInstance: GCP Apigee concepts with no AWS
    #   counterpart (AWS assigns the execute-api endpoint hostname itself).
    [api.API {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _spec.region
        spec.forProvider.name = _name
        spec.forProvider.protocolType = "HTTP"
        # Quick create: AWS derives the HTTP_PROXY integration from the URL.
        spec.forProvider.target = _spec.backendUrl
        if _spec?.description:
            spec.forProvider.description = _spec.description
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
        if _cors:
            # Only set the sub-fields the claim provided; unset ones keep the
            # AWS defaults instead of getting pinned to empty values.
            spec.forProvider.corsConfiguration = {
                allowOrigins = _cors.allowOrigins
                if _cors?.allowMethods:
                    allowMethods = _cors.allowMethods
                if _cors?.allowHeaders:
                    allowHeaders = _cors.allowHeaders
                if _cors?.exposeHeaders:
                    exposeHeaders = _cors.exposeHeaders
                # allowCredentials = False and maxAgeSeconds = 0 are meaningful,
                # so test for presence, not truthiness.
                if _cors?.allowCredentials != Undefined:
                    allowCredentials = _cors.allowCredentials
                if _cors?.maxAgeSeconds != Undefined:
                    maxAge = _cors.maxAgeSeconds
            }
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _region = (_at?.region) or _spec.region
    _endpoint = _at?.apiEndpoint or ""
    _id = _at?.id

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "ApiGateway"
        metadata.name = _name
        status = {
            provider = "aws"
            ready = _endpoint != ""
            if _endpoint != "":
                url = _endpoint
                host = _endpoint.removeprefix("https://")
            # Unlike Lambda's name-addressed console page, the API Gateway
            # console page is keyed by the API id, which only exists once the
            # API is observed — no cloud-url ahead of creation.
            if _id:
                id = _id
                "cloud-url" = "https://${_region}.console.aws.amazon.com/apigateway/main/api-detail?api=${_id}&region=${_region}"
            if _at?.arn:
                arn = _at.arn
        }
    }
}
