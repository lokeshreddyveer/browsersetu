//! SQLite persistence for one profile. Parameterized SQL only, WAL, versioned migrations.

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

pub type StorageError = rusqlite::Error;
pub type Result<T> = std::result::Result<T, StorageError>;

const MIGRATIONS: &[&str] = &[r#"
CREATE TABLE history (
    id INTEGER PRIMARY KEY,
    url TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL DEFAULT '',
    last_visit INTEGER NOT NULL,
    visit_count INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX history_last_visit ON history(last_visit DESC);
CREATE TABLE bookmarks (
    id INTEGER PRIMARY KEY,
    url TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL DEFAULT '',
    folder TEXT NOT NULL DEFAULT '',
    created INTEGER NOT NULL
);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE permissions (
    origin TEXT NOT NULL,
    kind TEXT NOT NULL,
    decision TEXT NOT NULL,
    PRIMARY KEY (origin, kind)
);
CREATE TABLE session (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    data TEXT NOT NULL,
    saved_at INTEGER NOT NULL
);
CREATE TABLE downloads (
    id INTEGER PRIMARY KEY,
    url TEXT NOT NULL,
    filename TEXT NOT NULL,
    created INTEGER NOT NULL
);
"#];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryEntry {
    pub url: String,
    pub title: String,
    pub last_visit: i64,
    pub visit_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bookmark {
    pub id: i64,
    pub url: String,
    pub title: String,
    pub folder: String,
    pub created: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadRecord {
    pub id: i64,
    pub url: String,
    pub filename: String,
    pub created: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionTab {
    pub url: String,
    pub title: String,
    #[serde(default)]
    pub group: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub workspace: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSnapshot {
    pub tabs: Vec<SessionTab>,
    pub active: usize,
}

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        // Reject newer/foreign files before anything (even the journal mode) can modify them.
        Self::check_version(&conn)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(mut conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "foreign_keys", "ON")?;
        Self::check_version(&conn)?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        for (i, sql) in MIGRATIONS.iter().enumerate().skip(version as usize) {
            let tx = conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", i as i64 + 1)?;
            tx.commit()?;
        }
        Ok(Self { conn })
    }

    fn check_version(conn: &Connection) -> Result<()> {
        let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version as usize > MIGRATIONS.len() {
            // Written by a newer app version; opening it could corrupt data.
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_SCHEMA),
                Some("database was created by a newer version".into()),
            ));
        }
        Ok(())
    }

    pub fn integrity_ok(&self) -> Result<bool> {
        let r: String = self
            .conn
            .pragma_query_value(None, "integrity_check", |r| r.get(0))?;
        Ok(r == "ok")
    }

    // --- history ---

    pub fn record_visit(&self, url: &str, title: &str, now: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO history (url, title, last_visit) VALUES (?1, ?2, ?3)
             ON CONFLICT(url) DO UPDATE SET
               title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END,
               last_visit = excluded.last_visit,
               visit_count = visit_count + 1",
            params![url, title, now],
        )?;
        Ok(())
    }

    pub fn search_history(&self, query: &str, limit: u32) -> Result<Vec<HistoryEntry>> {
        let pattern = like_pattern(query);
        let mut stmt = self.conn.prepare(
            "SELECT url, title, last_visit, visit_count FROM history
             WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
             ORDER BY visit_count DESC, last_visit DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![pattern, limit], |r| {
            Ok(HistoryEntry {
                url: r.get(0)?,
                title: r.get(1)?,
                last_visit: r.get(2)?,
                visit_count: r.get(3)?,
            })
        })?;
        rows.collect()
    }

    pub fn recent_history(&self, limit: u32) -> Result<Vec<HistoryEntry>> {
        let mut stmt = self.conn.prepare(
            "SELECT url, title, last_visit, visit_count FROM history
             ORDER BY last_visit DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(HistoryEntry {
                url: r.get(0)?,
                title: r.get(1)?,
                last_visit: r.get(2)?,
                visit_count: r.get(3)?,
            })
        })?;
        rows.collect()
    }

    /// Most visited pages, for the start page.
    pub fn top_sites(&self, limit: u32) -> Result<Vec<HistoryEntry>> {
        let mut stmt = self.conn.prepare(
            "SELECT url, title, last_visit, visit_count FROM history
             ORDER BY visit_count DESC, last_visit DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(HistoryEntry {
                url: r.get(0)?,
                title: r.get(1)?,
                last_visit: r.get(2)?,
                visit_count: r.get(3)?,
            })
        })?;
        rows.collect()
    }

    pub fn delete_history_entry(&self, url: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM history WHERE url = ?1", params![url])?;
        Ok(())
    }

    pub fn clear_history(&self) -> Result<()> {
        self.conn.execute("DELETE FROM history", [])?;
        Ok(())
    }

    // --- bookmarks ---

    pub fn add_bookmark(&self, url: &str, title: &str, folder: &str, now: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO bookmarks (url, title, folder, created) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(url) DO UPDATE SET title = excluded.title, folder = excluded.folder",
            params![url, title, folder, now],
        )?;
        Ok(())
    }

    pub fn remove_bookmark(&self, url: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM bookmarks WHERE url = ?1", params![url])?;
        Ok(())
    }

    pub fn is_bookmarked(&self, url: &str) -> Result<bool> {
        self.conn
            .query_row(
                "SELECT 1 FROM bookmarks WHERE url = ?1",
                params![url],
                |_| Ok(()),
            )
            .optional()
            .map(|o| o.is_some())
    }

    pub fn list_bookmarks(&self, query: &str) -> Result<Vec<Bookmark>> {
        let pattern = like_pattern(query);
        let mut stmt = self.conn.prepare(
            "SELECT id, url, title, folder, created FROM bookmarks
             WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
             ORDER BY folder, title COLLATE NOCASE",
        )?;
        let rows = stmt.query_map(params![pattern], |r| {
            Ok(Bookmark {
                id: r.get(0)?,
                url: r.get(1)?,
                title: r.get(2)?,
                folder: r.get(3)?,
                created: r.get(4)?,
            })
        })?;
        rows.collect()
    }

    // --- settings ---

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![key],
                |r| r.get(0),
            )
            .optional()
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    // --- permissions ---

    pub fn get_permission(&self, origin: &str, kind: &str) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT decision FROM permissions WHERE origin = ?1 AND kind = ?2",
                params![origin, kind],
                |r| r.get(0),
            )
            .optional()
    }

    pub fn set_permission(&self, origin: &str, kind: &str, decision: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO permissions (origin, kind, decision) VALUES (?1, ?2, ?3)
             ON CONFLICT(origin, kind) DO UPDATE SET decision = excluded.decision",
            params![origin, kind, decision],
        )?;
        Ok(())
    }

    pub fn clear_permission(&self, origin: &str, kind: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM permissions WHERE origin = ?1 AND kind = ?2",
            params![origin, kind],
        )?;
        Ok(())
    }

    pub fn list_permissions(&self) -> Result<Vec<(String, String, String)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT origin, kind, decision FROM permissions ORDER BY origin, kind")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect()
    }

    // --- session ---

    /// Atomic single-row checkpoint; a crash mid-write leaves the previous one intact.
    pub fn save_session(&self, snap: &SessionSnapshot, now: i64) -> Result<()> {
        let data = serde_json::to_string(snap)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
        self.conn.execute(
            "INSERT INTO session (id, data, saved_at) VALUES (1, ?1, ?2)
             ON CONFLICT(id) DO UPDATE SET data = excluded.data, saved_at = excluded.saved_at",
            params![data, now],
        )?;
        Ok(())
    }

    /// Returns `None` if there is no checkpoint or it is unreadable.
    pub fn load_session(&self) -> Result<Option<SessionSnapshot>> {
        let data: Option<String> = self
            .conn
            .query_row("SELECT data FROM session WHERE id = 1", [], |r| r.get(0))
            .optional()?;
        Ok(data.and_then(|d| serde_json::from_str(&d).ok()))
    }

    // --- downloads ---

    pub fn record_download(&self, url: &str, filename: &str, now: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO downloads (url, filename, created) VALUES (?1, ?2, ?3)",
            params![url, filename, now],
        )?;
        Ok(())
    }

    pub fn list_downloads(&self, limit: u32) -> Result<Vec<DownloadRecord>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, url, filename, created FROM downloads ORDER BY created DESC, id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(DownloadRecord {
                id: r.get(0)?,
                url: r.get(1)?,
                filename: r.get(2)?,
                created: r.get(3)?,
            })
        })?;
        rows.collect()
    }

    pub fn clear_downloads(&self) -> Result<()> {
        self.conn.execute("DELETE FROM downloads", [])?;
        Ok(())
    }
}

fn like_pattern(q: &str) -> String {
    let escaped = q
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    format!("%{escaped}%")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn history_counts_and_search() {
        let s = Store::open_in_memory().unwrap();
        s.record_visit("https://a.com", "Alpha", 1).unwrap();
        s.record_visit("https://a.com", "", 2).unwrap();
        s.record_visit("https://b.com", "Beta_100%", 3).unwrap();
        assert_eq!(s.top_sites(1).unwrap()[0].url, "https://a.com");
        let a = &s.search_history("alpha", 10).unwrap()[0];
        assert_eq!(
            (a.visit_count, a.last_visit, a.title.as_str()),
            (2, 2, "Alpha")
        );
        assert_eq!(s.search_history("_100%", 10).unwrap().len(), 1);
        assert_eq!(s.search_history("%", 10).unwrap().len(), 1);
        assert_eq!(s.recent_history(10).unwrap()[0].url, "https://b.com");
        s.clear_history().unwrap();
        assert!(s.recent_history(10).unwrap().is_empty());
    }

    #[test]
    fn sql_injection_is_inert() {
        let s = Store::open_in_memory().unwrap();
        s.record_visit("https://a.com", "x", 1).unwrap();
        assert!(s
            .search_history("'; DROP TABLE history;--", 10)
            .unwrap()
            .is_empty());
        assert_eq!(s.recent_history(10).unwrap().len(), 1);
    }

    #[test]
    fn bookmarks_settings_permissions() {
        let s = Store::open_in_memory().unwrap();
        s.add_bookmark("https://a.com", "A", "", 1).unwrap();
        assert!(s.is_bookmarked("https://a.com").unwrap());
        s.remove_bookmark("https://a.com").unwrap();
        assert!(!s.is_bookmarked("https://a.com").unwrap());
        assert_eq!(s.get_setting("k").unwrap(), None);
        s.set_setting("k", "v").unwrap();
        s.set_setting("k", "w").unwrap();
        assert_eq!(s.get_setting("k").unwrap().as_deref(), Some("w"));
        s.set_permission("https://a.com", "camera", "allow")
            .unwrap();
        assert_eq!(
            s.get_permission("https://a.com", "camera")
                .unwrap()
                .as_deref(),
            Some("allow")
        );
        s.clear_permission("https://a.com", "camera").unwrap();
        assert!(s.list_permissions().unwrap().is_empty());
    }

    #[test]
    fn session_roundtrip_and_corruption() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.load_session().unwrap(), None);
        let snap = SessionSnapshot {
            tabs: vec![SessionTab {
                url: "https://a.com".into(),
                title: "A".into(),
                group: "Work".into(),
                pinned: true,
                workspace: "W".into(),
            }],
            active: 0,
        };
        s.save_session(&snap, 1).unwrap();
        assert_eq!(s.load_session().unwrap(), Some(snap));
        s.conn
            .execute("UPDATE session SET data = 'garbage'", [])
            .unwrap();
        assert_eq!(s.load_session().unwrap(), None);
    }

    #[test]
    fn rejects_garbage_and_newer_databases() {
        let dir = std::env::temp_dir().join(format!("bs-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let garbage = dir.join("g.db");
        std::fs::write(&garbage, b"this is not a sqlite database at all, just text").unwrap();
        assert!(Store::open(&garbage).is_err());
        let newer = dir.join("n.db");
        rusqlite::Connection::open(&newer)
            .unwrap()
            .pragma_update(None, "user_version", 99)
            .unwrap();
        let before = std::fs::read(&newer).unwrap();
        let garbage_before = std::fs::read(&garbage).unwrap();
        assert!(Store::open(&newer).is_err());
        assert!(Store::open(&garbage).is_err());
        assert_eq!(
            std::fs::read(&newer).unwrap(),
            before,
            "newer database was modified"
        );
        assert_eq!(
            std::fs::read(&garbage).unwrap(),
            garbage_before,
            "corrupt database was modified"
        );
        assert!(!dir.join("n.db-wal").exists() && !dir.join("g.db-wal").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn migrations_are_idempotent_on_disk() {
        let dir = std::env::temp_dir().join(format!("bs-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("t.db");
        Store::open(&p).unwrap().set_setting("a", "b").unwrap();
        let s = Store::open(&p).unwrap();
        assert_eq!(s.get_setting("a").unwrap().as_deref(), Some("b"));
        assert!(s.integrity_ok().unwrap());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
