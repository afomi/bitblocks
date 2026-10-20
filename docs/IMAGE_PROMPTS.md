# Image Prompts

DALL-E / Grok prompts for Bitblocks visual content.

## 1. Block Announced, Txs Confirmed

```
A minimal, elegant digital illustration on a dark background.
A glowing golden cube (representing a new block) materializes at the center, emitting concentric rings of light outward.
Dozens of small luminous particles (transactions) are being absorbed into the cube from all directions, each leaving a faint trail as it locks into place.
The moment of confirmation — particles becoming solid, permanent, settled.
Clean geometric style, no text, subtle grid lines in the background suggesting a ledger.
Color palette: deep navy, gold, white.
Technical but poetic.
```

## 2. Block Timeline with Incoming Transactions

```
A technical diagram rendered as art on a dark background.
A single bold vertical arrow pointing upward dominates the center, representing the forward progression of time and chain height.
Horizontal notch marks cross the arrow at regular intervals like a ruler.
To the left of the arrow, a cloud of dozens of small scattered dots in varying brightness drift toward the line — these are incoming unconfirmed transactions.
To the right of each notch, small solid squares sit neatly aligned — these are confirmed blocks, stacked and permanent.
The contrast between the chaotic dots on the left and the ordered squares on the right tells the story.
Minimal, monochrome with gold accents, technical illustration style, no text.
```

## 3. Transaction Echoing Through Space

```
An abstract cosmic illustration.
A single bright point of light at the center represents one transaction on the blockchain.
From it, expanding wavefronts ripple outward like sonar or sound waves through a vast dark space.
As the waves travel outward they encounter and illuminate small geometric shapes — a contract folding open, a key turning, a handshake forming, a seedling sprouting — each representing a downstream action catalyzed by the original transaction.
The information doesn't just travel, it transforms what it touches.
Ethereal, contemplative, sparse.
Color palette: indigo, electric blue, warm amber at the points of catalysis.
No text.
Evokes the idea that every transaction in-forms — gives form to — future states of the world.
```

## Notes

- **Style modifiers** to append: `"in the style of a technical whitepaper illustration"` or `"inspired by Edward Tufte data visualization"` for a more grounded feel.
- **Aspect ratio**: append dimensions if needed (e.g., 16:9 for headers, 1:1 for social).
- For #2, image generators may struggle with precise spatial layout (left/right of a line).
  May need a few generations or compositing two outputs.

## Generated Images

All three images have been generated at 16:9 aspect ratio using the xAI Imagine API.

Images are stored in `priv/static/images/` for use in the web application.

- `block-announced.jpg` — Block Announced, Txs Confirmed.
- `block-timeline.jpg` — Block Timeline with Incoming Transactions.
- `tx-echo.jpg` — Transaction Echoing Through Space.
