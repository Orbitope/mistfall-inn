# Asset licensing — what was verified, and what to avoid

Research done 2026-08-14 against the ws 05 brief: 320×180, one Lospec palette,
CC0 preferred. Recorded so the next person does not re-derive it, and because
several of these licences are misreported elsewhere.

**The rule:** an asset with no entry in `CREDITS.md` does not ship. "Free" is not
a licence.

## Fonts

| Font | Licence | Verified how | Use at |
|---|---|---|---|
| **m5x7** | **CC0** | itch.io structured `Asset license` field = Creative Commons Zero v1.0 | 16/32/48 |
| **Pixel Operator** | **CC0** | ships full CC0 legal code in `LICENSE.txt`; font `name` ID 13 = "Creative Commons Zero (CC0) 1.0" | 16 (or 8 for PixelOperator8) |
| **Tiny5** | OFL 1.1 | `OFL.txt` + Google Fonts `METADATA.pb` | 8/16/24 |
| **Silkscreen** | OFL 1.1 | `OFL.txt` + `METADATA.pb` | 8/16 |
| **Departure Mono** | OFL 1.1 | `LICENSE` in the *release zip* | 11/22/33 |

**m5x7 and m6x11 are not the same licence, despite being by the same author and
usually named together.** m5x7 carries a formal CC0 declaration in itch.io's
structured licence field. **m6x11 has no licence field at all** — only the prose
"free to use with attribution", which is attribution-*required* and not a licence
instrument you could show a publisher. Same for m3x6. Use m5x7; replace m6x11
with Pixel Operator, which is formally CC0 and brings a real Bold.

**Departure Mono trap:** the GitHub repo's root `LICENSE` is **MIT** — that covers
the marketing website, not the font. Take the font from the release zip and keep
the OFL `LICENSE` shipped with it.

Rejected: **int10h Oldschool PC** (CC BY-SA — viral copyleft), **ZX Origins**
(informal, credit demanded as consideration), **Kitchen Sink** (attribution +
redistribution + field-of-use restrictions), **Silver** (itch field says CC BY 4.0
but the page adds a $100k revenue trigger — CC BY does not permit that, so the
licence contradicts itself; email them rather than relying on either reading).

Rejected on technical grounds, not licence: **VT323** and **Pixelify Sans** are
vector faces with no common pixel grid and will never render crisply at 320×180.
**Press Start 2P** is grid-perfect but 8px monospace — 40 characters per line,
unusable for prose. **Jersey 10** needs 56px multiples to be pixel-perfect.

## UI — solved, do not commission

- **[Generic Dark Pixel UI](https://flatus.itch.io/generic-dark-pixel-ui)** — CC0,
  elements at 13px, and it ships a **Godot 4 theme** plus `.aseprite` sources. Best
  size-and-engine match found.
- **[Pace Smith's retro GUI/HUD](https://opengameart.org/content/retro-pixel-art-guihud-elements-including-dialogue-box)**
  — CC0. The dialogue box PNG is 206 bytes; genuinely native-resolution.
- **[Kenney Pixel UI Pack](https://kenney.nl/assets/pixel-ui-pack)** — CC0, 16×16
  9-slice. Note Kenney's *other* "UI Pack" and "UI Pack (RPG Expansion)" are
  smooth/vector, not pixel art — wrong for this project.

Kenney's grant is confirmed but there is **no `kenney.nl/license` page** (404); it
lives on each asset page and at [kenney.nl/support](https://kenney.nl/support).

## Portraits and interiors — commission

The entire CC0 portrait inventory on itch.io is **six packs**: cyberpunk, military,
high fantasy, one alien, and a frame pack. **None is 19th-century rural, and there
is no near-miss.** CC0 interiors are worse — `assets-cc0/tag-interior` returns 3D
packs and modern kitchens, and `tag-tavern` returns nothing at all.

OpenGameArt's CC0 portraits are individually genuine but unusable as a *set*:
different artists, media, and scales (500px vector cutouts, 128×128 avatars,
hand-painted, a beginner's practice sheet).

So: **commission the three busts and three interiors.** The tight constraints that
make them unfindable are exactly what make the brief cheap — fixed palette, fixed
size, six images. Hand the artist the Lospec palette hex list and
[OGA's Public Domain Pack](https://opengameart.org/content/public-domain-pack),
which is 94 items retouched from genuine 19th-century public-domain sources and is
ideal reference.

**Avoid** [Post-Apocalyptic Character Portraits](https://fieraryan.itch.io/post-apocalyptic-character-portraits):
CC0-labelled but states it was made with Stable Diffusion. A CC0 dedication over
AI output rests on contested copyright, and some storefronts require disclosure.

## Godot import settings for pixel fonts

Use the designed size or an integer multiple — any other size breaks stems
regardless of import settings. Then: `Antialiasing = None`, `Hinting = None`,
`Subpixel Positioning = Disabled`, mipmaps off, autohinter off, MSDF off.

Lines available in 180px: Tiny5 @8px → 20 · PixelOperator8 @8px → 22 ·
Silkscreen @8px → 17 · Departure Mono @11px → 12 · Pixel Operator @16px → 11.
