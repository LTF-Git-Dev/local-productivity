#!/bin/zsh
# Builds a large workspace in .build/stress-vault for measuring speed: about 3,000 notes in
# nested folders, two years of daily notes, a 2 MB note, and a board with 300 cards.
#
#   Scripts/make-stress-vault.sh [path]

ROOT="${0:A:h:h}"
VAULT="${1:-$ROOT/.build/stress-vault}"
rm -rf "$VAULT"
mkdir -p "$VAULT"

python3 - "$VAULT" <<'PY'
import os, random, sys, datetime as dt
vault = sys.argv[1]
random.seed(7)
words = ("plan launch review budget design write ship meeting notes idea research draft call email team project "
         "customer roadmap quarter goal metric sprint retro feedback hiring travel health reading garden").split()

def sentence(n=12):
    return " ".join(random.choice(words) for _ in range(n)).capitalize() + "."

def page(title, paragraphs, tasks=0):
    lines = [f"# {title}", ""]
    for _ in range(paragraphs):
        lines += [sentence(random.randint(8, 30)), ""]
        if random.random() < 0.3:
            lines += [f"- {sentence(6)}" for _ in range(random.randint(2, 6))] + [""]
    today = dt.date.today()
    for i in range(tasks):
        due = today + dt.timedelta(days=random.randint(-20, 60))
        lines.append(f"- [{'x' if random.random() < 0.3 else ' '}] {sentence(5)} 📅 {due.isoformat()}")
    return "\n".join(lines) + "\n"

# 2,400 notes in 3 levels of folders.
for a in range(8):
    for b in range(10):
        folder = os.path.join(vault, f"Area {a}", f"Topic {b}")
        os.makedirs(folder, exist_ok=True)
        for c in range(30):
            with open(os.path.join(folder, f"Note {a}-{b}-{c}.md"), "w") as f:
                f.write(page(f"Note {a}-{b}-{c}", random.randint(2, 12), tasks=random.choice([0, 0, 0, 2, 4])))

# Two years of daily notes.
daily = os.path.join(vault, "Daily Notes")
os.makedirs(daily, exist_ok=True)
for i in range(730):
    day = dt.date.today() - dt.timedelta(days=i)
    with open(os.path.join(daily, f"{day.isoformat()}.md"), "w") as f:
        f.write(page(day.isoformat(), random.randint(1, 4), tasks=random.choice([0, 1, 2])))

# One very large note (about 2 MB).
with open(os.path.join(vault, "Huge Note.md"), "w") as f:
    f.write("# Huge Note\n\n")
    for i in range(9000):
        if i % 50 == 0:
            f.write(f"## Section {i // 50}\n\n")
        f.write(sentence(30) + " **" + random.choice(words) + "** and *" + random.choice(words) + "*.\n\n")

# A board with 300 cards in 6 lists.
lanes = ["Backlog", "Next", "In progress", "Review", "Blocked", "Done"]
lines = ["---", "", "kanban-plugin: basic", "lp-board: bstress", "", "---", ""]
card = 0
for index, lane in enumerate(lanes):
    lines += [f"## {lane}", ""]
    if lane == "Done":
        lines.append("**Complete**")
    for _ in range(50):
        due = dt.date.today() + dt.timedelta(days=random.randint(-10, 40))
        tag = random.choice(["web", "design", "ops", "bug", "launch"])
        done = "x" if lane == "Done" else " "
        lines.append(f"- [{done}] {sentence(6)[:-1]} #{tag} @{{{due.isoformat()}}} ^cs{card}")
        card += 1
    lines += ["", ""]
with open(os.path.join(vault, "Stress Board.md"), "w") as f:
    f.write("\n".join(lines))
PY

echo "Stress workspace created at $VAULT"
echo "  $(find "$VAULT" -name '*.md' | wc -l | tr -d ' ') notes, $(du -sh "$VAULT" | cut -f1) on disk"
