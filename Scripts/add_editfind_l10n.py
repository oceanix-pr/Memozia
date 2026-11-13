#!/usr/bin/env python3
# 编辑页查找/替换增强（20 种语言）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('替换', [
    '替換',
    'Replace',
    '置換',
    '바꾸기',
    'Remplacer',
    'Ersetzen',
    'Reemplazar',
    'Sostituisci',
    'Substituir',
    'Заменить',
    'استبدال',
    'बदलें',
    'แทนที่',
    'Thay thế',
    'Ganti',
    'Değiştir',
    'Vervang',
    'Zamień',
    'Замінити',
    'Ersätt',
])

add('上一个匹配', [
    '上一個匹配',
    'Previous Match',
    '前の一致',
    '이전 일치 항목',
    'Correspondance précédente',
    'Vorherige Übereinstimmung',
    'Coincidencia anterior',
    'Corrispondenza precedente',
    'Correspondência anterior',
    'Предыдущее совпадение',
    'التطابق السابق',
    'पिछला मिलान',
    'การจับคู่ก่อนหน้า',
    'Kết quả khớp trước',
    'Cocok sebelumnya',
    'Önceki eşleşme',
    'Vorige overeenkomst',
    'Poprzednie dopasowanie',
    'Попередній збіг',
    'Föregående matchning',
])

add('下一个匹配', [
    '下一個匹配',
    'Next Match',
    '次の一致',
    '다음 일치 항목',
    'Correspondance suivante',
    'Nächste Übereinstimmung',
    'Coincidencia siguiente',
    'Corrispondenza successiva',
    'Correspondência seguinte',
    'Следующее совпадение',
    'التطابق التالي',
    'अगला मिलान',
    'การจับคู่ถัดไป',
    'Kết quả khớp tiếp theo',
    'Cocok berikutnya',
    'Sonraki eşleşme',
    'Volgende overeenkomst',
    'Następne dopasowanie',
    'Наступний збіг',
    'Nästa matchning',
])

add('替换当前匹配项', [
    '替換當前匹配項',
    'Replace Current Match',
    '現在の一致を置換',
    '현재 일치 항목 바꾸기',
    'Remplacer la correspondance actuelle',
    'Aktuelle Übereinstimmung ersetzen',
    'Reemplazar la coincidencia actual',
    'Sostituisci la corrispondenza attuale',
    'Substituir a correspondência atual',
    'Заменить текущее совпадение',
    'استبدال التطابق الحالي',
    'वर्तमान मिलान बदलें',
    'แทนที่รายการที่ตรงกันปัจจุบัน',
    'Thay thế kết quả khớp hiện tại',
    'Ganti kecocokan saat ini',
    'Geçerli eşleşmeyi değiştir',
    'Huidige overeenkomst vervangen',
    'Zamień bieżące dopasowanie',
    'Замінити поточний збіг',
    'Ersätt aktuell matchning',
])


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    added = 0
    for key, vals in T.items():
        if key in existing:
            print(f'跳过（已存在）：{key}')
            continue
        entry = {'localizations': {
            # 源语言 zh-Hans 与既有条目格式保持一致（值 = Key 本身）
            'zh-Hans': {'stringUnit': {'state': 'translated', 'value': key}},
        }}
        for lang, val in zip(LANGS, vals):
            entry['localizations'][lang] = {'stringUnit': {'state': 'translated', 'value': val}}
        existing[key] = entry
        added += 1

    with open(CATALOG, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')
    print(f'完成：新增 {added} 条，共 {len(existing)} 条')


if __name__ == '__main__':
    main()
