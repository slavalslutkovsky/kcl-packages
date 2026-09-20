//! One error type for the controller, the CLI and the HTTP API, because all
//! three report the same failures: the render blew up, the cluster said no,
//! or the rendered objects are not applicable.

use axum::http::StatusCode;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// KCL failed to compile or evaluate.
    #[error("render failed: {0:#}")]
    Render(#[source] anyhow::Error),

    /// The render succeeded but produced something that cannot be applied.
    #[error("{0}")]
    Invalid(String),

    /// The cluster does not serve this kind — a CRD that is not installed,
    /// or a typo in `apiVersion`.
    #[error("the cluster serves no kind {0}")]
    UnknownKind(String),

    #[error("{kind} {name} not found")]
    NotFound { kind: &'static str, name: String },

    #[error(transparent)]
    Kube(#[from] kube::Error),

    #[error(transparent)]
    Discovery(#[from] kube::core::gvk::ParseGroupVersionError),

    /// A blocking render panicked or was cancelled.
    #[error("render task failed: {0}")]
    Task(#[from] tokio::task::JoinError),
}

impl Error {
    /// The `reason` of the `Ready` condition. CamelCase, because that is what
    /// the convention (and every consumer that switches on it) expects.
    pub fn reason(&self) -> &'static str {
        match self {
            Error::Render(_) => "RenderFailed",
            Error::Invalid(_) => "InvalidRender",
            Error::UnknownKind(_) => "UnknownKind",
            Error::NotFound { .. } => "NotFound",
            Error::Kube(_) => "ApplyFailed",
            Error::Discovery(_) => "InvalidRender",
            Error::Task(_) => "InternalError",
        }
    }

    /// A bad `spec.source` is the caller's fault; a broken API server is not.
    pub fn status(&self) -> StatusCode {
        match self {
            Error::Render(_) | Error::Invalid(_) | Error::Discovery(_) => StatusCode::BAD_REQUEST,
            Error::UnknownKind(_) => StatusCode::UNPROCESSABLE_ENTITY,
            Error::NotFound { .. } => StatusCode::NOT_FOUND,
            Error::Kube(kube::Error::Api(response)) => {
                StatusCode::from_u16(response.code).unwrap_or(StatusCode::BAD_GATEWAY)
            }
            Error::Kube(_) => StatusCode::BAD_GATEWAY,
            Error::Task(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}

/// `kube` reports "no such object" as a 404 inside a transport error; the
/// difference matters to every caller, so it is lifted into its own variant.
pub fn not_found(kind: &'static str, name: impl Into<String>, error: kube::Error) -> Error {
    match &error {
        kube::Error::Api(response) if response.code == 404 => Error::NotFound {
            kind,
            name: name.into(),
        },
        _ => Error::Kube(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::core::Status;

    fn api_error(code: u16) -> kube::Error {
        kube::Error::Api(Box::new(Status {
            code,
            message: "nope".into(),
            reason: "Conflict".into(),
            ..Status::default()
        }))
    }

    #[test]
    fn a_404_from_the_api_server_becomes_a_not_found() {
        let error = not_found("KclModule", "demo", api_error(404));
        assert!(matches!(error, Error::NotFound { .. }));
        assert_eq!(error.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn other_api_errors_keep_their_status_and_stay_kube_errors() {
        let error = not_found("KclModule", "demo", api_error(409));
        assert!(matches!(error, Error::Kube(_)));
        assert_eq!(error.status(), StatusCode::CONFLICT);
        assert_eq!(error.reason(), "ApplyFailed");
    }

    #[test]
    fn a_render_failure_is_the_callers_fault_not_the_clusters() {
        let error = Error::Render(anyhow::anyhow!("assert failed"));
        assert_eq!(error.status(), StatusCode::BAD_REQUEST);
        assert_eq!(error.reason(), "RenderFailed");
    }
}
