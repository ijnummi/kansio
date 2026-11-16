#!/bin/bash
# Generates test folders for benchmarks and manual testing.
#
#   Tools/make-fixtures.sh [target-dir]
#
# Default target: $KANSIO_FIXTURES, else $TMPDIR/kansio-fixtures.
# The target's last path component must contain "kansio-fixtures" (safety: this
# script deletes and recreates it). Files are sparse/empty, so disk use is tiny.
#
# Layout:
#   flat-1k, flat-10k, flat-100k  realistic mixed names, ~3% subfolders, varied sizes and dates
#   deep                          60 nested levels
#   long-names                    255-byte names (ASCII and multi-byte UTF-8)
#   unicode                       NFD, CJK, RTL, emoji, combining marks, odd whitespace…
#   symlinks                      file/dir/absolute/broken links, a loop, links to . and ..
#   hidden                        dotfiles and UF_HIDDEN-flagged files
#   packages                      fake Fake.app and Data.bundle (should show as single items)
#   empty                         an empty folder
set -euo pipefail

tmp="${TMPDIR:-/tmp}"
target="${1:-${KANSIO_FIXTURES:-${tmp%/}/kansio-fixtures}}"
target="${target%/}"
case "$(basename "$target")" in
  *kansio-fixtures*) ;;
  *) echo "refusing: target name must contain 'kansio-fixtures': $target" >&2; exit 1 ;;
esac

rm -rf "$target"
mkdir -p "$target"

/usr/bin/python3 - "$target" <<'PY'
import os, random, sys, unicodedata, subprocess

root = sys.argv[1]
rng = random.Random(42)  # deterministic fixtures
NOW = 1_763_000_000      # fixed "now" (Nov 2025) so dates are reproducible

words = ["Report", "invoice", "IMG", "Screenshot", "notes", "draft", "Budget", "photo", "backup",
         "Meeting", "summary", "design", "final", "v2", "Ärger", "naïve", "café", "résumé",
         "data", "export", "README", "chapter", "scan", "Untitled", "project", "build", "log"]
exts = ["txt", "jpg", "png", "pdf", "md", "swift", "zip", "docx", "xlsx", "mov", "json", "", "html", "heic"]

def make_flat(name, count):
    d = os.path.join(root, name)
    os.mkdir(d)
    used = set()
    for i in range(count):
        while True:
            base = f"{rng.choice(words)} {rng.randrange(100000)}" if rng.random() < 0.7 else \
                   f"{rng.choice(words)}_{rng.choice(words)}-{rng.randrange(1000)}"
            ext = rng.choice(exts)
            n = f"{base}.{ext}" if ext else base
            if n.lower() not in used:  # default APFS is case-insensitive
                used.add(n.lower()); break
        p = os.path.join(d, n)
        if rng.random() < 0.03:
            os.mkdir(p)
        else:
            with open(p, "wb") as f:
                size = int(rng.paretovariate(1.2) * 1000) if rng.random() < 0.8 else 0
                f.truncate(min(size, 50_000_000_000))  # sparse: no disk space used
        t = NOW - rng.randrange(0, 5 * 365 * 86400)
        os.utime(p, (t, t), follow_symlinks=False)

make_flat("flat-1k", 1_000)
make_flat("flat-10k", 10_000)
make_flat("flat-100k", 100_000)

# Deep nesting
p = os.path.join(root, "deep")
for level in range(1, 61):
    p = os.path.join(p, f"level-{level:02d}")
os.makedirs(p)
open(os.path.join(p, "bottom.txt"), "w").write("you made it\n")

# Long names (APFS limit: 255 UTF-8 bytes)
d = os.path.join(root, "long-names"); os.mkdir(d)
for n in ["a" * 255, ("long name " * 30)[:251] + ".txt", "ü" * 127, "名" * 85, "🎉" * 63 + "x.t"]:
    assert len(n.encode()) <= 255, n
    open(os.path.join(d, n), "w").close()

# Unicode
d = os.path.join(root, "unicode"); os.mkdir(d)
names = [
    unicodedata.normalize("NFD", "Café NFD.txt"),
    unicodedata.normalize("NFC", "Crème NFC.txt"),
    "日本語のファイル.txt", "中文文件.txt", "한국어.txt",
    "مرحبا.txt", "שלום.txt", "Русский.txt", "Ελληνικά.txt",
    "🎉 party.txt", "👩‍👩‍👧 family (ZWJ).txt", "flag 🇫🇮.txt",
    "á̂̃ stacked marks.txt", "１２３ full-width digits.txt",
    " leading space.txt", "trailing space .txt", "two  spaces.txt",
    "line\nbreak.txt", "tab\there.txt", "colon:shows-as-slash.txt", "zero​width.txt",
    "file2.txt", "file10.txt", "file1.txt", "File3.txt",
]
for n in names:
    open(os.path.join(d, n), "w").close()

# Symlinks
d = os.path.join(root, "symlinks"); os.mkdir(d)
os.mkdir(os.path.join(d, "real-folder"))
open(os.path.join(d, "real-file.txt"), "w").write("hello\n")
os.symlink("real-file.txt", os.path.join(d, "link-to-file"))
os.symlink("real-folder", os.path.join(d, "link-to-folder"))
os.symlink("/usr/bin", os.path.join(d, "absolute-link-to-usr-bin"))
os.symlink("nowhere", os.path.join(d, "broken-link"))
os.symlink("loop-b", os.path.join(d, "loop-a"))
os.symlink("loop-a", os.path.join(d, "loop-b"))
os.symlink(".", os.path.join(d, "link-to-self-dir"))
os.symlink("..", os.path.join(d, "link-to-parent"))

# Hidden
d = os.path.join(root, "hidden"); os.mkdir(d)
for n in [".dotfile", ".config", "visible.txt", "flagged-hidden.txt"]:
    open(os.path.join(d, n), "w").close()
os.mkdir(os.path.join(d, ".hidden-folder"))
subprocess.run(["chflags", "hidden", os.path.join(d, "flagged-hidden.txt")], check=True)

# Packages
d = os.path.join(root, "packages"); os.mkdir(d)
app = os.path.join(d, "Fake.app", "Contents")
os.makedirs(os.path.join(app, "MacOS")); os.makedirs(os.path.join(app, "Resources"))
open(os.path.join(app, "Info.plist"), "w").write("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.kansio.fixture.Fake</string>
<key>CFBundleName</key><string>Fake</string>
<key>CFBundleExecutable</key><string>Fake</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
""")
exe = os.path.join(app, "MacOS", "Fake")
open(exe, "w").write("#!/bin/sh\necho fake app\n"); os.chmod(exe, 0o755)
os.makedirs(os.path.join(d, "Data.bundle", "Contents"))
os.mkdir(os.path.join(d, "Plain Folder"))

# Empty folder
os.mkdir(os.path.join(root, "empty"))
PY

for d in flat-1k flat-10k flat-100k deep long-names unicode symlinks hidden packages empty; do
  printf '%-12s %7s entries\n' "$d" "$(find "$target/$d" -mindepth 1 -maxdepth 1 -print0 | tr -dc '\0' | wc -c | tr -d ' ')"
done
echo "fixtures ready: $target"
