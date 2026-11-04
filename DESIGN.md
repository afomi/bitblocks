# Design rules — Bitblocks

These are the rules every page follows.
They describe what the site already does; when a page and this doc disagree, fix the page or fix the doc, so the two match.
References for the look: `lib/bitblocks_web/components/layouts/root.html.heex`, `lib/bitblocks_web/components/nav_component.ex`, the home page (`lib/bitblocks_web/controllers/page_html/home.html.heex`), `/admin` (`lib/bitblocks_web/live/admin_live*`) and `/metanet`.
For chrome around a three.js scene, see `/block-graph` and `/chain-scrubber`.

## Light by default, dark by the toggle

Every page is light by default.
`<html>` starts with the `light` class; the footer toggle swaps it for `dark` and remembers the choice in `localStorage.theme`.
Tailwind runs with `darkMode: 'class'`, so dark styling is always a `dark:` variant beside its light class, never a bare dark class.
The body is `bg-white dark:bg-gray-900`, and a page inherits it rather than painting its own background.

## Dark backgrounds are for three.js scenes only

A page's background is dark only where it draws a three.js scene.
Today that includes `/chain-scrubber`, the `/block-graph` canvas, `/peers`, `/ecosystem`, `/wall` and `/reward_wall`.
A full-bleed scene may use `fixed inset-0`, but only the canvas region is dark, in both modes.
The chrome around it (header, filters, stats strips, playback bars, legends, tooltips) follows the site style in light and dark mode, as `/block-graph` does.
Keep the canvas container's background class equal to the scene's clear colour in the hook, so the page does not flash a different shade before three.js draws.
Floating chrome over a canvas uses a near-opaque surface (`bg-white/95 dark:bg-gray-800/95`) with a border, so its text keeps its contrast over any scene.
A floating panel that a hook fills later may carry `empty:hidden`, written as `<div ...></div>` with nothing between the tags, so it does not show as an empty box before then.
Markup a hook writes (tooltips, readouts, detail panels) uses the same class pairs as the templates; Tailwind scans `assets/js`, so `dark:` variants there are built.
SVG diagrams, lists of nodes and data tables are not three.js scenes, and use the site style.
Colour SVG marks with Tailwind's `fill-*` and `stroke-*` utilities and their `dark:` variants rather than hex attributes, so they follow the theme (see `/shape-layers`).
A mark that carries meaning needs 3:1 against its background in both modes; a 600 shade on `bg-gray-50` and a 400 shade on `dark:bg-gray-900` both clear it.

## Surfaces, borders and text

Use these pairs; each meets WCAG AA (4.5:1 for text) in both modes.

| Role | Light | Dark |
| --- | --- | --- |
| Page | `bg-white` (from the body) | `dark:bg-gray-900` |
| Card | `bg-white border border-gray-200 rounded-lg` | `dark:bg-gray-800 dark:border-gray-700` |
| Inset (code, raw content, toolbars) | `bg-gray-50` | `dark:bg-gray-900` or `dark:bg-gray-800` |
| Heading | `text-gray-900` | `dark:text-white` |
| Body text | `text-gray-700` or `text-gray-800` | `dark:text-gray-300` or `dark:text-gray-200` |
| Secondary text, labels | `text-gray-600` | `dark:text-gray-400` |
| Link | `text-blue-700 hover:text-blue-900` | `dark:text-blue-400 dark:hover:text-blue-300` |
| Input | `bg-white border-gray-300 text-gray-900` | `dark:bg-gray-800 dark:border-gray-600 dark:text-gray-100` |
| Primary button | `bg-blue-600 text-white hover:bg-blue-700` | same |
| Error | `bg-red-50 border-red-200 text-red-800` | `dark:bg-red-900/30 dark:border-red-800 dark:text-red-200` |

A link inside a sentence is underlined, because its colour alone is too close to the text around it (axe asks for 3:1 or an underline).
A link that stands on its own line, a nav item or a card needs no underline.
`text-gray-500` is the lightest gray for text on white, and only for text on `bg-white`; on `bg-gray-50` or tinted surfaces use `text-gray-600`.
White text needs a 700 shade under it for amber and green (`bg-amber-700`, `bg-green-700`); 600 is too light for AA.
Every form control has a label, visible or `sr-only`.
Hover borders on cards may use the brand orange (`hover:border-orange-400`), as `/admin` does.

Some pages use the themed tokens in `assets/css/app.css` instead: `bg-surface-base`, `bg-surface-raised`, `bg-surface-overlay` and `neutral-50`/`400`/`500`/`700`/`800`, which flip with the `light` class.
Those are fine to keep, but only those five `neutral` shades are themed; `neutral-200`, `300`, `600`, `900` and `950` are fixed Tailwind colours and stay dark in light mode.
New work uses the gray pairs above.

## Each colour has one job

Bitblocks is a thin web layer over a node, a database and command-line tools, so a page shows records plainly and says where they come from.
Colour carries meaning, never decoration:

- Brand orange is the chain itself: the logo, a block's height on hover, card hover borders, progress.
  Text in orange uses `text-brand-strong dark:text-brand`.
- Blue is a link or an action.
- Amber is beta or provisional.
- Green and amber 700 (400 in dark mode) mark good and slow, as the block intervals on the homepage do.
- Everything else is gray.

Chain data (heights, hashes, txids, sats, endpoints, commands) is `font-mono tabular-nums`; sentences are the sans face.
Where a page shows a number, name the record or endpoint it comes from when you can, as `/about` does.

## The beta badge

A beta product carries the homepage's amber pill: `rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-semibold text-amber-900 dark:bg-amber-900/40 dark:text-amber-200`.
Inside a card, where a pill would crowd the title, the same colours appear as text alone: `text-xs font-medium text-amber-900 dark:text-amber-200`.
The same pill marks other short states, such as a Metanet root.

## Markup

Write pages as `.html.heex` templates beside their LiveView, and prefer them over `render/1` functions.
Small reusable pieces may be function components with `~H` (for example `admin_card/1`).
Render one HTML attribute per line when an element has more than one.
Render text content one sentence per line.
Both keep diffs to the line that changed.

## Checking it

`test/bitblocks_web/accessibility_axe_test.exs` runs axe-core against pages in a real browser.
A restyled page gets an axe test in light mode and, where its colours differ, in dark mode too (see the `/metanet` and `/reorgs` tests).
A three.js page is scanned for its chrome only: the test Chrome has no WebGL, so those tests turn off Wallaby's `js_errors` for the test (see the `/chain-scrubber` and `/peers` tests).
The dark-mode tests switch off CSS transitions before toggling the theme, so axe never reads a colour part way through a `transition-colors` fade.
A full-screen scene with no visible title still needs an `<h1>`; use `sr-only` (see `/wall`).
