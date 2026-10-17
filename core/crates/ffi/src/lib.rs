//! UniFFI surface the native shells call. Every call is a typed command; no webpage
//! content ever reaches this layer directly.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use browser_domain::omnibox::{self, Resolved};
use browser_domain::policy::{self, NavigationDecision, PermissionDecision, PermissionKind};
use browser_domain::profile;
use browser_domain::tabs::{TabError, TabId, TabRegistry};
use browser_storage::{SessionSnapshot, SessionTab, Store};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("tab not found")]
    TabNotFound,
    #[error("invalid profile name")]
    InvalidProfile,
    #[error("storage error: {message}")]
    Storage { message: String },
}

impl From<TabError> for CoreError {
    fn from(e: TabError) -> Self {
        match e {
            TabError::NotFound => CoreError::TabNotFound,
        }
    }
}

impl From<browser_storage::StorageError> for CoreError {
    fn from(e: browser_storage::StorageError) -> Self {
        CoreError::Storage {
            message: e.to_string(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TabInfo {
    pub id: u64,
    pub url: String,
    pub title: String,
    pub private: bool,
    pub group: String,
    pub pinned: bool,
    pub workspace: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HistoryItem {
    pub url: String,
    pub title: String,
    pub last_visit: i64,
    pub visit_count: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BookmarkItem {
    pub url: String,
    pub title: String,
    pub folder: String,
    pub created: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadItem {
    pub url: String,
    pub filename: String,
    pub created: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PermissionGrant {
    pub origin: String,
    pub kind: PermissionType,
    pub decision: Decision,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PermissionVerdict {
    pub decision: Decision,
    /// Identifier of the rule that decided, for explainability.
    pub rule: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Decision {
    Allow,
    Deny,
    Prompt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PermissionType {
    Camera,
    Microphone,
    Location,
    Notifications,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NavDecision {
    Allow,
    External,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum OmniboxResult {
    Url { url: String },
    Search { url: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RestoredSession {
    pub tabs: Vec<TabInfo>,
    pub active_index: u32,
}

impl From<PermissionType> for PermissionKind {
    fn from(p: PermissionType) -> Self {
        match p {
            PermissionType::Camera => Self::Camera,
            PermissionType::Microphone => Self::Microphone,
            PermissionType::Location => Self::Location,
            PermissionType::Notifications => Self::Notifications,
        }
    }
}

fn kind_from_str(s: &str) -> Option<PermissionType> {
    Some(match s {
        "camera" => PermissionType::Camera,
        "microphone" => PermissionType::Microphone,
        "location" => PermissionType::Location,
        "notifications" => PermissionType::Notifications,
        _ => return None,
    })
}

impl From<PermissionDecision> for Decision {
    fn from(d: PermissionDecision) -> Self {
        match d {
            PermissionDecision::Allow => Self::Allow,
            PermissionDecision::Deny => Self::Deny,
            PermissionDecision::Prompt => Self::Prompt,
        }
    }
}

fn decision_str(d: Decision) -> &'static str {
    match d {
        Decision::Allow => "allow",
        Decision::Deny => "deny",
        Decision::Prompt => "prompt",
    }
}

fn decision_from_str(s: &str) -> Option<Decision> {
    match s {
        "allow" => Some(Decision::Allow),
        "deny" => Some(Decision::Deny),
        _ => None,
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn tab_info(t: browser_domain::tabs::Tab) -> TabInfo {
    TabInfo {
        id: t.id.0,
        url: t.url,
        title: t.title,
        private: t.private,
        group: t.group,
        pinned: t.pinned,
        workspace: t.workspace,
    }
}

fn profile_dir(root: &str, name: &str) -> Result<PathBuf, CoreError> {
    if !profile::is_valid_profile_name(name) {
        return Err(CoreError::InvalidProfile);
    }
    Ok(PathBuf::from(root).join("profiles").join(name))
}

/// Names of existing profiles under `root`, sorted.
#[uniffi::export]
pub fn list_profiles(root: String) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(PathBuf::from(root).join("profiles"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| profile::is_valid_profile_name(n))
        .collect();
    names.sort();
    names
}

/// Deletes a profile's stored browser data. The engine's website data is cleared by the shell.
#[uniffi::export]
pub fn delete_profile(root: String, name: String) -> Result<(), CoreError> {
    let dir = profile_dir(&root, &name)?;
    if dir.exists() {
        std::fs::remove_dir_all(dir).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;
    }
    Ok(())
}

#[uniffi::export]
pub fn resolve_input(input: String, search_template: String) -> Option<OmniboxResult> {
    omnibox::resolve(&input, &search_template).map(|r| match r {
        Resolved::Url(url) => OmniboxResult::Url { url },
        Resolved::Search(url) => OmniboxResult::Search { url },
    })
}

#[uniffi::export]
pub fn evaluate_navigation(url: String, main_frame: bool) -> NavDecision {
    match policy::evaluate_navigation(&url, main_frame) {
        NavigationDecision::Allow => NavDecision::Allow,
        NavigationDecision::External => NavDecision::External,
        NavigationDecision::Deny => NavDecision::Deny,
    }
}

#[uniffi::export]
pub fn default_search_template() -> String {
    omnibox::DEFAULT_SEARCH.to_owned()
}

/// One open profile: tabs in memory, durable data in that profile's SQLite database.
#[derive(uniffi::Object)]
pub struct BrowserCore {
    tabs: Mutex<TabRegistry>,
    store: Mutex<Store>,
}

#[uniffi::export]
impl BrowserCore {
    #[uniffi::constructor]
    pub fn open(root: String, profile: String) -> Result<Self, CoreError> {
        let dir = profile_dir(&root, &profile)?;
        std::fs::create_dir_all(&dir).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;
        let store = Store::open(&dir.join("browser.db"))?;
        Ok(Self {
            tabs: Mutex::new(TabRegistry::new()),
            store: Mutex::new(store),
        })
    }

    /// Non-persistent core for tests and previews.
    #[uniffi::constructor]
    pub fn in_memory() -> Result<Self, CoreError> {
        Ok(Self {
            tabs: Mutex::new(TabRegistry::new()),
            store: Mutex::new(Store::open_in_memory()?),
        })
    }

    // --- tabs ---

    pub fn create_tab(&self, url: String, private: bool) -> TabInfo {
        tab_info(self.tabs.lock().unwrap().create(&url, private))
    }

    pub fn close_tab(&self, tab_id: u64) -> Result<(), CoreError> {
        Ok(self.tabs.lock().unwrap().close(TabId(tab_id))?)
    }

    pub fn list_tabs(&self) -> Vec<TabInfo> {
        self.tabs
            .lock()
            .unwrap()
            .list()
            .into_iter()
            .map(tab_info)
            .collect()
    }

    pub fn set_tab_group(&self, tab_id: u64, group: String) -> Result<(), CoreError> {
        Ok(self.tabs.lock().unwrap().set_group(TabId(tab_id), &group)?)
    }

    pub fn set_tab_workspace(&self, tab_id: u64, workspace: String) -> Result<(), CoreError> {
        Ok(self
            .tabs
            .lock()
            .unwrap()
            .set_workspace(TabId(tab_id), &workspace)?)
    }

    pub fn move_tab(&self, tab_id: u64, index: u32) -> Result<(), CoreError> {
        Ok(self
            .tabs
            .lock()
            .unwrap()
            .move_to(TabId(tab_id), index as usize)?)
    }

    pub fn set_tab_pinned(&self, tab_id: u64, pinned: bool) -> Result<(), CoreError> {
        Ok(self
            .tabs
            .lock()
            .unwrap()
            .set_pinned(TabId(tab_id), pinned)?)
    }

    /// Records a committed navigation. Private tabs never reach history.
    pub fn commit_navigation(
        &self,
        tab_id: u64,
        url: String,
        title: String,
    ) -> Result<(), CoreError> {
        let private = {
            let mut tabs = self.tabs.lock().unwrap();
            tabs.set_page(TabId(tab_id), &url, &title)?;
            tabs.get(TabId(tab_id)).is_some_and(|t| t.private)
        };
        if !private
            && policy::evaluate_navigation(&url, true) == NavigationDecision::Allow
            && url != "about:blank"
        {
            self.store
                .lock()
                .unwrap()
                .record_visit(&url, &title, now())?;
        }
        Ok(())
    }

    // --- history ---

    pub fn search_history(&self, query: String, limit: u32) -> Result<Vec<HistoryItem>, CoreError> {
        let rows = self.store.lock().unwrap().search_history(&query, limit)?;
        Ok(rows.into_iter().map(history_item).collect())
    }

    pub fn recent_history(&self, limit: u32) -> Result<Vec<HistoryItem>, CoreError> {
        let rows = self.store.lock().unwrap().recent_history(limit)?;
        Ok(rows.into_iter().map(history_item).collect())
    }

    pub fn top_sites(&self, limit: u32) -> Result<Vec<HistoryItem>, CoreError> {
        let rows = self.store.lock().unwrap().top_sites(limit)?;
        Ok(rows.into_iter().map(history_item).collect())
    }

    pub fn delete_history_entry(&self, url: String) -> Result<(), CoreError> {
        Ok(self.store.lock().unwrap().delete_history_entry(&url)?)
    }

    pub fn clear_history(&self) -> Result<(), CoreError> {
        Ok(self.store.lock().unwrap().clear_history()?)
    }

    // --- bookmarks ---

    pub fn add_bookmark(
        &self,
        url: String,
        title: String,
        folder: String,
    ) -> Result<(), CoreError> {
        Ok(self
            .store
            .lock()
            .unwrap()
            .add_bookmark(&url, &title, &folder, now())?)
    }

    pub fn remove_bookmark(&self, url: String) -> Result<(), CoreError> {
        Ok(self.store.lock().unwrap().remove_bookmark(&url)?)
    }

    pub fn is_bookmarked(&self, url: String) -> Result<bool, CoreError> {
        Ok(self.store.lock().unwrap().is_bookmarked(&url)?)
    }

    pub fn list_bookmarks(&self, query: String) -> Result<Vec<BookmarkItem>, CoreError> {
        let rows = self.store.lock().unwrap().list_bookmarks(&query)?;
        Ok(rows
            .into_iter()
            .map(|b| BookmarkItem {
                url: b.url,
                title: b.title,
                folder: b.folder,
                created: b.created,
            })
            .collect())
    }

    // --- settings ---

    pub fn get_setting(&self, key: String) -> Result<Option<String>, CoreError> {
        Ok(self.store.lock().unwrap().get_setting(&key)?)
    }

    pub fn set_setting(&self, key: String, value: String) -> Result<(), CoreError> {
        Ok(self.store.lock().unwrap().set_setting(&key, &value)?)
    }

    pub fn search_template(&self) -> Result<String, CoreError> {
        Ok(self
            .get_setting("search_template".into())?
            .unwrap_or_else(omnibox::default_search_template))
    }

    // --- permissions ---

    pub fn decide_permission(
        &self,
        origin: String,
        kind: PermissionType,
        private: bool,
    ) -> Result<PermissionVerdict, CoreError> {
        let k: PermissionKind = kind.into();
        let stored = self
            .store
            .lock()
            .unwrap()
            .get_permission(&origin, k.as_str())?
            .and_then(|s| decision_from_str(&s))
            .map(|d| match d {
                Decision::Allow => PermissionDecision::Allow,
                _ => PermissionDecision::Deny,
            });
        let v = policy::decide_permission(&origin, stored, private);
        Ok(PermissionVerdict {
            decision: v.decision.into(),
            rule: v.rule.to_owned(),
        })
    }

    /// Persists an Allow/Deny choice. Private-session choices must not be passed here.
    pub fn remember_permission(
        &self,
        origin: String,
        kind: PermissionType,
        decision: Decision,
    ) -> Result<(), CoreError> {
        let k: PermissionKind = kind.into();
        let store = self.store.lock().unwrap();
        if decision == Decision::Prompt {
            Ok(store.clear_permission(&origin, k.as_str())?)
        } else {
            Ok(store.set_permission(&origin, k.as_str(), decision_str(decision))?)
        }
    }

    pub fn list_permissions(&self) -> Result<Vec<PermissionGrant>, CoreError> {
        let rows = self.store.lock().unwrap().list_permissions()?;
        Ok(rows
            .into_iter()
            .filter_map(|(origin, kind, decision)| {
                Some(PermissionGrant {
                    origin,
                    kind: kind_from_str(&kind)?,
                    decision: decision_from_str(&decision)?,
                })
            })
            .collect())
    }

    // --- downloads ---

    pub fn record_download(&self, url: String, filename: String) -> Result<(), CoreError> {
        Ok(self
            .store
            .lock()
            .unwrap()
            .record_download(&url, &filename, now())?)
    }

    pub fn list_downloads(&self, limit: u32) -> Result<Vec<DownloadItem>, CoreError> {
        let rows = self.store.lock().unwrap().list_downloads(limit)?;
        Ok(rows
            .into_iter()
            .map(|d| DownloadItem {
                url: d.url,
                filename: d.filename,
                created: d.created,
            })
            .collect())
    }

    pub fn clear_downloads(&self) -> Result<(), CoreError> {
        Ok(self.store.lock().unwrap().clear_downloads()?)
    }

    // --- session ---

    /// Checkpoints non-private tabs. `active_tab_id` is remembered if it is saved.
    pub fn save_session(&self, active_tab_id: u64) -> Result<(), CoreError> {
        let tabs = self.tabs.lock().unwrap().list();
        let saved: Vec<_> = tabs.into_iter().filter(|t| !t.private).collect();
        let active = saved
            .iter()
            .position(|t| t.id.0 == active_tab_id)
            .unwrap_or(0);
        let snap = SessionSnapshot {
            tabs: saved
                .into_iter()
                .map(|t| SessionTab {
                    url: t.url,
                    title: t.title,
                    group: t.group,
                    pinned: t.pinned,
                    workspace: t.workspace,
                })
                .collect(),
            active,
        };
        Ok(self.store.lock().unwrap().save_session(&snap, now())?)
    }

    /// Recreates the checkpointed tabs (metadata only; the shell loads pages lazily).
    pub fn restore_session(&self) -> Result<Option<RestoredSession>, CoreError> {
        let Some(snap) = self.store.lock().unwrap().load_session()? else {
            return Ok(None);
        };
        if snap.tabs.is_empty() {
            return Ok(None);
        }
        let mut registry = self.tabs.lock().unwrap();
        let tabs: Vec<TabInfo> = snap
            .tabs
            .iter()
            .filter(|t| policy::evaluate_navigation(&t.url, true) == NavigationDecision::Allow)
            .map(|t| {
                let tab = registry.create(&t.url, false);
                let _ = registry.set_page(tab.id, &t.url, &t.title);
                let _ = registry.set_group(tab.id, &t.group);
                let _ = registry.set_pinned(tab.id, t.pinned);
                let _ = registry.set_workspace(tab.id, &t.workspace);
                TabInfo {
                    id: tab.id.0,
                    url: t.url.clone(),
                    title: t.title.clone(),
                    private: false,
                    group: t.group.clone(),
                    pinned: t.pinned,
                    workspace: t.workspace.clone(),
                }
            })
            .collect();
        if tabs.is_empty() {
            return Ok(None);
        }
        let active_index = snap.active.min(tabs.len() - 1) as u32;
        Ok(Some(RestoredSession { tabs, active_index }))
    }
}

fn history_item(h: browser_storage::HistoryEntry) -> HistoryItem {
    HistoryItem {
        url: h.url,
        title: h.title,
        last_visit: h.last_visit,
        visit_count: h.visit_count,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_tabs_leave_no_trace() {
        let core = BrowserCore::in_memory().unwrap();
        let p = core.create_tab("about:blank".into(), true);
        let n = core.create_tab("about:blank".into(), false);
        core.commit_navigation(p.id, "https://secret.example/".into(), "S".into())
            .unwrap();
        core.commit_navigation(n.id, "https://open.example/".into(), "O".into())
            .unwrap();
        let urls: Vec<_> = core
            .recent_history(10)
            .unwrap()
            .into_iter()
            .map(|h| h.url)
            .collect();
        assert_eq!(urls, vec!["https://open.example/"]);
        core.save_session(n.id).unwrap();
        let restored = BrowserCore::in_memory().unwrap();
        assert!(restored.restore_session().unwrap().is_none());
        let s = core.restore_session().unwrap().unwrap();
        assert!(s
            .tabs
            .iter()
            .all(|t| !t.private && t.url != "https://secret.example/"));
    }

    #[test]
    fn groups_and_pins_survive_session_restore() {
        let core = BrowserCore::in_memory().unwrap();
        let t = core.create_tab("about:blank".into(), false);
        core.commit_navigation(t.id, "https://a.example/".into(), "A".into())
            .unwrap();
        core.set_tab_group(t.id, "Work".into()).unwrap();
        core.set_tab_pinned(t.id, true).unwrap();
        core.save_session(t.id).unwrap();
        let restored = core.restore_session().unwrap().unwrap();
        assert_eq!(restored.tabs[0].group, "Work");
        assert!(restored.tabs[0].pinned);
        core.set_tab_workspace(t.id, "Work".into()).unwrap();
        core.save_session(t.id).unwrap();
        assert_eq!(
            core.restore_session().unwrap().unwrap().tabs[0].workspace,
            "Work"
        );
        assert_eq!(core.top_sites(5).unwrap()[0].url, "https://a.example/");
    }

    #[test]
    fn permissions_flow() {
        let core = BrowserCore::in_memory().unwrap();
        let o = "https://a.example".to_string();
        let v = core
            .decide_permission(o.clone(), PermissionType::Camera, false)
            .unwrap();
        assert_eq!(v.decision, Decision::Prompt);
        core.remember_permission(o.clone(), PermissionType::Camera, Decision::Allow)
            .unwrap();
        let v = core
            .decide_permission(o.clone(), PermissionType::Camera, false)
            .unwrap();
        assert_eq!(v.decision, Decision::Allow);
        let v = core
            .decide_permission(o, PermissionType::Camera, true)
            .unwrap();
        assert_eq!(v.decision, Decision::Prompt);
    }

    #[test]
    fn permissions_are_per_profile() {
        let root = std::env::temp_dir().join(format!("bs-perm-{}", std::process::id()));
        let r = root.to_string_lossy().to_string();
        let a = BrowserCore::open(r.clone(), "a".into()).unwrap();
        let b = BrowserCore::open(r, "b".into()).unwrap();
        let o = "https://a.example".to_string();
        a.remember_permission(o.clone(), PermissionType::Microphone, Decision::Allow)
            .unwrap();
        assert_eq!(
            a.decide_permission(o.clone(), PermissionType::Microphone, false)
                .unwrap()
                .decision,
            Decision::Allow
        );
        assert_eq!(
            b.decide_permission(o.clone(), PermissionType::Microphone, false)
                .unwrap()
                .decision,
            Decision::Prompt
        );
        a.remember_permission(o.clone(), PermissionType::Microphone, Decision::Prompt)
            .unwrap();
        assert_eq!(
            a.decide_permission(o, PermissionType::Microphone, false)
                .unwrap()
                .decision,
            Decision::Prompt
        );
        drop((a, b));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn corrupt_profile_database_is_an_error_not_a_panic() {
        let root = std::env::temp_dir().join(format!("bs-corrupt-{}", std::process::id()));
        let dir = root.join("profiles").join("x");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("browser.db"), b"garbage garbage garbage garbage").unwrap();
        let r = BrowserCore::open(root.to_string_lossy().to_string(), "x".into());
        assert!(matches!(r, Err(CoreError::Storage { .. })));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn profiles_are_isolated_and_validated() {
        let root = std::env::temp_dir().join(format!("bs-ffi-{}", std::process::id()));
        let r = root.to_string_lossy().to_string();
        assert!(matches!(
            BrowserCore::open(r.clone(), "../evil".into()),
            Err(CoreError::InvalidProfile)
        ));
        let a = BrowserCore::open(r.clone(), "a".into()).unwrap();
        let b = BrowserCore::open(r.clone(), "b".into()).unwrap();
        a.add_bookmark("https://x.example".into(), "X".into(), String::new())
            .unwrap();
        assert!(b.list_bookmarks(String::new()).unwrap().is_empty());
        assert_eq!(list_profiles(r.clone()), vec!["a", "b"]);
        drop((a, b));
        delete_profile(r.clone(), "a".into()).unwrap();
        assert_eq!(list_profiles(r), vec!["b"]);
        std::fs::remove_dir_all(root).unwrap();
    }
}
