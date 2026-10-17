use url::Url;

pub const DEFAULT_SEARCH: &str = "https://duckduckgo.com/?q={}";

pub fn default_search_template() -> String {
    DEFAULT_SEARCH.to_owned()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    Url(String),
    Search(String),
}

/// Turns raw address-bar text into a navigable URL or a search URL.
pub fn resolve(input: &str, search_template: &str) -> Option<Resolved> {
    let text = input.trim();
    if text.is_empty() {
        return None;
    }
    if !text.contains(char::is_whitespace) {
        if let Some(u) = explicit_url(text) {
            return Some(Resolved::Url(u));
        }
        if let Some(u) = bare_host(text) {
            return Some(Resolved::Url(u));
        }
    }
    Some(Resolved::Search(search_url(text, search_template)))
}

fn explicit_url(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase();
    if lower == "about:blank" {
        return Some(lower);
    }
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return Url::parse(text)
            .ok()
            .filter(|u| u.host().is_some())
            .map(|u| u.into());
    }
    None
}

fn bare_host(text: &str) -> Option<String> {
    if text.contains("://") {
        return None;
    }
    let candidate = Url::parse(&format!("https://{text}")).ok()?;
    let host = candidate.host_str()?;
    let is_local = host == "localhost" || host.parse::<std::net::IpAddr>().is_ok();
    let has_tld = host
        .rsplit_once('.')
        .is_some_and(|(_, tld)| tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic()));
    if is_local {
        return Url::parse(&format!("http://{text}")).ok().map(Into::into);
    }
    has_tld.then(|| candidate.into())
}

pub fn search_url(query: &str, template: &str) -> String {
    let template = if template.contains("{}") {
        template
    } else {
        DEFAULT_SEARCH
    };
    let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    template.replace("{}", &encoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(s: &str) -> Option<Resolved> {
        resolve(s, DEFAULT_SEARCH)
    }

    #[test]
    fn urls_and_hosts() {
        assert_eq!(
            r("https://example.com/a"),
            Some(Resolved::Url("https://example.com/a".into()))
        );
        assert_eq!(
            r("example.com"),
            Some(Resolved::Url("https://example.com/".into()))
        );
        assert_eq!(
            r("localhost:3000"),
            Some(Resolved::Url("http://localhost:3000/".into()))
        );
        assert_eq!(
            r("192.168.1.1"),
            Some(Resolved::Url("http://192.168.1.1/".into()))
        );
        assert_eq!(r("about:blank"), Some(Resolved::Url("about:blank".into())));
    }

    #[test]
    fn searches() {
        assert_eq!(
            r("rust lang"),
            Some(Resolved::Search(
                "https://duckduckgo.com/?q=rust+lang".into()
            ))
        );
        assert_eq!(
            r("hello"),
            Some(Resolved::Search("https://duckduckgo.com/?q=hello".into()))
        );
        assert!(matches!(
            r("javascript:alert(1)"),
            Some(Resolved::Search(_))
        ));
        assert_eq!(r("   "), None);
    }
}
