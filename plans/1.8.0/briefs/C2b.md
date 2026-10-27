# C2b: the catalogue reaches every list, and no view reads a shared catalogue

**Goal.** Finish C2's Done-when. C2 (integrated on `v2`) gave the probe one outcome, derived the limits from the probe, put
efforts and defaults on `ModelCatalogEntry` and moved the Peek store onto `CatalogModel`. C2's write set was too narrow for
three of its items, so they are this slice:
1. **No `ModelCatalog.shared`** (optimizer 10): the catalogue lives on `CatalogModel` and is passed down.
2. **Every list of harnesses follows the catalogue,** the connect switch and availability, with no restart. Lists are the File
   menu's new-session items, the Dock menu, Home's buttons, the sidebar's new-session entries and the menu bar.
3. **Availability is wired:** a harness whose CLI is Not found never appears as startable.

**Starts after** C2 (integrated). It runs beside B1.

**Read.**
- `plans/1.8.0/briefs/C2.md` (its Goal, Approach 5–6 and Done-when are this slice's), and C2's report:
  `~/Library/Caches/loom-v2/evidence/r9/c2/REPORT.md` (its Needs 1–3 list every call site with its line).
- `Sources/LoomCore/HarnessCatalogue.swift`, `HarnessAvailability.swift` (`HarnessAvailabilityReader.read(_:)`),
  `HarnessConnections.swift`, `ModelCatalog.swift`.
- The call sites below, and how each view already reaches `CatalogModel` (initializer, environment or a parent's property).

**Write set.** Only the lines named here; the look of every surface is other slices' (B2, B3, B4, B5a, C3, C4).
- `CatalogModel.swift`: hold the `ModelCatalog` and the availability (one property each, set at install like
  `harnessConnections`).
- The readers of `ModelCatalog.shared`: `loom-app/AppDelegate+Harness.swift` (the wiring), `ProjectSessionViews.swift`,
  `NewSessionDefaults.swift`, `NewSessionComposer.swift`, `SidebarCardModels.swift`, `Chat/ComposerModelPopover.swift`,
  `HeaderModelSegment.swift`: the line that reads the catalogue and the plumbing that brings `CatalogModel`'s copy to it.
- The lists: `loom-app/AppDelegate+Menus.swift` (the new-session items), `loom-app/AppDelegate+Dock.swift`,
  `HomeEmptyStates.swift` (which buttons show, not their layout), `SidebarView.swift` (the new-session entries' list only;
  A1's reorder code is not yours), `MenuBarState.swift` (`items(for:)`).
- `ModelCatalog.swift` (remove `shared`), their tests, `SPEC.md` §6.7 and §12.2's lines for these lists, and
  `docs/ARCHITECTURE.md`'s lines that C2's report names under "Doc impact" plus the ones this slice changes.

Not yours: `SettingsConnectionsModel.swift` (C3), the usage chip's harness names (`UsageModel.rebuildChip`, `paces`,
`UsageChipContent`: B3 iterates the catalogue when it builds the status bar), anything visual.

**Approach.**
1. **The catalogue on `CatalogModel`.** One `ModelCatalog` for the app, made where `AppDelegate+Harness.swift` makes it today
   and handed to `CatalogModel`. Each reader takes it from `CatalogModel` (or from its parent, as the view already gets the
   model). Then delete `static let shared`. A test model gets its own catalogue.
2. **Availability on `CatalogModel`.** Read `HarnessAvailabilityReader.read(connections)` off the main actor at launch, on app
   activation (at most once a minute), when a connect switch changes, and on Check Again. The result is one
   `[HarnessID: HarnessAvailability]` value; a view reads only the harness it shows.
3. **One rule for "startable"** in one place (a function on `CatalogModel` or `HarnessCatalogue`): the harness is in the
   catalogue, its connect switch is on, its CLI is found, and this build can start it (Codex keeps "Codex comes in a later
   version" until D1). Every list iterates the catalogue in its order and asks this rule; a harness that is off disappears, a
   Not found one is not offered as startable (where a surface shows it at all, it shows it disabled, as today's Codex row).
4. **No restart:** the lists read observed state, so a switch or a new availability read changes them at once. The AppKit
   menus (File, Dock, menu bar) rebuild when they open or when the state changes, whichever the code already does.

**Done when.**
- `grep -rn "ModelCatalog.shared\|SidebarPeekStore.shared" Sources Tests` finds nothing.
- Turning Claude or Codex off or on in preferences changes the File menu, the Dock menu, Home's buttons, the sidebar's
  new-session entries and the menu bar without a restart; a Not found CLI is never startable. Tests pin both through the
  models and the list builders (not through screenshots).
- `--tests` passes.

**Checks.** The suites of every touched file (`MenuBarStateTests`, the Home and sidebar list tests, `HarnessCatalogTests`,
`UsageModelTests`, any app-delegate menu tests), new tests for Approach 2–4, then `--tests` once. Unverified: the AppKit menus
on screen (the gate).
