#!/usr/bin/env python3
"""Render the three-language GitHub Wiki from versioned local documents.

python3 docs/wiki/publish_wiki.py --output build/github-wiki --refresh-traditional
This prepares and validates files; it never commits or pushes automatically.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
WIKI = ROOT / "docs/wiki"
REPO = "https://github.com/oceanix-pr/Memozia"
PAGES = [
    ("Home.md", "Home", "首页", "首頁", "Home"),
    ("02-整体架构.md", "02-Architecture", "整体架构", "整體架構", "Architecture"),
    ("03-数据模型层.md", "03-Data-Models", "数据模型", "資料模型", "Data Models"),
    ("04-录音与音频采集.md", "04-Audio-Capture", "录音与音频采集", "錄音與音訊擷取", "Audio Capture"),
    ("05-语音转写与说话人分离.md", "05-Transcription-and-Diarization", "转写与说话人分离", "轉寫與說話者分離", "Transcription and Diarization"),
    ("06-LLM总结与智能功能.md", "06-AI-Features", "LLM 总结与智能功能", "LLM 摘要與智慧功能", "LLM Summaries and AI Features"),
    ("07-截图与OCR.md", "07-Screenshots-and-OCR", "截图与 OCR", "螢幕截圖與 OCR", "Screenshots and OCR"),
    ("08-数据同步与安全.md", "08-Sync-and-Security", "数据同步与安全", "資料同步與安全", "Data Sync and Security"),
    ("09-系统集成服务.md", "09-System-Integration", "系统集成与更新", "系統整合與更新", "System Integration and Updates"),
    ("10-ViewModel层.md", "10-ViewModels", "ViewModel 层", "ViewModel 層", "ViewModels"),
    ("11-视图层.md", "11-Views", "视图层", "檢視層", "Views"),
    ("12-依赖关系.md", "12-Dependencies", "依赖关系", "相依關係", "Dependencies"),
    ("13-构建与运行.md", "13-Build-and-Run", "构建与运行", "建置與執行", "Build and Run"),
]
LANGUAGES = [("zh-CN", None, "简体中文", 2), ("zh-TW", "zh-Hant", "繁體中文", 3), ("en", "en", "English", 4)]
LINK = re.compile(r"(?<!!)\[([^\]]+)\]\(([^)]+)\)")
INLINE = re.compile(r"(`+)(.+?)\1")


def prose_map(text, transform):
    """Keep executable examples, identifiers and paths byte-for-byte intact."""
    def convert_line(line):
        pos, parts = 0, []
        protected = sorted([(m.start(), m.end()) for m in INLINE.finditer(line)] +
                           [(m.start(2), m.end(2)) for m in LINK.finditer(line)])
        for start, end in protected:
            if start < pos:
                continue
            parts.extend([transform(line[pos:start]), line[start:end]])
            pos = end
        parts.append(transform(line[pos:]))
        return "".join(parts)

    output, fence, diagram = [], None, False
    for line in text.splitlines(keepends=True):
        match = re.match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if match:
            mark = match.group(1)[0]
            if fence == mark:
                fence, diagram = None, False
            else:
                fence = mark
                diagram = match.group(2).strip() in ("", "text")
            output.append(line)
        elif fence and not diagram:
            output.append(line)
        else:
            output.append(convert_line(line))
    return "".join(output)


def source_path(page, directory):
    return WIKI / directory / (page[1] + ".md") if directory else WIKI / page[0]


def refresh_traditional():
    try:
        from opencc import OpenCC
    except ImportError as exc:
        raise SystemExit("Install opencc-python-reimplemented before refreshing Traditional Chinese.") from exc
    converter = OpenCC("s2twp")
    mapping = {(WIKI / page[0]).resolve(): WIKI / "zh-Hant" / (page[1] + ".md") for page in PAGES}
    (WIKI / "zh-Hant").mkdir(exist_ok=True)
    for page in PAGES:
        source, target = WIKI / page[0], mapping[(WIKI / page[0]).resolve()]
        text = prose_map(source.read_text(), converter.convert)

        def adjust(match):
            label, url = match.groups()
            if urlsplit(url).scheme or url.startswith("#"):
                return match.group(0)
            resolved = (source.parent / unquote(url)).resolve()
            destination = mapping.get(resolved, resolved)
            import os
            return f"[{label}]({Path(os.path.relpath(destination, target.parent)).as_posix()})"

        target.write_text(LINK.sub(adjust, text))


def render(output):
    paths, slugs = {}, set()
    for prefix, directory, _, _ in LANGUAGES:
        for page in PAGES:
            source = source_path(page, directory).resolve()
            if not source.is_file():
                raise SystemExit(f"Missing translation: {source.relative_to(ROOT)}")
            paths[source] = f"{prefix}-{page[1]}"
            slugs.add(paths[source])

    generated = {}
    for prefix, directory, _, title_index in LANGUAGES:
        for page in PAGES:
            source = source_path(page, directory).resolve()

            def rewrite(match):
                label, url = match.groups()
                if urlsplit(url).scheme or url.startswith("#"):
                    return match.group(0)
                resolved = (source.parent / unquote(url)).resolve()
                if resolved in paths:
                    target = paths[resolved]
                else:
                    if not resolved.exists() or not resolved.is_relative_to(ROOT):
                        raise SystemExit(f"Broken source link in {source.relative_to(ROOT)}: {url}")
                    kind = "tree" if resolved.is_dir() else "blob"
                    target = f"{REPO}/{kind}/main/{quote(resolved.relative_to(ROOT).as_posix())}"
                return f"[{label}]({target})"

            navigation = " · ".join(f"**{name}**" if code == prefix else f"[{name}]({code}-{page[1]})"
                                      for code, _, name, _ in LANGUAGES)
            text = LINK.sub(rewrite, source.read_text())
            lines = text.splitlines()
            if not lines or not lines[0].startswith("# "):
                raise SystemExit(f"Missing page title: {source}")
            lines[1:1] = ["", navigation]
            text = "\n".join(lines).rstrip() + "\n"
            if sum(bool(re.match(r"^```", line)) for line in text.splitlines()) % 2:
                raise SystemExit(f"Unclosed fenced code block: {source}")
            generated[f"{prefix}-{page[1]}.md"] = text

    generated["Home.md"] = """# Memozia Wiki

原生 macOS 会议录音、转写、总结、待办与图片笔记应用的架构和模块文档。

原生 macOS 會議錄音、轉寫、摘要、待辦與圖片筆記應用程式的架構與模組文件。

Architecture and module documentation for the native macOS meeting recorder, transcription, summaries, tasks, and image notes app.

| 简体中文 | 繁體中文 | English |
|---|---|---|
| [进入简体中文 Wiki](zh-CN-Home) | [進入繁體中文 Wiki](zh-TW-Home) | [Read the English Wiki](en-Home) |

""".rstrip() + "\n" + "\n".join("| " + " | ".join(f"[{page[index]}]({prefix}-{page[1]})" for prefix, _, _, index in LANGUAGES) + " |" for page in PAGES[1:]) + f"\n\n[GitHub]({REPO}) · [Downloads / 下载 / 下載]({REPO}/releases)\n"
    sidebar = ["# Memozia", "", "[语言 / 語言 / Language](Home)", ""]
    for prefix, _, name, index in LANGUAGES:
        sidebar.extend([f"### {name}", ""])
        sidebar.extend(f"- [{page[index]}]({prefix}-{page[1]})" for page in PAGES)
        sidebar.append("")
    generated["_Sidebar.md"] = "\n".join(sidebar)
    generated["_Footer.md"] = f"[语言 / 語言 / Language](Home) · [Source / 源码 / 原始碼]({REPO}/tree/main/docs/wiki) · [Downloads / 下载 / 下載]({REPO}/releases)\n"
    slugs.update(["Home", "_Sidebar", "_Footer"])
    for name, text in generated.items():
        for _, target in LINK.findall(text):
            if not urlsplit(target).scheme and not target.startswith("#") and target not in slugs:
                raise SystemExit(f"Broken Wiki link in {name}: {target}")
    output.mkdir(parents=True, exist_ok=True)
    # Preserve existing unrelated pages and the Wiki's Git history.
    for name, text in generated.items():
        (output / name).write_text(text)
    print(f"Validated and rendered {len(PAGES)} pages × {len(LANGUAGES)} languages + Home, sidebar and footer ({len(generated)} files).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--refresh-traditional", action="store_true")
    args = parser.parse_args()
    if args.refresh_traditional:
        refresh_traditional()
    render(args.output.resolve())
