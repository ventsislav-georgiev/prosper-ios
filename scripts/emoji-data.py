#!/usr/bin/env python3
"""Writes the emoji picker's list (app/Sources/Keys/EmojiData.swift) from Unicode's
emoji-test.txt, https://unicode.org/Public/emoji/latest/emoji-test.txt, and its search
words (#666) from a Unicode CLDR release's common/ directory, https://github.com/unicode-org/cldr,
their order among ties (#684) from Unicode's emoji-freq.txt, https://github.com/unicode-org/unicodetools/blob/main/unicodetools/src/main/resources/org/unicode/props/emoji-freq.txt:

    python3 -I scripts/emoji-data.py <emoji-test.txt> <cldr>/common <emoji-freq.txt> > app/Sources/Keys/EmojiData.swift

Fully-qualified emoji only, in the file's order and groups, without the Component group
and without skin tones (U+1F3FB..U+1F3FF); the emoji taking one are listed apart (#667).

ponytail: only the five uniform tones (one tone for every person); mixed per-person tones
(🧑🏻‍🤝‍🧑🏿) are left out. Add them with a per-person strip if asked for."""
import hashlib
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET

# Emoji 14.0 and older iOS 16.0 draws; the newer ones are listed by version, and the picker
# keeps those this iOS's Apple Color Emoji has (`EmojiPicker.draws`).
BASE = 14.0
SKIN_TONES = range(0x1F3FB, 0x1F400)
PER_LINE = 16
# https://www.unicode.org/license.txt, which the data files carry with them.
UNICODE_LICENSE = """\
// UNICODE LICENSE V3
//
// COPYRIGHT AND PERMISSION NOTICE
//
// Copyright © 1991-2026 Unicode, Inc.
//
// NOTICE TO USER: Carefully read the following legal agreement. BY
// DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
// SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
// TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
// DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of data files and any associated documentation (the "Data Files") or
// software and any associated documentation (the "Software") to deal in the
// Data Files or Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, and/or sell
// copies of the Data Files or Software, and to permit persons to whom the
// Data Files or Software are furnished to do so, provided that either (a)
// this copyright and permission notice appear with all copies of the Data
// Files or Software, or (b) this copyright and permission notice appear in
// associated Documentation.
//
// THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
// KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
// THIRD PARTY RIGHTS.
//
// IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
// BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
// OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
// WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
// ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
// FILES OR SOFTWARE.
//
// Except as contained in this notice, the name of a copyright holder shall
// not be used in advertising or otherwise to promote the sale, use or other
// dealings in these Data Files or Software without prior written
// authorization of the copyright holder."""

version, group, groups, newer, qualified = "?", None, {}, {}, {}
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if m := re.match(r"# Version: (\S+)", line):
            version = m[1]
        elif line.startswith("# group: "):
            group = line[len("# group: "):].strip()
        elif m := re.match(r"([0-9A-F ]+?)\s*; fully-qualified\s*# \S+ E(\d+\.\d+) ", line):
            points = [int(p, 16) for p in m[1].split()]
            e, v = "".join(map(chr, points)), float(m[2])
            qualified[e] = v
            if group != "Component" and not any(p in SKIN_TONES for p in points):
                groups.setdefault(group, []).append(e)
                if v > BASE:
                    newer.setdefault(v, []).append(e)

# Skin tones (#667): an emoji takes them when its five uniform toned forms are all
# fully-qualified, derived as `EmojiPicker.toned` does: the tone after the first scalar, and
# after the last where that is a modifier base too (🧑‍🤝‍🧑), a U+FE0F after either dropped.
# Every uniform toned sequence in the file must be one of those, so nothing is missed.
MODIFIER_BASES = {ord(e[0]) for e in qualified if len(e) == 2 and ord(e[1]) in SKIN_TONES}
def toned(e, tone):
    out = []
    for i, c in enumerate(e):
        if c == "\ufe0f" and out and ord(out[-1]) in SKIN_TONES:
            continue
        out.append(c)
        if i == 0 or (i == len(e) - 1 and ord(c) in MODIFIER_BASES):
            out.append(chr(tone))
    return "".join(out)
toned_bases = [e for g in groups.values() for e in g if toned(e, SKIN_TONES[0]) in qualified]
variants = [toned(e, t) for e in toned_bases for t in SKIN_TONES]
uniform = {e for e in qualified if len({c for c in e if ord(c) in SKIN_TONES}) == 1}
assert set(variants) == uniform, (len(set(variants)), len(uniform))
assert len({e.replace("\ufe0f", "") for e in toned_bases}) == len(toned_bases)
toned_old, toned_newer = [], {}
for e in toned_bases:
    v = max(qualified[toned(e, t)] for t in SKIN_TONES)
    (toned_newer.setdefault(v, []) if v > BASE else toned_old).append(e)
# What `EmojiPickerTests` derives again: each base's five, light to dark, `toned` then `newerToned`.
tone_order = toned_old + [e for v in sorted(toned_newer) for e in toned_newer[v]]
tone_hash = hashlib.sha256("\n".join(toned(e, t) for e in tone_order for t in SKIN_TONES).encode()).hexdigest()
print(f"tones: {len(toned_bases)} emoji, {len(variants)} toned", file=sys.stderr)

# CLDR's names (tts) and keywords for each emoji, English and Bulgarian (#666), annotations
# and annotationsDerived (sequences), matched without U+FE0F. Folded as the query is
# (`PanelFilter.fold`): lowercase, no diacritics.
LANGUAGES = ["en", "bg"]
def fold(s):
    return unicodedata.normalize("NFC", "".join(c for c in unicodedata.normalize("NFD", s.lower())
                                                if not unicodedata.combining(c)))
def bare(e):
    return e.replace("\ufe0f", "")
cldr, keywords = sys.argv[2], {}
for language in LANGUAGES:
    names, words = {}, {}
    for kind in ["annotations", "annotationsDerived"]:
        root = ET.parse(f"{cldr}/{kind}/{language}.xml").getroot()
        for a in root.iter("annotation"):
            key, text = bare(a.get("cp")), fold(a.text or "")
            if a.get("type") == "tts":
                names[key] = text
            else:
                words[key] = list(dict.fromkeys(w.strip() for w in text.split("|") if w.strip()))
    lines = []
    for e in (e for g in groups.values() for e in g):
        if bare(e) in names:
            line = f"{e} {names[bare(e)]}|{'|'.join(words.get(bare(e), []))}|"
            assert names[bare(e)].count("|") == 0 and '"""' not in line and "\n" not in line, line
            lines.append(line)
    keywords[language] = lines
    print(f"{language}: {len(lines)} of {sum(map(len, groups.values()))} emoji", file=sys.stderr)

# How often each emoji is used (#684), the search's last tie-break: unicodetools' emoji-freq.txt,
# lines of code points and a count, matched without U+FE0F. A Unicode Data File (everything
# under github.com/unicode-org, https://www.unicode.org/copyright.html): the Unicode License v3.
by_bare, counts = {bare(e): e for g in groups.values() for e in g}, {}
with open(sys.argv[3], encoding="utf-8") as f:
    for line in f:
        points, count = line.rstrip("\n").split("\t")
        if e := by_bare.get("".join(chr(int(p[2:], 16)) for p in points.split())):
            counts[e] = max(counts.get(e, 0), int(count))
popular = sorted(counts, key=lambda e: -counts[e])
print(f"popular: {len(popular)} emoji", file=sys.stderr)

print(f"""// Generated by scripts/emoji-data.py from Unicode's emoji-test.txt, version {version}
// (https://unicode.org/Public/emoji/latest/emoji-test.txt): fully-qualified emoji up to
// Emoji {max(newer, default=BASE)}, skin tones apart (#667), no Component group; and from Unicode CLDR's
// annotations (https://github.com/unicode-org/cldr, common/annotations and
// common/annotationsDerived, {" and ".join(LANGUAGES)}); and from unicodetools' emoji-freq.txt
// (https://github.com/unicode-org/unicodetools). Don't edit; run the script again.
//
// The emoji data, CLDR annotations and emoji-freq.txt are Unicode's, under the Unicode License v3:
//
{UNICODE_LICENSE}

/// The emoji picker's groups (`EmojiPicker`), in Unicode's order, each a list of emoji
/// separated by whitespace; `newer` lists those iOS 16.0 may not draw.
enum EmojiData {{
    static let groups: [(name: String, emoji: String)] = [""")
for name, emoji in groups.items():
    lines = [" ".join(emoji[i:i + PER_LINE]) for i in range(0, len(emoji), PER_LINE)]
    print(f'        ("{name}", """')
    print("\n".join("            " + l for l in lines))
    print('            """),')
# The system keyboards' page (#629): hand-picked, at most 150, every one in the groups above.
FREQUENT = """
    😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩
    😘 😋 😛 😜 🤪 🤗 🤭 🤫 🤔 🤨 😐 😏 😒 🙄 😬 😌
    😔 😴 😷 🤒 🤯 🥳 😎 🤓 😕 🥺 😢 😭 😱 😩 😤 😡
    😈 💀 💩 🤡 👻 🤖 🙈 🙊 💯 💥 💫 💦 💤 💬 👀 🧠
    ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 💔 💕 💖 💗 💘 💝 ❤️‍🔥 💋
    👋 👌 🤌 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊
    👊 👏 🙌 🤲 🤝 🙏 💪 🤷 🤦 🙋 🙇 🔥 ✨ ⭐ 🌟 🌈
    ☀️ ⚡ 🌸 🌹 🍀 🎉 🎊 🎁 🎂 🍕 🍺 ☕ 🏆 🎵 💻 💡
    ✅ ❌ ❗ ❓ ⚠️ 🚫 ➡️ ⬅️ 🆗 🆕 🔴 🟢 🔵 📌 ⏰ 🚀
"""
print("    ]\n")
print("""    /// The emoji newer than 14.0 (all iOS 16.0 draws), by their Emoji version.
    static let newer: [(version: Double, emoji: String)] = [""")
for v, emoji in sorted(newer.items()):
    print(f'        ({v}, "{" ".join(emoji)}"),')
print("    ]\n")
print("""    /// The emoji taking a skin tone (#667), whose five uniform toned forms
    /// (`EmojiPicker.toned`) are fully-qualified; `newerToned` those whose toned forms are
    /// newer than 14.0, by their Emoji version.
    static let toned = \"\"\"""")
print("\n".join("        " + " ".join(toned_old[i:i + PER_LINE]) for i in range(0, len(toned_old), PER_LINE)))
print("        \"\"\"")
print("    static let newerToned: [(version: Double, emoji: String)] = [")
for v, emoji in sorted(toned_newer.items()):
    print(f'        ({v}, "{" ".join(emoji)}"),')
print("    ]")
print(f"""    /// SHA-256 of every toned form, a line each, light to dark, `toned` then `newerToned`.
    static let tonedHash = "{tone_hash}"
""")
print("""    /// The system keyboards' one page beside Recents on the shared font (#629, #664): every
    /// group's glyphs outgrow an extension's memory (#515), so the common faces, hearts,
    /// hands and symbols only.
    static let frequent = \"\"\"""")
print("\n".join("        " + l.strip() for l in FREQUENT.strip().splitlines()))
print("        \"\"\"\n")
print("""    /// The emoji by how often they're used, most first (#684, unicodetools' emoji-freq.txt):
    /// the search's last tie-break (`EmojiKeywords`), those not here tied last.
    static let popular = \"\"\"""")
print("\n".join("        " + " ".join(popular[i:i + PER_LINE]) for i in range(0, len(popular), PER_LINE)))
print("        \"\"\"\n")
print("""    /// Each emoji's CLDR name and keywords by language (#666), a line each in `groups`' order:
    /// the emoji, a space, its name, then each keyword between bars, all folded
    /// (`EmojiKeywords`). Literals: read in place, nothing loaded till a search parses them.
    static let keywords: [String: String] = [""")
for language, lines in keywords.items():
    print(f'        "{language}": #"""')
    print("\n".join("            " + l for l in lines))
    print('            """#,')
print("    ]\n}")
