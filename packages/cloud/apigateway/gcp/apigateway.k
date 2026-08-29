# apigateway (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-apigee schema package. The portable ApiGateway maps
# onto the per-API slice of an Apigee X runtime: an Environment, an
# environment group carrying the serving hostname, the attachment binding the
# two, a TargetServer describing the backend, and (when an instance is named)
# the attachment that puts the environment on that runtime instance.
#
# NOT composed, deliberately:
#   - Organization: Apigee is one organization per GCP project, provisioned
#     once per project and named after it. Composing it would make every XR in
#     a project fight over the same singleton external-name
#     ("organizations/<project>"), so the org is referenced by that literal id
#     instead — spec.project must already host an Apigee organization.
#   - Instance: a runtime instance is a regional, long-provisioning, paid
#     singleton shared by every environment in the org — same argument.
#   - The API proxy bundle: provider-gcp-apigee ships no APIProxy resource
#     (see xrd/providers.yaml), so the proxy that binds a path to the
#     TargetServer is deployed outside Crossplane. This Composition builds
#     everything that proxy needs and reports the names to target in
#     status.environment / status.targetServer.
import gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_environment as env
import gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_envgroup as envgroup
import gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_envgroup_attachment as envgroup_attachment
import gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_instance_attachment as instance_attachment
import gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_target_server as target_server

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# backendUrl -> the host/port/TLS triple a TargetServer is made of. Apigee
# addresses a backend by host and port with TLS as a flag (there is no HTTPS
# protocol value — protocol is the wire protocol, HTTP or HTTP2, and TLS lives
# in sSlInfo), and it has no place for a path: the request path is chosen by
# the proxy bundle's target endpoint, so a backendUrl carrying one cannot be
# expressed and fails loud rather than silently routing to the host root.
backend_target = lambda url: str -> {str:any} {
    assert url.startswith("https://") or url.startswith("http://"), "spec.backendUrl must be an http(s) URL, got '${url}'"

    _tls = url.startswith("https://")
    _rest = url.removeprefix("https://").removeprefix("http://")
    _path = _rest.split("/", 1)[1] if "/" in _rest else ""
    assert _path == "", "the gcp backend cannot express a backendUrl path ('/${_path}'): an Apigee TargetServer is host+port only, the path belongs to the proxy bundle's target endpoint"

    _hostport = _rest.split("/", 1)[0]
    _parts = _hostport.split(":")
    {
        host = _parts[0]
        port = int(_parts[1]) if len(_parts) > 1 else (443 if _tls else 80)
        tls = _tls
    }
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # An Apigee organization is named after the project that hosts it, and an
    # environment group is nothing without the hostname it answers on; neither
    # has a defensible default.
    assert _spec?.project, "the gcp backend requires spec.project (the GCP project hosting the Apigee organization)"
    assert _spec?.hostname, "the gcp backend requires spec.hostname (the hostname the Apigee environment group serves)"

    # Apigee applies CORS from a policy inside the proxy bundle, which this
    # provider cannot manage — accepting spec.cors here would answer a browser
    # access request with nothing at all.
    assert not _spec?.cors, "the gcp backend cannot express spec.cors: Apigee CORS is a policy in the proxy bundle, which provider-gcp-apigee cannot manage"

    _org = "organizations/${_spec.project}"
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _backend = backend_target(_spec.backendUrl)

    # Ignored portable fields, deliberately (not silently dropped — see XRD):
    # - region: an Apigee environment has no location of its own; the runtime
    #   region is the instance's, and this XR does not manage instances.
    # - tags: no Apigee resource in this family carries labels.
    # - resourceGroup, publisherEmail, publisherName: Azure API Management
    #   concepts with no GCP counterpart.
    _items: [any] = [envgroup.Envgroup {
        metadata.annotations = {
            # The envgroup owns the hostname traffic arrives on, so it is the
            # resource whose observed state answers "is the gateway serving?".
            "krm.kcl.dev/composition-resource-name" = "managed"
            # forProvider carries no name field — the envgroup name is the
            # upjet external-name, and its id is <org>/envgroups/<name>.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.orgId = _org
        spec.forProvider.hostnames = [_spec.hostname]
    }]

    _items += [env.Environment {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "env"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.orgId = _org
        spec.forProvider.displayName = _name
        if _spec?.description:
            spec.forProvider.description = _spec.description
        # PROXY, not ARCHIVE: archive deployments forbid creating target
        # servers (see the deploymentType docs on the Environment schema),
        # which is exactly what this Composition renders below.
        spec.forProvider.deploymentType = "PROXY"
    }]

    # Nothing reaches the environment until it is in the group that owns the
    # hostname. Both ends bind by controller ref, so the attachment waits for
    # its two parents instead of racing them.
    _items += [envgroup_attachment.EnvgroupAttachment {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "envgroup-attachment"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.envgroupIdSelector.matchControllerRef = True
        spec.forProvider.environmentSelector.matchControllerRef = True
    }]

    # The backend, named so the proxy bundle can target it by name.
    _items += [target_server.TargetServer {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "target"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.envIdSelector.matchControllerRef = True
        spec.forProvider.host = _backend.host
        spec.forProvider.port = _backend.port
        spec.forProvider.$protocol = "HTTP"
        spec.forProvider.isEnabled = True
        if _spec?.description:
            spec.forProvider.description = _spec.description
        if _backend.tls:
            # enforce=True keeps a certificate failure a failure; without TLS
            # the block stays absent so Apigee's own default (off) applies.
            spec.forProvider.sSlInfo = {
                enabled = True
                enforce = True
            }
    }]

    # An environment only gets runtime capacity once attached to an instance.
    # Optional: an environment may already be served by an instance attached
    # out of band, and this XR must not invent an instance name.
    if _spec?.apigeeInstance:
        _items += [instance_attachment.InstanceAttachment {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "instance-attachment"}
            if _mp:
                spec.managementPolicies = _mp
            # instanceIdRef would need an Instance managed resource in-cluster;
            # this XR references an existing instance by its documented id.
            spec.forProvider.instanceId = "${_org}/instances/${_spec.apigeeInstance}"
            spec.forProvider.environmentSelector.matchControllerRef = True
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    # The gateway answers on the hostname the envgroup reports back, not the
    # one that was asked for.
    _hostnames = _at?.hostnames or []
    _host = _hostnames[0] if _hostnames else ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "ApiGateway"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _host != ""
            if _host != "":
                url = "https://${_host}"
                host = _host
            # Both names are pinned by render() to the XR name, so the proxy
            # bundle author can read them before anything is observed.
            environment = _name
            targetServer = _name
            # The console page is keyed by project alone — available up front,
            # unlike the AWS console URL which needs the observed API id.
            "cloud-url" = "https://console.cloud.google.com/apigee/environment-groups?project=${_spec.project}"
            if _at?.id:
                id = _at.id
        }
    }
}
