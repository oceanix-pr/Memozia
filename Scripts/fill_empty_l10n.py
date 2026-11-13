#!/usr/bin/env python3
# 补齐 Localizable.xcstrings 中「已被源码抽取但还没有任何翻译」的空条目。
#
# 设计要点：
# 1. 译文来源为 Scripts/add_*l10n*.py 里 add('源文', [20 种语言]) 的**静态解析**结果，
#    不执行这些脚本（部分脚本没有 __main__ 守卫，导入即写文件，会覆盖既有译文）；
# 2. 只写当前为空（无 localizations）的键，已有译文一律不碰；
# 3. 每个键都校验 20 种语言齐全、并且与源文占位符（%@ / %d / %lld / %1$d / %.1f）完全一致；
# 4. 未覆盖的空条目会在末尾列出，需要新增翻译脚本补齐。
import ast
import glob
import json
import os
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
SOURCES = sorted(glob.glob('Scripts/add_*l10n*.py'))
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

PLACEHOLDER = re.compile(r'%(?:\d+\$)?[@dfsl]')


def normalized_placeholders(text):
    """占位符种类与数量（把 %1$@ 归一为 %@：位置说明符只是显式指定参数顺序，与源文等价）"""
    return sorted(PLACEHOLDER.sub(lambda m: '%' + m.group(0)[-1], text))


def static_translations():
    """静态收集所有脚本里的 add(源文, [...]) 译文，返回 {源文: (脚本名, 译文列表)}"""
    table = {}
    for path in SOURCES:
        name = os.path.basename(path)
        tree = ast.parse(open(path, encoding='utf-8').read())
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                    and node.func.id == 'add' and len(node.args) >= 2):
                continue
            key_node = node.args[0]
            if not (isinstance(key_node, ast.Constant) and isinstance(key_node.value, str)):
                continue
            try:
                values = ast.literal_eval(node.args[1])
            except Exception:
                continue
            if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                continue
            key = key_node.value
            if key in table and table[key][1] != values:
                # 同一键在多个批次脚本里被重写：后写的批次为准（脚本名排序靠后者优先），
                # 但必须显式提示，避免译文被静默替换
                previous, current = table[key], (name, values)
                winner = max([previous, current], key=lambda item: item[0])
                print(f'注意：{key[:40]} 同时定义于 {previous[0]} 与 {current[0]}，采用 {winner[0]}')
                table[key] = winner
                continue
            table[key] = (name, values)
    return table


def check_placeholders(key, values, source):
    expected = normalized_placeholders(key)
    for lang, value in zip(LANGS, values):
        got = normalized_placeholders(value)
        if got != expected:
            raise SystemExit(f'占位符不一致（{source}）：{key[:40]}\n  {lang}: {value}')
    return True


def main():
    table = static_translations()
    with open(CATALOG, encoding='utf-8') as f:
        catalog = json.load(f)
    strings = catalog['strings']

    filled, sources_used = [], []
    missing_zh_hans = []
    remaining = []
    for key, entry in strings.items():
        # 源语言条目：zh-Hans 即源文本身，缺了补上（历史脚本只写了 20 种目标语言）
        localizations = entry.setdefault('localizations', {})
        if 'zh-Hans' not in localizations:
            localizations['zh-Hans'] = {'stringUnit': {'state': 'translated', 'value': key}}
            missing_zh_hans.append(key)

        if len(localizations) > 1:
            continue
        source = table.get(key)
        if source is None:
            remaining.append(key)
            continue
        name, values = source
        if len(values) != len(LANGS):
            raise SystemExit(f'{name} 的 {key[:30]} 译文数量为 {len(values)}，应为 {len(LANGS)}')
        check_placeholders(key, values, name)
        for lang, value in zip(LANGS, values):
            localizations[lang] = {'stringUnit': {'state': 'translated', 'value': value}}
        entry.pop('extractionState', None)
        filled.append(key)
        sources_used.append(name)

    with open(CATALOG, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')

    print(f'补齐 zh-Hans 源语言条目 {len(missing_zh_hans)} 条')
    print(f'已补齐空条目 {len(filled)} 条（译文来自 {len(set(sources_used))} 个脚本）')
    print(f'仍缺译文 {len(remaining)} 条：')
    for key in remaining:
        print(f'  - {key}')


if __name__ == '__main__':
    main()
