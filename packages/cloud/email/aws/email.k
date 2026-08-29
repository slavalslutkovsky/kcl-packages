# email (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-sesv2 schema package. The portable EmailDomain maps
# onto an SESv2 EmailIdentity bound to a companion ConfigurationSet, plus MAIL
# FROM attributes when a custom envelope subdomain is asked for. The identity
# string and the configuration set name have no forProvider field — both are
# the upjet external-name. In-cluster-only fields (persistenceSizeGb,
# adminPasswordSecret) are ignored here; the managed backend stores nothing.
import aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_configuration_set as cs
import aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_email_identity as ei
import aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_email_identity_mail_from_attributes as mf

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# 1024/2048 -> the SESv2 Easy-DKIM signing key length enum.
key_length_for = lambda bits: int -> str {
    "RSA_1024_BIT" if bits == 1024 else "RSA_2048_BIT"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region
    _domain = _spec.domain
    _config = "${_name}-config"

    _tls = _spec?.tlsRequired
    if _tls == Undefined:
        _tls = True

    _sending = _spec?.sendingEnabled
    if _sending == Undefined:
        _sending = True

    _reputation = _spec?.reputationMetrics or False

    # An explicit empty list is the "disable suppression" signal, so it must
    # be sent rather than omitted; only an absent field falls to the default.
    _suppressed = _spec?.suppressedReasons
    if _suppressed == Undefined:
        _suppressed = ["BOUNCE", "COMPLAINT"]

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [
        cs.ConfigurationSet {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "config"
                # forProvider carries no name field; the set name is the external-name.
                "crossplane.io/external-name" = _config
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.deliveryOptions.tlsPolicy = "REQUIRE" if _tls else "OPTIONAL"
            spec.forProvider.sendingOptions.sendingEnabled = _sending
            spec.forProvider.reputationOptions.reputationMetricsEnabled = _reputation
            spec.forProvider.suppressionOptions.suppressedReasons = _suppressed
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }
        ei.EmailIdentity {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "identity"
                # The identity string (the sending domain) is the external-name.
                "crossplane.io/external-name" = _domain
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.dkimSigningAttributes.nextSigningKeyLength = key_length_for(_spec?.dkimKeyLength or 2048)
            # Bind the companion set by controller ref, not by name, so the
            # identity waits for it instead of racing its creation.
            spec.forProvider.configurationSetNameSelector = {matchControllerRef = True}
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }
    ]

    if _spec?.mailFromSubdomain:
        _items += [mf.EmailIdentityMailFromAttributes {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "mailfrom"
                # No emailIdentity field or selector in this model — the bound
                # identity is this resource's own external-name.
                "crossplane.io/external-name" = _domain
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.mailFromDomain = "${_spec.mailFromSubdomain}.${_domain}"
            # behaviorOnMxFailure is left to the provider default; the model
            # carries no tags field, so spec.tags cannot reach this MR.
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _domain = _spec.domain
    _sub = _spec?.mailFromSubdomain
    _at = (ocds["identity"]?.Resource?.status?.atProvider) if ("identity" in ocds) else Undefined

    _region = (_at?.region) or _spec.region
    _tokens = _at?.dkimSigningAttributes?.tokens or []
    _host = "email-smtp.${_region}.amazonaws.com"

    # DNS rows are deterministic from spec + observed tokens: the DKIM CNAMEs
    # need the tokens, the MAIL FROM MX/SPF rows only need the subdomain.
    _records: [any] = [{
        "type" = "CNAME"
        name = "${_t}._domainkey.${_domain}"
        value = "${_t}.dkim.amazonses.com"
    } for _t in _tokens]
    if _sub:
        _records += [
            {
                "type" = "MX"
                name = "${_sub}.${_domain}"
                value = "feedback-smtp.${_region}.amazonses.com"
                priority = 10
            }
            {
                "type" = "TXT"
                name = "${_sub}.${_domain}"
                value = "v=spf1 include:amazonses.com ~all"
            }
        ]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "EmailDomain"
        metadata.name = _name
        status = {
            provider = "aws"
            # Ready once the identity exists, not once DNS is verified.
            ready = True if (_at?.arn or _at?.id) else False
            verified = _at?.verifiedForSendingStatus or False
            dkimTokens = _tokens
            dnsRecords = _records
            smtpHost = _host
            smtpPort = 587
            smtpEndpoint = "${_host}:587"
            configurationSet = "${_name}-config"
            "cloud-url" = "https://${_region}.console.aws.amazon.com/ses/home?region=${_region}#/identities/${_domain}"
            if _at?.verificationStatus:
                verificationStatus = _at.verificationStatus
            if _at?.arn:
                arn = _at.arn
            if _at?.id:
                id = _at.id
        }
    }
}
