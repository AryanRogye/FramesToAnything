# App icon artwork

Generated with Codex's built-in image generation workflow, then resized locally for Android resources.

## Deliverables

- `fire-tv-app-icon-1280x720.png`: opaque Fire TV launcher and Appstore artwork.
- `launcher-icon-512x512.png`: square master used to produce the density-specific Android launcher icons.

## Landscape prompt

```text
Use case: logo-brand
Asset type: Amazon Fire TV app icon / launcher banner, designed for final opaque 1280x720 landscape delivery
Primary request: Create a polished original icon for an app that receives a live screen stream from a phone or computer and displays it on a television.
Scene/backdrop: full-bleed near-black charcoal background (#080B10) with a restrained deep navy-to-electric-blue glow, no empty border and no mockup frame.
Subject: one bold, simple centered emblem: a portrait mobile-screen outline smoothly flowing through two clean wireless motion arcs into a wider television-screen outline. The relationship must instantly read as “screen sent to TV.” Make the TV silhouette dominant and the phone clearly secondary. No remote control, no flames, no play button.
Style/medium: premium minimal vector-like app artwork, flat geometric forms with subtle dimensional glow, crisp edges, strong silhouette, modern media utility aesthetic.
Composition/framing: 16:9 landscape tile; emblem centered within the middle 60% safe area with generous breathing room; all important details far from corners and bottom edge so Fire TV badges cannot cover them; legible at small thumbnail size.
Lighting/mood: calm, fast, trustworthy, cinematic but restrained.
Color palette: charcoal black, deep navy, luminous cyan-blue, and clean soft white; high contrast.
Materials/textures: smooth matte background, very subtle glassy highlight only inside the screen shapes; no photographic texture.
Constraints: no words, no letters, no numbers; no Apple logo, Amazon logo, Fire TV logo, AirPlay logo, Chromecast logo, or other trademarks; no watermark; no border; no rounded app-tile container; no transparency; no gradients that muddy the silhouette; original design only.
Avoid: busy detail, multiple TVs, multiple phones, realistic devices, antennas, cables, arrows, tiny particles, stock icon look, excessive neon, purple, orange, red.
```

## Square prompt

```text
Use case: precise-object-edit
Asset type: square Android launcher icon companion to Image 1
Input images: Image 1: approved visual identity and style reference
Primary request: Recompose the same phone-to-TV emblem from Image 1 into a compact square app icon. Keep the exact charcoal, deep navy, luminous cyan-blue, and soft white visual identity, the same crisp vector-like geometry, restrained glow, and screen highlight language.
Composition/framing: square canvas; one dominant television outline centered in the upper-middle, a smaller portrait phone outline tucked clearly to its lower-left, and exactly two cyan wireless motion arcs connecting phone to TV. Keep the complete emblem within the central 72% of the canvas with generous padding on all sides. Strong simple silhouette that remains clear at 48x48 pixels.
Scene/backdrop: full-bleed near-black charcoal (#080B10) with restrained deep blue glow; no external frame or mockup.
Constraints: preserve the concept and style of Image 1, but re-layout cleanly for square—not a crop. No words, letters, or numbers; no Apple, Amazon, Fire TV, AirPlay, Chromecast, or other trademarks; no watermark; no border; no rounded app-tile container; no transparency; no extra devices.
Avoid: cropped elements, tiny details, realistic hardware, cables, arrows, play buttons, flames, excessive neon, purple, orange, red.
```

## Black-edge correction prompt

Applied separately to the landscape and square edit targets with their original compositions locked:

```text
Use case: precise-object-edit
Primary request: Remove the visible gray or dark-navy perimeter seams. Make the background at the complete outer perimeter pure solid black (#000000) on all four sides—left, right, top, and bottom—with a smooth seamless fade into the existing dark charcoal and blue glow toward the center.
Change only: the empty background near the canvas edges.
Preserve exactly: the phone outline, two wireless arcs, television outline, stand, all proportions and positions, screen highlights, cyan/blue lighting, composition, and padding. Do not redraw, resize, move, crop, or restyle the emblem.
Constraints: the outermost edge pixels must be uniformly pure black with no gray, navy, blue, border, frame, line, vignette ring, or transparency; keep the artwork full bleed; no text, logos, watermark, or new elements.
```

After resizing, the outer four pixels of each master and the outer pixel of each density-specific launcher icon are explicitly set to `#000000`.
