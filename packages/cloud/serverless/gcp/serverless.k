# serverless (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-cloudrun schema package. The portable ServerlessApp
# maps onto a Cloud Run v2 Service. Public exposure is a companion IAM
# binding (allUsers -> roles/run.invoker): Cloud Run gates unauthenticated
# traffic through IAM, not through the Service resource itself, so ingress
# alone never makes a service public.
import gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_v2_service as svc
import gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_service_i_a_m_member as iam

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

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

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [svc.V2Service {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            # Pin the Cloud Run service name to the XR name. Crossplane
            # otherwise generates a random external name, and the IAM member
            # below must address the service by its literal name.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _region
        # ingress only decides which networks may reach the service; public
        # traffic still has to pass the IAM invoker check bound below.
        spec.forProvider.ingress = "INGRESS_TRAFFIC_ALL" if _public else "INGRESS_TRAFFIC_INTERNAL_ONLY"
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
        spec.forProvider.template = {
            containers = [{
                image = _spec.image
                # The v2 API exposes exactly one port per container, so the
                # schema models ports as a single block, not a list.
                ports.containerPort = _port
                if _env:
                    # Sorted key order keeps the render deterministic.
                    env = [{name = _k, value = _env[_k]} for _k in sorted(_env)]
                # Cloud Run wants k8s quantity strings: cpu counts vCPUs
                # verbatim, memoryMb is MiB verbatim.
                resources.limits = {cpu = str(_cpu), memory = "${_memory}Mi"}
            }]
            scaling = {
                minInstanceCount = _min
                # Unset maxInstances leaves Cloud Run's own quota-derived
                # default instead of inventing a cap.
                if _max:
                    maxInstanceCount = _max
            }
            # Cloud Run takes a duration string ("60s"), not a number.
            timeout = "${_timeout}s"
            if _spec?.serviceAccount:
                serviceAccount = _spec.serviceAccount
        }
    }]

    # The provider only ships the v1-API ServiceIAMMember, but Cloud Run v1
    # and v2 share one IAM plane, so the binding still applies. Its
    # serviceSelector matches kind Service, not V2Service, so
    # matchControllerRef would never resolve — bind by explicit coordinates
    # instead (the external name pinned above plus the location).
    if _public:
        _items += [iam.ServiceIAMMember {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "invoker"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.service = _name
            spec.forProvider.location = _region
            spec.forProvider.role = "roles/run.invoker"
            spec.forProvider.member = "allUsers"
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _uri = _at?.uri or ""
    _region = (_at?.location) or _spec.region
    _project = _at?.project

    # The console URL is deterministic from the region and the pinned service
    # name; the project qualifier is only known once the service is observed.
    _console = "https://console.cloud.google.com/run/detail/${_region}/${_name}"
    if _project:
        _console = "${_console}?project=${_project}"

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "ServerlessApp"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _uri != ""
            "cloud-url" = _console
            if _uri != "":
                url = _uri
                host = _uri.removeprefix("https://")
            if _at?.id:
                id = _at.id
        }
    }
}
