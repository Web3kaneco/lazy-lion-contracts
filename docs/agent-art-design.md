# Dynamic agent art. design

How the generative agent art is built, drawn fully on chain, bound to the
Lion via ERC-8004, evolving, and never separately sellable. Captured now so
the contract work is unambiguous.

## What it is, and what it is NOT

IS: when a holder binds an agent (ERC-8004 on Ethereum mainnet), we
generate dynamic, unique generative art that becomes the Lion's evolving
FACE. It is computed on chain by layered Solidity engines, recomputed as
the agent evolves and on transfer, and it is referenced as the bound
agent's metadata image so any reader (OpenSea, wallets, explorers) shows
it. It follows the Lion because it is bound to the token, not a wallet.

IS NOT:
- NOT the original Lazy Lions art. that NFT on Ethereum is untouched.
- NOT a separate sellable token. there is no art NFT to detach or trade.
  it is metadata on the ERC-8004 binding, period.
- NOT `LionArt`. that contract (a collectible-art-drop ERC-721 we had
  written) is REMOVED in this change. it was the wrong model entirely.
- NOT off-chain AI imagery. the art is deterministic on-chain SVG, so it
  is genuinely on chain and can be recomputed by the chain itself.

## The layered-engine model (Heraldia / ABS38 style, Lion identity)

Reference architecture (Heraldia): a token has N layers; each layer is a
standalone on-chain engine that draws one part; some layers are static,
some dynamic; on transfer the wallet address is read, a new hash computed,
and the dynamic layers redraw. Infinite, deterministic, fully on chain.

We adopt that MECHANISM and THEORY, with the Lazy Lion visual identity (not
Heraldia's look). Proposed layers:

1. EMBLEM (static). the Lion silhouette / core identity, set at bind from
   the Lion's traits + bitmap. The anchor that says "this is Lion #X."
2. PATTERN (dynamic). a generative field whose density/texture derives from
   the agent's evolution level and activity hash. evolves as the agent
   works.
3. BACKGROUND (dynamic). a base field derived from a hash of (holder
   wallet, token id), so it shifts on transfer. new owner, new ground.
4. THEME (dynamic). palette / mode (e.g. the Lions gold family) derived
   from the activity seed, shifting as state changes.

Composite = EMBLEM + PATTERN + BACKGROUND + THEME, layered into one SVG.
3 of 4 dynamic, computed fully on chain. The existing LionRenderer is the
seed of this. it already composites a bitmap layer, a level-driven density
field, a palette from a seed, and a frame. The work is to formalize it into
named standalone layer-engines and add the transfer-driven recompute.

## On-chain, on mainnet

The renderer(s) deploy on Ethereum MAINNET (holder's call: the image lives
on the same chain as the Lion). Identity and art are mainnet; the activity
LEDGER stays on Base. Inputs the renderer reads:
- the Lion's bitmap + traits (static emblem), anchored at bind via adapter
- the evolution level (drives pattern density) . committed on mainnet via
  the evolution verifier
- an activity seed / wallet hash (drives background + theme, shifts on
  transfer)

## The binding: metadata, not a token

The art reaches external readers through the ERC-8004 binding's metadata.
The bound agent's metadata image points at the renderer output for the
current state. So:
- shows everywhere a reader looks (standard tokenURI-style metadata)
- evolves: as level/seed change, the rendered SVG changes, and readers see
  the new art on metadata refresh
- follows the Lion: bound to the token via adapter8004
- never separately sellable: it is not a token, it is a metadata pointer

OPEN ITEM to verify against the real adapter8004 before building: confirm
the adapter's metadata mechanism can point the displayed image at a
DYNAMIC rendered SVG that updates as level changes, vs only storing static
metadata at bind time. If static-only, "evolves in external readers"
requires a metadata-refresh step (re-point on evolve) rather than pure
live recompute. This determines whether evolution is auto-visible
externally or needs a push.

## Build sequence (tomorrow's contract work)

1. (this PR) remove LionArt + its deploy wiring + stale comments. DONE here.
2. formalize LionRenderer into named layer-engines (emblem/pattern/
   background/theme) with a clean composite, each deterministic.
3. add transfer/seed-driven recompute so background+theme shift on transfer.
4. wire the bound-agent metadata image to the renderer output for current
   state (via the adapter metadata pointer).
5. confirm the adapter dynamic-metadata question above; if needed, add a
   re-point-on-evolve step.

All on-chain Solidity, public contracts repo, enforced CI, PR-gated.
