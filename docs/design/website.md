# captylo.com (Deep Tide)

The landing page in `site/` is static HTML, CSS and JS with no build step. It wears the same Brand Direction 01 as the app (see [dusk-glass.md](dusk-glass.md)): Deep Tide colours, Manrope + Inter, clear glass and the animated Grainient. Texts come from the previous site, in Polish with English in `data-en` attributes.

## Layout

- **The page is Salt (#F2F7F4)**, like the brand board. The Grainient lives in rounded **tide blocks** (`.tide`, 36 px radius, 10 px from the viewport edge when full width): the hero, the three steps, the desktop with the real apps, the AI modes, the app tour, the privacy panel, the Pro plan, the typing race bar and the download block with the footer. The owner wants the animated grain gradient as the leading motif everywhere.
- Glass on tide follows the app: white 10 % + Abyss smoke 20 %, blur 22, a 1 px rim bright at the top. White type on glass, Abyss type on Salt.
- The header is a dark glass capsule that reads over both tide and Salt.
- Section order: hero with the live demo, facts, speed (typing race + real numbers), how it works (3 steps), where it works (a Mac desktop on the Grainient wallpaper with a macOS menu bar and the Captylo menu bar icon; faithful HTML/CSS replicas of Gmail in Safari, Word, Visual Studio Code, Claude Code in Terminal, Thunderbird and Slack, switched from a Dock-like row of app icons; in each one the widget records and the text lands at the cursor, then the next app), AI modes (the visitor picks a mode), self-learning (#uczy-sie, marked "Nowość w Captylo" since the feature is in the app: one glass card on a tide stage that plays once when seen: dictation with a misheard word, the one-time fix, the "Zapamiętałem ... Cofnij" toast, the next dictation right and the "Ucz się z moich poprawek" switch; a matching FAQ entry), the app tour (tabs with real screenshots), privacy, opinions as stories, the maker (#tworca: Dawid's photo from omniralab.com, short, casual first-person paragraphs (the owner asked for half the text and no principles list; one line says Captylo is also meant to be beautiful, not only working); facts from kawalec.pl, no vendor names), comparison, pricing (yearly / monthly; Free also lists cloud and AI with your own API key), FAQ (including "Czy mogę użyć własnego klucza API?" and "Czy Captylo jest open source?" with the GitHub link), download (while the signed build is "Wkrótce", a line links to building it from the code on GitHub) + footer (links include "Kod źródłowy") under a giant wordmark. The repo is public under GPLv3 (https://github.com/dawidkawalec/captylo); never name the cloud vendors on the site, even in the own-key copy.
- The app windows are built in HTML/CSS at their real proportions (no screenshots of other companies' apps, no logos: the Dock icons are simple glyphs in each app's colour). The owner rejected a grid of identical glass cards for this section: every app must look like itself. All windows share one height (500 px, 540 px in a narrow container) so the page never jumps when the app changes; narrow containers drop the side panes via container queries.
- Motion: one orchestrated moment, the hero demo (hotkey down, compact widget records, text is pasted at the cursor, three scenes in a loop). Everything else moves only when the visitor acts (tabs, modes, billing) plus the one-time race fill. Reduce Motion freezes the gradients and shows the demo's final state.

## Opinions (stories)

The "Ludzie, którzy mówią zamiast pisać" section (`#opinie`, a tide block between privacy and the comparison) shows opinions as Instagram-style stories: 9:16 cards in a horizontal snap carousel (arrows that move by whole cards and mouse drag on desktop, native swipe on phones; a drag never opens a story), video cards play muted while on screen, a tap opens a full-screen viewer with progress bars, tap left / right, sound toggle, Esc to close.

- Data: `site/assets/stories/stories.json`, either an array of entries or `{"title", "lead", "items"}` (the title and lead then replace the section heading, so it can read as illustrations now and as opinions later). **While there are no items the section is hidden.** Never present invented opinions as real: until real stories arrive the section holds five AI-generated (Gemini) photos of people dictating, each marked `"label": "Ilustracja"` and signed "captylo", with product descriptions instead of quotes.
- One entry: `{"type": "image" | "video", "src": "assets/stories/<file>", "poster": "assets/stories/<file>.jpg" (video), "avatar": "assets/stories/<face>.jpg" (optional, initials otherwise), "name": {"pl": "", "en": ""}, "role": {"pl": "", "en": ""}, "quote": {"pl": "", "en": ""}, "link": "https://instagram.com/..." (optional)}`. Plain strings work too when PL and EN are the same.
- Media: 1080 x 1920 or 720 x 1280. Photos as JPG or WebP (under 300 KB). Video as MP4 H.264 with `-movflags +faststart`, up to about 30 s and 8 MB, plus a JPG poster (`ffmpeg -i in.mov -vf scale=720:1280 -c:v libx264 -crf 26 -c:a aac -b:a 96k -movflags +faststart out.mp4`).
- Preview: `?stories=demo` loads `stories-demo.json` (sample cards made from our own screenshots, marked "Podgląd układu"); visitors never see it without the parameter.

## Grainient (`site/assets/js/grainient.js`)

The shader and the parameters are the app's `GlassTokens.Grainient` (the React Bits shader ported 1:1 to WebGL2), with the owner's 10 % dim built in for the dark palette. Any element with `data-grainient="dark|light"` gets a 2D canvas; `data-seed` offsets the time so two blocks never look alike, `data-zoom`, `data-cx`, `data-cy` frame the field. **One shared WebGL2 context** draws each visible block into an offscreen canvas and copies the frame into the block's 2D canvas: one context per block (12 of them) broke on Android, where Chrome keeps at most 8 contexts alive and silently drops the oldest (blank hero, choppy scrolling). Blocks render only near the viewport, at most 1.5 x device pixels on desktop and 1 x at 30 fps on phones (`max-width: 760px` or a coarse pointer); a CSS gradient in the same colours shows until the first frame and without WebGL2. Never add a second WebGL context to the page.

## Screenshots

Every product image is made from the current app, never from older material:

- Main window: `SNAP_BACKDROP=dark SNAP_SETTLE=3 scripts/snap.sh main-<screen> out.png` after `make build`, then `cwebp -q 84` into `site/assets/shots/`.
- The expanded widget: render a Grainient still (a page with one full-screen `data-grainient="dark"` block, 1072 x 1328, Reduce Motion on) and pass it as `SNAP_BACKDROP=<png>`, then crop the widget. Keep the pointer away from the Dock, its tooltip ends up in the capture.
- `historia.webp` hides the AI model id in the expanded row (vendor rule in AGENTS.md); the expanded History row in the app still shows it.
- `og.jpg` (1200 x 630) is a Grainient block with the wordmark, the headline and the compact widget, captured with Playwright.

## Caching

Caddy caches `/assets/*` for 7 days. `index.html` and `kawa/index.html` load `site.css`, `site.js` and `grainient.js` with `?v=<date+letter>`: bump it whenever one of those files changes, or returning visitors get the old file with the new HTML. The icon links carry the same kind of `?v=` (browsers keep favicons for weeks, and the old logo sat at the same URLs): `favicon.ico` and `apple-touch-icon.png` live at the site root too, because Safari and iOS ask for them there without reading the HTML; regenerate `favicon.ico` (16/32/48/64) from `branding/direction-01/png/icon-256.png` when the logo changes.

## Deploy

`site/` is plain static files: any web server can host it, and `python3 -m http.server` inside `site/` is enough for a local preview. captylo.com is deployed by syncing `site/` to the web root of our server (host details are kept outside the repo, no reload needed). It is production, so it needs the owner's go-ahead.
