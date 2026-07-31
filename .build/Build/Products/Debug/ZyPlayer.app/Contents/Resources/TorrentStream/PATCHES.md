# Vendored WebTorrent patches

`node_modules/` here is vendored on purpose (no global `npm -g` install) and it
is **patched**. Re-running `npm install` wipes these; re-apply them, or streaming
breaks in ways that look like network problems.

All patches are in `node_modules/webtorrent/lib/torrent.js` and carry a
`ZyPlayer patch` comment. Against webtorrent **3.0.16**.

| # | Where | What | Why |
|---|---|---|---|
| 1 | `_request` | `if (!piece) return false` | A piece verified while the tick was queued is nulled before its bitfield bit is set, so the guard above lets it through and the next line throws `TypeError: Cannot read properties of null (reading 'reserve')`. Uncaught, it kills the helper mid-playback and mpv finds a dead port. |
| 2 | `speedRanker` (hotswap) | null check before `.missing` | Same race. |
| 3 | `_hotswap` | `this.pieces[index]?.cancel(...)` | Same race. |
| 4 | `get downloaded` | skip null pieces | Same race — and the worst one: this getter runs on every status tick, so unpatched it throws continuously and **no progress is ever reported**. |
| 5 | constructor + `_onMetadata` | new `assumeEmpty` option | Without it, adding a torrent hashes every piece of the freshly allocated multi-gigabyte file to see what is already on disk. That pass calls `_markUnverified` as it walks, replacing the `Piece` objects the live download is filling in and clearing their bits — the buffered count climbs and falls for ever and playback never starts. `skipVerify` is *not* the answer: it claims the opposite, that the whole store is already complete, and the server then streams zeros. |
| 6 | `_onWire` | `wire.bitfield(new BitField(this.bitfield.buffer.slice()))` | Handing the live `BitField` to a peer connection lets its backing buffer be reused, and bits for verified pieces come back cleared — with no call to `bitfield.set(i, false)` anywhere. The loss grew with peer count. Peers only need a snapshot from handshake time. |

Patches 1–4 keep the process alive; 5 and 6 are what make the buffer actually
reach 100%.
