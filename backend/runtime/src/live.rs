use std::{
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use postgres::{Client, NoTls};

use crate::{
    http::{RuntimeHttpConfig, RuntimeHttpService},
    postgres::{
        PostgresDecisionCommitter, PostgresRequestTalkTurnSnapshotLoader,
        ProcessRequestTalkTurnKernelWorker, SnapshotPolicyConfig,
    },
    routes::SelfHostedRouteService,
    websocket_audit::PostgresWebSocketAuthorizationFactSink,
    websocket_cluster::ClusterWebSocketAuthority,
    websocket_network::AppCompatibleWebSocketHub,
};

pub type LiveRuntimeHttpService = RuntimeHttpService<
    PostgresRequestTalkTurnSnapshotLoader,
    ProcessRequestTalkTurnKernelWorker,
    PostgresDecisionCommitter,
>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LiveRuntimeConfig {
    pub bind_addr: SocketAddr,
    pub database_url: String,
    pub repo_root: PathBuf,
    pub snapshot_built_at_ms: i64,
    pub kernel_deadline: Duration,
    pub runtime_id: String,
    pub websocket_mode: LiveWebSocketMode,
    pub websocket_owner_ttl_ms: i64,
    pub policy: SnapshotPolicyConfig,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LiveWebSocketMode {
    SingleInstance,
    ClusteredSingleActive,
}

#[derive(Debug, thiserror::Error)]
pub enum LiveRuntimeConfigError {
    #[error("missing environment variable `{0}`")]
    MissingEnv(&'static str),
    #[error("environment variable `{name}` was invalid: {message}")]
    InvalidEnv { name: &'static str, message: String },
}

#[derive(Debug, thiserror::Error)]
pub enum LiveRuntimeBuildError {
    #[error("failed to connect to runtime Postgres: {0}")]
    Postgres(#[from] postgres::Error),
}

impl LiveRuntimeConfig {
    pub fn from_env() -> Result<Self, LiveRuntimeConfigError> {
        Self::from_values(
            required_env("TURBO_RUNTIME_DATABASE_URL")?,
            optional_env("TURBO_RUNTIME_BIND"),
            optional_env("TURBO_REPO_ROOT"),
            optional_env("TURBO_RUNTIME_SNAPSHOT_BUILT_AT_MS"),
            optional_env("TURBO_KERNEL_DEADLINE_MS"),
            optional_env("TURBO_RUNTIME_ID"),
            optional_env("TURBO_RUNTIME_WEBSOCKET_MODE"),
            optional_env("TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS"),
        )
    }

    pub fn from_values(
        database_url: String,
        bind_addr: Option<String>,
        repo_root: Option<String>,
        snapshot_built_at_ms: Option<String>,
        kernel_deadline_ms: Option<String>,
        runtime_id: Option<String>,
        websocket_mode: Option<String>,
        websocket_owner_ttl_ms: Option<String>,
    ) -> Result<Self, LiveRuntimeConfigError> {
        let bind_addr = bind_addr
            .unwrap_or_else(|| "127.0.0.1:8091".to_owned())
            .parse()
            .map_err(|err| LiveRuntimeConfigError::InvalidEnv {
                name: "TURBO_RUNTIME_BIND",
                message: format!("{err}"),
            })?;
        let repo_root = PathBuf::from(repo_root.unwrap_or_else(|| ".".to_owned()));
        let snapshot_built_at_ms = snapshot_built_at_ms
            .map(|value| parse_i64_env("TURBO_RUNTIME_SNAPSHOT_BUILT_AT_MS", &value))
            .transpose()?
            .unwrap_or(10_000);
        let kernel_deadline_ms = kernel_deadline_ms
            .map(|value| parse_u64_env("TURBO_KERNEL_DEADLINE_MS", &value))
            .transpose()?
            .unwrap_or(20_000);
        let runtime_id = runtime_id.unwrap_or_else(|| "runtime-single".to_owned());
        if runtime_id.is_empty() {
            return Err(LiveRuntimeConfigError::InvalidEnv {
                name: "TURBO_RUNTIME_ID",
                message: "must not be empty".to_owned(),
            });
        }
        let websocket_mode = parse_websocket_mode(websocket_mode)?;
        let websocket_owner_ttl_ms = websocket_owner_ttl_ms
            .map(|value| parse_i64_env("TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS", &value))
            .transpose()?
            .unwrap_or(15_000);
        if websocket_owner_ttl_ms <= 0 {
            return Err(LiveRuntimeConfigError::InvalidEnv {
                name: "TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS",
                message: "must be positive".to_owned(),
            });
        }
        Ok(Self {
            bind_addr,
            database_url,
            repo_root,
            snapshot_built_at_ms,
            kernel_deadline: Duration::from_millis(kernel_deadline_ms),
            runtime_id,
            websocket_mode,
            websocket_owner_ttl_ms,
            policy: SnapshotPolicyConfig::default(),
        })
    }
}

pub fn build_live_http_service(
    config: &LiveRuntimeConfig,
) -> Result<LiveRuntimeHttpService, LiveRuntimeBuildError> {
    let snapshot_client = Client::connect(&config.database_url, NoTls)?;
    let committer_client = Client::connect(&config.database_url, NoTls)?;
    let snapshot_loader = PostgresRequestTalkTurnSnapshotLoader::new(
        snapshot_client,
        config.policy.clone(),
        config.snapshot_built_at_ms,
    );
    let kernel_worker =
        ProcessRequestTalkTurnKernelWorker::new(&config.repo_root, config.kernel_deadline);
    let committer = PostgresDecisionCommitter::new(committer_client);
    Ok(RuntimeHttpService::new_with_config(
        SelfHostedRouteService::with_committer(snapshot_loader, kernel_worker, committer),
        RuntimeHttpConfig::live_from_env(),
    ))
}

pub fn build_live_websocket_hub(
    config: &LiveRuntimeConfig,
) -> Result<AppCompatibleWebSocketHub, LiveRuntimeBuildError> {
    let authorization_fact_client = Client::connect(&config.database_url, NoTls)?;
    let authorization_fact_sink = Arc::new(PostgresWebSocketAuthorizationFactSink::new(
        authorization_fact_client,
    ));
    Ok(match config.websocket_mode {
        LiveWebSocketMode::SingleInstance => {
            AppCompatibleWebSocketHub::with_authorization_fact_sink(authorization_fact_sink)
        }
        LiveWebSocketMode::ClusteredSingleActive => {
            AppCompatibleWebSocketHub::with_authorization_fact_sink_and_cluster_owner(
                authorization_fact_sink,
                config.runtime_id.clone(),
                Arc::new(Mutex::new(ClusterWebSocketAuthority::default())),
                config.websocket_owner_ttl_ms,
            )
        }
    })
}

fn required_env(name: &'static str) -> Result<String, LiveRuntimeConfigError> {
    std::env::var(name).map_err(|_| LiveRuntimeConfigError::MissingEnv(name))
}

fn optional_env(name: &'static str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn parse_i64_env(name: &'static str, value: &str) -> Result<i64, LiveRuntimeConfigError> {
    value
        .parse()
        .map_err(|err| LiveRuntimeConfigError::InvalidEnv {
            name,
            message: format!("{err}"),
        })
}

fn parse_u64_env(name: &'static str, value: &str) -> Result<u64, LiveRuntimeConfigError> {
    value
        .parse()
        .map_err(|err| LiveRuntimeConfigError::InvalidEnv {
            name,
            message: format!("{err}"),
        })
}

fn parse_websocket_mode(
    value: Option<String>,
) -> Result<LiveWebSocketMode, LiveRuntimeConfigError> {
    match value.as_deref().unwrap_or("single") {
        "single" | "single-instance" => Ok(LiveWebSocketMode::SingleInstance),
        "clustered-single-active" | "cluster" => Ok(LiveWebSocketMode::ClusteredSingleActive),
        other => Err(LiveRuntimeConfigError::InvalidEnv {
            name: "TURBO_RUNTIME_WEBSOCKET_MODE",
            message: format!("unsupported mode `{other}`"),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_runtime_config_uses_defaults_for_optional_values() {
        let config = LiveRuntimeConfig::from_values(
            "postgres://localhost/turbo".to_owned(),
            None,
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .expect("config should parse");

        assert_eq!(config.database_url, "postgres://localhost/turbo");
        assert_eq!(
            config.bind_addr,
            "127.0.0.1:8091".parse::<SocketAddr>().unwrap()
        );
        assert_eq!(config.repo_root, PathBuf::from("."));
        assert_eq!(config.snapshot_built_at_ms, 10_000);
        assert_eq!(config.kernel_deadline, Duration::from_millis(20_000));
        assert_eq!(config.runtime_id, "runtime-single");
        assert_eq!(config.websocket_mode, LiveWebSocketMode::SingleInstance);
        assert_eq!(config.websocket_owner_ttl_ms, 15_000);
    }

    #[test]
    fn live_runtime_config_reads_explicit_values() {
        let config = LiveRuntimeConfig::from_values(
            "postgres://localhost/turbo".to_owned(),
            Some("127.0.0.1:19091".to_owned()),
            Some("/tmp/turbo-repo".to_owned()),
            Some("12345".to_owned()),
            Some("2500".to_owned()),
            Some("runtime-a".to_owned()),
            Some("clustered-single-active".to_owned()),
            Some("45000".to_owned()),
        )
        .expect("config should parse");

        assert_eq!(config.database_url, "postgres://localhost/turbo");
        assert_eq!(
            config.bind_addr,
            "127.0.0.1:19091".parse::<SocketAddr>().unwrap()
        );
        assert_eq!(config.repo_root, PathBuf::from("/tmp/turbo-repo"));
        assert_eq!(config.snapshot_built_at_ms, 12345);
        assert_eq!(config.kernel_deadline, Duration::from_millis(2500));
        assert_eq!(config.runtime_id, "runtime-a");
        assert_eq!(
            config.websocket_mode,
            LiveWebSocketMode::ClusteredSingleActive
        );
        assert_eq!(config.websocket_owner_ttl_ms, 45_000);
    }

    #[test]
    fn live_runtime_config_rejects_bad_bind_addr() {
        let err = LiveRuntimeConfig::from_values(
            "postgres://localhost/turbo".to_owned(),
            Some("not-an-address".to_owned()),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap_err();

        assert!(matches!(
            err,
            LiveRuntimeConfigError::InvalidEnv {
                name: "TURBO_RUNTIME_BIND",
                ..
            }
        ));
    }

    #[test]
    fn live_runtime_config_rejects_bad_websocket_mode_and_ttl() {
        let bad_mode = LiveRuntimeConfig::from_values(
            "postgres://localhost/turbo".to_owned(),
            None,
            None,
            None,
            None,
            None,
            Some("active-active".to_owned()),
            None,
        )
        .unwrap_err();

        assert!(matches!(
            bad_mode,
            LiveRuntimeConfigError::InvalidEnv {
                name: "TURBO_RUNTIME_WEBSOCKET_MODE",
                ..
            }
        ));

        let bad_ttl = LiveRuntimeConfig::from_values(
            "postgres://localhost/turbo".to_owned(),
            None,
            None,
            None,
            None,
            None,
            Some("cluster".to_owned()),
            Some("0".to_owned()),
        )
        .unwrap_err();

        assert!(matches!(
            bad_ttl,
            LiveRuntimeConfigError::InvalidEnv {
                name: "TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS",
                ..
            }
        ));
    }
}
