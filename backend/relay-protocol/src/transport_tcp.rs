pub const TCP_TLS_TRANSPORT_NAME: &str = "tcp-tls";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tcp_transport_name_is_stable() {
        assert_eq!(TCP_TLS_TRANSPORT_NAME, "tcp-tls");
    }
}
