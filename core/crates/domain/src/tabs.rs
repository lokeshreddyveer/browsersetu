use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TabId(pub u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tab {
    pub id: TabId,
    pub url: String,
    pub title: String,
    pub private: bool,
    /// Tab group name; empty means ungrouped.
    pub group: String,
    pub pinned: bool,
    /// Workspace name; empty means the default workspace.
    pub workspace: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum TabError {
    NotFound,
}

/// In-memory registry of open tabs, in display order.
#[derive(Default)]
pub struct TabRegistry {
    next_id: u64,
    order: Vec<TabId>,
    tabs: HashMap<TabId, Tab>,
}

impl TabRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn create(&mut self, url: &str, private: bool) -> Tab {
        self.next_id += 1;
        let tab = Tab {
            id: TabId(self.next_id),
            url: url.to_owned(),
            title: String::new(),
            private,
            group: String::new(),
            pinned: false,
            workspace: String::new(),
        };
        self.order.push(tab.id);
        self.tabs.insert(tab.id, tab.clone());
        tab
    }

    pub fn close(&mut self, id: TabId) -> Result<(), TabError> {
        self.tabs.remove(&id).ok_or(TabError::NotFound)?;
        self.order.retain(|t| *t != id);
        Ok(())
    }

    pub fn navigate(&mut self, id: TabId, url: &str) -> Result<(), TabError> {
        self.tabs.get_mut(&id).ok_or(TabError::NotFound)?.url = url.to_owned();
        Ok(())
    }

    pub fn set_group(&mut self, id: TabId, group: &str) -> Result<(), TabError> {
        self.tabs.get_mut(&id).ok_or(TabError::NotFound)?.group = group.to_owned();
        Ok(())
    }

    pub fn set_pinned(&mut self, id: TabId, pinned: bool) -> Result<(), TabError> {
        self.tabs.get_mut(&id).ok_or(TabError::NotFound)?.pinned = pinned;
        Ok(())
    }

    pub fn set_workspace(&mut self, id: TabId, workspace: &str) -> Result<(), TabError> {
        self.tabs.get_mut(&id).ok_or(TabError::NotFound)?.workspace = workspace.to_owned();
        Ok(())
    }

    /// Moves a tab to `index` in display order (clamped).
    pub fn move_to(&mut self, id: TabId, index: usize) -> Result<(), TabError> {
        let from = self
            .order
            .iter()
            .position(|t| *t == id)
            .ok_or(TabError::NotFound)?;
        self.order.remove(from);
        self.order.insert(index.min(self.order.len()), id);
        Ok(())
    }

    pub fn get(&self, id: TabId) -> Option<&Tab> {
        self.tabs.get(&id)
    }

    pub fn set_page(&mut self, id: TabId, url: &str, title: &str) -> Result<(), TabError> {
        let t = self.tabs.get_mut(&id).ok_or(TabError::NotFound)?;
        t.url = url.to_owned();
        t.title = title.to_owned();
        Ok(())
    }

    pub fn list(&self) -> Vec<Tab> {
        self.order
            .iter()
            .filter_map(|id| self.tabs.get(id).cloned())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_navigate_close() {
        let mut r = TabRegistry::new();
        let a = r.create("https://a.example", false);
        let b = r.create("https://b.example", true);
        r.navigate(a.id, "https://c.example").unwrap();
        assert_eq!(r.list()[0].url, "https://c.example");
        r.close(b.id).unwrap();
        assert_eq!(r.list().len(), 1);
        assert_eq!(r.close(b.id), Err(TabError::NotFound));
    }

    #[test]
    fn workspace_and_reorder() {
        let mut r = TabRegistry::new();
        let a = r.create("https://a", false);
        let b = r.create("https://b", false);
        let c = r.create("https://c", false);
        r.set_workspace(b.id, "Work").unwrap();
        assert_eq!(r.list()[1].workspace, "Work");
        r.move_to(c.id, 0).unwrap();
        assert_eq!(
            r.list().iter().map(|t| t.id).collect::<Vec<_>>(),
            vec![c.id, a.id, b.id]
        );
        r.move_to(c.id, 99).unwrap();
        assert_eq!(r.list().last().unwrap().id, c.id);
        assert_eq!(r.move_to(TabId(99), 0), Err(TabError::NotFound));
    }

    #[test]
    fn groups_and_pinning() {
        let mut r = TabRegistry::new();
        let a = r.create("https://a.example", false);
        r.set_group(a.id, "Work").unwrap();
        r.set_pinned(a.id, true).unwrap();
        let t = &r.list()[0];
        assert_eq!((t.group.as_str(), t.pinned), ("Work", true));
        assert_eq!(r.set_group(TabId(99), "x"), Err(TabError::NotFound));
    }
}
