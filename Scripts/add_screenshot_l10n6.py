#!/usr/bin/env python3
# 截图文字属性（字号/格式）+ 全屏状态标签（20 种语言）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('字号', ['字號', 'Font Size', 'フォントサイズ', '글자 크기', 'Taille de police', 'Schriftgröße', 'Tamaño de fuente', 'Dimensione font', 'Tamanho da fonte', 'Размер шрифта', 'حجم الخط', 'फ़ॉन्ट आकार', 'ขนาดตัวอักษร', 'Cỡ chữ', 'Ukuran font', 'Yazı boyutu', 'Lettergrootte', 'Rozmiar czcionki', 'Розмір шрифту', 'Textstorlek'])
add('格式', ['格式', 'Style', 'スタイル', '스타일', 'Style', 'Stil', 'Estilo', 'Stile', 'Estilo', 'Стиль', 'النمط', 'शैली', 'รูปแบบ', 'Kiểu', 'Gaya', 'Biçim', 'Stijl', 'Styl', 'Стиль', 'Stil'])
add('常规', ['常規', 'Regular', '標準', '보통', 'Normal', 'Standard', 'Normal', 'Normale', 'Normal', 'Обычный', 'عادي', 'सामान्य', 'ปกติ', 'Thường', 'Normal', 'Normal', 'Standaard', 'Zwykły', 'Звичайний', 'Normal'])
add('粗体', ['粗體', 'Bold', 'ボールド', '굵게', 'Gras', 'Fett', 'Negrita', 'Grassetto', 'Negrito', 'Полужирный', 'غامق', 'बोल्ड', 'ตัวหนา', 'Đậm', 'Tebal', 'Kalın', 'Vet', 'Pogrubienie', 'Жирний', 'Fet'])
add('斜体', ['斜體', 'Italic', 'イタリック', '기울임', 'Italique', 'Kursiv', 'Cursiva', 'Corsivo', 'Itálico', 'Курсив', 'مائل', 'इटैलिक', 'ตัวเอียง', 'Nghiêng', 'Miring', 'İtalik', 'Cursief', 'Kursywa', 'Курсив', 'Kursiv'])
add('回车保存 · Esc 取消', ['按下 Enter 儲存 · Esc 取消', 'Press Enter to save · Esc to cancel', 'Enter で保存 · Esc でキャンセル', 'Enter 키 저장 · Esc 취소', 'Entrée pour enregistrer · Échap pour annuler', 'Enter zum Speichern · Esc zum Abbrechen', 'Enter para guardar · Esc para cancelar', 'Invio per salvare · Esc per annullare', 'Enter para guardar · Esc para cancelar', 'Enter — сохранить · Esc — отмена', 'اضغط Enter للحفظ · Esc للإلغاء', 'सहेजने के लिए Enter · रद्द करने के लिए Esc', 'กด Enter เพื่อบันทึก · Esc เพื่อยกเลิก', 'Nhấn Enter để lưu · Esc để hủy', 'Tekan Enter untuk menyimpan · Esc untuk membatalkan', 'Kaydetmek için Enter · İptal için Esc', 'Enter om op te slaan · Esc om te annuleren', 'Enter, aby zapisać · Esc, aby anulować', 'Enter, щоб зберегти · Esc, щоб скасувати', 'Enter för att spara · Esc för att avbryta'])


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    added = 0
    for key, vals in T.items():
        if key in existing:
            print(f'跳过（已存在）：{key}')
            continue
        entry = {'localizations': {}}
        for lang, val in zip(LANGS, vals):
            entry['localizations'][lang] = {'stringUnit': {'state': 'translated', 'value': val}}
        existing[key] = entry
        added += 1

    with open(CATALOG, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')

    print(f'新增 {added} 个键，总计 {len(existing)} 个键')


if __name__ == '__main__':
    main()
