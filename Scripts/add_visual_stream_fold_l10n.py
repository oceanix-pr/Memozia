#!/usr/bin/env python3
# 画面分析进行中面板：折叠标题文案 21 种语言
# 与 add_micdocs_l10n.py 同一策略（键不存在则新增，存在则补全 21 种语言条目）
# 注意：三个位置占位符 %1$d / %2$d / %3$d 必须在每种语言里各出现一次（check_l10n.py 会校验）
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('画面读取过程（第 %1$d/%2$d 段，已收到 %3$d 字）', [
    '畫面讀取過程（第 %1$d/%2$d 段，已收到 %3$d 字）',
    'Visual reading progress (%1$d of %2$d segments, %3$d characters received)',
    '画面の読み取り状況（%2$d セグメント中 %1$d 番目、%3$d 文字を受信）',
    '화면 읽기 진행 상황(%2$d개 세그먼트 중 %1$d번째, %3$d자 수신)',
    'Lecture des images (%1$d sur %2$d segments, %3$d caractères reçus)',
    'Bildauswertung (%1$d von %2$d Segmenten, %3$d Zeichen empfangen)',
    'Lectura de imágenes (%1$d de %2$d segmentos, %3$d caracteres recibidos)',
    'Lettura delle immagini (%1$d di %2$d segmenti, %3$d caratteri ricevuti)',
    'Leitura das imagens (%1$d de %2$d segmentos, %3$d caracteres recebidos)',
    'Чтение изображений (%1$d из %2$d сегментов, получено символов: %3$d)',
    'قراءة الصور (%1$d من %2$d مقطعًا، تم استلام %3$d حرفًا)',
    'छवि पढ़ने की प्रक्रिया (%2$d में से %1$d सेगमेंट, %3$d अक्षर प्राप्त)',
    'กระบวนการอ่านภาพ (ส่วนที่ %1$d จาก %2$d, ได้รับ %3$d ตัวอักษร)',
    'Quá trình đọc hình ảnh (phân đoạn %1$d/%2$d, đã nhận %3$d ký tự)',
    'Proses pembacaan gambar (segmen %1$d dari %2$d, %3$d karakter diterima)',
    'Görüntü okuma süreci (%2$d segmentten %1$d., %3$d karakter alındı)',
    'Beeldlezen (%1$d van %2$d segmenten, %3$d tekens ontvangen)',
    'Odczyt obrazu (segment %1$d z %2$d, odebrano %3$d znaków)',
    'Читання зображень (%1$d з %2$d сегментів, отримано символів: %3$d)',
    'Bildläsning (%1$d av %2$d segment, %3$d tecken mottagna)',
])


def dump_catalog(catalog):
    """按 String Catalog 的既有排版写出：json.dumps 默认输出 `"key": value`，
    而 Xcode 写的是 `"key" : value`（冒号前留空格）。不做这一步会把整个文件
    重排成另一种风格，产生十万行级别的无意义 diff（内容完全一致）。
    末尾不补换行，与原文件保持一致。"""
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False)
    key_colon = re.compile(r'^( *)(("(?:[^"\\]|\\.)*")): ')
    return '\n'.join(key_colon.sub(r'\1\2 : ', line) for line in text.split('\n'))


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    added = filled = 0
    for key, vals in T.items():
        entry = existing.get(key)
        if entry is None:
            entry = {}
            existing[key] = entry
            added += 1
        else:
            filled += 1
        entry['localizations'] = {
            'zh-Hans': {'stringUnit': {'state': 'translated', 'value': key}},
        }
        for lang, val in zip(LANGS, vals):
            entry['localizations'][lang] = {'stringUnit': {'state': 'translated', 'value': val}}
        entry.pop('extractionState', None)

    with open(CATALOG, 'w', encoding='utf-8') as f:
        f.write(dump_catalog(catalog))
    print(f'完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()