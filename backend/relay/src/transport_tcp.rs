use std::{
    fs::File,
    io::BufReader,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

pub const TCP_TLS_TRANSPORT_NAME: &str = "tcp-tls";

pub fn server_config(cert_pem: &Path, key_pem: &Path) -> Result<rustls::ServerConfig> {
    let certs = load_certs(cert_pem)?;
    let key = load_key(key_pem)?;
    rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .context("invalid relay certificate or key")
}

pub fn load_certs(path: &Path) -> Result<Vec<CertificateDer<'static>>> {
    let file = File::open(path)
        .with_context(|| format!("failed to open cert PEM at {}", display_path(path)))?;
    let mut reader = BufReader::new(file);
    rustls_pemfile::certs(&mut reader)
        .collect::<std::result::Result<Vec<_>, _>>()
        .context("failed to parse cert PEM")
}

pub fn load_key(path: &Path) -> Result<PrivateKeyDer<'static>> {
    let file = File::open(path)
        .with_context(|| format!("failed to open key PEM at {}", display_path(path)))?;
    let mut reader = BufReader::new(file);
    rustls_pemfile::private_key(&mut reader)
        .context("failed to parse key PEM")?
        .ok_or_else(|| anyhow::anyhow!("key PEM contained no private key"))
}

fn display_path(path: &Path) -> String {
    PathBuf::from(path).display().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tcp_transport_name_is_stable() {
        assert_eq!(TCP_TLS_TRANSPORT_NAME, "tcp-tls");
    }

    #[test]
    fn missing_cert_reports_path() {
        let err = load_certs(Path::new("missing-cert.pem")).unwrap_err();
        let message = format!("{err:#}");

        assert!(message.contains("missing-cert.pem"));
    }
}
