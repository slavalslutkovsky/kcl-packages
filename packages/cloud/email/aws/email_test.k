import .email

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "EmailDomain", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The ConfigurationSet forProvider block from a render() of the given spec.
_fp = lambda _spec {
    email.render(_build(_spec))[0].spec.forProvider
}

# The EmailIdentity forProvider block from a render() of the given spec.
_ifp = lambda _spec {
    email.render(_build(_spec))[1].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: a ConfigurationSet plus an EmailIdentity, no MAIL FROM MR.
test_render_minimal = lambda {
    items = email.render(_build({region = "us-east-1", domain = "mail.example.com"}))
    assert len(items) == 2, "minimal render must emit exactly two MRs"
    assert items[0].apiVersion == "sesv2.aws.m.upbound.io/v1beta1", "wrong ConfigurationSet apiVersion"
    assert items[0].kind == "ConfigurationSet", "first MR must be the ConfigurationSet"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "config", "must be the config resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo-config", "set name must derive from the XR"
    assert items[1].apiVersion == "sesv2.aws.m.upbound.io/v1beta1", "wrong EmailIdentity apiVersion"
    assert items[1].kind == "EmailIdentity", "second MR must be the EmailIdentity"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "identity", "must be the identity resource"
    assert items[1].metadata.annotations["crossplane.io/external-name"] == "mail.example.com", "the domain must be the identity's external-name"
    assert items[0].spec.forProvider.region == "us-east-1", "region must reach the ConfigurationSet"
    assert items[1].spec.forProvider.region == "us-east-1", "region must reach the EmailIdentity"
    assert items[1].spec.forProvider.configurationSetNameSelector.matchControllerRef == True, "identity must bind the set by controller ref"
}

# ---- render: MAIL FROM ------------------------------------------------------

# A custom envelope subdomain adds the MailFromAttributes companion MR.
test_mail_from_subdomain = lambda {
    items = email.render(_build({region = "us-east-1", domain = "mail.example.com", mailFromSubdomain = "bounce"}))
    assert len(items) == 3, "mailFromSubdomain must add a third MR"
    _mfa = _by_kind(items, "EmailIdentityMailFromAttributes")
    assert _mfa != Undefined, "EmailIdentityMailFromAttributes must be present"
    assert _mfa.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "mailfrom", "must be the mailfrom resource"
    assert _mfa.metadata.annotations["crossplane.io/external-name"] == "mail.example.com", "the identity is the external-name"
    assert _mfa.spec.forProvider.mailFromDomain == "bounce.mail.example.com", "MAIL FROM domain must join sub and domain"
    assert _mfa.spec.forProvider.region == "us-east-1", "region must reach the MAIL FROM MR"
    assert _mfa.spec.forProvider?.behaviorOnMxFailure == Undefined, "MX failure behavior is left to the provider default"
}

test_no_mail_from_by_default = lambda {
    items = email.render(_build({region = "us-east-1", domain = "mail.example.com"}))
    assert _by_kind(items, "EmailIdentityMailFromAttributes") == Undefined, "no MAIL FROM MR unless asked for"
}

# ---- render: DKIM -----------------------------------------------------------
test_dkim_key_length = lambda {
    assert email.key_length_for(1024) == "RSA_1024_BIT", "1024 must map to RSA_1024_BIT"
    assert email.key_length_for(2048) == "RSA_2048_BIT", "2048 must map to RSA_2048_BIT"
    assert _ifp({region = "us-east-1", domain = "a.io"}).dkimSigningAttributes.nextSigningKeyLength == "RSA_2048_BIT", "key length must default to 2048"
    assert _ifp({region = "us-east-1", domain = "a.io", dkimKeyLength = 1024}).dkimSigningAttributes.nextSigningKeyLength == "RSA_1024_BIT", "1024 must be carried"
    assert _ifp({region = "us-east-1", domain = "a.io", dkimKeyLength = 2048}).dkimSigningAttributes.nextSigningKeyLength == "RSA_2048_BIT", "explicit 2048 must be carried"
}

# ---- render: configuration set options --------------------------------------
test_tls_required = lambda {
    assert _fp({region = "us-east-1", domain = "a.io"}).deliveryOptions.tlsPolicy == "REQUIRE", "TLS must default to REQUIRE"
    assert _fp({region = "us-east-1", domain = "a.io", tlsRequired = False}).deliveryOptions.tlsPolicy == "OPTIONAL", "tlsRequired=false must relax to OPTIONAL"
    assert _fp({region = "us-east-1", domain = "a.io", tlsRequired = True}).deliveryOptions.tlsPolicy == "REQUIRE", "explicit true must stay REQUIRE"
}

test_sending_enabled = lambda {
    assert _fp({region = "us-east-1", domain = "a.io"}).sendingOptions.sendingEnabled == True, "sending must default on"
    assert _fp({region = "us-east-1", domain = "a.io", sendingEnabled = False}).sendingOptions.sendingEnabled == False, "sendingEnabled=false must pause sending"
}

test_reputation_metrics = lambda {
    assert _fp({region = "us-east-1", domain = "a.io"}).reputationOptions.reputationMetricsEnabled == False, "reputation metrics must default off"
    assert _fp({region = "us-east-1", domain = "a.io", reputationMetrics = True}).reputationOptions.reputationMetricsEnabled == True, "reputationMetrics=true must be carried"
}

# An explicit empty list is the "disable suppression" signal, so it must be
# sent to AWS rather than dropped with the block.
test_suppressed_reasons = lambda {
    assert _fp({region = "us-east-1", domain = "a.io"}).suppressionOptions.suppressedReasons == ["BOUNCE", "COMPLAINT"], "suppression must default to both reasons"
    assert _fp({region = "us-east-1", domain = "a.io", suppressedReasons = ["BOUNCE"]}).suppressionOptions.suppressedReasons == ["BOUNCE"], "a single reason must be carried"
    assert _fp({region = "us-east-1", domain = "a.io", suppressedReasons = []}).suppressionOptions.suppressedReasons == [], "an empty list must be sent to disable suppression"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach every MR, or deleting the XR still drops the companions.
test_deletion_policy_orphan = lambda {
    items = email.render(_build({region = "us-east-1", domain = "a.io", mailFromSubdomain = "bounce", deletionPolicy = "Orphan"}))
    assert items[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the set"
    assert items[1].spec.managementPolicies == _orphan, "Orphan must reach the identity"
    assert _by_kind(items, "EmailIdentityMailFromAttributes").spec.managementPolicies == _orphan, "Orphan must reach the MAIL FROM MR"
}

test_deletion_policy_delete_default = lambda {
    items = email.render(_build({region = "us-east-1", domain = "a.io"}))
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
    assert items[1].spec.managementPolicies != _orphan, "Delete must not set the orphan policies on the identity"
}

# ---- render: tags -----------------------------------------------------------

# The MailFromAttributes model carries no tags field, so tags only fan out to
# the set and the identity.
test_tags_fan_out = lambda {
    _tags = {team = "platform", env = "prod"}
    items = email.render(_build({region = "us-east-1", domain = "a.io", tags = _tags}))
    assert items[0].spec.forProvider.tags == _tags, "tags must reach the ConfigurationSet"
    assert items[1].spec.forProvider.tags == _tags, "tags must reach the EmailIdentity"
    assert _fp({region = "us-east-1", domain = "a.io"})?.tags == Undefined, "no tags unless asked for"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = email.status(_build({region = "us-east-1", domain = "mail.example.com"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "EmailDomain", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.verified == False, "nothing is verified before creation"
    assert dxr.status?.verificationStatus == Undefined, "no verification status before the identity exists"
    assert dxr.status.dkimTokens == [], "no DKIM tokens before the identity exists"
    assert dxr.status.dnsRecords == [], "no DNS rows without tokens or a MAIL FROM subdomain"
    assert dxr.status.smtpHost == "email-smtp.us-east-1.amazonaws.com", "SMTP host is known ahead of creation"
    assert dxr.status.smtpPort == 587, "SMTP submission port must be 587"
    assert dxr.status.smtpEndpoint == "email-smtp.us-east-1.amazonaws.com:587", "SMTP endpoint must be host:port"
    assert dxr.status.configurationSet == "demo-config", "the set name is known ahead of creation"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/ses/home?region=us-east-1#/identities/mail.example.com", "cloud-url must point at the SES console"
}

# The MAIL FROM MX/SPF rows are deterministic from spec, so they publish even
# before the identity reports anything.
test_status_mail_from_records_pre_creation = lambda {
    dxr = email.status(_build({region = "eu-west-1", domain = "mail.example.com", mailFromSubdomain = "bounce"}), {})
    assert len(dxr.status.dnsRecords) == 2, "MAIL FROM must contribute the MX and SPF rows"
    _mx = dxr.status.dnsRecords[0]
    assert _mx["type"] == "MX", "first MAIL FROM row must be the MX record"
    assert _mx.name == "bounce.mail.example.com", "MX name must be the MAIL FROM domain"
    assert _mx.value == "feedback-smtp.eu-west-1.amazonses.com", "MX must target the regional feedback endpoint"
    assert _mx.priority == 10, "MX preference must be 10"
    _spf = dxr.status.dnsRecords[1]
    assert _spf["type"] == "TXT", "second MAIL FROM row must be the SPF record"
    assert _spf.name == "bounce.mail.example.com", "SPF name must be the MAIL FROM domain"
    assert _spf.value == "v=spf1 include:amazonses.com ~all", "SPF must include amazonses.com"
}

test_status_observed = lambda {
    ocds = {
        identity = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:ses:us-east-1:1:identity/mail.example.com"
                        id = "mail.example.com"
                        region = "us-east-1"
                        verificationStatus = "SUCCESS"
                        verifiedForSendingStatus = True
                        dkimSigningAttributes = {tokens = ["tok1", "tok2", "tok3"]}
                    }
                }
            }
        }
    }
    dxr = email.status(_build({region = "us-east-1", domain = "mail.example.com"}), ocds)
    assert dxr.status.ready == True, "an observed identity must mark the domain ready"
    assert dxr.status.verified == True, "verifiedForSendingStatus must be surfaced"
    assert dxr.status.verificationStatus == "SUCCESS", "raw verification state must be surfaced"
    assert dxr.status.dkimTokens == ["tok1", "tok2", "tok3"], "DKIM tokens must be surfaced"
    assert len(dxr.status.dnsRecords) == 3, "three tokens -> three DKIM CNAMEs"
    assert dxr.status.dnsRecords[0]["type"] == "CNAME", "DKIM rows must be CNAMEs"
    assert dxr.status.dnsRecords[0].name == "tok1._domainkey.mail.example.com", "CNAME name must be <token>._domainkey.<domain>"
    assert dxr.status.dnsRecords[0].value == "tok1.dkim.amazonses.com", "CNAME value must be <token>.dkim.amazonses.com"
    assert dxr.status.dnsRecords[2].name == "tok3._domainkey.mail.example.com", "every token must expand to a row"
    assert dxr.status.arn.endswith("identity/mail.example.com"), "arn must be surfaced"
    assert dxr.status.id == "mail.example.com", "observed id must be surfaced"
}

# Pending identities exist (ready) without being verified, and the observed
# region must win over spec for every region-derived field.
test_status_observed_pending = lambda {
    ocds = {
        identity = {
            Resource = {
                status = {
                    atProvider = {
                        id = "mail.example.com"
                        region = "eu-central-1"
                        verificationStatus = "PENDING"
                        verifiedForSendingStatus = False
                        dkimSigningAttributes = {tokens = ["tok1"]}
                    }
                }
            }
        }
    }
    dxr = email.status(_build({region = "us-east-1", domain = "mail.example.com", mailFromSubdomain = "bounce"}), ocds)
    assert dxr.status.ready == True, "an observed id must mark the domain ready even unverified"
    assert dxr.status.verified == False, "PENDING must not report verified"
    assert dxr.status.verificationStatus == "PENDING", "the pending state must be surfaced"
    assert dxr.status.smtpHost == "email-smtp.eu-central-1.amazonaws.com", "the observed region must win over spec"
    assert len(dxr.status.dnsRecords) == 3, "one token plus the MAIL FROM rows"
    assert dxr.status.dnsRecords[1].value == "feedback-smtp.eu-central-1.amazonses.com", "MAIL FROM MX must follow the observed region"
    assert dxr.status?.arn == Undefined, "no arn until reported"
}
