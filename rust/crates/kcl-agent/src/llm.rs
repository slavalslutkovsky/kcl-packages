//! A chat client for the OpenAI-compatible `POST {base}/chat/completions`
//! endpoint, which is what OpenAI, Ollama, vLLM, llama.cpp and every gateway
//! in between speak. Tool calling only, no streaming: the agent needs whole
//! tool calls before it can run anything, and a run is a batch job.
//!
//! The one incompatibility worth handling is `function.arguments`: OpenAI
//! sends a JSON *string*, several local servers send an object. Both are
//! accepted, and the string form is always sent back.

use std::time::Duration;

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Value, json};

use crate::error::Error;

/// Where the model lives. `base_url` is the endpoint root that has
/// `/chat/completions` under it — `https://api.openai.com/v1`,
/// `http://localhost:11434/v1`.
#[derive(Clone, Debug)]
pub struct LlmConfig {
    pub base_url: String,
    pub api_key: Option<String>,
    pub model: String,
}

pub struct Llm {
    http: reqwest::Client,
    base_url: String,
    api_key: Option<String>,
    model: String,
}

/// Hand-written so a key never reaches a log line or a panic message.
impl std::fmt::Debug for Llm {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Llm")
            .field("base_url", &self.base_url)
            .field("model", &self.model)
            .field("api_key", &self.api_key.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

impl Llm {
    pub fn new(config: LlmConfig) -> Result<Self, Error> {
        if config.model.trim().is_empty() {
            return Err(Error::Config(
                "no model: pass --model or set KCLX_LLM_MODEL".into(),
            ));
        }
        let base_url = config.base_url.trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(Error::Config("no model base URL".into()));
        }
        let http = reqwest::Client::builder()
            // A tool-calling turn over a large cluster listing is slow, but a
            // run that hangs forever is worse than one that fails.
            .timeout(Duration::from_secs(120))
            .build()
            .map_err(|error| Error::Config(format!("building the HTTP client: {error}")))?;
        Ok(Self {
            http,
            base_url,
            api_key: config.api_key.filter(|key| !key.trim().is_empty()),
            model: config.model,
        })
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    /// One turn. `tools` empty means "answer in prose"; otherwise the model
    /// may call any of them.
    pub async fn chat(&self, messages: &[Message], tools: &[ToolSpec]) -> Result<Message, Error> {
        let mut body = json!({
            "model": self.model,
            "messages": messages,
            // Deterministic: this is an operator, not a writing assistant.
            "temperature": 0,
        });
        if !tools.is_empty() {
            let map = body.as_object_mut().expect("the body is an object");
            map.insert("tools".into(), serde_json::to_value(tools)?);
            map.insert("tool_choice".into(), json!("auto"));
        }

        let url = format!("{}/chat/completions", self.base_url);
        let mut request = self.http.post(&url).json(&body);
        if let Some(key) = &self.api_key {
            request = request.bearer_auth(key);
        }
        let response = request
            .send()
            .await
            .map_err(|error| Error::Model(format!("{url}: {error}")))?;

        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|error| Error::Model(format!("reading the reply: {error}")))?;
        if !status.is_success() {
            return Err(Error::Model(format!(
                "{}: {}",
                status.as_u16(),
                truncate(&text, 2000)
            )));
        }

        let parsed: ChatResponse = serde_json::from_str(&text)
            .map_err(|error| Error::Model(format!("{error}: {}", truncate(&text, 2000))))?;
        parsed
            .choices
            .into_iter()
            .next()
            .map(|choice| choice.message)
            .ok_or_else(|| Error::Model("no choices in the reply".into()))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

/// One chat message. `tool_calls` is omitted when empty and `content` when
/// absent, because OpenAI rejects both as nulls/empty arrays on the way back.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Message {
    pub role: Role,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ToolCall>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

impl Message {
    pub fn system(content: impl Into<String>) -> Self {
        Self::text(Role::System, content)
    }

    pub fn user(content: impl Into<String>) -> Self {
        Self::text(Role::User, content)
    }

    /// The reply to one tool call, addressed by the id the model gave it.
    pub fn tool(tool_call_id: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: Role::Tool,
            content: Some(content.into()),
            tool_calls: Vec::new(),
            tool_call_id: Some(tool_call_id.into()),
        }
    }

    fn text(role: Role, content: impl Into<String>) -> Self {
        Self {
            role,
            content: Some(content.into()),
            tool_calls: Vec::new(),
            tool_call_id: None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ToolCall {
    pub id: String,
    #[serde(rename = "type", default = "function_type")]
    pub kind: String,
    pub function: FunctionCall,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FunctionCall {
    pub name: String,
    /// Parsed either way; always serialized as the JSON string OpenAI expects.
    #[serde(
        deserialize_with = "string_or_value",
        serialize_with = "as_json_string"
    )]
    pub arguments: Value,
}

/// What the model is offered. Static strs because the set is compiled in.
#[derive(Clone, Debug, Serialize)]
pub struct ToolSpec {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub function: FunctionSpec,
}

impl ToolSpec {
    pub fn new(name: &'static str, description: &'static str, parameters: Value) -> Self {
        Self {
            kind: "function",
            function: FunctionSpec {
                name,
                description,
                parameters,
            },
        }
    }

    pub fn name(&self) -> &'static str {
        self.function.name
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct FunctionSpec {
    pub name: &'static str,
    pub description: &'static str,
    pub parameters: Value,
}

#[derive(Debug, Deserialize)]
struct ChatResponse {
    #[serde(default)]
    choices: Vec<Choice>,
}

#[derive(Debug, Deserialize)]
struct Choice {
    message: Message,
}

fn function_type() -> String {
    "function".to_string()
}

fn string_or_value<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Value, D::Error> {
    match Value::deserialize(deserializer)? {
        // An empty string means "no arguments", which some servers send for
        // zero-parameter tools.
        Value::String(text) if text.trim().is_empty() => Ok(json!({})),
        Value::String(text) => serde_json::from_str(&text).map_err(D::Error::custom),
        other => Ok(other),
    }
}

fn as_json_string<S: Serializer>(value: &Value, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&value.to_string())
}

/// Byte-bounded but never mid-character, and it says so when it cuts.
fn truncate(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut end = limit;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &text[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_deserialize_from_a_json_string_and_from_an_object_alike() {
        let expected = json!({"apiVersion": "v1", "kind": "ConfigMap"});
        let as_string: FunctionCall = serde_json::from_value(json!({
            "name": "get_resource",
            "arguments": "{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\"}",
        }))
        .unwrap();
        let as_object: FunctionCall = serde_json::from_value(json!({
            "name": "get_resource",
            "arguments": {"apiVersion": "v1", "kind": "ConfigMap"},
        }))
        .unwrap();
        assert_eq!(as_string.arguments, expected);
        assert_eq!(as_object.arguments, expected);
    }

    #[test]
    fn empty_arguments_mean_no_arguments_rather_than_a_parse_failure() {
        let call: FunctionCall =
            serde_json::from_value(json!({"name": "list_kinds", "arguments": ""})).unwrap();
        assert_eq!(call.arguments, json!({}));
    }

    #[test]
    fn arguments_serialize_back_as_a_json_string() {
        let call = FunctionCall {
            name: "list_kinds".into(),
            arguments: json!({"limit": 5}),
        };
        let encoded = serde_json::to_value(&call).unwrap();
        assert_eq!(encoded["arguments"], json!("{\"limit\":5}"));
    }

    #[test]
    fn a_message_without_tool_calls_omits_the_field() {
        let encoded = serde_json::to_value(Message::user("hi")).unwrap();
        assert_eq!(encoded, json!({"role": "user", "content": "hi"}));
    }

    #[test]
    fn a_tool_reply_carries_the_call_id_it_answers() {
        let encoded = serde_json::to_value(Message::tool("call_1", "{}")).unwrap();
        assert_eq!(
            encoded,
            json!({"role": "tool", "content": "{}", "tool_call_id": "call_1"})
        );
    }

    #[test]
    fn a_model_is_required_before_any_request_is_attempted() {
        let error = Llm::new(LlmConfig {
            base_url: "http://localhost:11434/v1".into(),
            api_key: None,
            model: "  ".into(),
        })
        .unwrap_err();
        assert_eq!(error.reason(), "InvalidConfig");
    }

    #[test]
    fn a_trailing_slash_on_the_base_url_does_not_double_up() {
        let llm = Llm::new(LlmConfig {
            base_url: "http://localhost:11434/v1/".into(),
            api_key: Some("  ".into()),
            model: "qwen2.5:7b".into(),
        })
        .unwrap();
        assert_eq!(llm.base_url, "http://localhost:11434/v1");
        // A blank key is no key: OpenAI-compatible local servers want no header.
        assert!(llm.api_key.is_none());
    }
}
