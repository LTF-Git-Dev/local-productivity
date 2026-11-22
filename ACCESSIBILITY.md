# Accessibility

*Last updated: 19 November 2026*

LP should be comfortable for everyone: with VoiceOver, with a keyboard alone, with larger text,
with reduced motion, and in light or dark. We aim for **WCAG 2.2 level AA**, applied to a native
macOS app, and follow Apple's Human Interface Guidelines for accessibility.

## What LP supports

- **VoiceOver** — every control that shows only an icon has a spoken name and a tooltip; status
  (overdue, due soon, done) is told in words, never by colour alone; decorative images are hidden
  from VoiceOver.
- **Keyboard** — everything has a keyboard path: search (⌘K), new page (⌘N), today's note (⌘T),
  the block menu (`/`), and on boards: open a card with Return, move it between lists with ⌘← and
  ⌘→, delete it with Delete. Drag and drop always has a menu or keyboard alternative. See the
  shortcuts in the [user guide](docs/LP%20User%20Guide.pdf).
- **Text size** — the editor's text from 12 to 24 points (⌘+ / ⌘−), line spacing and page width in
  Settings → Editor, and the interface size for the rest of LP.
- **Contrast** — text meets 4.5:1 in light and dark (measured for every colour token; see
  [docs/DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md)).
- **Motion** — animations follow **Reduce Motion** (shorter, without movement).
- **Targets** — clickable areas are at least 24 points.

## The accessibility pass of 19 November 2026

Every screen's code was checked for icon-only buttons without a spoken name, controls that react
only to a click, text below 11 points, and animations that ignore Reduce Motion; each finding was
then looked at by hand. Fixed:

- the calendar's task checkboxes now say "Mark as done" / "Mark as not done" (as Home's already did);
- the sidebar's folder arrows now say "Expand folder" / "Collapse folder";
- search results (⌘K) and the block menu (`/`) are now buttons for VoiceOver, as they were for the
  keyboard.

Checked and fine: board cards, sidebar rows, Home's tasks, the editor's block handles, the progress
panel and settings already had names and keyboard paths; the smallest sizes found are chevron
icons, not text; LP's animation styles shorten under Reduce Motion.

## Known limitations

- Tables are edited in a sheet rather than in place.
- A few small labels in the calendar (the "+3" count on a busy day, the icons on its chips) are
  9–10 points; they grow with the interface size setting.
- LP has not yet been tested end to end by VoiceOver users. If something is hard to use, please
  tell us.

## Feedback

Open an issue on the project's GitHub page, or contact the maintainer (LTF-Git-Dev) through GitHub.
Describe what you were doing, what you expected and what assistive technology you use.
