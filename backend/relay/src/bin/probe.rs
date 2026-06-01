use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::{Context, Result, anyhow};
use bytes::Bytes;
use futures_util::StreamExt;
use quinn::{ClientConfig, Endpoint, TransportConfig};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use serde_json::json;
use tokio::{io::AsyncWriteExt, net::lookup_host, time};
use tokio_util::codec::{FramedRead, LinesCodec};

const ALPN: &[u8] = b"turbo-relay-v2";
const DEFAULT_HOST: &str = "relay.beepbeep.to";
const DEFAULT_PORT: u16 = 443;
const MAX_RELAY_DATAGRAM_BUFFER_LENGTH: usize = 256 * 1024;

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    let mut args = std::env::args().skip(1);
    let mode = args.next().unwrap_or_else(|| "both".to_string());
    let host = args.next().unwrap_or_else(|| DEFAULT_HOST.to_string());
    let port = args
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    match mode.as_str() {
        "stream" => probe_stream_join(&host, port).await?,
        "datagram" => probe_datagram_join(&host, port).await?,
        "datagram-pair" => probe_datagram_pair(&host, port).await?,
        "both" => {
            probe_stream_join(&host, port).await?;
            probe_datagram_join(&host, port).await?;
        }
        other => {
            return Err(anyhow!(
                "unknown mode `{other}`; use stream, datagram, datagram-pair, or both"
            ));
        }
    }

    Ok(())
}

async fn probe_stream_join(host: &str, port: u16) -> Result<()> {
    let connection = connect(host, port).await?;
    let (mut send, recv) = connection
        .open_bi()
        .await
        .context("failed to open QUIC stream")?;
    let join = json!({
        "type": "join",
        "session_id": "probe-session",
        "device_id": "probe-device-a",
        "peer_device_id": "probe-device-b",
        "token": ""
    });
    send.write_all(format!("{join}\n").as_bytes())
        .await
        .context("failed to write stream join")?;
    send.flush().await.context("failed to flush stream join")?;

    let mut framed = FramedRead::new(recv, LinesCodec::new());
    let ack = time::timeout(Duration::from_secs(3), framed.next())
        .await
        .context("stream join ack timed out")?
        .ok_or_else(|| anyhow!("stream closed before join ack"))?
        .context("invalid stream join ack")?;
    println!("stream_join_ack={ack}");
    connection.close(0u32.into(), b"probe done");
    Ok(())
}

async fn probe_datagram_join(host: &str, port: u16) -> Result<()> {
    let connection = connect(host, port).await?;
    println!("datagram_max_size={:?}", connection.max_datagram_size());
    let join = json!({
        "type": "datagram-join",
        "session_id": "probe-session",
        "device_id": "probe-device-a",
        "peer_device_id": "probe-device-b",
        "token": ""
    });
    connection
        .send_datagram(Bytes::from(join.to_string()))
        .context("failed to send datagram join")?;
    let ack = time::timeout(Duration::from_secs(3), connection.read_datagram())
        .await
        .context("datagram join ack timed out")?
        .context("failed to read datagram join ack")?;
    println!(
        "datagram_join_ack={}",
        std::str::from_utf8(ack.as_ref()).unwrap_or("<non-utf8>")
    );
    connection.close(0u32.into(), b"probe done");
    Ok(())
}

async fn probe_datagram_pair(host: &str, port: u16) -> Result<()> {
    let session_id = "probe-pair-session";
    let a = connect(host, port).await?;
    let b = connect(host, port).await?;
    datagram_join(&a, session_id, "probe-device-a", "probe-device-b").await?;
    datagram_join(&b, session_id, "probe-device-b", "probe-device-a").await?;

    let audio = json!({
        "type": "packet-audio",
        "session_id": session_id,
        "sender_device_id": "probe-device-a",
        "sequence_number": 1,
        "sent_at_ms": 123456,
        "payload": "probe-audio"
    });
    a.send_datagram(Bytes::from(audio.to_string()))
        .context("failed to send packet audio datagram")?;
    let forwarded = time::timeout(Duration::from_secs(3), b.read_datagram())
        .await
        .context("packet audio datagram timed out")?
        .context("failed to read packet audio datagram")?;
    println!(
        "packet_audio_forwarded={}",
        std::str::from_utf8(forwarded.as_ref()).unwrap_or("<non-utf8>")
    );
    a.close(0u32.into(), b"probe done");
    b.close(0u32.into(), b"probe done");
    Ok(())
}

async fn datagram_join(
    connection: &quinn::Connection,
    session_id: &str,
    device_id: &str,
    peer_device_id: &str,
) -> Result<()> {
    let join = json!({
        "type": "datagram-join",
        "session_id": session_id,
        "device_id": device_id,
        "peer_device_id": peer_device_id,
        "token": ""
    });
    connection
        .send_datagram(Bytes::from(join.to_string()))
        .context("failed to send datagram join")?;
    let ack = time::timeout(Duration::from_secs(3), connection.read_datagram())
        .await
        .context("datagram join ack timed out")?
        .context("failed to read datagram join ack")?;
    println!(
        "datagram_join_ack={}",
        std::str::from_utf8(ack.as_ref()).unwrap_or("<non-utf8>")
    );
    Ok(())
}

async fn connect(host: &str, port: u16) -> Result<quinn::Connection> {
    let remote = resolve(host, port).await?;
    let mut endpoint = Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(client_config()?);
    let connection = time::timeout(Duration::from_secs(5), endpoint.connect(remote, host)?)
        .await
        .context("QUIC connect timed out")?
        .context("QUIC connect failed")?;
    println!("connected remote={}", connection.remote_address());
    Ok(connection)
}

async fn resolve(host: &str, port: u16) -> Result<SocketAddr> {
    lookup_host((host, port))
        .await
        .with_context(|| format!("failed to resolve {host}:{port}"))?
        .find(|addr| addr.is_ipv4())
        .ok_or_else(|| anyhow!("no IPv4 address resolved for {host}:{port}"))
}

fn client_config() -> Result<ClientConfig> {
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let mut tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(SkipServerVerification::new(provider))
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];

    let mut config = ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(tls)?,
    ));
    let mut transport = TransportConfig::default();
    transport.max_idle_timeout(Some(Duration::from_secs(10).try_into()?));
    transport.datagram_receive_buffer_size(Some(MAX_RELAY_DATAGRAM_BUFFER_LENGTH));
    transport.datagram_send_buffer_size(MAX_RELAY_DATAGRAM_BUFFER_LENGTH);
    config.transport_config(Arc::new(transport));
    Ok(config)
}

#[derive(Debug)]
struct SkipServerVerification(Arc<rustls::crypto::CryptoProvider>);

impl SkipServerVerification {
    fn new(provider: Arc<rustls::crypto::CryptoProvider>) -> Arc<Self> {
        Arc::new(Self(provider))
    }
}

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}
