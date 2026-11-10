# Download extensions (API version 1)

A download extension is a small package of **data**: a `manifest.json` and one rule file. It cannot run code, open a connection, read the browser's data, or start a download. When you paste an address into Add Download, Browser Setu asks each enabled extension "what would you suggest for this address?", checks every answer again, and shows the result. You decide what to do with it.

## Why rules and not scripts
Scripts would need a sandbox. JavaScriptCore is not one (it has no memory limit, and its execution-time limit is a private interface), and a helper process with a verified sandbox profile is not something this build can prove. So version 1 offers only what can be enforced: rules interpreted by the app. Manifests that ask for `"runtime": "javascript"` or `"wasm"` are refused with a clear message. A future API version may add a script runtime behind the same permission model.

## Package
A `.zip` (or `.crx`) or a folder, at most 2 MB and 50 files. A folder that contains a link is refused; a link inside a zip is only ever written out as an ordinary file and is then subject to the same size limits. `manifest.json` is at the top.

## manifest.json
| field | meaning |
|---|---|
| `manifestVersion` | `1` |
| `apiVersion` | `1` (an extension that needs a newer API is refused) |
| `runtime` | `"declarative"` (the default; anything else is refused) |
| `id` | lowercase words joined by `.` or `-`, such as `com.example.files` |
| `name`, `version`, `description`, `author` | shown to the person; version is `1.2.3` |
| `entry` | the rule file, a `.json` path inside the package (no `..`, no hidden parts) |
| `capabilities` | any of `resolve`, `filename`, `category` |
| `hostPermissions` | URL patterns the extension may be asked about (required) |
| `optionalHostPermissions` | more patterns, granted only if the person allows |
| `proposeHosts` | the addresses it may suggest (scheme, host and path are all enforced; required with `resolve`; named public hosts only: numbers in any spelling, local names and DNS names that resolve to whatever address is written in them, such as `nip.io`, are refused) |
| `storage.quotaBytes` | 0 to 65536 (default 8192) |
| `settings` | up to 20 `{name,title,type: string/number/boolean,default,options}` |
| `update.url` | an https address, informational: never fetched by the app |
| `integrity.entrySHA256` | SHA-256 of the rule file, checked at install |

Patterns look like `https://*.example.com/files/*`. `*` in a path matches anything; `*.` in a host matches the domain and its subdomains; `<all_urls>` is allowed but shown as a warning.

## Rule file
```json
{ "rules": [ { "id": "page", "match": "https://files.example.org/view/*",
  "resolve": { "resources": [ { "url": "https://cdn.example.org/files/{last}.zip", "filename": "{last}.zip", "mimeType": "application/zip", "size": 1048576, "title": "{last}" } ] },
  "filename": "{last}.zip", "category": "Archives" } ] }
```
Tokens: `{url}` `{scheme}` `{host}` `{path}` `{path.N}` (1-based segment) `{last}` `{query.NAME}` `{fragment}` `{setting.NAME}`. A token with no value (a missing segment or parameter) makes that rule suggest nothing. In an address, token values are percent-encoded, so a value can fill in a name but never change the host, add a path separator, or add a parameter. **The scheme and host of a suggested address must be written out in the template and must be listed in `proposeHosts`.** At most 100 rules, 20 resources per rule, 512 characters per template.

## Permissions
The app grants exactly what the manifest declares and the person approved. Access is checked on every request, so turning something off takes effect at once. An extension is only ever asked about addresses matching a granted host pattern. Updates that ask for more access need approval; the old version stays active until then, and a failed update leaves the old version untouched.

## What an extension can and cannot do
Can: suggest addresses (and a list of related files), a file name, a kind of file, with names and sizes to display. Cannot: start, pause, cancel or finish a download, choose a folder, read or write files, use the network, read cookies or passwords, or see other extensions' data. Suggested addresses are marked as coming from an extension and the app's download safety rule, which only accepts addresses you gave it yourself, still applies: "Copy Address" is how a suggestion reaches a download, by you pasting it.

## Not supported in version 1
Scripts and WebAssembly; network access for extensions; task events (`onProgress`, `onCompleted`…, which need code to react); automatic update downloads; compatibility with Gopeed or Chrome extensions.

## Errors
Install and update errors are plain sentences (for example "The manifest does not say its “id”", "The package holds something that is not allowed (a link)"). Diagnostics keep the last 100 events per profile and never include addresses.

## Developing
Put `manifest.json` and the rule file in a folder, choose **Install Extension…** in Settings > Downloads > Download extensions, read the permissions, install, then paste a matching address into Add Download. See `docs/examples/download-extension-sample`.
