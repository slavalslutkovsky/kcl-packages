//! Everything that touches rendered objects in the cluster: kind discovery,
//! server-side apply, and deletion.
//!
//! **No owner references.** The obvious cleanup mechanism does not survive
//! contact with what a KCL package renders: a namespaced `KclModule` may not
//! own a cluster-scoped object (the garbage collector treats such a reference
//! as invalid and deletes the dependent), nor an object in another namespace.
//! Rather than run two mechanisms — owner references for the easy objects and
//! an inventory for the rest — everything is tracked in `status.inventory`
//! and deleted from it, which is also what makes pruning a render that lost
//! an object work at all.

use std::collections::HashMap;
use std::sync::Mutex;

use kube::api::{Api, ApiResource, DeleteParams, DynamicObject, Patch, PatchParams};
use kube::core::GroupVersionKind;
use kube::discovery::Scope;
use kube::{Client, discovery};

use crate::crd::ResourceRef;
use crate::error::Error;
use crate::plan::{self, Planned};

/// A planned object whose kind has been resolved against the API server.
#[derive(Clone, Debug)]
pub struct Target {
    pub reference: ResourceRef,
    resource: ApiResource,
    namespaced: bool,
    object: DynamicObject,
}

pub struct Applier {
    client: Client,
    field_manager: String,
    /// Discovery is an HTTP round trip per kind; a module re-applies the same
    /// handful of kinds every interval, so the resolution is cached for the
    /// life of the process. Cost of staleness: a kind that changes its scope
    /// or preferred version needs a restart, which no real API does without
    /// a version bump.
    kinds: Mutex<HashMap<GroupVersionKind, (ApiResource, bool)>>,
}

impl Applier {
    pub fn new(client: Client, field_manager: impl Into<String>) -> Self {
        Self {
            client,
            field_manager: field_manager.into(),
            kinds: Mutex::new(HashMap::new()),
        }
    }

    /// Resolve every kind and settle every namespace. Read-only: this is also
    /// what the dry-run preview behind `POST /v1/render` uses, which is why
    /// it is separate from [`Applier::apply`].
    pub async fn resolve(
        &self,
        planned: Vec<Planned>,
        default_namespace: &str,
    ) -> Result<Vec<Target>, Error> {
        let mut targets = Vec::with_capacity(planned.len());
        for Planned { gvk, mut object } in planned {
            let (resource, namespaced) = self.kind(&gvk).await?;
            plan::scope(&mut object, namespaced, default_namespace);
            targets.push(Target {
                reference: plan::reference(&object),
                resource,
                namespaced,
                object,
            });
        }
        Ok(targets)
    }

    /// Server-side apply, forced. Forced because the operator is the declared
    /// owner of these fields: without it, a human `kubectl edit` takes over a
    /// field and every later reconcile fails with a conflict instead of
    /// correcting the drift.
    pub async fn apply(&self, targets: &[Target]) -> Result<Vec<ResourceRef>, Error> {
        let params = PatchParams::apply(&self.field_manager).force();
        let mut applied = Vec::with_capacity(targets.len());
        for target in targets {
            let api = self.api(target);
            let name = target.reference.name.clone();
            api.patch(&name, &params, &Patch::Apply(&target.object))
                .await
                .map_err(|e| {
                    Error::Kube(match e {
                        // The object name is nowhere in the API server's
                        // message for most failures.
                        kube::Error::Api(mut response) => {
                            response.message =
                                format!("applying {}: {}", target.reference, response.message);
                            kube::Error::Api(response)
                        }
                        other => other,
                    })
                })?;
            applied.push(target.reference.clone());
        }
        Ok(applied)
    }

    /// Delete each reference, tolerating the ones that are already gone —
    /// a prune re-run, or a namespace that took its contents with it.
    /// Returns what was actually deleted.
    pub async fn delete(&self, references: &[ResourceRef]) -> Result<Vec<ResourceRef>, Error> {
        let mut deleted = Vec::new();
        for reference in references {
            let gvk = plan::gvk_of(&reference.api_version, &reference.kind)
                .map_err(|e| Error::Invalid(format!("inventory entry {reference}: {e}")))?;
            let (resource, namespaced) = match self.kind(&gvk).await {
                Ok(kind) => kind,
                // The CRD went away before its instances did; nothing to
                // delete, and blocking cleanup on it would strand the module.
                Err(Error::UnknownKind(_)) => continue,
                Err(other) => return Err(other),
            };
            let api: Api<DynamicObject> = match (namespaced, reference.namespace.as_deref()) {
                (true, Some(namespace)) => {
                    Api::namespaced_with(self.client.clone(), namespace, &resource)
                }
                _ => Api::all_with(self.client.clone(), &resource),
            };
            match api.delete(&reference.name, &DeleteParams::default()).await {
                Ok(_) => deleted.push(reference.clone()),
                Err(kube::Error::Api(response)) if response.code == 404 => {}
                Err(other) => return Err(Error::Kube(other)),
            }
        }
        Ok(deleted)
    }

    fn api(&self, target: &Target) -> Api<DynamicObject> {
        match (target.namespaced, target.reference.namespace.as_deref()) {
            (true, Some(namespace)) => {
                Api::namespaced_with(self.client.clone(), namespace, &target.resource)
            }
            _ => Api::all_with(self.client.clone(), &target.resource),
        }
    }

    async fn kind(&self, gvk: &GroupVersionKind) -> Result<(ApiResource, bool), Error> {
        if let Some(hit) = self.kinds.lock().expect("kind cache").get(gvk) {
            return Ok(hit.clone());
        }
        let (resource, capabilities) = discovery::pinned_kind(&self.client, gvk)
            .await
            .map_err(|error| match error {
                kube::Error::Api(response) if response.code == 404 => {
                    Error::UnknownKind(format!("{}/{}", gvk.api_version(), gvk.kind))
                }
                other => Error::Kube(other),
            })?;
        let resolved = (resource, capabilities.scope == Scope::Namespaced);
        self.kinds
            .lock()
            .expect("kind cache")
            .insert(gvk.clone(), resolved.clone());
        Ok(resolved)
    }
}
