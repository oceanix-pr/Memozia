#!/usr/bin/env python3
# 只读的本地化目录校验脚本（独立运行，不接入构建阶段）。
#
# 用法：
#   python3 Scripts/check_l10n.py            # 全量检查，发现问题返回非零退出码
#   python3 Scripts/check_l10n.py --quiet    # 只打印错误/告警计数与详情
#
# 检查项（不修改任何文件）：
#   1. 源语言（catalog.sourceLanguage，当前为 zh-Hans）条目是否缺失或为空；
#   2. 「使用中」的 key 是否缺目标语言、目标语言值是否为空（意外空翻译）：
#      只缺部分目标语言判为错误；完全没有目标语言（刚被 Xcode 抽取、state=new）判为「待翻译」告警；
#   3. 占位符（%@ / %d / %lld / %1$d / %.1f …）种类与数量在源文与各译文间是否一致；
#   4. plural / variation 各语言的分支是否与源语言一致；
#   5. 源码里出现但目录里没有的用户可见文案（新文案是否进入 catalog）——启发式，只告警；
#   6. 目录里存在但源码已不再引用的 key（stale）：Xcode 抽取看不到「动态引用」
#      （如 `titleKey: "…"`、返回纯 String 的展示名），这类 key 会被误标 stale 但仍在用，
#      按审计要求视为 **allowlist**，只计数不告警；仅「stale 且源码中确未找到」才告警（可删除）。
#
# 说明：
# - 「使用中」与「新文案」依赖对 Swift 字符串字面量的正则启发式抽取，与 Xcode 编译期
#   抽取不完全等价（插值字符串里嵌套引号等场景可能漏判），因此第 5 项只告警不报错。
# - 本脚本面向 macOS 单平台工程：只扫描 Memozia/ 下的 .swift。
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_PATH = os.path.join(ROOT, 'Memozia/Resources/Localizable.xcstrings')
PROJECT_PATH = os.path.join(ROOT, 'project.yml')
SOURCE_DIR = os.path.join(ROOT, 'Memozia')

PLACEHOLDER = re.compile(
    r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|L|q|z|j|t)?[@dfsl]')
SENTINEL = '\x01'
CJK = re.compile(r'[\u3400-\u9fff\u3000-\u303f\uff00-\uffef]')

# 视为「用户可见文案来源」的调用点（用于降低误报）
QUALIFIERS = (
    'Text(', 'Label(', 'Button(', 'Toggle(', 'Picker(', 'Section(', 'Link(',
    'NavigationLink(', 'LocalizedStringKey(', 'String(localized:', '.help(',
    '.navigationTitle(', '.accessibilityLabel(', '.alert(', '.confirmationDialog(',
    'title:', 'content:', 'message:', 'label:', 'placeholder:', 'prompt:',
    'subtitle:', 'caption:', 'note:',
)


def load_expected_languages():
    """期望的目标语言集合：project.yml 的 knownRegions 加上源语言。"""
    langs = []
    text = open(PROJECT_PATH, encoding='utf-8').read()
    in_regions = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('knownRegions:'):
            in_regions = True
            continue
        if in_regions:
            if stripped.startswith('- '):
                langs.append(stripped[2:].strip())
            elif stripped and not line.startswith((' ', '\t')):
                break
    return langs


def normalize(text):
    """把 Swift 插值（\\(...)）与 % 占位符统一成同一哨兵，得到可比对的签名。"""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == '\\' and i + 1 < n and text[i + 1] == '(':
            depth = 0
            j = i + 1
            while j < n:
                if text[j] == '(':
                    depth += 1
                elif text[j] == ')':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            out.append(SENTINEL)
            i = j + 1
            continue
        out.append(text[i])
        i += 1
    return PLACEHOLDER.sub(SENTINEL, ''.join(out))


def placeholders(text):
    """占位符种类与数量（%1$@ 归一为 %@）。"""
    return sorted('%' + m[-1] for m in PLACEHOLDER.findall(text))


def decode_escape(ch):
    """把 Swift 转义序列还原成实际字符（\\( 保留给插值归一化处理）。"""
    return {'n': '\n', 't': '\t', 'r': '\r', '"': '"', "'": "'", '\\': '\\', '0': '\0'}.get(ch, ch)


def swift_literals(source):
    """极简 Swift 字符串扫描：返回 (literal_text, start_offset) 列表。

    字面量里的转义序列会被还原成实际字符，插值 `\\(...)` 原样保留（供 normalize 处理）。
    """
    results = []
    i = 0
    n = len(source)
    while i < n:
        if source.startswith('//', i):
            j = source.find('\n', i)
            i = n if j < 0 else j
            continue
        if source.startswith('/*', i):
            j = source.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        if source[i] == '"':
            start = i
            if source.startswith('"""', i):
                j = i + 3
                buf = []
                while j < n and not source.startswith('"""', j):
                    if source[j] == '\\' and j + 1 < n:
                        nxt = source[j + 1]
                        buf.append('\\(' if nxt == '(' else decode_escape(nxt))
                        j += 2
                        continue
                    buf.append(source[j])
                    j += 1
                results.append((''.join(buf), start))
                i = j + 3
                continue
            j = i + 1
            buf = []
            while j < n:
                ch = source[j]
                if ch == '\\' and j + 1 < n:
                    nxt = source[j + 1]
                    buf.append('\\(' if nxt == '(' else decode_escape(nxt))
                    j += 2
                    continue
                if ch == '"' or ch == '\n':
                    break
                buf.append(ch)
                j += 1
            results.append((''.join(buf), start))
            i = j + 1
            continue
        i += 1
    return results


def collect_source_literals():
    all_sigs = set()
    candidates = []
    blob = []
    for dirpath, _dirnames, filenames in os.walk(SOURCE_DIR):
        for name in filenames:
            if not name.endswith('.swift'):
                continue
            path = os.path.join(dirpath, name)
            source = open(path, encoding='utf-8').read()
            blob.append(source)
            for literal, start in swift_literals(source):
                sig = normalize(literal)
                all_sigs.add(sig)
                if not CJK.search(literal):
                    continue
                # 抽取器无法可靠还原的插值串（嵌套引号等会截断）直接跳过，避免误报
                if '\\(' in literal:
                    continue
                window = source[max(0, start - 40):start].rstrip()
                if any(window.endswith(q) for q in QUALIFIERS):
                    candidates.append((os.path.relpath(path, ROOT), sig, literal))
    return all_sigs, candidates, '\n'.join(blob)


def variation_categories(entry):
    """返回 {variation_type: {lang: set(categories)}}，无 variation 时为空。"""
    result = {}
    for vtype, per_lang in (entry.get('variations') or {}).items():
        result[vtype] = {
            lang: set(branches.keys()) for lang, branches in per_lang.items()
        }
    return result


def main():
    parser = argparse.ArgumentParser(description='只读校验 Localizable.xcstrings')
    parser.add_argument('--quiet', action='store_true', help='只输出错误与告警')
    args = parser.parse_args()

    catalog = json.load(open(CATALOG_PATH, encoding='utf-8'))
    source_language = catalog['sourceLanguage']
    strings = catalog['strings']

    expected_languages = load_expected_languages()
    target_languages = [lang for lang in expected_languages if lang != source_language]

    source_sigs, candidates, source_blob = collect_source_literals()
    key_sigs = {normalize(key) for key in strings}

    errors = []
    warnings = []
    unused_heuristic = []
    untranslated = []
    dynamic_stale = []

    for key, entry in strings.items():
        localizations = entry.get('localizations') or {}
        in_use = normalize(key) in source_sigs or (key.strip() and key in source_blob)
        # 0) 完全空条目：Xcode 抽取后尚未翻译的占位（等价于 state=new），归入「待翻译」
        if not localizations:
            if in_use and key.strip():
                untranslated.append(key)
            continue
        # 1) 源语言条目
        source_unit = (localizations.get(source_language) or {}).get('stringUnit') or {}
        source_value = source_unit.get('value')
        if source_value is None:
            errors.append(f'缺源语言（{source_language}）条目：{key[:50]}')
            continue
        if key.strip() and not source_value.strip():
            errors.append(f'源语言（{source_language}）译文为空：{key[:50]}')

        # 2) 目标语言覆盖与空翻译（空 key 本身允许为空）
        #    区分两种缺翻译：完全没有目标语言（待翻译，告警）与只缺部分语言（不一致，报错）
        if in_use and key.strip():
            present_targets = [lang for lang in target_languages if lang in localizations]
            if not present_targets:
                untranslated.append(key)
            else:
                for lang in target_languages:
                    unit = (localizations.get(lang) or {}).get('stringUnit') or {}
                    value = unit.get('value')
                    if value is None:
                        errors.append(f'使用中的 key 缺目标语言 {lang}：{key[:50]}')
                    elif not value.strip():
                        errors.append(f'空翻译（{lang}）：{key[:50]}')

        # 3) 占位符一致性
        if key.strip():
            expected = placeholders(source_value)
            for lang, unit in localizations.items():
                if lang == source_language:
                    continue
                value = (unit.get('stringUnit') or {}).get('value')
                if value is None:
                    continue
                if placeholders(value) != expected:
                    errors.append(
                        f'占位符不一致（{lang}）：{key[:40]}\n    {value[:80]}')

        # 4) variation / plural 分支完整性
        for vtype, per_lang in variation_categories(entry).items():
            base = per_lang.get(source_language)
            if base is None:
                errors.append(f'{vtype} variation 缺源语言分支：{key[:40]}')
                continue
            for lang, categories in per_lang.items():
                if categories != base:
                    errors.append(
                        f'{vtype} variation 分支不完整（{lang}）：{key[:40]} '
                        f'缺 {sorted(base - categories)} 多 {sorted(categories - base)}')
                for branch in categories:
                    unit = (per_lang[lang][branch].get('stringUnit') or {})
                    if key.strip() and not (unit.get('value') or '').strip():
                        errors.append(f'{vtype} variation 空翻译（{lang}/{branch}）：{key[:40]}')

        # 6) stale：Xcode 标记源码已不再引用
        #    - stale 且源码中确实找不到 → 可安全删除，告警
        #    - stale 但源码中仍能匹配到 → 动态引用（Xcode 抽取视为不可见），按 allowlist 处理，只计数
        if entry.get('extractionState') == 'stale':
            if in_use:
                dynamic_stale.append(key)
            else:
                warnings.append(f'stale key（Xcode 标记且源码中确未找到，可删除）：{key[:60]}')
        elif not in_use and key.strip():
            unused_heuristic.append(key)

    # 5) 源码里有、目录里没有的新文案（启发式）
    seen_missing = set()
    for path, sig, literal in candidates:
        if sig in key_sigs:
            continue
        if sig in seen_missing:
            continue
        seen_missing.add(sig)
        warnings.append(f'新文案未进入 catalog：{literal[:60]}（{path}）')

    if not args.quiet:
        print(f'catalog：{CATALOG_PATH}')
        print(f'源语言：{source_language}；目标语言 {len(target_languages)} 种；key 共 {len(strings)} 条')
    print(f'错误 {len(errors)} 条，告警 {len(warnings)} 条；'
          f'仅源语言（待翻译）{len(untranslated)} 条，'
          f'动态引用被标记 stale（allowlist，不告警）{len(dynamic_stale)} 条，'
          f'启发式判定未引用 {len(unused_heuristic)} 条（动态拼接或已废弃，仅供参考）')
    for item in errors:
        print(f'  [错误] {item}')
    for item in warnings:
        print(f'  [告警] {item}')
    for key in untranslated:
        print(f'  [待翻译] 仅源语言、无任何目标语言译文：{key[:60]}')

    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
