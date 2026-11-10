# First-launch film — artwork contract

For: the artist or tool producing the plates. If you deliver files that meet this contract and a valid `film.json`, the film is built from them with no code changes.

The film is an engine (`Shared/Intro/Film`). It owns the timeline (540 frames, 60 fps), the camera with parallax, the live article page that is mapped onto the laptop's screen with true perspective, and every protection effect. **You supply the picture of the person, the laptop and the room.** Without a valid manifest the film is not shown at all and first launch goes straight to setup, so nothing placeholder can reach a person.

---

## 1. What to deliver

All layers are drawn at the **camera's rest pose** (zoom 1, centred), in the **master design space**:

- landscape (Mac, iPad): **1920 × 1080**
- portrait (iPhone): **1080 × 1920**

Each layer is a transparent PNG or HEIC (sRGB), placed by a `frame` rectangle in master space. Supply 2× the master size for Retina-sharp edges (3840 × 2160 / 2160 × 3840) and keep the `frame` in master units.

| Role | Depth (how much of the camera it follows) | What it is |
|---|---|---|
| `room` | 0.55 (far) | the dark room, the desk plane, any background; full frame; **no laptop, no person** |
| `laptop` | 1.00 (reference) | the laptop body: lid, bezel, hinge, base, and its contact shadow on the desk. **The screen area is transparent** (a hole): the live page shows through it |
| `person` | 1.45 (near) | the person from behind, over the shoulder, cut out on transparent, lit by the screen's teal light on the edge facing it (rim light, ear, shoulder). Everything except the hands |
| `handsA` | 1.45 | the hands on the keys; the same frame as `handsB` |
| `handsB` | 1.45 | the same shot with the hand on the trackpad. **Only the hands differ.** Camera, person, laptop and light are identical |
| `foreground` *(optional)* | 1.70 | anything in front of the person: an out-of-focus edge of a lamp, a plant |

`handsA` and `handsB` must have an identical `frame` (the validator checks this). The film dissolves from A to B over frames 56 to 70.

### The screen quad
The four corners of the laptop's screen (the hole) in master space, **at rest**, ordered **top-left, top-right, bottom-right, bottom-left** (clockwise). It may be a true quadrilateral (a screen seen at an angle). Corners must lie inside the master space and the shape must be convex.

### The live page
Rendered by the engine at **1440 × 900** (`screenSize`; portrait **900 × 1600**) and mapped onto the quad. Keep the screen area in your art empty and evenly lit; the engine adds the page, its glow, and the protection effects.

### Why the camera moves
The camera pushes in over frames 0 to 119, settles to 227, is **locked off** from 228 to 431 (the protection events are drawn against this exact framing), then pulls back and fades. Design the art so that it holds up at zoom 2.1 on the screen area and person's shoulder; the room can be soft.

---

## 2. The manifest

`Film/film.json` in the app bundle. One composition per orientation.

```json
{
  "version": 1,
  "compositions": {
    "landscape": {
      "master": [1920, 1080],
      "screenQuad": [[610, 210], [1530, 210], [1530, 775], [610, 775]],
      "screenSize": [1440, 900],
      "layers": [
        { "id": "room",   "role": "room",    "file": "film_room",   "frame": [0, 0, 1920, 1080], "depth": "room",   "z": 0 },
        { "id": "laptop", "role": "laptop",  "file": "film_laptop", "frame": [0, 0, 1920, 1080], "depth": "laptop", "z": 1 },
        { "id": "person", "role": "person",  "file": "film_person", "frame": [0, 0, 1920, 1080], "depth": "person", "z": 3 },
        { "id": "handsA", "role": "handsA",  "file": "film_handsA", "frame": [0, 0, 1920, 1080], "depth": "person", "z": 4 },
        { "id": "handsB", "role": "handsB",  "file": "film_handsB", "frame": [0, 0, 1920, 1080], "depth": "person", "z": 4 }
      ]
    },
    "portrait": { "...": "same structure, master [1080, 1920]" }
  },
  "provenance": [
    { "asset": "film_room", "source": "who made it, how", "license": "the exact licence", "redistribution": "allowed inside a packaged macOS and iOS app" }
  ]
}
```

- `file` is the name of an image in the asset catalog (add each as an image set).
- `z` orders layers: the screen is drawn after every layer with `z ≤ 1` and before every layer with `z ≥ 2`, so the person and hands correctly cover the screen's edge.
- Example coordinates above are the starting composition from the brief; replace them with the real ones.

---

## 3. Provenance (required)

Every `file` needs a `provenance` entry with a non-empty source, licence and redistribution statement. The validator refuses a manifest without it. For generated imagery, record the tool, the date and the terms that allow commercial redistribution inside a distributed app; for stock, a licence that covers embedding in software.

---

## 4. Validation

The engine validates the manifest before showing anything. A manifest is refused (and the film not shown) if:

- a required role is missing (`room`, `laptop`, `person`, `handsA`, `handsB`);
- a layer id is repeated, a role or depth is unknown, or a frame is not `[x, y, w, h]`;
- an image named in a layer is not in the app;
- `handsA` and `handsB` do not share one frame;
- the screen quad has a corner outside the master space, is not convex, or does not run clockwise from the top left;
- a file has no provenance entry.

These checks are unit-tested (`Tests/Film/FilmEngineTests.swift`).

---

## 5. Checking your art

Set `BS_FILM_TEST_PLATES=1` to see the engine's **diagnostic plates** (labelled grids, the screen quad's corners, never artwork) and `BS_FILM_FRAME=<n>` to freeze on frame *n*. The same variables with real art let you review any of the 26 checkpoint frames. The film is not considered finished until the final art is integrated and reviewed frame by frame and in motion.

---

## 6. What the art does not do

- The art does not move, except for the hands dissolve (A to B) and a slow breath of the person (about 2 master pixels). All other motion is the camera, the page and the protection effects.
- No text, logos or UI in the art. The article, the browser chrome and the effects are live.
- No red, orange, gold or electric green: the grade is the BrowserSetu palette (`#09090F` blacks, `#397E96` and `#8FD0E3` light, `#472E5A` shadows).
