# Website accounts for downloads (Phase 24)

**Settings ▸ Downloads ▸ Website accounts.** A list, per browser profile, of websites you have chosen to give a credential to for downloads the app makes itself.

## What it is, and what it is not

* **For:** an address typed or pasted into Add Download (the app's own downloader).
* **Not:** a login robot. It never reads a login form, never sees a password typed into a page, never handles one-time codes or captchas, and never reads or exports the browser's cookies or session. A download started from a page you are signed in to keeps using that page's own WebKit session exactly as before (Phase 12). Nothing in the WebKit download code, the extension layer, the automation service, the Website Explorer or the remote companion references accounts (a test scans the sources for this).

## Methods

| Method | What is stored | What is sent |
|---|---|---|
| **API token** | the token, in the Keychain | `Authorization: Bearer <token>` |
| **User name and password (HTTP Basic)** | the user name in the list, the password in the Keychain | `Authorization: Basic …` |
| **Signed-in browser session** | nothing | nothing (the entry only records that you use the site signed in, so a link on it is explained) |

Not supported: Digest, OAuth/OpenID Connect flows, and site-specific adapters. None of the three has a real integration here, and no hoster is claimed to work. The only verification is against a local fixture server that answers 401 unless it gets the exact header.

## Where a credential goes

Only to the **exact website** (host and port) you named, only over **https**, only for **your own** request (not a page-derived, automation, extension or remote one), never for a private download, and only in the `Authorization` header. The existing redirect rules drop it the moment a redirect leaves that website (checked on all four paths: single transfer, probe, parts, streams). Mirrors and other sources a server names are asked as strangers. Plain `http://` to an account's website is refused with an explanation rather than sent without the credential or with it.

## Storage

* The list (`accounts/<profile>/accounts.json`, owner-only) holds names, hosts, methods, states, times and user names, never a secret.
* The secret is in the Keychain, **this device only** (never iCloud), under a service named for the profile. A locked or refused Keychain is shown as "Keychain unavailable", not as signed out, and the account works again when it can be read. If the Keychain will not save, nothing is added and an existing credential is untouched (it is updated in place).
* A task never holds a credential: only a flag (`account=1`) saying one was used. Resume data from the system embeds the request, headers included, so **none is ever kept or used** for a transfer that carried a credential; it starts again from the beginning.
* Removing a profile removes its list and its Keychain items. An unreadable list is moved aside (never overwritten) and nothing is added until you reset it.

## Lifecycle

Connected → (website answers 401) **Sign-in needed again** → you reconnect. Also: Expired (an end date you gave passes), Disconnected (credential forgotten, entry kept), Revoked, Keychain unavailable. A refused or expired account **stops** the download with the reason; it is never sent anonymously (which could save a login page as the file) and never with another account, and nothing is retried with a refused credential. Only a request that carried the credential, from you, started after the credential was last changed, can mark it refused. Disconnecting, deleting or a refusal stops the downloads running with that account, and a download that used it is not carried on anonymously afterwards.

## LinkGrabber

A link whose website has an account shows a small line under its host: connected (use Add Download to sign in), sign in again, expired, signed-in session, or only-over-https. Links from a page are never given credentials.

## Not verified

No real website, hoster or OAuth service; the Settings screen has never been seen running; the Keychain code paths (locked, denied) are exercised only through an in-memory stand-in.
