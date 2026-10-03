//! The loop: prompt, model turn, tool calls, repeat until the model answers
//! in prose or the step budget runs out.
//!
//! There is no conversation memory between runs and no streaming — one task
//! per call, the whole transcript returned at the end. What the model may do
//! is decided once, at the top, by [`RunRequest::approve`]: it picks the tool
//! set and it picks the half of the system prompt that tells the model which
//! mode it is in.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tracing::debug;

use kcl_operator::ResourceRef;

use crate::error::Error;
use crate::llm::{Llm, Message, ToolSpec};
use crate::tools::{Toolbox, WRITE_TOOLS, describe_error, render_result};

pub struct Agent {
    llm: Llm,
    toolbox: Toolbox,
}

/// One task. `approve` is the whole authorisation model: false means the
/// agent can look and dry-run but not write.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRequest {
    pub task: String,

    /// Namespace for objects the task does not qualify.
    #[serde(default = "default_namespace")]
    pub namespace: String,

    #[serde(default)]
    pub approve: bool,

    /// Model turns before the run is abandoned.
    #[serde(default = "default_max_steps")]
    pub max_steps: usize,
}

/// One tool call and what it returned, in the order they happened.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub tool: String,
    pub arguments: Value,
    pub result: Value,
    pub ok: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub answer: String,
    pub approved: bool,
    pub steps: Vec<Step>,
    /// Everything the run wrote or deleted. Empty unless `approve` was set.
    pub writes: Vec<ResourceRef>,
}

impl Agent {
    pub fn new(llm: Llm, toolbox: Toolbox) -> Self {
        Self { llm, toolbox }
    }

    pub fn toolbox(&self) -> &Toolbox {
        &self.toolbox
    }

    /// `observe` sees each step as it completes, so a CLI can print progress
    /// while the run is still going; the HTTP front end passes a no-op. It is
    /// `Send` because the returned future has to be.
    pub async fn run(
        &self,
        request: RunRequest,
        observe: &mut (dyn FnMut(&Step) + Send),
    ) -> Result<Run, Error> {
        if request.task.trim().is_empty() {
            return Err(Error::Invalid("task is empty".into()));
        }

        let tools = Toolbox::specs(request.approve);
        let mut messages = vec![
            Message::system(system_prompt(&request)),
            Message::user(request.task.clone()),
        ];
        let mut steps: Vec<Step> = Vec::new();
        let mut writes: Vec<ResourceRef> = Vec::new();
        // Smaller models sometimes end a turn with neither an answer nor a
        // tool call after a run of tool results. One retry with the tools
        // withdrawn forces prose; a second empty turn is the endpoint's
        // failure, not something more looping will fix.
        let mut nudged = false;

        for turn in 0..request.max_steps {
            let offered: &[ToolSpec] = if nudged { &[] } else { &tools };
            let reply = self.llm.chat(&messages, offered).await?;
            debug!(turn, calls = reply.tool_calls.len(), "model turn");

            if reply.tool_calls.is_empty() {
                let answer = reply.content.clone().unwrap_or_default();
                if answer.trim().is_empty() {
                    if nudged {
                        return Err(Error::Model("the model returned no answer".into()));
                    }
                    nudged = true;
                    messages.push(Message::user(
                        "Answer the task now, in plain text, from the tool results above.",
                    ));
                    continue;
                }
                return Ok(Run {
                    answer,
                    approved: request.approve,
                    steps,
                    writes,
                });
            }

            let calls = reply.tool_calls.clone();
            messages.push(reply);
            for call in calls {
                let tool = call.function.name;
                let arguments = call.function.arguments;
                let outcome = self
                    .toolbox
                    .call(request.approve, &tool, &arguments, &request.namespace)
                    .await;
                let (result, ok) = match outcome {
                    Ok(value) => (value, true),
                    Err(error) if error.is_tool_level() => {
                        (json!({"error": describe_error(&error)}), false)
                    }
                    // A model or configuration failure is not something the
                    // model can recover from by trying another tool.
                    Err(fatal) => return Err(fatal),
                };
                if ok && WRITE_TOOLS.contains(&tool.as_str())
                    && let Ok(reference) = serde_json::from_value::<ResourceRef>(result.clone())
                {
                    writes.push(reference);
                }
                messages.push(Message::tool(call.id, render_result(&result)));
                let step = Step {
                    tool,
                    arguments,
                    result,
                    ok,
                };
                observe(&step);
                steps.push(step);
            }
        }

        Err(Error::StepLimit(request.max_steps))
    }
}

/// The operating rules. Everything here is a rule the tools cannot enforce on
/// their own: which call to make first, what to do with a failing condition,
/// and what "propose" means when the write tools are simply absent.
pub fn system_prompt(request: &RunRequest) -> String {
    let mode = if request.approve {
        "- Mode: APPROVED. apply_resource and delete_resource are available. Apply only what a \
         dry run validated; after writing, re-read the object with get_resource and report its \
         conditions. Never delete anything the task did not name."
    } else {
        "- Mode: PROPOSE. You have no write tools. Finish with the exact objects to apply \
         (complete YAML) and the command that would apply them: `kclx agent ask --yes \"<this \
         task>\"`, or `kubectl apply -f -`."
    };
    format!(
        "You are kclx-agent, an operator for a Kubernetes cluster that runs Crossplane \
         composites (groups cloud.example.org and platform.example.org, rendered from KCL \
         packages) and KclModule objects (kclx.example.org/v1alpha1, a KCL package the kclx \
         operator renders and applies).\n\
         \n\
         Working rules:\n\
         - Call list_kinds before naming a kind you have not seen in this conversation, and \
         describe_kind before authoring or editing an object of that kind. Never invent fields: \
         every spec field you write must appear in describe_kind output.\n\
         - To diagnose a composite that is not Ready, call composed_resources and read the Synced \
         and Ready conditions of each composed object, then events on the composite. Report the \
         first failing condition's message verbatim.\n\
         - Composites choose their backend with \
         spec.crossplane.compositionSelector.matchLabels.provider (aws, azure, gcp, …) or \
         spec.crossplane.compositionRef.name; check describe_kind for which the kind expects.\n\
         - Before proposing or applying a KclModule, call preview_module with its source and \
         params; before proposing or applying any other object, call validate_resource with the \
         full object. Never skip the dry run.\n\
         - Namespace for objects that name none: {namespace}.\n\
         - Do not read Secrets; the tools refuse them.\n\
         {mode}\n\
         \n\
         Answer in plain text. When you propose an object, include it as a complete YAML \
         document.",
        namespace = request.namespace,
    )
}

fn default_namespace() -> String {
    "default".to_string()
}

fn default_max_steps() -> usize {
    20
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(approve: bool) -> RunRequest {
        RunRequest {
            task: "list buckets".into(),
            namespace: "apps".into(),
            approve,
            max_steps: 20,
        }
    }

    #[test]
    fn a_request_needs_only_a_task() {
        let request: RunRequest = serde_json::from_value(json!({"task": "how many modules?"}))
            .expect("a bare task is a valid request");
        assert_eq!(request.namespace, "default");
        assert_eq!(request.max_steps, 20);
        assert!(!request.approve, "runs never write unless asked to");
    }

    #[test]
    fn the_step_budget_is_camel_case_on_the_wire() {
        let request: RunRequest =
            serde_json::from_value(json!({"task": "x", "maxSteps": 3, "approve": true})).unwrap();
        assert_eq!(request.max_steps, 3);
        assert!(request.approve);
    }

    #[test]
    fn the_propose_prompt_names_the_approval_command_and_the_approved_one_does_not() {
        let propose = system_prompt(&request(false));
        assert!(propose.contains("Mode: PROPOSE"));
        assert!(propose.contains("kclx agent ask --yes"));

        let approved = system_prompt(&request(true));
        assert!(approved.contains("Mode: APPROVED"));
        assert!(!approved.contains("--yes"));
    }

    #[test]
    fn the_prompt_tells_the_model_which_namespace_unqualified_objects_land_in() {
        assert!(system_prompt(&request(false)).contains("objects that name none: apps."));
    }
}
