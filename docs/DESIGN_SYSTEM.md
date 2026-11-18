# LP — Design System

Notion's structure with an Apple finish: quiet, generous, one accent colour. The content is the
loudest thing on screen; the interface recedes.

The source of truth for every value below is code: `Local Productivity/Design/Theme.swift`
(app-wide tokens), `Editor/EditorTheme.swift` (the writing surface) and `Boards/BoardView.swift`
(`BoardPalette`). Use the tokens — never a literal colour or size in a view.

Values here were **measured**, not eyeballed: contrast was computed against the real rendered
backgrounds (sampled from screenshots) with the dataviz validator, in both modes.

---

## 1. Principles

1. **Content first.** Chrome is light, hairline and grey; colour is spent on meaning.
2. **One accent.** Blue marks interaction and "today". Other colours carry status (done, overdue,
   due soon) or identity (calendars, tags) — never decoration.
3. **Nothing important by colour alone.** Status always pairs colour with an icon or a word.
4. **Calm motion.** Short, purposeful, and a fade when Reduce Motion is on.
5. **Native first.** SF Pro, SF Symbols, system controls, Liquid Glass toolbars. Custom only
   where the system has no equivalent.

## 2. Colour

### Surfaces

| Token | Light | Dark | Use |
|---|---|---|---|
| `lpCanvas` | `#FFFFFF` | `#1B1B1D` | The page, board and calendar background |
| `lpSurface` | `#FFFFFF` | `#2A2A2D` | Raised things: cards, menus, palette, tooltips |
| Sidebar | system material (≈ `#F1F1F1`) | ≈ `#2C2D2F` | Navigation |
| `lpFillSubtle` | black 3.5% | white 5% | Board lists, inset cards, stat tiles |
| `lpFillHover` | black 4.5% | white 6% | Hover |
| `lpFillSelected` | black 8% | white 10.5% | Selection, pressed |
| `lpHairline` | black 9% | white 10% | Borders, separators, chart gridlines |

### Ink (text)

Every text level clears WCAG AA (4.5:1) on the canvas, the sidebar and board lists, in both modes.

| Token | Value | Contrast (light / dark, worst surface) | Use |
|---|---|---|---|
| `lpInk` | `#1D1D1F` / `#F2F2F4` | ~16:1 / ~14:1 | Body text, titles |
| `lpInkSecondary` | ink @ 74% / 70% | 6.7:1 / 6.9:1 | Supporting text, labels, metadata |
| `lpInkTertiary` | ink @ 64% / 56% | 4.9:1 / 5.0:1 | Section headers, timestamps, hints, placeholders |
| `lpInkFaint` | ink @ 24% / 22% | 1.6:1 / 1.9:1 | **Decoration only** — chevrons, separators, dashed outlines. Never words. |

### Accent

| | Light | Dark | Measured |
|---|---|---|---|
| `AccentColor` (asset) | `#1A63CC` | `#3B8FF7` | Light: 5.7:1 canvas, 5.0:1 sidebar, 4.8:1 on its 12% tint, white-on-accent 5.7:1. Dark: 5.3:1 canvas, 4.5:1 on 12% tint; white-on-accent 3.3:1 — only for large/bold text (today's date is 14pt bold). |

- Accent tints behind text: **12% opacity maximum** (13–14% drops dark-mode text under 4.5:1).
- The asset applies when the system accent is "Multicolor"; a user's chosen accent wins.

### Status (text- and icon-safe)

| Token | Light | Dark | Meaning | Always with |
|---|---|---|---|---|
| `lpCritical` | `#B42318` | `#FF6B61` | Overdue, errors, destructive | ⓘ/❗ icon or "Overdue" |
| `lpWarning` | `#A14A0A` | `#F5A25D` | Due within 3 days | clock icon |
| `lpAccentText` | `#1C5CAB` | `#86B6EF` | Due today, accent labels | — |
| `lpGood` | `#0CA30C` | `#0CA30C` | Done | check mark |

Each clears 4.5:1 on the surface **and** on its own 12% tint.

### Data visualisation

- **Series:** `lpSeriesPrimary` `#2A78D6` / `#3987E5` (the point), `lpSeriesContext` `#898781` (context).
- **Board lists are ordinal** (workflow stages), so they use one blue ramp that deepens towards
  done — validated with the dataviz `--ordinal` checks (monotone lightness, adjacent ΔL ≥ 0.06,
  light end ≥ 2:1):

| Lists | Light (first → last) | Dark (first → last) |
|---|---|---|
| 2 | `#6DA7EC` `#184F95` | `#256ABF` `#9EC5F4` |
| 3 | `#86B6EF` `#2A78D6` `#104281` | `#184F95` `#3987E5` `#9EC5F4` |
| 4 | `#86B6EF` `#3987E5` `#1C5CAB` `#0D366B` | `#184F95` `#2A78D6` `#6DA7EC` `#B7D3F6` |
| 5 | `#86B6EF` `#5598E7` `#2A78D6` `#1C5CAB` `#104281` | `#184F95` `#256ABF` `#3987E5` `#6DA7EC` `#B7D3F6` |

  Six or more lists exceed what light mode can separate; order, 2pt gaps and the legend carry it.
- **Tags** get a stable categorical dot (8 validated hues); the tag text stays in ink.
- **Calendars** keep their own colour (from Apple/Google/Microsoft) as a dot or bar beside ink text.

## 3. Typography

System font (SF Pro) throughout; SF Mono for code. The editor can use Rounded, Serif (New York),
Mono or any installed family. The type is deliberately calm: content first, chrome quiet.

**The editor scale follows one number** — the text size (Settings → Editor, default **15 pt**,
any size 12–24, ⌘+ / ⌘− / ⌘0) — and the line spacing (Compact 1.35, Default 1.55, Relaxed 1.8):

| Role | Size / weight | Line height |
|---|---|---|
| Editor body | text size, regular (15) | × line spacing (23 at default) |
| Editor H1 | × 1.75, bold (26) | × 1.25 (33) |
| Editor H2 | × 1.4, bold (21) | × 1.25 |
| Editor H3 | × 1.2, semibold (18) | × 1.31 |
| Editor H4 | × 1.07, semibold (16) | at least the body line |
| Editor code | × 0.87, mono (13) | × (line spacing − 0.05) |
| Page title | × 2.15, bold (32) | — |
| Page icon | × 1.4 of the title (45) | — |

Block gaps and list indents scale with the text size; looser line spacing adds a little room
between blocks. Page width: Narrow 600, Default 720, Wide 920 (widened for larger text), Full.

**Interface text** (sidebar, lists, boards, Home, calendar, search) uses `Font.lp(size:)`, which
follows Settings → Editor → Interface size (Small × 0.92, Default × 1, Large × 1.1). Use
`.lp(size:)` for every interface font; `.system(size:)` only for glyphs sized to their tile
(page icons) and in Settings, which keeps system sizes.

| Role | Size / weight (at Default) |
|---|---|
| Screen title (Home, folder, board, Boards) | 28 bold |
| Calendar month / day title | 24 / 22 bold |
| Hero figure (board progress panel) | 48 bold, proportional figures |
| Board overview percentage | 22 semibold rounded |
| Card and row titles | 13–14 regular/semibold |
| UI body | 13 regular/medium |
| Secondary UI | 11.5–12.5 |
| Section header | 11 semibold, tertiary ink |
| Smallest (chart axes, chips) | 10–11 |

Numbers that align in columns use monospaced digits; standalone large numbers use proportional
figures.

## 4. Space, size and shape

| Token | Value |
|---|---|
| Reading width | 720pt (`Metrics.readingWidth`), page margin 56pt |
| Spacing rhythm | 4 / 8 / 12 / 16 / 22 / 28pt |
| Radii | 6 (`radiusSmall`, controls) · 10 (`radiusMedium`, cards, fields) · 14 (board lists, home cards) · 16 (`radiusLarge`) — always continuous corners |
| Sidebar row | 30pt high, 14pt indent per level |
| Board list | 260–340pt wide (shares the window), 14pt apart; progress panel 316pt, beside the lists from 960pt, floating below |
| Boards overview | cards ≥ 268pt in an adaptive grid; 48pt margins, 24pt when narrow |
| Pointer targets | **≥ 24 × 24pt** for every clickable control |

## 5. Elevation

| Level | Treatment |
|---|---|
| Flat | No border — the canvas |
| Inset | `lpFillSubtle` fill, no border (lists, tiles) |
| Raised | `lpSurface` + 1pt hairline + shadow 3.5% / 1.5pt; on hover 9% / 6pt (cards) |
| Floating | Material/glass + hairline + soft shadow (palette, menus, tooltips) |

## 6. Motion

| Token | Default | Reduce Motion |
|---|---|---|
| `Animation.lpQuick` | snappy 0.18s — hover, selection, small changes | ease-out 0.12s |
| `Animation.lpSmooth` | smooth 0.28s — disclosure, panels | ease-out 0.15s |
| Panel transitions | slide + fade | fade only (`accessibilityReduceMotion`) |

Animate one or two things per change. Never animate layout on every keystroke.

## 7. Iconography

- SF Symbols only for interface icons; outline at rest, filled for state (selected, done).
- Emoji are **user content** (page and board icons), never interface icons.
- Board symbol: `rectangle.split.3x1`. Page: `doc.text`. Folder: `folder`. Daily note: `sun.max.fill`.

## 8. Components (where to find them)

| Component | File | Notes |
|---|---|---|
| Sidebar rows, section headers | `Sidebar/SidebarView.swift` | Hover actions appear on hover; inline rename |
| Page icon tile | `Home/HomeView.swift` (`PageIcon`) | Emoji, or a symbol for pages, boards, folders, daily notes |
| Card surface | `cardSurface(isHovering:)` | Home and folder cards |
| Breadcrumb | `Editor/PageView.swift` | Folders · icon · title |
| Due chip | `Boards/BoardView.swift` (`DueChip`) | Icon + words + colour |
| Tag chip | `TagChip` | Colour dot + ink text |
| Board list / card | `LaneView`, `CardView` | Card focus ring drawn by us (2pt accent, 2pt outside) |
| Progress bar | `LaneProgressBar` | Segments with 2pt gaps, capsule |
| Stat tile | `Boards/BoardProgressPanel.swift` | Label · value · optional status icon |
| Trend chart | `TrendChart` | Swift Charts; legend with latest values; hover crosshair + tooltip; table view |
| Calendar chips | `Calendar/CalendarView.swift` | Timed: dot + title (+ time); all-day: tinted bar |
| Event editor | `Calendar/EventEditorView.swift` | Grouped form sheet |
| Board overview card | `Boards/BoardsView.swift` (`BoardOverviewCard`) | Icon · title · folder · overdue; % with "x of y done"; list bar in stage colours; lists line; due soon · edited |
| New board sheet | `NewBoardSheet`, `TemplateTile` | Name, template tiles (selected: 12% accent tint + 1.5pt accent ring), folder |
| Notification settings | `Settings/NotificationSettingsView.swift` | Permission row, options, "Next reminder", "Coming up"; scrolls within 620pt so it fits small screens |
| Editor settings | `Settings/SettingsView.swift` (`EditorSettings`, `TextPreview`) | Size slider with A/A, segmented spacing/width/interface, live preview |
| Widgets | `LPWidgets/` (`TodayWidget`, `BoardWidget`, `WidgetStyle`) | System type; accent for the date and progress; critical only for overdue, always with an icon; `WidgetMessage` for empty and set-up states |

## 9. Writing (UX copy)

- Sentence case everywhere ("New board", not "New Board") except menu commands, which follow
  macOS title case.
- Say what happens, plainly: "Changes you make in LP are saved back to them."
- Relative times inside sentences keep capitals for days and months ("Edited yesterday",
  "Added 30 Oct") — use `Date.inlineRelative`.

## 10. Review checklist (run before calling UI work done)

Capture with the snapshot harness and look at every image:

- [ ] Light **and** dark, at 1280×800 and a narrow window (~900×640)
- [ ] Text contrast ≥ 4.5:1 (use the tokens; if you add a colour, measure it)
- [ ] Nothing communicated by colour alone
- [ ] Every icon-only control has `.help` **and** `.accessibilityLabel`
- [ ] Pointer targets ≥ 24pt
- [ ] Keyboard path exists for every new action; focus is visible
- [ ] Reduce Motion: no slides or springs
- [ ] Empty, loading and error states designed (not blank)
- [ ] Long text truncates or wraps gracefully; no clipped labels
- [ ] Charts: legend for ≥ 2 series, hairline solid grid, table view, no dual axes
