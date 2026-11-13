#!/usr/bin/env python3
# 麦克风菜单路径迁移：菜单栏「捕获屏幕 → 麦克风」→「麦克风」
#
# 1) 改写 add_micprivacy_l10n.py 该键的 20 种语言文案：移除「捕获屏幕 → 」这一段路径前缀；
# 2) 用改写后的文案替换 Localizable.xcstrings 中的旧键（旧键由 Xcode 从源码抽取，无翻译）。
#
# 片段定位规则：取「右侧紧接麦克风词」的那个箭头，向左回扫到最近的开引号/引号类分隔符，
# 删除分隔符与箭头之间的整段。这样各语言的引号风格（「」/«»/„“/‘’）都能正确处理。
#
# 例外：英文（bar’s）与法文（l'écran）的撇号与引号同形，回扫会多吃掉一个撇号——
# 本次迁移后已用显式替换修正这两条（bar’s Microphone / « Microphone »），
# 本脚本的一次性迁移已完成，重复执行会因断言失败而中止。
import importlib.util
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
SOURCE_SCRIPT = 'Scripts/add_micprivacy_l10n.py'

OLD_KEY = ('录音使用的输入设备可自行指定（「设置 → 录音 → 输入设备」，或菜单栏「捕获屏幕 → 麦克风」）。'
           '可选范围与系统「声音 → 输入」一致，包含外接麦克风与虚拟/回环设备。'
           '该选择只保存在本机、只作用于本应用，不会修改系统默认输入设备。')
NEW_KEY = ('录音使用的输入设备可自行指定（「设置 → 录音 → 输入设备」，或菜单栏「麦克风」）。'
           '可选范围与系统「声音 → 输入」一致，包含外接麦克风与虚拟/回环设备。'
           '该选择只保存在本机、只作用于本应用，不会修改系统默认输入设备。')

# 各语言的「麦克风」词：用于定位需要删除的路径片段
MIC_WORD = {
    'zh-Hant': '麥克風', 'en': 'Microphone', 'ja': 'マイク', 'ko': '마이크',
    'fr': 'Microphone', 'de': 'Mikrofon', 'es': 'Micrófono', 'it': 'Microfono',
    'pt': 'Microfone', 'ru': 'Микрофон', 'ar': 'الميكروفون', 'hi': 'माइक्रोफ़ोन',
    'th': 'ไมโครโฟน', 'vi': 'Micrô', 'id': 'Mikrofon', 'tr': 'Mikrofon',
    'nl': 'Microfoon', 'pl': 'Mikrofon', 'uk': 'Мікрофон', 'sv': 'Mikrofon',
}

# 引号类分隔符：回扫到此即停止，删除分隔符之后的片段
DELIMITERS = '「『“‘„«"\'’`，,（('


def strip_menu_path(value, mic_word, lang):
    """把「<捕获屏幕短语> → <麦克风词>」压缩为「<麦克风词>」"""
    pattern = ' → ' + mic_word
    idx = value.rfind(pattern)
    assert idx > 0, f'{lang}: 未找到「 → {mic_word}」'
    start = idx
    while start > 0 and value[start - 1] not in DELIMITERS:
        start -= 1
    assert start < idx, f'{lang}: 未找到引号分隔符，回扫到字符串开头'
    return value[:start] + value[idx + len(' → '):]


def load_script_values():
    spec = importlib.util.spec_from_file_location('micprivacy', SOURCE_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.T[OLD_KEY], module.LANGS


def main():
    old_values, langs = load_script_values()
    assert len(old_values) == len(langs) == 20

    new_values = [strip_menu_path(v, MIC_WORD[lang], lang) for lang, v in zip(langs, old_values)]

    # 1) 同步改写维护脚本：键 + 20 条文案（脚本内每段文案都是唯一字符串，逐个替换）
    script = open(SOURCE_SCRIPT, encoding='utf-8').read()
    assert script.count(OLD_KEY) == 1, '脚本中旧键出现次数异常'
    script = script.replace(OLD_KEY, NEW_KEY, 1)
    for old, new in zip(old_values, new_values):
        assert script.count(old) == 1, f'脚本中文案出现次数异常: {old[:20]}'
        script = script.replace(old, new, 1)
    open(SOURCE_SCRIPT, 'w', encoding='utf-8').write(script)

    # 2) 目录：写入新键（含 21 种语言），移除旧键
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)
    strings = catalog['strings']

    strings.pop(OLD_KEY, None)
    entry = strings.setdefault(NEW_KEY, {})
    entry['localizations'] = {'zh-Hans': {'stringUnit': {'state': 'translated', 'value': NEW_KEY}}}
    for lang, value in zip(langs, new_values):
        entry['localizations'][lang] = {'stringUnit': {'state': 'translated', 'value': value}}
    entry.pop('extractionState', None)

    with open(CATALOG, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')

    print('旧键已移除，新键写入 21 种语言：')
    for lang, value in zip(langs, new_values):
        # 打印路径附近片段，便于人工核对
        i = value.find('菜单栏') if 'zh' in lang else -1
        if i >= 0:
            print(f'  {lang}: {value[max(0, i - 12):i + 30]}')
        else:
            j = value.find(' → ')
            print(f'  {lang}: {value[max(0, j - 30):j + 20]}')


if __name__ == '__main__':
    main()
