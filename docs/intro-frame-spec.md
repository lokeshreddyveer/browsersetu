# The Invisible Web — master frame specification

Status: specification. It is the contract between the artwork (whatever route produces it) and the engine. Numbers marked *initial* are starting values to be refined against the real artwork; nothing here is a measured result.

Master: 9.0 s · 60 fps · **540 frames** · 1920 × 1080 design space · 16:9 · sRGB · dark. The master is a coordinate system, not a bitmap: every position is mapped to the real window by one responsive transform (§9).

---

## 1. Verdict on the current film (for the record)

| Area | Finding | Cause |
|---|---|---|
| Person | A dome on a dome; no ear, hair, hood, posture or contact with the laptop | not drawable from a few paths |
| Laptop | orthographic, front-on, no keyboard or hinge depth, no light on the desk | no perspective, no light model |
| Camera | uniform scale of one flat plane | no depth, so no parallax |
| Ads / trackers | a diagram (boxes, labels, lines in empty space), too many at once | not anchored to page regions |
| Boundary touches | soft blobs | generic radial glows |
| Final mark | old blue-and-gold icon | palette bug |
| Pacing | judged on stills only | never reviewed in motion |

Kept: the exclusive first-launch root, Skip, Reduce Motion, `intro_done`, `FirstLaunchGate`, the invented article page, the browser chrome, the address cleaning, the warning card, the palette, the typography.

---

## 2. Production approach (decision pending: see the last section)

```
  A. ART PLATE            B. SCREEN                C. CAMERA               D. OVERLAY
  person, laptop, room    the article page, live   parallax of 3 layers    boundary, filter, clean,
  (supplied artwork)      in 1440×900, mapped to   + a perspective-mapped  refuse, warn, mark, type
  3 depth layers          the laptop's screen quad screen                  (live vector, crisp)
  + 2 hand poses
```

Layers (back to front): `L0 room + desk + laptop body` · `L1 laptop screen (live page)` · `L2 person`. The camera moves each layer by a different amount (parallax) and re-projects the screen. This gives real depth from a still without a 3D model.

---

## 3. Camera (design space, initial)

Camera = (cx, cy, zoom) over the 1920 × 1080 space, with per-layer parallax factors `L0 0.55 · L1 1.00 · L2 1.45`.

| Segment | Frames | From → to | Curve |
|---|---|---|---|
| Push toward the laptop | 0–119 | zoom 1.00 → 1.95, centre (960, 540) → (1040, 480) | cubic-bezier(0.45, 0, 0.20, 1) |
| Settle on the page | 120–227 | zoom 1.95 → 2.10, centre → (1040, 470) | cubic-bezier(0.30, 0, 0.30, 1) |
| Hold | 228–431 | locked (zoom 2.10) | none; the overlay is aligned here |
| Pull back | 432–470 | zoom 2.10 → 1.70 | cubic-bezier(0.40, 0, 0.20, 1) |
| Ease to brand | 471–530 | zoom 1.70 → 1.55, room fades to `#09090F` | cubic-bezier(0.45, 0, 0.55, 1) |

No handheld shake. Velocity is zero at every segment boundary.

---

## 4. Scene 1 · A person browsing (frames 0–119)

*Composition (initial, from the brief):* screen centre (1040, 480), screen bounds x 610–1530 / y 210–775, laptop base x 470–1620 / y 760–915, person x 170–660 / y 270–1080, desk in the lower 20–25%. The screen is the key light.

| ID | Asset | Anchor | Frames | Notes |
|---|---|---|---|---|
| `env.bg` | `#09090F` + 2 glows | window | 0–539 | purple `#472E5A` upper right, teal haze `#2E4C5A` lower left |
| `env.desk` | desk plane | (960, 960) | 0–539 | contact shadow under the base, blur 24 |
| `laptop.body` | layered artwork | (1045, 838) | 0–539 | lid, bezel, hinge, base |
| `laptop.screen` | live page, mapped | screen quad | 20–539 | 1440 × 900 local; 4 corner points per frame |
| `light.screen` | teal glow on desk and person | screen quad | 0–539 | opacity follows screen brightness |
| `person.body` | layered artwork, 3 layers | (415, 760) | 0–539 | back, shoulder, head; rim light on the screen side |
| `person.hands` | two poses, cross-dissolved | (880, 800) | 21–90 | pose A (keys) → pose B (trackpad), 14-frame dissolve |

| Frames | What happens |
|---|---|
| 0–20 | the screen's light comes up first (no hard black); the laptop is revealed by it |
| 21–55 | the posture settles; one keystroke; the page appears on the screen |
| 56–90 | the hand moves to the trackpad (pose B); the article scrolls 12 px |
| 91–119 | the push continues; the screen becomes the dominant element |

*Easing:* hands ease-in-out over 14 frames; scroll uses a decelerating curve; the person's head moves ≤ 4 px.

---

## 5. Scene 2 · The unseen activity (frames 120–227)

The page: **"Cosmos Daily", "How do black holes form?"** (invented). Real page structure: masthead, navigation, headline, byline, a figure, body copy with one inline link, a "Read next" column.

Page content is rendered live at 1440 × 900 and mapped to the screen quad.

| Frames | What happens | Anchor of each element |
|---|---|---|
| 120–150 | camera finishes its push; the room leaves the frame | — |
| 151–180 | the page separates by ~14 px into **3 depth planes**: content / resources / requests. The article stays the anchor | planes share the page's origin |
| 181–205 | request lines grow **from named page regions** (figure, body, link, sidebar) to host labels at the screen edge | each line starts on a region's edge |
| 206–227 | the camera settles; content and activity are both readable | — |

Rule: nothing exists without a source. No free particles.

---

## 6. Scene 3 · Unwanted activity (frames 228–311), one event at a time

| Event | Frames | Cause → effect |
|---|---|---|
| A · advertising | 228–255 | an ad slot reserved in the sidebar starts to fill (a panel grows from the slot, not from outside the screen) |
| B · tracking | 256–280 | a request leaves the figure toward `analytics.example`; the line has an origin and a destination |
| C · suspicious link | 281–311 | the inline link is hovered; the status bar shows its destination `cosmosdaily-files.example/download`, visibly different from the site |
| (pop-up, as D) | 296–311 | held for Scene 4 so it is not shown at the same time as A–C |

Motion: controlled acceleration, no bounce, no shake, no flash.

---

## 7. Scene 4 · Protection (frames 312–431)

Real features only (see `docs/intro-the-invisible-web.md` §2).

| Frames | Event | Feature | Detail |
|---|---|---|---|
| 312–340 | a highlight travels the window edge | — | `#8FD0E3` core, `#397E96` support, 0.85 opacity at the head |
| 341–365 | boundary completes; ad request rejected at the edge | content rules | the panel stops growing and dissolves into the slot; one clean spark at the contact point |
| 366–378 | tracker request filtered | content rules | the line ends at the boundary and fades; no claim of cross-site prevention |
| 379–390 | the address loses `utm_source`, `utm_campaign`, `fbclid`; `topic=stars` stays | link cleaning | only parameters the sanitizer strips |
| 391–405 | pop-up refused | pop-up blocking | collapses to a "Pop-up blocked" chip in the address bar |
| 391–415 | link followed; calm warning | WebKit fraud warning | "Deceptive website ahead", "Go back" |
| 416–431 | effects settle; planes retract | — | boundary resting opacity 0.25 |

Boundary keyframes (initial): f312 0 · f324 0.5 · f340 0.85 · f358 1.0 · f400 0.7 · f460 0.25.

---

## 8. Scene 5 · Calm and brand (frames 432–539)

| Frames | Event |
|---|---|
| 432–470 | the planes are gone; the person reads; ambient light returns; the camera pulls back |
| 471–505 | the room fades to `#09090F`; the boundary glows once, then becomes the mark |
| 506–530 | **Browser Setu** (serif) · *The web is yours.* · Keep the unwanted out. |
| 531–539 | the film is already the setup's background; setup step 1 appears under it without a black frame |

The mark is the app's own icon, recoloured to the palette: ice teal ring, deep teal globe, `#DFF3F8` shield. No new logo.

---

## 9. Responsive transform

`screen = master × s + offset`, with `s = max(w / 1920, h / 1080)` for macOS and iPad landscape (aspect-fill, the story stays inside the centre 80%). iPhone portrait uses a second composition (9:16) with the same event order: a person holding a phone, the same page narrower, the same four protections stacked. Compositions are authored per aspect, not stretched.

---

## 10. Asset manifest

| Asset | Status | Needed from the art route |
|---|---|---|
| Room, desk, laptop body (L0) | **missing** | layered, 3 depth layers, no screen content |
| Person (L2) | **missing** | cut out on transparent, 3 layers (back, shoulder, head), rim-lit from the screen side |
| Hand poses A and B | **missing** | two stills with identical camera and light |
| Screen quad corners | **missing** | 4 points per camera position |
| Article page | exists (live) | to be re-laid at 1440 × 900 |
| Browser chrome, address cleaning, pop-up chip, warning card | exist (live) | |
| Boundary, spark, mark, type | exist (live) | recolour the mark |
| Sound | not started | synthesised in code, off by default |

For each supplied asset: record where it came from and the licence that allows redistribution inside a macOS/iOS app. Nothing is bundled without that record.

---

## 11. Verification

Checkpoint frames: **0, 15, 30, 60, 90, 119, 120, 150, 180, 205, 227, 228, 255, 280, 311, 312, 340, 365, 390, 415, 431, 432, 470, 505, 530, 539**, plus any frame where motion looks wrong. At each: anatomy, screen perspective, composition, occlusion, lighting, scale, typography, brand, continuity. Then play the film at speed and review contact sheets and short segments; a good still does not prove natural motion.

Performance: measure frame time, memory and decode cost on a real Mac and iPhone; report the numbers, do not assume them.

---

## 12. The decision that blocks the build

The engine can be built to this specification now. The film will look believable only if the **art plate** (§10, first four rows) is real artwork. I cannot create a convincing person or laptop in code, and I have no image or 3D generator in this environment.

**Route I recommend, which needs only still images:** supply one high-resolution still of the over-the-shoulder shot (person from behind, laptop with a **blank, evenly lit screen**, dark room, teal screen light, purple haze), plus a second still with the hand in a different position and nothing else changed. I will cut it into three depth layers, map the live page onto the screen with true perspective, and move the camera with real parallax. Hand and head motion will be small (a cross-dissolve and a slow breath), which is honest for a still. For iPhone, a second still of a person holding a phone.
