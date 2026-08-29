# serverless (knative) — Crossplane Composition logic (function-kcl module).
# The self-hosted backend: no cloud account, no VPC. Typed against the knative
# schema package, it renders one namespaced serving.knative.dev/v1 Service
# DIRECTLY — Crossplane v2 composes arbitrary namespaced resources, so there
# is no provider MR wrapper, no providerConfigRef and no managementPolicies
# (deletionPolicy is documented as ignored in-cluster: the Service's lifetime
# follows the XR). region is ignored too: the app runs where the XR lives.
import knative.models.v1.serving_knative_dev_v1_service as backend

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    _port = _spec?.port or 8080
    _cpu = _spec?.cpu or 1
    _memory = _spec?.memoryMb or 512
    _min = _spec?.minInstances or 0
    _max = _spec?.maxInstances
    _timeout = _spec?.timeoutSeconds or 60
    _env = _spec?.env or {}

    _public = _spec?.public
    if _public == Undefined:
        _public = True

    # Knative's visibility switch is a label on the Service: cluster-local
    # keeps the route off the external ingress, leaving only the
    # <name>.<ns>.svc.cluster.local address. Public is the platform default,
    # so the label only appears when the claim opts out.
    _labels = _spec?.tags or {}
    if not _public:
        _labels |= {"networking.knative.dev/visibility" = "cluster-local"}

    [backend.Service {
        # The route hostname (and so the serving URL) derives from the
        # Service name, so naming it after the XR is what makes the DNS
        # deterministic. No namespace: Crossplane places composed namespaced
        # resources in the XR's own namespace.
        metadata.name = _name
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _labels:
            metadata.labels = _labels
        # Autoscaling knobs live on the REVISION template, and Knative reads
        # them from annotations — which are strings by definition, hence the
        # str() casts. max-scale only when asked for: unset keeps the
        # autoscaler's own default (unbounded unless the operator capped it).
        spec.template.metadata.annotations = {
            "autoscaling.knative.dev/min-scale" = str(_min)
            if _max != Undefined:
                "autoscaling.knative.dev/max-scale" = str(_max)
        }
        spec.template.spec = {
            containers = [{
                image = _spec.image
                # Knative allows exactly one containerPort; it is what the
                # queue-proxy forwards request traffic to.
                ports = [{containerPort = _port}]
                # Sorted for a stable order: any template diff stamps out a
                # new Revision, so map iteration order must never leak in.
                if _env:
                    env = [{name = _k, value = _env[_k]} for _k in sorted(_env)]
                # cpu/memory map onto plain container limits — Kubernetes
                # quantities, so the number formats as a string ("0.5") and
                # MiB carries the Mi suffix verbatim.
                resources.limits = {cpu = str(_cpu), memory = "${_memory}Mi"}
            }]
            # Max duration of one request, enforced by the queue-proxy.
            timeoutSeconds = _timeout
            if _spec?.serviceAccount:
                serviceAccountName = _spec.serviceAccount
        }
    }]
}

# Build the desired composite carrying observed status back to the XR.
# This is the CR's OWN status (no provider wrapper, so no atProvider): the
# Route controller publishes the serving URL once traffic is routable.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _st = (ocds["managed"]?.Resource?.status) if ("managed" in ocds) else Undefined

    _url = _st?.url or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "ServerlessApp"
        metadata.name = _name
        status = {
            provider = "knative"
            # The URL only appears once the Route has a ready Revision behind
            # it, so its presence is the readiness signal.
            ready = _url != ""
            # The Service name IS the provider-assigned id in-cluster.
            # No cloud-url and no arn: there is no console to link to.
            id = _name
            if _url != "":
                url = _url
                host = _url.split("://")[-1]
        }
    }
}
