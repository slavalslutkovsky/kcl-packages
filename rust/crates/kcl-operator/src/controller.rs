//! The reconcile loop: watch `KclModule`s, render each one, apply what it
//! produced, prune what it no longer produces, and say so in the status.
//!
//! Drift is corrected on `spec.interval`, not by watching the applied
//! objects. Watching them would mean a dynamic watch per kind a render
//! happens to emit — started and stopped as renders change — for a
//! correction that a re-apply already performs. The cost is bounded by the
//! interval; the complexity of the alternative is not.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context as _, Result};
use futures::StreamExt;
use k8s_openapi::apimachinery::pkg::apis::meta::v1::Time;
use kcl_render::Engine;
use kube::api::{Api, ListParams, Patch, PatchParams};
use kube::runtime::controller::{Action, Controller};
use kube::runtime::{finalizer, watcher};
use kube::{Client, ResourceExt};
use serde_json::json;
use tracing::{info, warn};

use crate::apply::Applier;
use crate::crd::{FINALIZER, KclModule, KclModuleStatus, parse_interval, ready_condition};
use crate::crd::{READY, set_condition};
use crate::error::Error;
use crate::plan;
use crate::service::render;

pub struct Options {
    /// Watch one namespace, or every namespace when absent.
    pub namespace: Option<String>,
    /// Field manager for both the applied objects and the status writes.
    pub field_manager: String,
    /// Backoff after a failed reconcile. The successful path requeues on
    /// `spec.interval` instead.
    pub error_requeue: Duration,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            namespace: None,
            field_manager: "kclx".to_string(),
            error_requeue: Duration::from_secs(30),
        }
    }
}

struct Context {
    client: Client,
    engine: Arc<Engine>,
    applier: Applier,
    options: Options,
}

/// Run until the process is signalled. Returns an error only for problems
/// that no amount of retrying fixes — a missing CRD, or no cluster.
pub async fn run(client: Client, engine: Arc<Engine>, options: Options) -> Result<()> {
    let modules: Api<KclModule> = match &options.namespace {
        Some(namespace) => Api::namespaced(client.clone(), namespace),
        None => Api::all(client.clone()),
    };

    // Fail fast and legibly: without this, a missing CRD is an endless
    // stream of watcher errors in the log and a controller that never
    // reconciles anything.
    modules.list(&ListParams::default().limit(1)).await.context(
        "listing KclModules; install the CRD first (`kclx operator crd | kubectl apply -f -`)",
    )?;

    let context = Arc::new(Context {
        applier: Applier::new(client.clone(), options.field_manager.clone()),
        client,
        engine,
        options,
    });

    info!(
        namespace = context.options.namespace.as_deref().unwrap_or("*"),
        "watching KclModules"
    );

    Controller::new(modules, watcher::Config::default())
        .shutdown_on_signal()
        .run(reconcile, error_policy, context)
        .for_each(|outcome| async move {
            match outcome {
                Ok((object, _)) => info!(module = %object.name, "reconciled"),
                // Already reported by `error_policy` with the module it
                // belongs to; this arm also catches watcher failures.
                Err(error) => warn!(%error, "reconcile failed"),
            }
        })
        .await;

    Ok(())
}

async fn reconcile(module: Arc<KclModule>, context: Arc<Context>) -> Result<Action, Error> {
    let namespace = module
        .namespace()
        .ok_or_else(|| Error::Invalid("KclModule has no namespace".into()))?;
    let api: Api<KclModule> = Api::namespaced(context.client.clone(), &namespace);

    finalizer(&api, FINALIZER, module, |event| async {
        match event {
            finalizer::Event::Apply(module) => context.apply(module).await,
            finalizer::Event::Cleanup(module) => context.cleanup(module).await,
        }
    })
    .await
    .map_err(|error| match error {
        finalizer::Error::ApplyFailed(inner) | finalizer::Error::CleanupFailed(inner) => inner,
        finalizer::Error::AddFinalizer(e) | finalizer::Error::RemoveFinalizer(e) => Error::Kube(e),
        other => Error::Invalid(other.to_string()),
    })
}

fn error_policy(module: Arc<KclModule>, error: &Error, context: Arc<Context>) -> Action {
    warn!(module = %module.label_value(), %error, "reconcile failed");
    Action::requeue(context.options.error_requeue)
}

impl Context {
    async fn apply(&self, module: Arc<KclModule>) -> Result<Action, Error> {
        if module.spec.suspend {
            self.write_status(&module, |status| {
                set_condition(
                    &mut status.conditions,
                    suspended_condition(module.metadata.generation),
                );
            })
            .await?;
            // Nothing to requeue for: the next spec change wakes the watch.
            return Ok(Action::await_change());
        }

        let interval = parse_interval(&module.spec.interval)
            .map_err(|e| Error::Invalid(format!("spec.interval: {e}")))?;

        match self.render_and_apply(&module).await {
            Ok(outcome) => {
                let Outcome {
                    inventory,
                    pruned,
                    digest,
                } = outcome;
                let message = summary(inventory.len(), pruned);
                info!(module = %module.label_value(), %message, "applied");
                self.write_status(&module, |status| {
                    status.inventory = inventory;
                    // The timestamp follows the *content*, not the reconcile:
                    // stamping it every time makes every status write a real
                    // change, and a status write we watch is a reconcile
                    // trigger. See `write_status`.
                    if status.last_applied_hash.as_deref() != Some(digest.as_str()) {
                        status.last_applied_time = Some(now());
                    }
                    status.last_applied_hash = Some(digest);
                    set_condition(
                        &mut status.conditions,
                        ready_condition(
                            "True",
                            "Applied",
                            message,
                            module.metadata.generation,
                            now(),
                        ),
                    );
                })
                .await?;
                Ok(Action::requeue(interval))
            }
            Err(error) => {
                // The inventory is deliberately left alone: a failed render
                // must not make the operator forget what it already owns.
                self.write_status(&module, |status| {
                    set_condition(
                        &mut status.conditions,
                        ready_condition(
                            "False",
                            error.reason(),
                            error.to_string(),
                            module.metadata.generation,
                            now(),
                        ),
                    );
                })
                .await?;
                Err(error)
            }
        }
    }

    async fn render_and_apply(&self, module: &KclModule) -> Result<Outcome, Error> {
        let label = module.label_value();
        let rendered = render(self.engine.clone(), module.spec.clone()).await?;
        let planned = plan::plan(&rendered.items, &label)?;
        let targets = self
            .applier
            .resolve(planned, module.target_namespace())
            .await?;
        let inventory = self.applier.apply(&targets).await?;

        let previous = module
            .status
            .as_ref()
            .map(|status| status.inventory.clone())
            .unwrap_or_default();
        let stale = plan::stale(&previous, &inventory);
        let pruned = if module.spec.prune && !stale.is_empty() {
            let deleted = self.applier.delete(&stale).await?;
            for reference in &deleted {
                info!(module = %label, resource = %reference, "pruned");
            }
            deleted.len()
        } else {
            0
        };

        Ok(Outcome {
            inventory,
            pruned,
            digest: plan::digest(&rendered.items),
        })
    }

    async fn cleanup(&self, module: Arc<KclModule>) -> Result<Action, Error> {
        let inventory = module
            .status
            .as_ref()
            .map(|status| status.inventory.clone())
            .unwrap_or_default();
        if !inventory.is_empty() {
            let deleted = self.applier.delete(&inventory).await?;
            info!(
                module = %module.label_value(),
                deleted = deleted.len(),
                "deleted the inventory"
            );
        }
        Ok(Action::await_change())
    }

    /// Status is written with a merge patch on the status subresource: the
    /// spec is the user's, the status is ours, and a merge patch cannot
    /// accidentally carry one into the other.
    ///
    /// A write that changes nothing is skipped, and that is not an
    /// optimisation. The controller watches its own objects, so every status
    /// write it makes schedules another reconcile; if each reconcile writes
    /// a status that differs — a fresh timestamp is enough — the pair is a
    /// hot loop that only the API server's second-granularity timestamps
    /// ever damped.
    async fn write_status(
        &self,
        module: &KclModule,
        edit: impl FnOnce(&mut KclModuleStatus),
    ) -> Result<(), Error> {
        let mut status = module.status.clone().unwrap_or_default();
        status.observed_generation = module.metadata.generation;
        edit(&mut status);
        if module.status.as_ref() == Some(&status) {
            return Ok(());
        }
        let api: Api<KclModule> = Api::namespaced(
            self.client.clone(),
            &module.namespace().unwrap_or_else(|| "default".into()),
        );
        api.patch_status(
            &module.name_any(),
            &PatchParams::default(),
            &Patch::Merge(json!({ "status": status })),
        )
        .await?;
        Ok(())
    }
}

struct Outcome {
    inventory: Vec<crate::crd::ResourceRef>,
    pruned: usize,
    digest: String,
}

fn suspended_condition(generation: Option<i64>) -> k8s_openapi::apimachinery::pkg::apis::meta::v1::Condition {
    k8s_openapi::apimachinery::pkg::apis::meta::v1::Condition {
        type_: READY.to_string(),
        status: "Unknown".to_string(),
        reason: "Suspended".to_string(),
        message: "reconciliation is suspended by spec.suspend".to_string(),
        observed_generation: generation,
        last_transition_time: now(),
    }
}

fn summary(applied: usize, pruned: usize) -> String {
    let objects = if applied == 1 { "object" } else { "objects" };
    match pruned {
        0 => format!("applied {applied} {objects}"),
        n => format!("applied {applied} {objects}, pruned {n}"),
    }
}

/// `k8s-openapi` 0.28 models `metav1.Time` as a jiff `Timestamp`, and
/// re-exports jiff so callers need no dependency of their own.
fn now() -> Time {
    Time(k8s_openapi::jiff::Timestamp::now())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_summary_counts_and_only_mentions_pruning_when_it_happened() {
        assert_eq!(summary(1, 0), "applied 1 object");
        assert_eq!(summary(3, 0), "applied 3 objects");
        assert_eq!(summary(3, 2), "applied 3 objects, pruned 2");
    }
}
