# The Invisible Web — first-launch film: design and engineering plan

Status: plan only. Nothing here is built yet. The earlier films (archer, bridge, Govardhan arc) are superseded by this one.

---

## 1. What the film must say

> A normal page has a second page behind it. Browser Setu shows you that page, and quietly deals with the parts you did not ask for.

One continuous take, 8.5 s, no cuts to browser UI, ending in the existing setup assistant.

```
  normal page ──► the page behind the page ──► what it is doing ──► Browser Setu draws itself ──► the same page, calmer ──► name ──► setup
     0–1.8s            1.8–3.6s                    3.6–5.0s               5.0–6.9s                     6.9–7.8s          7.8–8.5s
```

---

## 2. Accuracy audit — what may be shown

Checked in the code on 2026-11-10. The film may only depict a row marked **Show**.

| Protection | In Browser Setu? | On by default? | Evidence | Film |
|---|---|---|---|---|
| Ad and tracker request blocking (compiled content rules, filter lists) | Yes | Needs a fresh-profile check (the Start Page says "Protection on") | `Packages/SetuPrivacyKit` (`WKContentRuleList`), `Shared/BlockedCounter.swift`, `Shared/Privacy/*` | **Show**, as "requests filtered at the gate" |
| Tracking parameters stripped from links (`utm_…`) | Yes | **Yes** (`stripTrackingParameters = true`) | `BrowserModel.swift:862`, Start Page shows "N links cleaned" | **Show**, as parameters peeling off an address |
| Pop-up blocking | Yes | **Yes** (`blockPopups = true`) | `BrowserModel.swift:512` | **Show**, as an intrusive panel refused before it opens |
| Fraudulent-website warning | Yes, WebKit's own, switched on by the app | Yes | `WebKitEngine.swift:123` `isFraudulentWebsiteWarningEnabled = true` | **Show**, as a generic warning page; never as Browser Setu's own database |
| Camera / microphone / location permission controls, with expiry | Yes | Ask-each-time + expiry | `PermissionExpiry.swift`, `SitePermissionsSection` | Optional, one small chip |
| Cross-site tracking prevention | Not a Browser Setu feature. Third-party tracker requests are blocked by the filter lists; WebKit has its own engine-level protections. | — | no dedicated code | Show only as "third-party tracker requests blocked". Never claim cookie partitioning. |
| Fingerprint randomisation | Yes | **No (off)** | `BrowserModel.swift:441` | **Do not show** |
| WebRTC blocking | Yes | **No (off)** | `BrowserModel.swift:435` | **Do not show** |

Rules for the script: no "blocks all", no "stops hackers", no "safe". Copy says what it does: filters, cleans, warns, asks.

Before final: open a fresh profile and confirm the ad and tracker rules are on out of the box (the film shows them on).

---

## 3. Storyboard

Canvas 1000 × 560 grid (landscape). A portrait grid is specified in §8.

### Scene 1 · Normal browsing (0.0–1.8 s)

```
 ┌──────────────────────────────────────────────────────────────┐
 │  near black room, a soft pool of light on a desk            │
 │                                                              │
 │            ╭────────────────────────────╮                    │
 │            │ ● ● ●  ▭ trails & coastlines   │  ← a laptop,   │
 │            │ ┌────────────────────────┐ │    lit by its own  │
 │            │ │  TRAVEL PAGE: hero     │ │    screen          │
 │            │ │  photo, "Lisbon, 4 days"│ │                    │
 │            │ └────────────────────────┘ │                    │
 │            ╰────────────────────────────╯                    │
 │         ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔                  │
 └──────────────────────────────────────────────────────────────┘
 Camera: slow dolly in, ~6% per second, ending with the screen filling ~85% of the frame.
```

The page is a believable travel site we design ourselves (no real brand): hero image, a search card, three destination cards, a footer. Neutral invented name ("Wayfare").

### Scene 2 · Behind the page (1.8–3.6 s)

The page separates into layers along the depth axis; the camera slips between them.

```
  camera ──►     z = +3   VISIBLE PAGE        (what you see)
                 z = +2   AD RESOURCES        (banner, sponsored cards)
                 z = +1   TRACKER REQUESTS    (small gray hosts: analytics, pixels)
                 z =  0   IDENTIFIER          (one id, drawn as a thread to the other site)
                 z = −1   ANOTHER SITE        (a second faint page: "Shop")
```

Exploded view, side on:

```
        ┌────────┐ z=+3  page
          ┌────────┐ z=+2  ad slots, drawn as outlined boxes labelled with their host names
            ┌────────┐ z=+1  request lines leaving the page toward hosts
              ╲          z=0   one identifier (abc-3f9…) shown on both sites, joined by a line
                ┌────────┐ z=−1 the other site
```

Honest labels only: real-sounding but fictional hosts (`ads.example`, `pixel.example`, `metrics.example`).

### Scene 3 · Risks appear (3.6–5.0 s)

Three understandable risks, 0.4 s apart, none sensational:

1. An advertising panel slides over the page and covers the destination cards.
2. A link whose address is long and tracked (`…?utm_source=…&id=…`).
3. A second link whose text says one site and whose destination is another (a look-alike login).

### Scene 4 · Browser Setu emerges (5.0–6.9 s)

The scene darkens ~25%. An ice-teal line (#8FD0E3) draws the outline of a new browser window from one corner. Then, as the window settles, four visually distinct mechanisms play, one per protection:

| Mechanism | What you see | Real feature |
|---|---|---|
| Filter | Ad requests reach a thin gate line and dissolve into fine dust; the ad panel collapses into the gate | content rules |
| Clean | The tracked address loses its parameters one by one, leaving the plain address | strip tracking parameters |
| Refuse | The intrusive panel shrinks to a small "blocked" chip before it opens | pop-up blocking |
| Warn | The look-alike link, when followed, shows a plain, calm warning page with a "Go back" button | WebKit fraud warning |

The identifier thread is cut where it crosses the gate (the filter), not "destroyed".

### Scene 5 · A better browsing experience (6.9–8.5 s)

The travel page stays. The layers fold back into it, the room settles, the camera eases into the window until only the page and Browser Setu's frame remain. The wordmark rises; two lines in the serif:

> **The web is yours to explore.**
> Your privacy should stay yours.

Then the film dissolves into setup step 1 (same dark ground, same teal), with no black frame.

---

## 4. Timeline

```
 time(s) 0     1     2     3     4     5     6     7     8   8.5
         │─ S1 ─────│─ S2 ──────│─ S3 ─────│─ S4 ──────────│─ S5 ──────│
 camera  dolly in ───►  slip between layers ──►  settle  ──►  ease into window
 layers  ·············· separate ━━━━━━ hold ━━━━━ ─ ─ fold back ─ ─ ─ ─
 risks                                      ad ▪ link ▪ lookalike ▪
 protect                                                 filter▪clean▪refuse▪warn▪
 copy                                                                  name ▪ lines ▪
 handoff                                                                         ──► setup
```

Frame budget: 60 fps on macOS, up to 120 fps on ProMotion, never more than 16 ms of main-thread work in a frame.

---

## 5. Rendering technology — decision

| Option | Quality | Cost / risk | Verdict |
|---|---|---|---|
| **SwiftUI `Canvas` + `TimelineView`, 2.5D** (layers with scale, offset, blur, perspective faked on the camera) | Crisp vector, brand-exact type and colour, resolution independent, runs on macOS and iOS from one source, no assets | Not true 3D: no real lighting or refraction | **Chosen for everything on screen except the laptop** |
| SwiftUI views with `rotation3DEffect` / `perspectiveRotationEffect` | Real perspective tilt per layer | Apple warns the angle and axis interpolate separately, which can look wrong in long camera moves ([docs](https://developer.apple.com/documentation/swiftui/view/rotation3deffect(_:axis:anchor:).md)); text-heavy views are costly | Use only for the 2–3 hero layers, with the camera driven by one clock |
| SceneKit | Real 3D | Soft-deprecated: maintenance mode only ([WWDC25 summary](https://dev.to/arshtechpro/wwdc-2025-scenekit-deprecation-and-realitykit-migration-a-comprehensive-guide-for-ios-developers-o26)) | **Rejected** for a new feature |
| RealityKit | Real 3D, PBR, Apple's recommended engine | A procedurally built, believable laptop is a project of its own; startup cost; more GPU | Reserve: only if the 2.5D laptop is judged not good enough |
| Metal directly | Anything | Largest build and maintenance cost | Rejected |
| Pre-rendered HEVC video, bundled | Photoreal possible | Large (tens of MB), a fixed resolution and aspect, no live typography, harder to localise, needs a 3D tool outside this repo | Rejected unless you supply the clip |

Decision: **vector 2.5D in SwiftUI Canvas**, the laptop included, drawn with careful gradients, edge light and a soft contact shadow, in the style of an Apple product still, not a photograph. To be honest: this will read as an elegant illustration, not as a photoreal laptop. If you want photoreal, the options are a RealityKit laptop (more work, riskier) or a clip you provide.

---

## 6. Architecture

```
  BrowserSetuMacApp / BrowserSetuiOSApp
            │
            ▼
   MacRootView / PhoneRootView / IPadRootView
     ZStack
      ├─ browser content            (built beneath, opacity 0, not hit-testable, hidden from VoiceOver while the film plays)
      └─ FirstLaunchIntro           (only if model.showIntro; opaque from the first frame; zIndex top)
            │
            ├─ IntroClock           one clock t for the whole film; frozen by BS_INTRO_AT for review
            ├─ IntroCamera          position, zoom, drift as functions of t
            ├─ Scenes
            │    ├─ RoomScene       room, desk light, laptop (Scene 1)
            │    ├─ PageLayers      page, ads, trackers, identifier, other site (Scenes 2–3)
            │    ├─ SetuWindow      the drawn browser window and the four mechanisms (Scene 4)
            │    └─ Resolve         fold-back, wordmark, lines (Scene 5)
            ├─ IntroPalette         the ten brand colours (below), nothing else
            ├─ SkipButton           ⌘. / Esc / tap; 44 pt target on iOS
            └─ ReducedMotion        three still frames, cross-faded
```

First-launch state machine (extends the existing `setup_done` flow):

```
                      ┌───────────────────────────────────────────┐
  launch ──► setup_done == "1" ? ──yes──► BrowserReady (no film)  │
                │no                                               │
                ▼                                                 │
        intro_done == "1" or forced or BS_SKIP_INTRO ? ──yes──► SetupAssistant
                │no
                ▼
          CinematicIntro ── Skip ───────────────┐
                │ plays to the end              │
                ▼                               ▼
           intro_done = "1" ──────────────► SetupAssistant ──► setup_done = "1" ──► BrowserReady
   quit during the film: intro_done stays unset, setup_done stays unset (the film plays again next launch)
```

Failure rule: if the film cannot draw (an exception, a missing asset, a thermal/low-power refusal), it calls `finish()` at once and setup shows. The film never gates onboarding.

Persistence: two keys, `intro_done` (new) and `setup_done` (existing). Secondary windows never show the film. "Run Setup Again" never shows the film. Existing profiles have `setup_done` and never see it.

---

## 7. Brand tokens (the only colours allowed)

| Token | Hex | Used for |
|---|---|---|
| ink | `#09090F` | the room, window ground |
| surface | `#15161A` | desk, laptop body |
| panel | `#1B1D24` | page cards, panels |
| accent | `#397E96` | lines, buttons, glow |
| ice teal | `#8FD0E3` | the drawn window outline, key highlights |
| deep teal | `#1F5870` | shadows in teal |
| muted purple | `#472E5A` | ambient glow upper right |
| teal haze | `#2E4C5A` | ambient glow lower left |
| highlight | `#DFF3F8` | type, shield, small specular |
| secondary text | `#8C8D91` | captions, host labels |

Type: New York (serif) for the wordmark and the two lines; SF for the page and hosts.

The invented travel page uses these tokens as well (desaturated photos are drawn from teal and purple), so nothing competes with the brand.

---

## 8. iOS

Same source, two compositions:

```
   Landscape (Mac, iPad)              Portrait (iPhone)
   grid 1000 × 560                     grid 560 × 1000
   ┌───────────────────────┐           ┌────────────┐
   │   laptop on a desk    │           │  phone in   │   iPhone: no laptop. Scene 1 shows the page already
   │   page fills ~85%     │           │  hand-less  │   in a phone frame (same drawn style), so the story
   └───────────────────────┘           │  frame      │   starts with the same page on a smaller screen.
                                       │  page fills │   Layers separate vertically instead of in depth.
                                       └────────────┘
```

- Hosted in `PhoneRootView` and `IPadRootView` exactly like `MacRootView` (the view is already cross-platform; the Krishna image slot used AppKit, and is removed).
- Safe areas: the film ignores them; Skip sits inside them.
- Skip target ≥ 44 pt. Dynamic Type does not scale the wordmark, but the two lines respect it down to a limit.
- Low Power Mode and `ProcessInfo.thermalState >= .serious`: reduce blur, drop to 30 fps, or take the Reduce-Motion path.
- iPad: landscape composition, scaled to the window; Stage Manager resizes are handled because the layout is a function of the window size.

---

## 9. Accessibility

- Reduce Motion (macOS: Reduce motion; iOS: Reduce Motion): no camera move. Three still frames cross-faded: the page, the page with the four protections shown as a diagram, the wordmark. About 3 s, then setup.
- VoiceOver: the film is one element with a spoken summary; Skip is the first control.
- The two lines are real text (not baked into artwork).
- Contrast: all type ≥ 4.5:1 against its background.

---

## 10. Performance budget

| Item | Budget |
|---|---|
| First frame | before the browser content is built; the film is the first thing drawn |
| Main-thread work per frame | ≤ 8 ms average, ≤ 16 ms worst |
| Memory | ≤ 40 MB for the film |
| Blur layers on screen at once | ≤ 6 |
| Assets | none required (all vector); any bundled image < 1 MB, local |
| After the film | the clock stops, the view is removed, nothing keeps animating |

---

## 11. Verification plan

1. Frames at fixed moments via `BS_INTRO_AT` (0.9, 1.7, 2.6, 3.4, 4.3, 5.2, 6.0, 7.2, 8.3) in dark mode, at three window sizes, plus iPhone and iPad simulators.
2. UI tests: no browser chrome visible during the film; Skip reaches setup; playing through reaches setup; a returning profile never shows it; `BS_SKIP_INTRO` bypasses it.
3. Reduced Motion test: the still path.
4. Instruments: frame pacing, memory, GPU time over the 8.5 s.
5. Interrupted launch: quit at 3 s, relaunch, film plays again, setup not marked done.
6. Independent review by a second reader of the code and the frames.

---

## 12. Build order

1. Clock, camera, palette, Skip and Reduced-Motion shell (reuse what exists in `Shared/Intro`).
2. The travel page and the laptop (Scene 1).
3. The layer separation and the camera slip (Scene 2).
4. The three risks (Scene 3).
5. The drawn window and the four mechanisms (Scene 4).
6. The resolve and the wordmark (Scene 5) and the setup hand-off.
7. iPhone portrait composition and iPad.
8. Frames, tests, review, report.

---

## 13. Decisions I need from you

1. **Laptop**: vector illustration (recommended) or photoreal RealityKit model (more work, more risk)?
2. **iPhone**: a phone frame (recommended) or no device at all, just the page filling the screen?
3. **The look-alike login**: shown as a calm warning page only (recommended), or also shown being followed?
4. **Copy**: confirm the two lines exactly as written, and that no other text is wanted.
