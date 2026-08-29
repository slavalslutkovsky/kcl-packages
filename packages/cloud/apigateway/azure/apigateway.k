# apigateway (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-apimanagement schema package. The portable
# ApiGateway maps onto an API Management Consumption service plus one
# catch-all API proxying everything to the backend URL, a wildcard
# operation per HTTP method, and an optional CORS policy — all bound
# together by controller reference.
import azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_management as apim
import azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api as api
import azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_operation as op
import azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_policy as policy

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# APIM only routes requests that MATCH a declared operation, so a catch-all
# API needs one wildcard operation per method. Static list keeps the render
# deterministic.
_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

# Build APIM's inbound <cors> policy XML. <allowed-origins>, <allowed-methods>
# and <allowed-headers> are MANDATORY elements of the cors policy, so unset
# methods/headers fall back to a single wildcard entry instead of being
# dropped; the optional pieces (allow-credentials, preflight max-age,
# expose-headers) only render when asked for.
cors_xml = lambda _cors: any -> str {
    _cred = ""
    if _cors?.allowCredentials != Undefined:
        _cred = " allow-credentials=\"" + ("true" if _cors.allowCredentials else "false") + "\""

    _age = ""
    if _cors?.maxAgeSeconds != Undefined:
        _age = " preflight-result-max-age=\"${_cors.maxAgeSeconds}\""

    _origins = "".join(["<origin>${_o}</origin>" for _o in _cors.allowOrigins])
    _allow_methods = "".join(["<method>${_m}</method>" for _m in (_cors?.allowMethods or ["*"])])
    _headers = "".join(["<header>${_h}</header>" for _h in (_cors?.allowHeaders or ["*"])])
    _expose = ""
    if _cors?.exposeHeaders:
        _expose = "<expose-headers>" + "".join(["<header>${_h}</header>" for _h in _cors.exposeHeaders]) + "</expose-headers>"

    "<policies><inbound><base /><cors${_cred}><allowed-origins>${_origins}</allowed-origins><allowed-methods${_age}>${_allow_methods}</allowed-methods><allowed-headers>${_headers}</allowed-headers>${_expose}</cors></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # An API Management service cannot exist outside a resource group or
    # without a publisher contact and this XR manages neither; fail loud
    # instead of rendering resources Azure rejects.
    assert _spec?.resourceGroup, "the azure backend requires spec.resourceGroup"
    assert _spec?.publisherEmail, "the azure backend requires spec.publisherEmail"

    _rg = _spec.resourceGroup
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Ignored portable fields, deliberately (not silently dropped — see XRD):
    # - project, hostname, apigeeInstance: GCP Apigee concepts with no Azure
    #   counterpart (the APIM service name fixes the gateway hostname).
    _items: [any] = [apim.Management {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            # The service name IS the gateway hostname (<name>.azure-api.net)
            # and the composed API/operations address the service by name.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.publisherEmail = _spec.publisherEmail
        spec.forProvider.publisherName = _spec?.publisherName or _name
        # Consumption is the serverless per-call tier: it provisions in
        # minutes where Developer and up take ~40, matching the claim's
        # "one endpoint now" semantics.
        spec.forProvider.skuName = "Consumption_0"
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    _items += [api.API {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "api"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.apiManagementNameSelector.matchControllerRef = True
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.revision = "1"
        spec.forProvider.displayName = _name
        if _spec?.description:
            spec.forProvider.description = _spec.description
        # Serve at the gateway root for parity with the AWS endpoint.
        spec.forProvider.path = ""
        spec.forProvider.protocols = ["https"]
        spec.forProvider.serviceUrl = _spec.backendUrl
        # Open endpoint, parity with the AWS default: APIM would otherwise
        # 401 every call arriving without a subscription key.
        spec.forProvider.subscriptionRequired = False
    }]

    _items += [op.APIOperation {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "op-" + _m.lower()
            # The lowercase method doubles as the stable operation id.
            "crossplane.io/external-name" = _m.lower()
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.apiNameSelector.matchControllerRef = True
        spec.forProvider.apiManagementNameSelector.matchControllerRef = True
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.method = _m
        # APIM's wildcard suffix template: matches every path under the root.
        spec.forProvider.urlTemplate = "/*"
        spec.forProvider.displayName = "${_m} /*"
    } for _m in _methods]

    if _spec?.cors:
        _items += [policy.APIPolicy {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "cors"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.apiNameSelector.matchControllerRef = True
            spec.forProvider.apiManagementNameSelector.matchControllerRef = True
            spec.forProvider.resourceGroupName = _rg
            spec.forProvider.xmlContent = cors_xml(_spec.cors)
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _url = _at?.gatewayUrl or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "ApiGateway"
        metadata.name = _name
        status = {
            provider = "azure"
            ready = _url != ""
            if _url != "":
                url = _url
                host = _url.removeprefix("https://")
            if _at?.id:
                id = _at.id
                # The ARM id starts with a /, so the concatenation is clean.
                "cloud-url" = "https://portal.azure.com/#resource${_at.id}"
        }
    }
}
