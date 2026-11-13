#!/usr/bin/env python3
# 搜索导航与目录切换确认（20 种语言）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('下一个', [
    '下一個',
    'Next',
    '次へ',
    '다음',
    'Suivant',
    'Weiter',
    'Siguiente',
    'Avanti',
    'Próximo',
    'Далее',
    'التالي',
    'अगला',
    'ถัดไป',
    'Tiếp theo',
    'Berikutnya',
    'Sonraki',
    'Volgende',
    'Następny',
    'Наступний',
    'Nästa',
])

add('切换', [
    '切換',
    'Switch',
    '切り替え',
    '전환',
    'Basculer',
    'Wechseln',
    'Cambiar',
    'Passa a',
    'Alternar',
    'Переключить',
    'تبديل',
    'बदलें',
    'สลับ',
    'Chuyển',
    'Beralih',
    'Değiştir',
    'Schakelen',
    'Przełącz',
    'Перемкнути',
    'Växla',
])

add('切换数据文件夹', [
    '切換資料夾',
    'Switch Data Folder',
    'データフォルダを切り替え',
    '데이터 폴더 전환',
    'Changer de dossier de données',
    'Datenordner wechseln',
    'Cambiar carpeta de datos',
    'Cambia cartella dati',
    'Alterar pasta de dados',
    'Сменить папку данных',
    'تبديل مجلد البيانات',
    'डेटा फ़ोल्डर बदलें',
    'สลับโฟลเดอร์ข้อมูล',
    'Chuyển thư mục dữ liệu',
    'Ganti folder data',
    'Veri klasörünü değiştir',
    'Gegevensmap wijzigen',
    'Zmień folder danych',
    'Змінити папку даних',
    'Byt datamapp',
])

add('定位到下一个匹配的段落', [
    '定位到下一個匹配的段落',
    'Jump to the next matching segment',
    '次の一致するセグメントへ移動',
    '다음 일치 항목으로 이동',
    'Aller au segment correspondant suivant',
    'Zum nächsten übereinstimmenden Absatz springen',
    'Ir al siguiente segmento coincidente',
    'Vai al segmento corrispondente successivo',
    'Ir para o próximo segmento correspondente',
    'Перейти к следующему совпадающему фрагменту',
    'الانتقال إلى المقطع المطابق التالي',
    'अगले मिलान खंड पर जाएँ',
    'ไปยังส่วนที่ตรงกันถัดไป',
    'Chuyển đến phân đoạn khớp tiếp theo',
    'Lompat ke segmen yang cocok berikutnya',
    'Sonraki eşleşen bölüme git',
    'Ga naar het volgende overeenkomende segment',
    'Przejdź do następnego dopasowanego segmentu',
    'Перейти до наступного збігу',
    'Hoppa till nästa matchande segment',
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
