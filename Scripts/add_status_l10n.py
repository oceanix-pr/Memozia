#!/usr/bin/env python3
# 列表页状态标签（未转写/已转写/未总结/已总结，20 种语言）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('未转写', [
    '未轉寫',
    'Not Transcribed',
    '未文字起こし',
    '전사 안 됨',
    'Non transcrit',
    'Nicht transkribiert',
    'Sin transcribir',
    'Non trascritto',
    'Não transcrito',
    'Не расшифровано',
    'لم يُفرَّغ',
    'ट्रांसक्रिप्ट नहीं हुआ',
    'ยังไม่ถอดความ',
    'Chưa chuyển ngữ',
    'Belum ditranskripsi',
    'Transkript edilmedi',
    'Niet getranscribeerd',
    'Nieprzetranskrybowane',
    'Не транскрибовано',
    'Ej transkriberat',
])

add('已转写', [
    '已轉寫',
    'Transcribed',
    '文字起こし済み',
    '전사 완료',
    'Transcrit',
    'Transkribiert',
    'Transcrito',
    'Trascritto',
    'Transcrito',
    'Расшифровано',
    'تم التفريغ',
    'ट्रांसक्रिप्ट हो गया',
    'ถอดความแล้ว',
    'Đã chuyển ngữ',
    'Ditranskripsi',
    'Transkript edildi',
    'Getranscribeerd',
    'Przetranskrybowane',
    'Транскрибовано',
    'Transkriberat',
])

add('未总结', [
    '未總結',
    'Not Summarized',
    '未要約',
    '요약 안 됨',
    'Non résumé',
    'Nicht zusammengefasst',
    'Sin resumir',
    'Non riassunto',
    'Não resumido',
    'Не резюмировано',
    'لم يُلخَّص',
    'सारांश नहीं बना',
    'ยังไม่สรุป',
    'Chưa tóm tắt',
    'Belum diringkas',
    'Özetlenmedi',
    'Niet samengevat',
    'Niepodsumowane',
    'Не підсумовано',
    'Ej sammanfattat',
])

add('已总结', [
    '已總結',
    'Summarized',
    '要約済み',
    '요약 완료',
    'Résumé',
    'Zusammengefasst',
    'Resumido',
    'Riassunto',
    'Resumido',
    'Резюмировано',
    'تم التلخيص',
    'सारांश तैयार',
    'สรุปแล้ว',
    'Đã tóm tắt',
    'Telah diringkas',
    'Özetlendi',
    'Samengevat',
    'Podsumowane',
    'Підсумовано',
    'Sammanfattat',
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
