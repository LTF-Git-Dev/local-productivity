#!/bin/zsh
# Builds a sample workspace in .build/demo-vault for UI snapshots and manual testing.
# Dates are relative to today so the calendar and daily notes always have something to show.

ROOT="${0:A:h:h}"
VAULT="${1:-$ROOT/.build/demo-vault}"
rm -rf "$VAULT"
mkdir -p "$VAULT/Projects/Archive" "$VAULT/Areas" "$VAULT/Daily Notes" "$VAULT/Meeting Notes" "$VAULT/assets"

day() { date -v"$1"d +%Y-%m-%d; }
TODAY=$(day +0); YESTERDAY=$(day -1); EARLIER=$(day -3); SOON=$(day +2); LATER=$(day +6)

cat > "$VAULT/Welcome.md" <<MD
---
icon: 👋
---

Everything you write here is saved as plain Markdown in your folder. There is nothing to export and nothing to lock you in: the same files open in any other app, whenever you like.

## Write without the syntax

Formatting appears as you type and the symbols get out of the way. Try a few:

- Type \`**bold**\`, \`*italic*\` or \`~~strike~~\` and keep going
- Start a line with \`#\`, \`##\` or \`###\` and a space for a heading
- Start a line with \`-\` for a list, \`1.\` for a numbered list, or \`[]\` for a to-do
- Press \`/\` on an empty line to see every kind of block

> [!tip] Select any text to format it
> A small bar appears above the selection. ⌘B, ⌘I and ⌘K work too.

## A few things to try

- [x] Open this guide
- [ ] Press ⌘N to make a page of your own
- [ ] Press ⌘K to find anything
- [ ] Open the Calendar and start today’s note

## Pages link to each other

Type \`[[\` to link to another page, such as [[Website Redesign]] or [[Reading List]]. A link to a page that does not exist yet creates it when you click it.

---

When you are done with this guide, move it to the Trash from the ••• menu.
MD

cat > "$VAULT/Kitchen Sink.md" <<'MD'
---
icon: 🧪
tags: [reference, formatting]
---

A page that uses every kind of block, to check how they sit together.

# Heading one

Body text with **bold**, *italic*, ***both at once***, ~~struck through~~, ==highlighted== and `inline code`. A [link to a website](https://www.apple.com), a bare address https://example.com/docs, and a wiki link to [[Welcome]].

## Heading two

A paragraph that runs long enough to wrap onto a second line so the line height and the measure of the column can be judged properly at the reading width.

### Heading three

#### Heading four

- Bulleted item
- Another item with **bold** inside
  - Nested item
    - Deeper still
  - Back out one level
- Last item

1. First step
2. Second step
   - A bullet inside a numbered list
3. Third step

- [ ] An open to-do
- [x] A finished to-do
- [ ] A to-do with a due date 📅 2026-11-20
  - [ ] A nested to-do

> A block quote. Good design is as little design as possible.
> It carries on to a second line.

> [!note] A note callout
> Callouts draw attention to something without shouting.

> [!warning] Careful
> This one is a warning.

```swift
struct Greeting {
    let name: String

    func text() -> String {
        "Hello, \(name)!"
    }
}
```

---

| Shortcut | Action | Notes |
|:---------|:------:|------:|
| ⌘K | Search | Everywhere |
| ⌘N | New page | In the current folder |
| ⌘T | Today’s note | Creates it if needed |

![A gradient](assets/gradient.png)

Some raw HTML is kept exactly as written: <kbd>⌘</kbd> + <kbd>S</kbd> is never needed.

The end.
MD

cat > "$VAULT/Projects/Website Redesign.md" <<MD
---
icon: 🚀
date: $SOON
---

The marketing site has not changed in two years. This is the plan for replacing it before the spring launch.

## Goals

1. Load in under a second on a phone
2. Make pricing understandable in one screen
3. Let the content team publish without an engineer

## This week

- [x] Audit the current pages
- [ ] Draft the new navigation 📅 $TODAY
- [ ] Review type scale with Mina 📅 $SOON
- [ ] Call the printer about proofs 📅 $SOON 14:30
- [ ] Decide on the image pipeline 📅 $LATER

> [!note] Decision
> We are keeping the blog on the same domain. Moving it would cost more search ranking than it is worth.

## Notes

The old site spends most of its weight on fonts. Two families and five weights is three weights too many.

\`\`\`css
:root {
  --measure: 68ch;
  --step-0: clamp(1rem, 0.95rem + 0.3vw, 1.125rem);
}
\`\`\`
MD

cat > "$VAULT/Projects/Reading List.md" <<'MD'
---
icon: 📚
---

Books and essays worth the time, roughly in the order I mean to get to them.

## Reading now

- [ ] *The Design of Everyday Things* — Don Norman
- [ ] *A Pattern Language* — Christopher Alexander

## Finished

- [x] *How Buildings Learn* — Stewart Brand
- [x] *The Elements of Typographic Style* — Robert Bringhurst

> Typography exists to honor content.
MD

cat > "$VAULT/Projects/Q4 Planning.md" <<MD
---
icon: 📈
date: $LATER
---

## Themes

- Finish what was started in Q3 before opening anything new
- One launch, done properly

## Open questions

- [ ] Who owns onboarding after the reorg? 📅 $LATER
- [ ] Do we need a second designer?
MD

cat > "$VAULT/Projects/Archive/Old Ideas.md" <<'MD'
Things that did not make the cut, kept in case they look better later.

- A browser extension
- Weekly email digest
MD

cat > "$VAULT/Areas/Health.md" <<'MD'
---
icon: 🌱
---

## Habits

- [x] Walk before work
- [ ] Stretch in the evening
- [ ] Lights out by eleven

## Running log

| Week | Distance | Feeling |
|------|---------:|---------|
| 44 | 18 km | Heavy legs |
| 45 | 22 km | Better |
| 46 | 25 km | Strong |
MD

cat > "$VAULT/Areas/Finances.md" <<'MD'
---
icon: 💰
---

Monthly review checklist.

1. Reconcile accounts
2. Move savings
3. Check subscriptions
MD

cat > "$VAULT/Ideas.md" <<'MD'
---
icon: 💡
---

A running list. Most of these will not survive a second look, which is the point.

- A calendar that only shows free time
- Recipes that scale by the number of people at the table
- A map of every bench in the city with a view
MD

cat > "$VAULT/Meeting Notes/Weekly Sync.md" <<MD
---
icon: 🗓
date: $SOON
---

## Agenda

1. Launch date
2. Hiring
3. Anything else

## Actions

- [ ] Send the revised timeline 📅 $SOON
- [ ] Book the room for the offsite 📅 $LATER
- [x] Share last week’s notes
MD

cat > "$VAULT/Daily Notes/$TODAY.md" <<'MD'
## Plan

- [ ] Finish the navigation draft
- [ ] Reply to Mina
- [x] Morning walk

## Notes

Slow start, good afternoon. The new type scale finally feels right at small sizes.
MD

cat > "$VAULT/Daily Notes/$YESTERDAY.md" <<'MD'
## Plan

- [x] Audit the current pages
- [x] Call the bank

## Notes

Found three pages nobody has visited since last year.
MD

cat > "$VAULT/Daily Notes/$EARLIER.md" <<'MD'
A quiet day. Read for an hour and wrote nothing down, which was the right call.
MD

# A board, in the format Obsidian's Kanban plugin uses, with a few weeks of history.
cat > "$VAULT/Projects/Launch Board.md" <<MD
---

kanban-plugin: basic
lp-board: bdemolaunch
icon: 📋

---

## Backlog

- [ ] Write the press release #launch @{$LATER} ^cbk1
- [ ] Record a product walkthrough #video ^cbk2
- [ ] Plan the launch-day posts #launch ^cbk3


## In progress

- [ ] Finish the pricing page #web @{$SOON} @@{16:00} ^cip1
	Two plans, and one switch for yearly billing.
	- [x] Draft the copy
	- [x] Pick the plan names
	- [ ] Review with Mina
- [ ] Fix sign-up on mobile #web #bug @{$YESTERDAY} ^cip2


## Review

- [ ] Accessibility pass on the homepage #web ^crv1


## Done

**Complete**
- [x] Choose a launch date ^cdn1
- [x] Set up analytics #web ^cdn2
- [x] Brief the support team ^cdn3


%% kanban:settings
\`\`\`
{"kanban-plugin":"basic"}
\`\`\`
%%
MD

mkdir -p "$VAULT/.lp/boards"
python3 - "$VAULT/.lp/boards/bdemolaunch.json" <<'PY'
import json, sys, uuid, datetime as dt
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
def at(days_ago, hour=10):
    return (now - dt.timedelta(days=days_ago)).replace(hour=hour, minute=0, second=0).strftime("%Y-%m-%dT%H:%M:%SZ")
def day(days_ago):
    d = dt.date.today() - dt.timedelta(days=days_ago)
    return {"year": d.year, "month": d.month, "day": d.day}
titles = {"cbk1": "Write the press release", "cbk2": "Record a product walkthrough", "cbk3": "Plan the launch-day posts",
          "cip1": "Finish the pricing page", "cip2": "Fix sign-up on mobile", "crv1": "Accessibility pass on the homepage",
          "cdn1": "Choose a launch date", "cdn2": "Set up analytics", "cdn3": "Brief the support team"}
added = {"cdn1": 20, "cdn2": 20, "cip1": 18, "cdn3": 16, "cbk1": 14, "cip2": 11, "crv1": 9, "cbk2": 6, "cbk3": 3}
events = []
def event(days_ago, kind, card, frm=None, to=None, hour=10):
    events.append({"id": str(uuid.uuid4()).upper(), "at": at(days_ago, hour), "kind": kind, "cardID": card,
                   "cardTitle": titles[card], **({"from": frm} if frm else {}), **({"to": to} if to else {})})
for card, ago in sorted(added.items(), key=lambda item: -item[1]):
    event(ago, "created", card, to="Backlog")
event(17, "moved", "cdn1", "Backlog", "Done", 11); event(17, "completed", "cdn1", hour=11)
event(15, "moved", "cip1", "Backlog", "In progress")
event(12, "moved", "cdn2", "Backlog", "In progress")
event(8, "moved", "cdn2", "In progress", "Done", 16); event(8, "completed", "cdn2", hour=16)
event(7, "moved", "crv1", "Backlog", "Review")
event(4, "moved", "cdn3", "Backlog", "Done", 15); event(4, "completed", "cdn3", hour=15)
event(2, "moved", "cip2", "Backlog", "In progress")
event(0, "dueChanged", "cip1", to=(dt.date.today() + dt.timedelta(days=2)).isoformat(), hour=9)
snapshots = []
for ago in range(20, -1, -1):
    total = sum(1 for a in added.values() if a >= ago)
    done = sum(1 for e in events if e["kind"] == "completed" and (now - dt.datetime.strptime(e["at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)).days >= ago)
    if ago in (19, 13, 5):   # Days the board was not opened.
        continue
    snapshots.append({"day": day(ago), "total": total, "done": done})
log = {"boardID": "bdemolaunch", "events": events, "snapshots": snapshots,
       "firstSeen": {card: at(ago, 9) for card, ago in added.items()}}
json.dump(log, open(sys.argv[1], "w"), sort_keys=True)
PY

# A small image to embed.
swift - "$VAULT/assets/gradient.png" <<'SWIFT' 2>/dev/null
import AppKit
let path = CommandLine.arguments[1]
let size = NSSize(width: 1440, height: 720)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: 720, height: 360)   // 144 dpi
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(origin: .zero, size: rep.size)
NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.98, green: 0.62, blue: 0.55, alpha: 1)])!
    .draw(in: rect, angle: 35)
NSColor.white.withAlphaComponent(0.18).setFill()
NSBezierPath(ovalIn: NSRect(x: 420, y: 60, width: 360, height: 360)).fill()
NSBezierPath(ovalIn: NSRect(x: -80, y: -120, width: 320, height: 320)).fill()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
SWIFT

echo "Demo workspace created at $VAULT"
find "$VAULT" -type f | sed "s|$VAULT/|  |" | sort
