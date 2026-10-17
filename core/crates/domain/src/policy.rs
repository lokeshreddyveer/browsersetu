use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavigationDecision {
    Allow,
    /// Hand to the OS (mail client, dialer) after user confirmation.
    External,
    Deny,
}

const EXTERNAL_SCHEMES: &[&str] = &["mailto", "tel", "sms", "facetime"];

/// Mandatory navigation restrictions, enforced before any engine load.
pub fn evaluate_navigation(raw: &str, main_frame: bool) -> NavigationDecision {
    if raw.eq_ignore_ascii_case("about:blank")
        || (!main_frame && raw.eq_ignore_ascii_case("about:srcdoc"))
    {
        return NavigationDecision::Allow;
    }
    let Ok(url) = Url::parse(raw) else {
        return NavigationDecision::Deny;
    };
    match url.scheme() {
        "http" | "https" => NavigationDecision::Allow,
        "blob" if !main_frame => NavigationDecision::Allow,
        s if EXTERNAL_SCHEMES.contains(&s) && main_frame => NavigationDecision::External,
        _ => NavigationDecision::Deny,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionKind {
    Camera,
    Microphone,
    Location,
    Notifications,
}

impl PermissionKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Camera => "camera",
            Self::Microphone => "microphone",
            Self::Location => "location",
            Self::Notifications => "notifications",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionDecision {
    Allow,
    Deny,
    Prompt,
}

/// A decision plus the rule that produced it, so it can be explained.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    pub decision: PermissionDecision,
    pub rule: &'static str,
}

/// Precedence: insecure origin → private session → stored user choice → default.
pub fn decide_permission(
    origin: &str,
    stored: Option<PermissionDecision>,
    private: bool,
) -> Verdict {
    let secure = Url::parse(origin)
        .map(|u| u.scheme() == "https" || matches!(u.host_str(), Some("localhost")))
        .unwrap_or(false);
    if !secure {
        return Verdict {
            decision: PermissionDecision::Deny,
            rule: "sec.insecure-origin",
        };
    }
    if private {
        return Verdict {
            decision: PermissionDecision::Prompt,
            rule: "priv.always-prompt",
        };
    }
    match stored {
        Some(d) => Verdict {
            decision: d,
            rule: "user.stored-choice",
        },
        None => Verdict {
            decision: PermissionDecision::Prompt,
            rule: "default.prompt",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn navigation_rules() {
        use NavigationDecision::*;
        assert_eq!(evaluate_navigation("https://a.com", true), Allow);
        assert_eq!(evaluate_navigation("file:///etc/passwd", true), Deny);
        assert_eq!(evaluate_navigation("javascript:alert(1)", true), Deny);
        assert_eq!(evaluate_navigation("data:text/html,x", true), Deny);
        assert_eq!(evaluate_navigation("mailto:a@b.c", true), External);
        assert_eq!(evaluate_navigation("mailto:a@b.c", false), Deny);
        assert_eq!(evaluate_navigation("not a url", true), Deny);
        assert_eq!(evaluate_navigation("about:srcdoc", false), Allow);
        assert_eq!(evaluate_navigation("about:srcdoc", true), Deny);
    }

    #[test]
    fn permission_precedence() {
        use PermissionDecision::*;
        let o = "https://a.com";
        assert_eq!(
            decide_permission("http://a.com", Some(Allow), false).decision,
            Deny
        );
        assert_eq!(decide_permission(o, Some(Allow), true).decision, Prompt);
        assert_eq!(decide_permission(o, Some(Allow), false).decision, Allow);
        assert_eq!(decide_permission(o, None, false).rule, "default.prompt");
    }
}
