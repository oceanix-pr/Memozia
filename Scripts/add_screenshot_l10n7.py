#!/usr/bin/env python3
# 帮助页文字属性描述（20 种语言）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('框选后可标注：矩形、椭圆、箭头、画笔、文字、马赛克，支持撤销/重做；文字可设字号与粗体/斜体格式', [
    '框選後可標註：矩形、橢圓、箭頭、畫筆、文字、馬賽克，支援復原/重做；文字可設字號與粗體/斜體格式',
    'After selecting, annotate with rectangle, ellipse, arrow, pen, text, or mosaic; undo/redo supported; text supports font size and bold/italic styles',
    '選択後、矩形・楕円・矢印・ペン・テキスト・モザイクで注釈を付けられます。取り消し/やり直し対応。テキストはサイズと太字/斜体を設定可能',
    '선택 후 사각형, 타원, 화살표, 펜, 텍스트, 모자이크로 주석을 달 수 있으며 실행 취소/다시 실행 지원; 텍스트는 글자 크기와 굵게/기울임 설정 가능',
    'Après sélection, annotez avec rectangle, ellipse, flèche, stylo, texte ou mosaïque ; annuler/rétablir pris en charge ; le texte gère la taille et le gras/italique',
    'Nach der Auswahl können Sie mit Rechteck, Ellipse, Pfeil, Stift, Text oder Mosaik annotieren; Wiederholen/Widerrufen unterstützt; Text unterstützt Schriftgröße und Fett/Kursiv',
    'Tras seleccionar, anota con rectángulo, elipse, flecha, lápiz, texto o mosaico; se admite deshacer/rehacer; el texto admite tamaño y negrita/cursiva',
    'Dopo la selezione, annota con rettangolo, ellisse, freccia, penna, testo o mosaico; annulla/ripristino supportati; il testo supporta dimensione e grassetto/corsivo',
    'Após selecionar, anote com retângulo, elipse, seta, caneta, texto ou mosaico; desfazer/refazer suportado; o texto suporta tamanho e negrito/itálico',
    'После выделения добавляйте аннотации: прямоугольник, овал, стрелка, перо, текст, мозаика; поддерживаются отмена/повтор; для текста доступны размер и полужирный/курсив',
    'بعد التحديد، أضف تعليقات بمستطيل أو بيضاوي أو سهم أو قلم أو نص أو فسيفساء؛ مع دعم التراجع/الإعادة؛ يدعم النص الحجم والغامق/المائل',
    'चयन के बाद आयत, दीर्घवृत्त, तीर, पेन, टेक्स्ट या मोज़ेक से एनोटेट करें; अनडू/रीडू समर्थित; टेक्स्ट में आकार और बोल्ड/इटैलिक समर्थित',
    'หลังเลือกพื้นที่ ใส่คำอธิบายด้วยสี่เหลี่ยม วงรี ลูกศร ปากกา ข้อความ หรือโมเสก; รองรับเลิกทำ/ทำซ้ำ; ข้อความรองรับขนาดและตัวหนา/ตัวเอียง',
    'Sau khi chọn vùng, chú thích bằng hình chữ nhật, elip, mũi tên, bút, văn bản hoặc khảm; hỗ trợ hoàn tác/làm lại; văn bản hỗ trợ cỡ chữ và đậm/nghiêng',
    'Setelah memilih, beri anotasi dengan persegi, elips, panah, pena, teks, atau mozaik; mendukung undo/redo; teks mendukung ukuran dan tebal/miring',
    'Seçimden sonra dikdörtgen, elips, ok, kalem, metin veya mozaik ile açıklama ekleyin; geri al/yinele desteklenir; metin boyut ve kalın/italik destekler',
    'Selecteer daarna met rechthoek, ellips, pijl, pen, tekst of mozaïek; ongedaan maken/opnieuw ondersteund; tekst ondersteunt lettergrootte en vet/cursief',
    'Po zaznaczeniu dodawaj adnotacje: prostokąt, elipsa, strzałka, pióro, tekst, mozaika; obsługiwane cofanie/ponawianie; tekst obsługuje rozmiar i pogrubienie/kursywę',
    'Після виділення додавайте анотації: прямокутник, овал, стрілка, перо, текст, мозаїка; підтримуються скасування/повтор; для тексту доступні розмір і напівжирний/курсив',
    'Efter markering kan du annotera med rektangel, ellips, pil, penna, text eller mosaik; ångra/gör om stöds; text stöder storlek och fet/kursiv stil',
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
