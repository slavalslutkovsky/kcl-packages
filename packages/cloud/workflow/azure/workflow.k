# workflow (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-logic schema package. The portable Workflow maps
# onto a Consumption Logic App (AppWorkflow). Unlike Workflows or Step
# Functions, an AppWorkflow does not carry its definition: upjet-azure models
# every trigger and every action as its own resource under the workflow, so
# the Workflow Definition Language JSON in spec.definition is split here — one
# AppTriggerCustom per `triggers` entry and one AppActionCustom per `actions`
# entry, each named after its key and bound to the workflow by controller-ref.
# Actions keep their own `runAfter`, so ordering survives the split; nested
# actions (Scope/If/Foreach bodies) stay inside their parent's body.
# encryptionKmsKeyId is ignored: Consumption Logic Apps always encrypt with
# Microsoft-managed keys.
import json
import azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_workflow as app
import azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_trigger_custom as trigger
import azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_action_custom as action

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The Workflow Definition Language keys this backend can place somewhere.
# Anything else — most likely the {"definition": …, "parameters": …} envelope
# the portal's code view exports — would otherwise be dropped silently.
_known_keys = ["$schema", "contentVersion", "parameters", "triggers", "actions", "outputs"]

# Stable JSON for the MR bodies: key order must not flap between reconciles.
_encode = lambda v {
    json.encode(v, sort_keys=True)
}

# The decoded, validated definition object.
definition_of = lambda spec {
    _d = json.decode(spec.definition)
    assert typeof(_d) == "dict", "workflow-azure: spec.definition must be a Workflow Definition Language JSON object"
    _unknown = [k for k in _d if k not in _known_keys]
    assert not _unknown, "workflow-azure: spec.definition has unsupported top-level keys ${_unknown} — pass the workflow definition itself (the object holding triggers and actions), not the portal's {\"definition\": …} envelope"
    assert not _d?.outputs, "workflow-azure: spec.definition sets outputs — a Consumption Logic App resource has no field to carry them; drop the outputs block"
    _d
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # A Logic App cannot exist outside a resource group and this XR does not
    # manage one; fail loud instead of rendering resources Azure rejects.
    assert _spec?.resourceGroup, "workflow-azure: the azure backend requires spec.resourceGroup"

    _def = definition_of(_spec)
    _triggers = _def?.triggers or {}
    _actions = _def?.actions or {}
    _params = _def?.parameters or {}

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [app.AppWorkflow {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            # The workflow name is the upjet external name (the ARM id is
            # templated from it); pin it to the XR name.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        if _spec?.serviceAccount:
            spec.forProvider.identity = {
                $type = "UserAssigned"
                identityIds = [_spec.serviceAccount]
            }
        else:
            # Give the workflow an identity of its own to grant roles to, the
            # same way the other backends always run as some principal.
            spec.forProvider.identity.$type = "SystemAssigned"
        if _def?["$schema"]:
            spec.forProvider.workflowSchema = _def["$schema"]
        if _def?.contentVersion:
            spec.forProvider.workflowVersion = _def.contentVersion
        # Parameter DECLARATIONS; the model takes each one as a JSON string.
        if _params:
            spec.forProvider.workflowParameters = {k = _encode(_params[k]) for k in sorted(_params)}
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    _items += [trigger.AppTriggerCustom {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "trigger-${k}"
            # The key is the trigger's name inside the workflow.
            "crossplane.io/external-name" = k
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.logicAppIdSelector.matchControllerRef = True
        spec.forProvider.body = _encode(_triggers[k])
    } for k in sorted(_triggers)]

    _items += [action.AppActionCustom {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "action-${k}"
            "crossplane.io/external-name" = k
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.logicAppIdSelector.matchControllerRef = True
        spec.forProvider.body = _encode(_actions[k])
    } for k in sorted(_actions)]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    # Ready only once the workflow AND every trigger and action exist: a Logic
    # App missing one of its steps runs, just wrongly.
    _def = definition_of(_spec)
    _parts = ["trigger-${k}" for k in (_def?.triggers or {})] + ["action-${k}" for k in (_def?.actions or {})]
    _missing = [p for p in _parts if not ((ocds[p]?.Resource?.status?.atProvider?.id) if (p in ocds) else Undefined)]

    # A system-assigned identity is only known once Azure has created it; a
    # user-assigned one is what the spec named.
    _identity = (_at?.identity?.principalId) or _spec?.serviceAccount

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Workflow"
        metadata.name = _name
        status = {
            provider = "azure"
            ready = bool(_at?.id) and not _missing
            name = _name
            if _at?.id:
                id = _at.id
                # The ARM id starts with a /, so the concatenation is clean.
                "cloud-url" = "https://portal.azure.com/#resource${_at.id}"
            if _identity:
                identity = _identity
        }
    }
}
