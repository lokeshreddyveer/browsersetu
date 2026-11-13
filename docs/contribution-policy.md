# Git contribution, authorship and AI-attribution policy

Authoritative for this repository. It is the project copy of the owner's universal policy for every repository they own or maintain; `CLAUDE.md` points here and must not repeat it.
The owner's wording stays the source of truth: where this file and the owner's instruction differ, the instruction wins and this file is corrected.

## 1. Authorship rules (always)
- Keep the owner's configured author and committer identity. Never alter anyone's identity to make a contributor disappear, and never invent or replace human authorship.
- Never add an AI assistant (Claude, Anthropic, ChatGPT, OpenAI, Copilot, Gemini, Cursor, Codex, or any other) as author, co-author or contributor: no `Co-authored-by:`, `Signed-off-by:`, `Generated-by:` or `Assisted-by:` trailer, no "Generated with ..." footer.
- No AI credits in READMEs, source comments, documentation, changelogs, release notes, contributor listings or other public material.
- Keep every legitimate human contributor and all legally required third-party copyright, licence and attribution text. Respect mandatory disclosure requirements where they apply.
- Technical mentions of AI (this product's own AI-tools connection feature, interoperability text) are not attribution and are not blocked.

## 2. Enforcement in this repository
- Commit-message hook `.githooks/commit-msg` strips AI trailers and "Generated with" footers and refuses a commit whose author or committer identity names an AI tool. Enable once per clone: `git config core.hooksPath .githooks`.
- `python3 -I scripts/check-attribution.py` checks tracked files, generated metadata, release notes and every commit after `.attribution-baseline`. `release.sh` and `publish-release.sh` run it.
- Automated tools that create commits must not add attribution; the hook is the safety net, not the plan.

## 3. Cleaning up an existing repository (only when the owner asks for that repository)
1. Audit all branches, tags and remote refs; list the trailers and the commits affected; check whether the AI account appears in GitHub's Contributors graph because of them.
2. Back up first: a bundle of all refs, a copy of `.git`, a mirror of the remote; prove the bundle restores every ref; write the rollback steps; keep the backup somewhere durable (not a temp folder).
3. Rewrite in an isolated mirror, removing only the AI co-author metadata. Keep identities, dates, parents, file changes and trees.
4. Compare old and new history commit by commit: trees identical, only the intended lines removed, no unexpected differences.
5. Work out the consequences for tags, signed tags, releases, build provenance, checksums, CI/CD, update feeds and existing clones; do not break published artifacts. If keeping a published reference conflicts with removing a trailer, report the conflict instead of changing or falsifying provenance.
6. Only then update the remote (leased force-push, tags only if release compatibility is preserved), keep an old-to-new commit-id map with the release, and verify a fresh clone, the release assets, the update feed and the Contributors graph. GitHub's statistics can be cached: report the corrected history separately from a pending UI refresh.
7. Never delete production releases, application data or backups as part of the cleanup. Never touch repositories the owner did not name.

## 4. Completion report (every authorized cleanup)
Repository; AI attribution found and commits affected; original and rewritten refs; human authorship preserved; source-tree equivalence; backup and recovery status; release and deployment integrity; GitHub contributor status; future prevention; unresolved risks.

## 5. This repository's cleanup (done 2026-11-11)
19 commits carried one trailer each; removed in a verified rewrite (trees identical, 116 of 116 commits paired, only those 19 lines removed). `main` 65ff512 -> 5b99984, `v0.4.2` 921c7fa -> 4038420; the id map is attached to the v0.4.2 release. Recovery backups: `~/Documents/BrowserSetu-recovery/history-cleanup-2026-11-11/` (rollback steps in `ROLLBACK.txt`).
