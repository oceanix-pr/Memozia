#!/usr/bin/env python3
# 统一截图模式：选择阶段操作提示（20 种语言）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('拖拽框选区域，点击截取窗口，按空格全屏', [
    '拖曳框選區域，點擊擷取視窗，按空白鍵全螢幕',
    'Drag to select a region, click to capture a window, press Space for full screen',
    'ドラッグで範囲を選択、クリックでウィンドウを取得、Spaceキーで全画面',
    '드래그로 영역을 선택하고, 클릭으로 창을 캡처하고, 스페이스로 전체 화면',
    'Faites glisser pour sélectionner une zone, cliquez pour capturer une fenêtre, appuyez sur Espace pour tout l’écran',
    'Ziehen, um einen Bereich auszuwählen, klicken, um ein Fenster aufzunehmen, Leertaste für Vollbild',
    'Arrastra para seleccionar un área, haz clic para capturar una ventana, pulsa Espacio para pantalla completa',
    'Trascina per selezionare un’area, clicca per catturare una finestra, premi Spazio per schermo intero',
    'Arraste para selecionar uma área, clique para capturar uma janela, prima Espaço para ecrã inteiro',
    'Потяните, чтобы выбрать область, щёлкните, чтобы захватить окно, нажмите Пробел для всего экрана',
    'اسحب لتحديد منطقة، وانقر لالتقاط نافذة، واضغط على مسافة للشاشة الكاملة',
    'क्षेत्र चुनने के लिए खींचें, विंडो कैप्चर करने के लिए क्लिक करें, पूरी स्क्रीन के लिए स्पेस दबाएँ',
    'ลากเพื่อเลือกพื้นที่ คลิกเพื่อจับหน้าต่าง กด Space เพื่อทั้งหน้าจอ',
    'Kéo để chọn vùng, nhấp để chụp cửa sổ, nhấn Space cho toàn màn hình',
    'Seret untuk memilih area, klik untuk menangkap jendela, tekan Spasi untuk layar penuh',
    'Seçmek için sürükleyin, pencere yakalamak için tıklayın, tam ekran için boşluk tuşuna basın',
    'Sleep om een gebied te selecteren, klik om een venster vast te leggen, druk op Spatie voor het volledige scherm',
    'Przeciągnij, aby zaznaczyć obszar, kliknij, aby przechwycić okno, naciśnij Spację dla pełnego ekranu',
    'Потягніть, щоб вибрати область, клацніть, щоб захопити вікно, натисніть Пробіл для всього екрана',
    'Dra för att markera ett område, klicka för att fånga ett fönster, tryck på mellanslag för helskärm',
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
