# mgmt (gcp) — Crossplane Composition logic (function-kcl module).
#
# The infra repo's `mgmt` Pulumi stack (shluviza/infra apps/mgmt/index.ts and
# the gcp-gke, gcp-postgres and gcp-apis components it instantiates) as one
# Mgmt XR. Every resource the stack declares maps onto a namespaced
# *.gcp.m.upbound.io managed resource with the same GCP name, so an XR can
# adopt what the stack created (external-name = the GCP name) instead of
# replacing it. What the stack reads through StackReferences (organization
# folders, network host, security keys) arrives as plain ids in the spec.
#
# Ordering. Pulumi orders creation with dependsOn; a Composition has none, so
# what would fail (or worse, half-create) without its prerequisite is held
# back from the desired state until that prerequisite is observed:
#
#   project number   the service agents' emails and the Workload Identity
#                    principals embed it, so their grants wait for the Project
#   GKE cluster      waits for the attachment, the host grants, the key grant
#                    and the container API to be Ready: a GKE create that
#                    fails half-way leaves an ERROR cluster behind
#   Cloud SQL        waits for the CMEK grant (settable at creation only)
#   WI bindings      wait for the cluster, which creates the identity pool
#
# A held-back resource that already exists stays in the desired state
# whatever its prerequisites report later: dropping it would delete it.
# status.pending lists what is still held back.
#
# Not composed (no Crossplane kind in provider-gcp v2.6.0):
#   - billing account IAM (crossplane@ and crossplane-prod@ billing.user and
#     billing.costsManager): grant them out of band
#   - google_project_service_identity: the GKE agent exists once
#     container.googleapis.com is on; the Cloud SQL agent may not until
#     `gcloud beta services identity create --service=sqladmin.googleapis.com`
#   - Secret Manager password secrets of the databases: Cloud SQL users read
#     their password from a Kubernetes Secret (passwordSecretRef) instead
#   - bootstrapFlux (src/flux.ts): an in-cluster install, not a cloud resource
import regex
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project as project
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_service as projectservice
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account as serviceaccount
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_i_a_m_member as projectmember
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_folder_i_a_m_member as foldermember
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account_i_a_m_member as samember
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_shared_v_p_c_service_project as servicevpc
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_subnetwork_i_a_m_member as subnetmember
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_address as address
import gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_cluster as gkecluster
import gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_node_pool as nodepool
import gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_crypto_key_i_a_m_member as keymember
import gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_database_instance as sqlinstance
import gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_database as sqldb
import gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_user as sqluser
import gcp_artifact.models.v1beta1.artifact_gcpm_upbound_io_v1beta1_registry_repository as repository
import gcp_artifact.models.v1beta1.artifact_gcpm_upbound_io_v1beta1_registry_repository_i_a_m_member as repomember
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket as bucket
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_i_a_m_member as bucketmember
import gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_managed_zone as zone
import gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_record_set as recordset
import gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_managed_zone_i_a_m_member as zonemember
# These two families import into models/unknown/ as one package per family:
# a kind's file needs its siblings (SecretSpec, ...), so the whole directory.
import gcp_secretmanager.models.unknown as secretmanager
import gcp_binaryauthorization.models.unknown as binauthz

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# ── Constants from index.ts ──────────────────────────────────────────────────
apis = [
    "container.googleapis.com"
    "compute.googleapis.com"
    "binaryauthorization.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "sts.googleapis.com"
    "secretmanager.googleapis.com"
    "cloudkms.googleapis.com"
    "artifactregistry.googleapis.com"
    "servicenetworking.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "serviceusage.googleapis.com"
    "cloudbilling.googleapis.com"
    "billingbudgets.googleapis.com"
    "storage.googleapis.com"
    "sqladmin.googleapis.com"
    "pubsub.googleapis.com"
    "dns.googleapis.com"
    "bigquery.googleapis.com"
    "run.googleapis.com"
    "redis.googleapis.com"
    "workflows.googleapis.com"
    # The mgmt GKE cluster registers to this project's own fleet (fleet.project).
    "gkehub.googleapis.com"
]

# What Crossplane needs on an environment folder to create projects in it...
_project_lifecycle_roles = [
    "roles/resourcemanager.projectCreator"
    "roles/billing.projectManager"
    "roles/serviceusage.serviceUsageAdmin"
    "roles/resourcemanager.projectIamAdmin"
    "roles/resourcemanager.tagUser"
]

# ...and to compose the platform's resources inside them.
_platform_roles = [
    "roles/container.admin"
    "roles/compute.networkAdmin"
    "roles/compute.securityAdmin"
    "roles/compute.instanceAdmin.v1"
    "roles/compute.loadBalancerAdmin"
    "roles/servicenetworking.networksAdmin"
    "roles/cloudsql.admin"
    "roles/redis.admin"
    "roles/run.admin"
    "roles/workflows.admin"
    "roles/storage.admin"
    "roles/pubsub.admin"
    "roles/bigquery.admin"
    "roles/artifactregistry.admin"
    "roles/secretmanager.admin"
    "roles/dns.admin"
    "roles/cloudkms.admin"
    "roles/iam.serviceAccountAdmin"
    # Every GKE cluster it composes registers to a fleet (fleet.project), which
    # creates the Membership in the fleet host project.
    "roles/gkehub.admin"
    "roles/iam.serviceAccountUser"
]

_env_roles = _project_lifecycle_roles + _platform_roles

_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
_shielded = {enableSecureBoot = True, enableIntegrityMonitoring = True}

# ── Helpers ──────────────────────────────────────────────────────────────────
# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would swallow an explicit
# false or 0, so presence decides.
_or = lambda v, fallback -> any {
    fallback if v in [None, Undefined] else v
}

# composition-resource-name fragment: lowercase, [a-z0-9-] only. Renaming a
# composed resource deletes and recreates it, so this mapping is contract.
slug = lambda value: str -> str {
    regex.replace(value.lower(), "[^a-z0-9-]", "-")
}

# index.ts roleSlug: grant names derive from the role.
role_slug = lambda role: str -> str {
    slug(role.removeprefix("roles/").replace(".", "-"))
}

# Self link or bare name -> bare name (index.ts `selfLink.split('/').pop()`).
last_segment = lambda value: str -> str {
    value.split("/")[-1]
}

sa_email = lambda account_id: str, project_id: str -> str {
    "${account_id}@${project_id}.iam.gserviceaccount.com"
}

_res_name = lambda item -> str {
    item.metadata.annotations["krm.kcl.dev/composition-resource-name"]
}

_meta = lambda resource_name: str, external_name: str -> {str:str} {
    {"krm.kcl.dev/composition-resource-name" = resource_name} | ({"crossplane.io/external-name" = external_name} if external_name else {})
}

# Ready=True on an observed composed resource.
is_ready = lambda ocds, resource_name: str -> bool {
    _conds = (ocds[resource_name]?.Resource?.status?.conditions or []) if resource_name in ocds else []
    any c in _conds {c?.type == "Ready" and c?.status == "True"}
}

# ── Plan ─────────────────────────────────────────────────────────────────────
# Every resource the stack declares, then the ones whose prerequisites are not
# observed yet split off as `pending`. render() emits `items`, status() reports
# `pending`.
plan = lambda oxr, ocds -> {str:} {
    _spec = oxr.spec
    _cds = ocds or {}
    _at = lambda resource_name: str -> any {
        (_cds[resource_name]?.Resource?.status?.atProvider) if resource_name in _cds else Undefined
    }
    _ok = lambda resource_name: str -> bool {
        is_ready(_cds, resource_name)
    }

    _region = _spec.region
    _zone = _spec?.zone or "${_region}-a"
    _prefix = _spec?.prefix or "shl"
    _pid = _spec?.projectId or "${_prefix}-mgmt"
    _domain = _spec.domain
    _folders = _spec.folders
    _net = _spec.network
    _dev_net = _spec?.devNetwork
    _keys = _spec.keys
    _groups = _spec?.groups or {}
    _cl = _spec?.cluster or {}
    _sas = _spec?.serviceAccounts or {}
    _pg = _spec?.postgres or {}
    _dns = _spec?.dns or {}

    _group = lambda local_part: str -> str {
        "${local_part}@${_domain}"
    }
    _admin_group = _group(_groups?.admin or "gcp-organization-admins")
    _developer_group = _group(_groups?.developer or "gcp-devops")
    _cluster_name = _cl?.name or "mgmt"
    _pool = "${_pid}.svc.id.goog"
    _postgres = _or(_pg?.enabled, False)
    _dns_on = _or(_dns?.enabled, True)
    _crossplane_ksa = {namespace = "crossplane-system", name = _sas?.crossplane or "crossplane-gcp"}
    _eso_ksa = {namespace = "external-secrets", name = _sas?.externalSecrets or "external-secrets"}

    assert regex.match(_pid, r"^[a-z][-a-z0-9]{4,28}[a-z0-9]$"), "mgmt-gcp: project id '${_pid}' is not a valid GCP project id (6-30 characters: lowercase letters, digits, hyphens)"
    assert (not _postgres) or _keys?.cloudsql, "mgmt-gcp: spec.postgres.enabled needs spec.keys.cloudsql, the instance's CMEK key"
    assert _or(_cl?.minNodesPerZone, 3) <= _or(_cl?.maxNodesPerZone, 5), "mgmt-gcp: spec.cluster.minNodesPerZone exceeds maxNodesPerZone"
    _record_ids = [r.id for r in (_dns?.records or [])]
    assert isunique(_record_ids), "mgmt-gcp: spec.dns.records repeats an id ${_record_ids}"
    assert "wildcard" not in _record_ids, "mgmt-gcp: spec.dns.records id 'wildcard' is reserved for the *.<domain> record to the gateway"
    _db_names = [d.name for d in (_pg?.databases or [])]
    assert isunique(_db_names), "mgmt-gcp: spec.postgres.databases repeats a name ${_db_names}"

    # Parameters are `_`-prefixed: in a config body `member = member` resolves
    # the right-hand side as the attribute being defined, not the parameter.
    _lbl = lambda _purpose: str -> {str:str} {
        {"managed-by" = "crossplane", tier = "0", org = _prefix, purpose = _purpose}
    }

    # The project number: the service agents' emails and the Workload Identity
    # principals embed it. GCP assigns it, so it is only known once observed.
    _num = _at("project")?.number or ""
    _gke_agent = "serviceAccount:service-${_num}@container-engine-robot.iam.gserviceaccount.com"
    _apis_agent = "serviceAccount:${_num}@cloudservices.gserviceaccount.com"
    _sql_agent = "serviceAccount:service-${_num}@gcp-sa-cloud-sql.iam.gserviceaccount.com"
    _principal = lambda ns: str, ksa: str -> str {
        "principal://iam.googleapis.com/projects/${_num}/locations/global/workloadIdentityPools/${_pool}/subject/ns/${ns}/sa/${ksa}"
    }

    # The platform's Google service accounts: composition key, account id,
    # display name. Emails are deterministic, so grants never wait for them.
    _accounts = [
        {key = "nodes", id = "gke-nodes", display = "mgmt GKE nodes"}
        {key = "crossplane", id = "crossplane", display = "Crossplane GCP providers: dev, staging"}
        {key = "crossplaneProd", id = "crossplane-prod", display = "Crossplane GCP providers: prod"}
        {key = "externalSecrets", id = "external-secrets", display = "External Secrets Operator"}
        {key = "grafana", id = "grafana", display = "Grafana: Managed Prometheus, Cloud Logging, Cloud Trace"}
        {key = "openbao", id = "openbao", display = "OpenBao: Cloud KMS auto-unseal"}
        {key = "ciBuilder", id = "ci-builder", display = "Tekton CI builder: pushes to Artifact Registry ci"}
    ]
    _email = {a.key: sa_email(a.id, _pid) for a in _accounts}
    _sa_member = {k: "serviceAccount:${v}" for k, v in _email}

    # ── project, APIs, Shared VPC attachment ────────────────────────────────
    _project_items = [
        project.Project {
            metadata.annotations = _meta("project", _pid)
            spec.forProvider = {
                projectId = _pid
                name = _pid
                folderId = _folders.platform
                billingAccount = _spec.billingAccount
                autoCreateNetwork = False
                deletionPolicy = _spec?.projectDeletionPolicy or "PREVENT"
                labels = _lbl("mgmt")
            }
        }
    ] + [projectservice.ProjectService {
        metadata.annotations = _meta("api-${slug(_api)}", "")
        spec.forProvider = {
            project = _pid
            service = _api
            # Dropping an API from the list stops managing it; it does not
            # tear down whatever still runs on it.
            disableOnDestroy = False
        }
    } for _api in apis + [a for a in (_spec?.additionalApis or []) if a not in apis]] + [
        servicevpc.SharedVPCServiceProject {
            metadata.annotations = _meta("attachment", "")
            spec.forProvider = {
                hostProject = _net.hostProject
                serviceProject = _pid
            }
        }
    ]

    # ── service agents on the host and the keys (need the project number) ───
    _host_region = _net?.region or _region
    _subnet_name = last_segment(_net.subnetwork)
    _agent_items = [subnetmember.SubnetworkIAMMember {
        metadata.annotations = _meta("subnet-network-user-${_who}", "")
        spec.forProvider = {
            project = _net.hostProject
            region = _host_region
            subnetwork = _subnet_name
            role = "roles/compute.networkUser"
            member = _m
        }
    } for _who, _m in {"gke-agent" = _gke_agent, "apis-agent" = _apis_agent}] + [
        projectmember.ProjectIAMMember {
            metadata.annotations = _meta("host-service-agent-user", "")
            spec.forProvider = {project = _net.hostProject, role = "roles/container.hostServiceAgentUser", member = _gke_agent}
        }
        # GKE writes the firewall rules its load balancers need in the host.
        projectmember.ProjectIAMMember {
            metadata.annotations = _meta("host-firewall-admin", "")
            spec.forProvider = {project = _net.hostProject, role = "roles/compute.securityAdmin", member = _gke_agent}
        }
        keymember.CryptoKeyIAMMember {
            metadata.annotations = _meta("gke-agent-uses-gke-secrets", "")
            spec.forProvider = {cryptoKeyId = _keys.gkeSecrets, role = "roles/cloudkms.cryptoKeyEncrypterDecrypter", member = _gke_agent}
        }
    ] + ([keymember.CryptoKeyIAMMember {
        metadata.annotations = _meta("cloudsql-agent-uses-cloudsql", "")
        spec.forProvider = {cryptoKeyId = _keys.cloudsql, role = "roles/cloudkms.cryptoKeyEncrypterDecrypter", member = _sql_agent}
    }] if _keys?.cloudsql else [])

    # ── identities and their grants ─────────────────────────────────────────
    _project_roles = lambda id: str, _member: str, roles: [str] -> [any] {
        [projectmember.ProjectIAMMember {
            metadata.annotations = _meta("${id}-${role_slug(_r)}", "")
            spec.forProvider = {project = _pid, role = _r, member = _member}
        } for _r in roles]
    }
    _folder_roles = lambda id: str, folder_id: str, _member: str, roles: [str] -> [any] {
        [foldermember.FolderIAMMember {
            metadata.annotations = _meta("${id}-${role_slug(_r)}", "")
            spec.forProvider = {folder = "folders/${folder_id}", role = _r, member = _member}
        } for _r in roles] if folder_id else []
    }
    _key_roles = lambda id: str, key_id: str, _member: str, roles: [str] -> [any] {
        [keymember.CryptoKeyIAMMember {
            metadata.annotations = _meta("${id}-${role_slug(_r)}", "")
            spec.forProvider = {cryptoKeyId = key_id, role = _r, member = _member}
        } for _r in roles] if key_id else []
    }

    _identity_items: [any] = [serviceaccount.ServiceAccount {
        # external-name is the account id: the email is <id>@<project>.iam...
        metadata.annotations = _meta("sa-${a.id}", a.id)
        spec.forProvider = {project = _pid, displayName = a.display}
    } for a in _accounts]
    _identity_items += _project_roles("gke-nodes", _sa_member.nodes, ["roles/container.defaultNodeServiceAccount"])
    # crossplane@ on dev and staging (plus Shared VPC Admin to attach their
    # projects to the dev host), crossplane-prod@ on prod.
    _identity_items += _folder_roles("crossplane-dev", _folders?.dev, _sa_member.crossplane, _env_roles + ["roles/compute.xpnAdmin"])
    _identity_items += _folder_roles("crossplane-staging", _folders?.staging, _sa_member.crossplane, _env_roles + ["roles/compute.xpnAdmin"])
    _identity_items += _folder_roles("crossplane-network", _folders?.network, _sa_member.crossplane, ["roles/compute.xpnAdmin"])
    _identity_items += _folder_roles("crossplane-prod", _folders?.prod, _sa_member.crossplaneProd, _env_roles)
    # The mgmt project is the providers' quota project.
    _identity_items += _project_roles("crossplane", _sa_member.crossplane, ["roles/serviceusage.serviceUsageConsumer"])
    _identity_items += _project_roles("crossplane-prod", _sa_member.crossplaneProd, ["roles/serviceusage.serviceUsageConsumer"])
    _identity_items += [samember.ServiceAccountIAMMember {
        metadata.annotations = _meta("crossplane-impersonates-crossplane-prod", "")
        spec.forProvider = {
            serviceAccountId = "projects/${_pid}/serviceAccounts/${_email.crossplaneProd}"
            role = "roles/iam.serviceAccountTokenCreator"
            member = _sa_member.crossplane
        }
    }]
    if _dev_net:
        _identity_items += [subnetmember.SubnetworkIAMMember {
            metadata.annotations = _meta("crossplane-net-dev-network-user", "")
            spec.forProvider = {
                project = _dev_net.hostProject
                region = _dev_net?.region or _region
                subnetwork = last_segment(_dev_net.subnetwork)
                role = "roles/compute.networkUser"
                member = _sa_member.crossplane
            }
        }]
    _identity_items += _project_roles("grafana", _sa_member.grafana, ["roles/monitoring.viewer", "roles/logging.viewer", "roles/cloudtrace.user"])
    _identity_items += _key_roles("openbao", _keys?.openbaoUnseal, _sa_member.openbao, ["roles/cloudkms.cryptoKeyEncrypterDecrypter", "roles/cloudkms.viewer"])

    # ── Cloud SQL ───────────────────────────────────────────────────────────
    _instance_name = _pg?.instanceName or "${_cluster_name}-postgres"
    _sql_items: [any] = []
    if _postgres:
        _sql_items = [sqlinstance.DatabaseInstance {
            metadata.annotations = _meta("cloud-sql", _instance_name)
            spec.forProvider = {
                project = _pid
                region = _region
                databaseVersion = _pg?.databaseVersion or "POSTGRES_18"
                # Settable at creation only: the agent's grant must exist first.
                encryptionKeyName = _keys.cloudsql
                deletionProtection = True
                settings = {
                    tier = _pg?.tier or "db-custom-1-3840"
                    edition = "ENTERPRISE"
                    availabilityType = "ZONAL"
                    diskType = "PD_SSD"
                    diskSize = _or(_pg?.diskSizeGb, 20)
                    diskAutoresize = True
                    diskAutoresizeLimit = 500
                    backupConfiguration = {
                        enabled = True
                        pointInTimeRecoveryEnabled = True
                        startTime = "03:00"
                        transactionLogRetentionDays = 7
                        backupRetentionSettings = {retainedBackups = 30, retentionUnit = "COUNT"}
                    }
                    maintenanceWindow = {day = 7, hour = 4, updateTrack = "stable"}
                    insightsConfig = {queryInsightsEnabled = True, recordApplicationTags = True, recordClientAddress = True}
                    # Private IP only, from the host's Private Service Access range.
                    ipConfiguration = {ipv4Enabled = False, privateNetwork = _net.network, sslMode = "ENCRYPTED_ONLY"}
                    deletionProtectionEnabled = True
                }
            }
        }]
        _dbs = _pg?.databases or []
        _sql_items += [sqldb.Database {
            metadata.annotations = _meta("db-${slug(_d.name)}", _d.name)
            spec.forProvider = {project = _pid, instanceSelector.matchControllerRef = True}
        } for _d in _dbs]
        _sql_items += [sqluser.User {
            metadata.annotations = _meta("db-${slug(_d.name)}-user", _d?.user or _d.name)
            spec.forProvider = {
                project = _pid
                instanceSelector.matchControllerRef = True
                passwordSecretRef = {name = _d.passwordSecretRef.name, key = _d.passwordSecretRef?.key or "password"}
            }
        } for _d in _dbs if _d?.passwordSecretRef]

    # ── admission policy, the cluster, its pools ────────────────────────────
    _binauthz_items = [binauthz.Policy {
        metadata.annotations = _meta("binary-authorization", "")
        spec.forProvider = {
            project = _pid
            globalPolicyEvaluationMode = "ENABLE"
            admissionWhitelistPatterns = [{namePattern = "${_region}-docker.pkg.dev/${_prefix}-artifacts/**"}]
            # Audit only: violations are logged, nothing is blocked yet.
            defaultAdmissionRule = {evaluationMode = "ALWAYS_DENY", enforcementMode = "DRYRUN_AUDIT_LOG_ONLY"}
        }
    }]

    _node_config = lambda machine_type: str, disk_type: str, disk_gb: int -> {str:} {
        {
            machineType = machine_type
            serviceAccount = _email.nodes
            oauthScopes = _scopes
            imageType = "COS_CONTAINERD"
            diskType = disk_type
            diskSizeGb = disk_gb
            shieldedInstanceConfig = _shielded
            workloadMetadataConfig = {mode = "GKE_METADATA"}
            metadata = {"disable-legacy-endpoints" = "true"}
        }
    }

    _monitoring = _cl?.monitoringPackages or ["POD", "DEPLOYMENT", "STATEFULSET", "CADVISOR", "KUBELET"]
    _cluster_items: [any] = [gkecluster.Cluster {
        metadata.annotations = _meta("gke", _cluster_name)
        spec.forProvider = {
            project = _pid
            location = _zone
            deletionProtection = _or(_cl?.deletionProtection, True)
            # The API requires a default pool; it is created and deleted right
            # away. Its VMs still face compute.requireShieldedVm, so they get
            # the real pools' identity and boot settings (see initProvider).
            removeDefaultNodePool = True
            initialNodeCount = 1
            network = _net.network
            subnetwork = _net.subnetwork
            networkingMode = "VPC_NATIVE"
            ipAllocationPolicy = {
                clusterSecondaryRangeName = _net?.podsRange or "pods"
                servicesSecondaryRangeName = _net?.servicesRange or "services"
            }
            # No external node IPs; the control plane is reached only through
            # its IAM-gated DNS endpoint.
            privateClusterConfig.enablePrivateNodes = True
            controlPlaneEndpointsConfig = {
                dnsEndpointConfig.allowExternalTraffic = True
                ipEndpointsConfig.enabled = False
            }
            releaseChannel.channel = "REGULAR"
            # Fri and Sat nights in Israel, 8 h each.
            maintenancePolicy.recurringWindow = {
                startTime = "2026-01-02T22:00:00Z"
                endTime = "2026-01-03T06:00:00Z"
                recurrence = "FREQ=WEEKLY;BYDAY=FR,SA"
            }
            workloadIdentityConfig.workloadPool = _pool
            databaseEncryption = {state = "ENCRYPTED", keyName = _keys.gkeSecrets}
            enableShieldedNodes = True
            authenticatorGroupsConfig.securityGroup = _group(_groups?.gkeSecurity or "gke-security-groups")
            gatewayApiConfig.channel = "CHANNEL_STANDARD"
            costManagementConfig.enabled = True
            loggingConfig.enableComponents = ["SYSTEM_COMPONENTS", "WORKLOADS"]
            monitoringConfig = {
                enableComponents = ["SYSTEM_COMPONENTS"] + _monitoring
                managedPrometheus.enabled = True
            }
            binaryAuthorization.evaluationMode = "PROJECT_SINGLETON_POLICY_ENFORCE"
            # Every platform GKE cluster is fleet-registered; mgmt hosts its own
            # fleet (same project, so the same Workload Identity pool).
            fleet.project = _pid
        }
        # Shapes the deleted default pool only: set at creation, never
        # reconciled, so editing it can not force a cluster replacement
        # (index.ts ignoreChanges: ['nodeConfig']).
        spec.initProvider.nodeConfig = {
            serviceAccount = _email.nodes
            oauthScopes = _scopes
            imageType = "COS_CONTAINERD"
            diskType = "pd-standard"
            shieldedInstanceConfig = _shielded
            workloadMetadataConfig = {mode = "GKE_METADATA"}
            metadata = {"disable-legacy-endpoints" = "true"}
        }
    }]

    _pools = [
        {
            name = "default"
            min = _or(_cl?.minNodesPerZone, 3)
            max = _or(_cl?.maxNodesPerZone, 5)
            config = _node_config(_cl?.nodeMachineType or "e2-standard-4", "pd-standard", 50)
        }
        {
            # Tekton runs: spot, from zero, tainted so nothing else lands there.
            name = "ci"
            min = 0
            max = _or(_cl?.ciMaxNodesPerZone, 4)
            config = _node_config(_cl?.ciMachineType or "e2-standard-4", "pd-standard", 50) | {
                spot = True
                taint = [{key = "cloud.google.com/gke-spot", value = "true", effect = "NO_SCHEDULE"}]
            }
        }
    ]
    _cluster_items += [nodepool.NodePool {
        metadata.annotations = _meta("node-pool-${p.name}", p.name)
        spec.forProvider = {
            project = _pid
            location = _zone
            clusterSelector.matchControllerRef = True
            initialNodeCount = p.min
            autoscaling = {minNodeCount = p.min, maxNodeCount = p.max}
            management = {autoRepair = True, autoUpgrade = True}
            upgradeSettings = {maxSurge = 1, maxUnavailable = 0}
            nodeConfig = p.config
        }
    } for p in _pools]

    _wi = lambda id: str, account_key: str, ns: str, ksa: str -> any {
        samember.ServiceAccountIAMMember {
            metadata.annotations = _meta("${id}-workload-identity", "")
            spec.forProvider = {
                serviceAccountId = "projects/${_pid}/serviceAccounts/${_email[account_key]}"
                role = "roles/iam.workloadIdentityUser"
                member = "serviceAccount:${_pool}[${ns}/${ksa}]"
            }
        }
    }
    _wi_items = [
        _wi("crossplane", "crossplane", _crossplane_ksa.namespace, _crossplane_ksa.name)
        _wi("eso", "externalSecrets", _eso_ksa.namespace, _eso_ksa.name)
        _wi("grafana", "grafana", "monitoring", "grafana")
        _wi("gmp-frontend", "grafana", "monitoring", "gmp-frontend")
        _wi("openbao", "openbao", "openbao", "openbao")
        _wi("ci-builder", "ciBuilder", "ci", "builder")
    ]

    # ── Artifact Registry `ci`, the nx cache bucket, cluster access ─────────
    _nx_bucket = "${_pid}-nx-cache"
    _storage_items = [
        repository.RegistryRepository {
            metadata.annotations = _meta("ci-repo", "ci")
            spec.forProvider = {
                project = _pid
                location = _region
                description = "Images built by the mgmt cluster CI (gitops platform/tekton/ci)"
                format = "DOCKER"
                dockerConfig.immutableTags = True
                labels = _lbl("ci")
            }
        }
    ] + [repomember.RegistryRepositoryIAMMember {
        metadata.annotations = _meta("ci-${g.id}", "")
        spec.forProvider = {project = _pid, location = _region, repository = "ci", role = g.role, member = g.member}
    } for g in [
        {id = "ci-builder-writer", role = "roles/artifactregistry.writer", member = _sa_member.ciBuilder}
        {id = "gke-nodes-reader", role = "roles/artifactregistry.reader", member = _sa_member.nodes}
    ]] + [
        bucket.Bucket {
            metadata.annotations = _meta("nx-cache-bucket", _nx_bucket)
            spec.forProvider = {
                project = _pid
                location = _region.upper()
                uniformBucketLevelAccess = True
                publicAccessPrevention = "enforced"
                lifecycleRule = [{action.$type = "Delete", condition.age = 14}]
                forceDestroy = True
                labels = _lbl("nx-cache")
            }
        }
        projectmember.ProjectIAMMember {
            metadata.annotations = _meta("admins-container-admin", "")
            spec.forProvider = {project = _pid, role = "roles/container.admin", member = "group:${_admin_group}"}
        }
        projectmember.ProjectIAMMember {
            metadata.annotations = _meta("developers-cluster-viewer", "")
            spec.forProvider = {project = _pid, role = "roles/container.clusterViewer", member = "group:${_developer_group}"}
        }
    ]
    # Workload Identity Federation principal: needs the number and the pool.
    _principal_items = [bucketmember.BucketIAMMember {
        metadata.annotations = _meta("nx-cache-${role_slug(_r)}", "")
        spec.forProvider = {bucket = _nx_bucket, role = _r, member = _principal("nx-cache", "butler-cache")}
    } for _r in ["roles/storage.objectViewer", "roles/storage.objectCreator"]]

    # ── the org domain's public zone, main-gateway's address, the records ───
    _zone_name = _domain.replace(".", "-")
    _gateway_ip = _at("gateway-ip")?.address or ""
    # Once composed, the wildcard keeps its last rendered address while the
    # Address is momentarily unobserved, rather than rendering an empty record.
    _wildcard_seen = (_cds["dns-wildcard"]?.Resource?.spec?.forProvider?.rrdatas or []) if "dns-wildcard" in _cds else []
    _wildcard_data = [_gateway_ip] if _gateway_ip else _wildcard_seen
    _dns_items: [any] = []
    _wildcard_items: [any] = []
    _dns_principal_items: [any] = []
    if _dns_on:
        _dns_items = [
            zone.ManagedZone {
                metadata.annotations = _meta("dns-zone", _zone_name)
                spec.forProvider = {
                    project = _pid
                    dnsName = "${_domain}."
                    description = "${_domain}: Workspace mail, platform hosts (main-gateway)"
                    visibility = "public"
                    dnssecConfig.state = "on"
                    labels = _lbl("dns")
                }
            }
            address.Address {
                metadata.annotations = _meta("gateway-ip", "main-gateway")
                spec.forProvider = {
                    project = _pid
                    region = _region
                    addressType = "EXTERNAL"
                    description = "main-gateway (gitops platform/gateway), *.${_domain}"
                    labels = _lbl("gateway")
                }
            }
        ] + [recordset.RecordSet {
            metadata.annotations = _meta("dns-${r.id}", "")
            spec.forProvider = {
                project = _pid
                managedZone = _zone_name
                name = "${r?.name or ''}${_domain}."
                $type = r.type
                ttl = _or(r?.ttl, 3600)
                rrdatas = r.rrdatas
            }
        } for r in _dns?.records or []]
        if _wildcard_data:
            _wildcard_items = [recordset.RecordSet {
                metadata.annotations = _meta("dns-wildcard", "")
                spec.forProvider = {project = _pid, managedZone = _zone_name, name = "*.${_domain}.", $type = "A", ttl = 300, rrdatas = _wildcard_data}
            }]
        _dns_principal_items = [zonemember.ManagedZoneIAMMember {
            metadata.annotations = _meta("cert-manager-dns", "")
            spec.forProvider = {project = _pid, managedZone = _zone_name, role = "roles/dns.admin", member = _principal("cert-manager", "cert-manager")}
        }]

    # ── Flux GitHub App secret: the container only ──────────────────────────
    _secret_items = [
        secretmanager.Secret {
            metadata.annotations = _meta("github-app-secret", "flux-github-app")
            spec.forProvider = {
                project = _pid
                replication.userManaged.replicas = [{location = _region}]
                labels = _lbl("flux")
            }
        }
        secretmanager.SecretIAMMember {
            metadata.annotations = _meta("flux-github-app-admins", "")
            spec.forProvider = {
                project = _pid
                secretIdSelector.matchControllerRef = True
                role = "roles/secretmanager.secretAccessor"
                member = "group:${_admin_group}"
            }
        }
    ]

    # ── gates ───────────────────────────────────────────────────────────────
    _has_num = _num != ""
    # api-gkehub: the cluster registers to the fleet at creation.
    _cluster_deps = ["attachment", "subnet-network-user-gke-agent", "subnet-network-user-apis-agent", "host-service-agent-user", "host-firewall-admin", "gke-agent-uses-gke-secrets", "api-container-googleapis-com", "api-gkehub-googleapis-com"]
    _cluster_ready = _ok("gke")
    _groups_of = [
        {items = _project_items + _identity_items + _binauthz_items + _storage_items + _dns_items + _secret_items, open = True}
        {items = _agent_items, open = _has_num}
        {items = _cluster_items, open = _has_num and all d in _cluster_deps {_ok(d)}}
        {items = _sql_items[:1:], open = _ok("cloudsql-agent-uses-cloudsql")}
        {items = _sql_items[1::], open = _ok("cloud-sql")}
        {items = _wi_items, open = _cluster_ready}
        {items = _principal_items + _dns_principal_items, open = _has_num and _cluster_ready}
        {items = _wildcard_items, open = True}
    ]
    # Already composed: keep it, whatever its prerequisites report now.
    _kept = [i for g in _groups_of for i in g.items if g.open or _res_name(i) in _cds]
    _held = [_res_name(i) for g in _groups_of for i in g.items if not (g.open or _res_name(i) in _cds)]
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _pcr = {kind = "ProviderConfig", name = _spec.providerConfigName} if _spec?.providerConfigName else Undefined

    {
        items = [i | {
            if _mp:
                spec.managementPolicies = _mp
            if _pcr:
                spec.providerConfigRef = _pcr
        } for i in _kept]
        pending = _held + (["dns-wildcard"] if _dns_on and not _wildcard_data else [])
        projectId = _pid
        projectNumber = _num
        zone = _zone
        clusterName = _cluster_name
        workloadPool = _pool
        emails = _email
        adminGroup = _admin_group
        developerGroup = _developer_group
        crossplaneKsa = _crossplane_ksa.name
        postgres = _postgres
    }
}

render = lambda oxr, ocds -> [any] {
    plan(oxr, ocds).items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _cds = ocds or {}
    _p = plan(oxr, _cds)
    _at = lambda resource_name: str -> any {
        (_cds[resource_name]?.Resource?.status?.atProvider) if resource_name in _cds else Undefined
    }
    _gke = _at("gke")
    _endpoint = _gke?.controlPlaneEndpointsConfig?.dnsEndpointConfig?.endpoint or ""
    _pools_up = all n in ["node-pool-default", "node-pool-ci"] {is_ready(_cds, n)}
    _sql = _at("cloud-sql")
    _gateway = _at("gateway-ip")?.address or ""
    _pid = _p.projectId
    _region = _spec.region
    _prefix = _spec?.prefix or "shl"
    _e = _p.emails

    # Tier-0 facts gitops substitutes (flux-system/cluster-identity), the
    # Pulumi stack's clusterIdentityValues; values not observed yet are omitted.
    _identity = {
        CLUSTER_NAME = _p.clusterName
        CLUSTER_RUNTIME = "gke"
        GCP_ADMIN_PROJECT = _pid
        GCP_REGION = _region
        GCP_BILLING_ACCOUNT = _spec.billingAccount
        GCP_PROJECT_PREFIX = _prefix
        if _spec.folders?.dev:
            DEV_FOLDER = "folders/${_spec.folders.dev}"
        XP_KSA = _p.crossplaneKsa
        XP_GSA_EMAIL = _e.crossplane
        ESO_GSA_EMAIL = _e.externalSecrets
        K8S_ADMIN_GROUP = _p.adminGroup
        K8S_DEVELOPER_GROUP = _p.developerGroup
        GRAFANA_GSA_EMAIL = _e.grafana
        if _gateway:
            GATEWAY_IP = _gateway
        OPENBAO_GSA_EMAIL = _e.openbao
        CI_IMAGE_REGISTRY = "${_region}-docker.pkg.dev/${_pid}/ci"
        CI_BUILDER_GSA_EMAIL = _e.ciBuilder
        NX_CACHE_STORAGE = "gs://${_pid}-nx-cache"
    }

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Mgmt"
        metadata.name = oxr.metadata.name
        status = {
            provider = "gcp"
            ready = _endpoint != "" and _pools_up
            projectId = _pid
            if _p.projectNumber:
                projectNumber = _p.projectNumber
            clusterName = _p.clusterName
            location = _p.zone
            if _endpoint:
                dnsEndpoint = _endpoint
            workloadPool = _p.workloadPool
            serviceAccounts = _e
            if _at("dns-zone")?.nameServers:
                dnsNameServers = _at("dns-zone").nameServers
            if _gateway:
                gatewayAddress = _gateway
            if _p.postgres and _sql?.connectionName:
                postgresConnectionName = _sql.connectionName
            if _p.postgres and _sql?.privateIpAddress:
                postgresPrivateIp = _sql.privateIpAddress
            clusterIdentity = _identity
            getCredentials = "gcloud container clusters get-credentials ${_p.clusterName} --location=${_p.zone} --project=${_pid} --dns-endpoint"
            pending = _p.pending
            "cloud-url" = "https://console.cloud.google.com/kubernetes/clusters/details/${_p.zone}/${_p.clusterName}?project=${_pid}"
        }
    }
}
