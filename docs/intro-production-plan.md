# First-launch film — visual diagnosis and production plan

Status: diagnosis and recommendation only. No further visual iteration has been made. Nothing is committed.

Frames reviewed: the nine rendered frames of the latest build ("Nothing gets between you and the web"), plus the earlier rounds (archer, bridge, arc, Invisible Web layers).

---

## 1. Why the current film looks artificial

| Area | What the frames show | Root cause |
|---|---|---|
| **The person** | A dome-shaped head on a pinched neck on a dome of shoulders. It is huge, sits dead centre, covers the article, and reads as an icon or a bust, not a person. The "rim light" is a stroke around the shape, not light falling on a body. | A human cannot be convincingly built from a few bezier paths. There is no ear, hair, hood, back, posture, or relation to the laptop (no arm, no chair). |
| **The laptop** | Flat, dead-on, orthographic: a rounded rectangle on a thin bar. No foreshortening, no keyboard or hinge depth, no screen light falling on the desk or the person. It reads as a monitor on a ledge. | Perspective and lighting are the two things a 2D canvas cannot fake without a 3D model. |
| **The room** | One dark gradient with a hard horizon line. Nothing grounds the scene: no lamp, window, depth of field or reflections. | No scene, only a background. |
| **Camera** | A uniform scale and a small shift of one flat plane. No parallax and no perspective change, so it reads as a zoom, not a camera. | Canvas scales; it does not have a camera. |
| **Ads and trackers** | Drawn as a diagram: dashed boxes with host labels, lines through empty space to pills that are cut off at the screen edge. Nothing happens inside the page, where real activity would be. At 5.0 s, a pop-up, two ad panels, three tooltips, a status bar, a chip, four tracker lines and glow flashes are on screen at once; none can be read in the time they are visible. | Too many things at once, and a diagram standing in for behaviour. |
| **The boundary** | The "touch" glows are soft blobs on the edge. They read as smudges, not as a barrier meeting a request. | Generic radial glows. |
| **The brand mark** | The final frame shows the old blue-and-gold icon inside a gold ring. It breaks the teal-only palette. | The mark was not recoloured for this palette. This one is a plain bug. |
| **Pacing** | Not measured. I only evaluated stills. | A film has to be judged in motion. |

What does work: the invented article page, the browser chrome, the address cleaning, the pop-up, the warning card, the typography, and the palette. Those are interface and typography, which is what code draws well.

The diagnosis in one line: **I used code for the part of the film that needs a camera, light and a human, and it cannot do those.** Rive and Lottie would not fix it either: they are 2D vector runtimes with the same limit.

---

## 2. Options

| Option | Quality of person, laptop, room, camera | Size | Risk | Verdict |
|---|---|---|---|---|
| **A. Code only** (SwiftUI Canvas, what exists) | Poor for human and laptop, good for UI | ~0 MB | Already tried five times | Stop |
| **B. Lottie / Rive** | Same 2D limit; adds a runtime | Rive runtime is large on mobile (about 12 MB of native libraries in one Android test, [Wikimedia](https://phabricator.wikimedia.org/T433250)) | New dependency, no quality gain for a human | Reject |
| **C. RealityKit / SceneKit live 3D** | Real 3D, but needs a modelled, rigged person and laptop | Assets of several MB | A believable person is a modelling project; SceneKit is in maintenance mode | Reject for a short film |
| **D. Pre-rendered video only** (HEVC), played natively | Whatever the plate looks like, predictable | About 6 to 12 MB at 1080p ([size is bitrate × seconds ÷ 8](https://compresto.app/blog/hevc-codec-explained)) | The film becomes a fixed picture: text baked in, hard to localise, truthful UI is only as truthful as the artist | Good, but see E |
| **E. Hybrid: video plate + live vector overlay (recommended)** | The cinematic parts (person, laptop, room, camera) are real footage or render; the protection moments are crisp live vector | Same as D | Needs a locked-off shot for the overlay | **Recommended** |

### Why the hybrid
- The part of the film code cannot do (the person, the laptop, light, camera moves) comes from a real plate.
- The part code does very well (the page, the address cleaning, the warning card, the boundary, the type, the mark) stays live: it is crisp at any resolution, accurate to the real features, and stays editable and localisable.
- The overlay only needs to line up with the picture while the camera is still. So the shot list moves the camera in Scenes 1 and 2 and locks it off for Scene 3, where the protections happen.

---

## 3. Recommended pipeline

```
 plate (HEVC, 16:9 and 9:16)        live overlay (SwiftUI Canvas)         sound (separate, off by default)
 ─ person, laptop, room, light       ─ tracker lines, ad panels            ─ synthesised, AVAudioEngine
 ─ camera moves in S1–S2             ─ boundary + touches, filter count
 ─ locked-off from ~3.8 s            ─ address cleaning, pop-up chip
 ─ article on the screen             ─ warning card, mark, wordmark, lines
        │                                  │
        └──────────── AVPlayer (AVKit/AVPlayerLayer) ──┘   one clock: the player's time
                       │
        Skip · Reduce Motion (poster frames) · failure → straight to setup · stops when inactive
```

- **Playback**: `AVPlayer` with an `AVPlayerLayer` in a SwiftUI representable, full window, muted by default (video track has no audio). The overlay reads the player's current time, so it can never drift from the picture.
- **Skip**: stops the player and removes the layer at once.
- **Reduce Motion**: three poster frames cross-faded (no video decode at all).
- **Failure**: if the file is missing or the player fails, go to setup immediately.
- **Offline**: the clip is in the app bundle.
- **Memory**: one decoded stream; the clip is released when the film ends.

### Size budget
| Deliverable | Spec | Approx. size |
|---|---|---|
| Mac and iPad | 16:9, 2560 × 1440, HEVC, 8 Mbps, 24 or 30 fps, 9 s | about 9 MB |
| iPhone | 9:16, 1080 × 1920, HEVC, 6 Mbps, 9 s | about 7 MB |
| Poster frames (Reduce Motion) | 3 stills, HEIC | under 1 MB |
| **Total in the app** | | **about 17 MB** |

(Estimates from bitrate × duration; measure the real encode before committing to a size.)

---

## 4. Where the plate comes from — the decision I need

| Route | Quality | Cost | Licence / risk |
|---|---|---|---|
| **1. A motion designer or 3D artist** (Blender, Cinema 4D) to a brief | Highest and fully controlled | Highest | Clear: work for hire |
| **2. A generative video tool**, prompted from the brief, then graded to the palette | Can look filmic; people and screens can be unstable (hands, text, screen content) | Low | Check each tool's commercial and in-app redistribution terms |
| **3. Licensed stock footage** of a person at a laptop at night, then graded | Realistic, no 3D work | Low to medium | Many stock licences forbid embedding in distributed software; check "software or app" use specifically |

My recommendation: **route 2 or 3 for speed, route 1 for the best result.** In every route the screen shows a plain, uncluttered article page, so the live overlay can sit on it.

---

## 5. Production brief (for any of the routes)

**Look**: near-black night room lit only by the laptop screen; cool teal light on the hair, ear and shoulder; deep purple haze in the background; shallow depth of field. Grade to the palette: `#09090F` blacks, `#397E96` and `#8FD0E3` highlights, `#472E5A` shadows.

**Shot list (9 s)**

| Time | Shot |
|---|---|
| 0.0–2.0 | Over the shoulder, slow push toward the laptop. The person reads; the screen shows an article ("How do black holes form?"). |
| 2.0–3.8 | The push continues until the screen fills about 75% of the frame. The person scrolls once. |
| 3.8–7.0 | **Locked off.** Same framing, the article steady. This is where the live overlay works. |
| 7.0–7.5 | A gentle pull back to the person, still reading. |
| 7.5–9.0 | Slow fade to `#09090F` (the brand reveal is live on top). |

**Screen area**: keep a clean, flat, evenly lit page; give me the screen's corner positions in pixels for the locked-off section (for overlay alignment).
**Camera**: no handheld shake; slow, even eases.
**No on-screen text to be baked in** beyond the article itself; no brand logos.

**Deliverables**: 16:9 and 9:16 versions, HEVC (hvc1) in .mov or .mp4, sRGB/Rec.709, no audio track, 24 or 30 fps, plus 3 poster stills.

---

## 6. What I would do next (after you choose a route)

1. Fix the mark colour in the final frame (a bug, independent of the route).
2. Build the playback harness: `AVPlayer` in the exclusive root, Skip, Reduce Motion posters, failure fallback, and the overlay driven by the player clock. I can build and test this with a placeholder clip before the real plate exists.
3. Rework the overlay so only one protection plays at a time, at readable size, over the locked-off shot.
4. Add the synthesised, off-by-default sound.
5. Render, review in motion, performance check, independent review.

## 7. Decisions needed

1. Which production route (1, 2 or 3)?
2. Is a hybrid (plate + live overlay) acceptable, with the film's text and protection effects live?
3. Should I start on the playback harness with a placeholder clip now?
