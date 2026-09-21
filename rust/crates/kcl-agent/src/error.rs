//! One error type for the agent loop, its tools and its HTTP front end.
//!
//! The split that matters is not the variant but what the loop does with it:
//! [`Error::Cluster`] and [`Error::Invalid`] are *tool-level* failures, handed
//! back to the model as a tool result so it can correct itself, while
//! [`Error::Model`], [`Error::Config`] and [`Error::StepLimit`] end the run.
//! Cluster failures keep [`kcl_operator::Error`]'s `reason`, so an agent
//! response and a `KclModule` status use the same vocabulary.

use axum::http::StatusCode;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The cluster said no, or a render did.
    #[error(transparent)]
    Cluster(#[from] kcl_operator::Error),

    /// The model endpoint failed: transport, a non-2xx reply, or a body that
    /// is not a chat completion.
    #[error("model request failed: {0}")]
    Model(String),

    /// Bad configuration, found before any request is sent.
    #[error("{0}")]
    Config(String),

    /// The model kept calling tools and never answered.
    #[error("no answer after {0} steps")]
    StepLimit(usize),

    /// The model called a tool with arguments that do not fit its schema, or
    /// asked for something the agent refuses to do.
    #[error("{0}")]
    Invalid(String),
}

impl Error {
    /// CamelCase, matching [`kcl_operator::Error::reason`].
    pub fn reason(&self) -> &'static str {
        match self {
            Error::Cluster(error) => error.reason(),
            Error::Model(_) => "ModelFailed",
            Error::Config(_) => "InvalidConfig",
            Error::StepLimit(_) => "StepLimitReached",
            Error::Invalid(_) => "InvalidArguments",
        }
    }

    /// A model that will not answer is a bad gateway, not a bad request; a
    /// run that never converges is unprocessable.
    pub fn status(&self) -> StatusCode {
        match self {
            Error::Cluster(error) => error.status(),
            Error::Model(_) => StatusCode::BAD_GATEWAY,
            Error::Config(_) => StatusCode::INTERNAL_SERVER_ERROR,
            Error::StepLimit(_) => StatusCode::UNPROCESSABLE_ENTITY,
            Error::Invalid(_) => StatusCode::BAD_REQUEST,
        }
    }

    /// Whether the loop can keep going after this: the model sees the failure
    /// and tries something else.
    pub fn is_tool_level(&self) -> bool {
        matches!(self, Error::Cluster(_) | Error::Invalid(_))
    }
}

impl From<kube::Error> for Error {
    fn from(error: kube::Error) -> Self {
        Error::Cluster(kcl_operator::Error::Kube(error))
    }
}

impl From<serde_json::Error> for Error {
    fn from(error: serde_json::Error) -> Self {
        Error::Invalid(format!("malformed JSON: {error}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cluster_failure_keeps_the_operators_reason_and_status() {
        let error = Error::Cluster(kcl_operator::Error::UnknownKind(
            "cloud.example.org/v1alpha1/Buckett".into(),
        ));
        assert_eq!(error.reason(), "UnknownKind");
        assert_eq!(error.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert!(error.is_tool_level());
    }

    #[test]
    fn a_model_failure_ends_the_run_and_blames_the_gateway() {
        let error = Error::Model("404: no such model".into());
        assert_eq!(error.reason(), "ModelFailed");
        assert_eq!(error.status(), StatusCode::BAD_GATEWAY);
        assert!(!error.is_tool_level());
    }

    #[test]
    fn a_step_limit_is_unprocessable_rather_than_a_server_fault() {
        let error = Error::StepLimit(20);
        assert_eq!(error.to_string(), "no answer after 20 steps");
        assert_eq!(error.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert!(!error.is_tool_level());
    }
}
