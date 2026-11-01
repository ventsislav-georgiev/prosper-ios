#!/usr/bin/env python3
"""Writes the emoji picker's list (app/Sources/Keys/EmojiData.swift) from Unicode's
emoji-test.txt, https://unicode.org/Public/emoji/latest/emoji-test.txt, and its search
words (#666) from a Unicode CLDR release's common/ directory, https://github.com/unicode-org/cldr:

    python3 -I scripts/emoji-data.py <emoji-test.txt> <cldr>/common > app/Sources/Keys/EmojiData.swift

Fully-qualified emoji only, in the file's order and groups, without the Component group
and without skin tones (U+1F3FB..U+1F3FF)."""
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

version, group, groups, newer = "?", None, {}, {}
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if m := re.match(r"# Version: (\S+)", line):
            version = m[1]
        elif line.startswith("# group: "):
            group = line[len("# group: "):].strip()
        elif m := re.match(r"([0-9A-F ]+?)\s*; fully-qualified\s*# \S+ E(\d+\.\d+) ", line):
            points = [int(p, 16) for p in m[1].split()]
            e, v = "".join(map(chr, points)), float(m[2])
            if group != "Component" and not any(p in SKIN_TONES for p in points):
                groups.setdefault(group, []).append(e)
                if v > BASE:
                    newer.setdefault(v, []).append(e)

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

print(f"""// Generated by scripts/emoji-data.py from Unicode's emoji-test.txt, version {version}
// (https://unicode.org/Public/emoji/latest/emoji-test.txt): fully-qualified emoji up to
// Emoji {max(newer, default=BASE)}, no skin tones, no Component group; and from Unicode CLDR's
// annotations (https://github.com/unicode-org/cldr, common/annotations and
// common/annotationsDerived, {" and ".join(LANGUAGES)}). Don't edit; run the script again.
//
// The emoji data and CLDR annotations are Unicode's, under the Unicode License v3:
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
print("""    /// The system keyboards' one page beside Recents on the shared font (#629, #664): every
    /// group's glyphs outgrow an extension's memory (#515), so the common faces, hearts,
    /// hands and symbols only.
    static let frequent = \"\"\"""")
print("\n".join("        " + l.strip() for l in FREQUENT.strip().splitlines()))
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
