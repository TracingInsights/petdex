# ti-pet — what comes from upstream Petdex

`packages/ti-pet` is the TracingInsights desktop pet: Petdex's native renderer
driven by the TracingInsights desktop app over a per-user socket. It never
edits files under `packages/petdex-desktop-native`; Zig cannot `@import`
outside a package root, so the parts it needs are **copied** (unchanged) or
**adapted** (rewritten after reading upstream). `scripts/check-ti-pet-upstream.sh`
fails when an upstream source below changes, so a merge from
`crafter-station/petdex` tells us what to re-port.

Upstream commit at the time of copying: `31c0aee` (desktop 0.9.2).

| ti-pet file                | Upstream source                                      | How     | Upstream sha256                                                    |
| -------------------------- | ---------------------------------------------------- | ------- | ------------------------------------------------------------------ |
| `src/sprite.zig`           | `packages/petdex-desktop-native/src/sprite.zig`      | copied  | `90f82172169e748ec89182b8d67e1cd1017bd909b036591bcbe6a1fec6b7a2c9` |
| `src/main.zig` (parts)     | `packages/petdex-desktop-native/src/main.zig`        | adapted | `5e6121c07184b68e71040d24ea6ae28481e31ee295cf071443d982b699959d8d` |

Adapted from upstream `main.zig`: the shell window / GPU-surface declaration,
the sheet decode through `PlatformServices.decodeImage` and per-frame image
registration (`decodeSheet`, `registerStateFrames`), the frame timer, the
Linux `window_drag` + `native-sdk.window-drag.*` commands with a drag
watchdog, the Win/mac app-owned drag on the frame clock (`frame_clock`), the
transparent tokens, the GtkPopover bubble placement on Linux and the tray
(`status_item_fn`). Differences: one optional duo partner instead of a flock,
one bubble instead of a conversation stack, frames re-decoded per row instead
of keeping the decoded sheet (saves ~13 MB per pet), and no hook server,
agent hooks, SSH remotes, login, updater, settings window or `petdex://`.

Not upstream: the round-3 states `look-a` / `look-b` (rows 9–10 of 8×11
Petdex v2 sheets) live in `protocol.zig`'s `State`, which extends
`sprite.State` in order (a comptime check keeps them aligned), because
`src/sprite.zig` must stay a byte-identical copy. Their frame counts and
durations come from the payload / timeline, never from `sprite.zig`.

## Native SDK patches

`patches/ti-pet-sdk-linux-pointer.patch` (applied after upstream's own SDK
patches by `.github/workflows/ti-pet-*.yml`) adds to the GTK host:

- click / double-click / pointer enter-leave commands for presses inside a
  `window_drag` region (`native-sdk.window-drag.click|dblclick`,
  `native-sdk.pointer.enter|leave`) — the press never reaches the canvas;
- argv: GApplication rejects unknown `--options`, so only argv[0] and URI
  arguments are forwarded to it (the app parses its own argv);
- X11 `moveWindow` / `resizeWindow` (Wayland has none);
- `_NET_WM_STATE_ABOVE` / `SKIP_TASKBAR` / `SKIP_PAGER` sent as a
  ClientMessage after map (GTK4 rewrites the pre-map property; GNOME then
  dropped ABOVE — measured 2026-11-06), plus SKIP_* in the pre-map hint.

All additions are inert for apps that do not use them (unknown commands are
ignored; upstream Petdex never passes `--options` on Linux).

`patches/ti-pet-sdk-render-perf.patch` (applied after the one above) cuts
the animating pet's CPU. Each lever was measured on Linux (XWayland, cairo)
and kept only because it helped (numbers in the tif1ai repo,
`.tmp-claude/pets-native/tp-perf.md`):

- GTK host: a frame request no longer `queue_draw`s the unchanged retained
  buffer (the present queues its own), so one cairo paint per sprite frame
  instead of two; the host frame tick runs at 16 ms only for ~1 s after
  startup or a window create/resize/allocation change, else at 100 ms;
- runtime image registry: each image's render fingerprint is computed once
  at registration (`ReferenceImage.resource_fingerprint`) instead of
  re-hashing every registered frame's pixels on every planned frame — the
  same key value, so caches are untouched;
- reference renderer: nearest-sampled image draws compute the source
  column/row once per destination column/row (the per-pixel expressions,
  separated), opaque and fully transparent samples at full opacity skip
  the float blend, and `clearRect` copies rows — all byte-identical
  (checked against the unpatched renderer on randomized draws);
- the widget display-list refresh no longer zero-fills its ~300 KB
  scratch on every refresh (only the counts need a value).
