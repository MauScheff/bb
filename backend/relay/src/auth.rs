use anyhow::{Result, anyhow};

pub fn validate_join_token(expected: &str, actual: &str) -> Result<()> {
    if actual == expected {
        Ok(())
    } else {
        Err(anyhow!("invalid relay token"))
    }
}

pub fn validate_id(label: &str, value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 160 {
        return Err(anyhow!("{label} has invalid length"));
    }
    if !value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | ':' | '.'))
    {
        return Err(anyhow!("{label} contains unsupported characters"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_join_tokens() {
        assert!(validate_join_token("secret", "secret").is_ok());
        assert!(validate_join_token("secret", "wrong").is_err());
    }

    #[test]
    fn rejects_invalid_relay_ids() {
        assert!(validate_id("device_id", "device-a_1:ios.local").is_ok());
        assert!(validate_id("device_id", "").is_err());
        assert!(validate_id("device_id", &"a".repeat(161)).is_err());
        assert!(validate_id("device_id", "device/a").is_err());
    }
}
