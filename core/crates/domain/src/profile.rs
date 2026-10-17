/// Profile names become directory names, so they are strictly validated.
pub fn is_valid_profile_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert!(is_valid_profile_name("default"));
        assert!(is_valid_profile_name("work_2"));
        assert!(!is_valid_profile_name(""));
        assert!(!is_valid_profile_name("../x"));
        assert!(!is_valid_profile_name("a/b"));
        assert!(!is_valid_profile_name(&"a".repeat(33)));
    }
}
