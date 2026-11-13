#!/usr/bin/env python3
# 帮助页统一截图模式描述（20 种语言）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('截图现场自由选择模式：拖拽框选区域、悬停点击截取窗口、按空格截取全屏；多显示器环境自动覆盖所有屏幕', [
    '截圖現場自由選擇模式：拖曳框選區域、懸停點擊擷取視窗、按空白鍵擷取全螢幕；多顯示器環境自動覆蓋所有螢幕',
    'Choose the mode while capturing: drag to select a region, hover and click to capture a window, press Space for full screen; all displays are covered automatically in multi-monitor setups',
    'キャプチャー時にモードを選択：ドラッグで範囲を選択、ホバーしてクリックでウィンドウを取得、Spaceキーで全画面。マルチディスプレイ環境ではすべての画面を自動的にカバー',
    '캡처 중에 모드 선택: 드래그로 영역 선택, 가져다 대고 클릭으로 창 캡처, 스페이스로 전체 화면. 멀티 디스플레이 환경에서는 모든 화면을 자동으로 커버',
    'Choisissez le mode pendant la capture : glissez pour sélectionner une zone, survolez et cliquez pour capturer une fenêtre, appuyez sur Espace pour tout l’écran ; tous les écrans sont couverts automatiquement en multi-écrans',
    'Wählen Sie den Modus während der Aufnahme: Ziehen zum Auswählen eines Bereichs, mit der Maus darüberfahren und klicken zum Aufnehmen eines Fensters, Leertaste für Vollbild; bei mehreren Monitoren werden alle Bildschirme automatisch abgedeckt',
    'Elige el modo al capturar: arrastra para seleccionar un área, pasa el cursor y haz clic para capturar una ventana, pulsa Espacio para pantalla completa; en entornos multimonitor se cubren todas las pantallas automáticamente',
    'Scegli la modalità durante la cattura: trascina per selezionare un’area, passa il mouse e clicca per catturare una finestra, premi Spazio per lo schermo intero; con più monitor tutte le schermate sono coperte automaticamente',
    'Escolha o modo durante a captura: arraste para selecionar uma área, passe o cursor e clique para capturar uma janela, prima Espaço para ecrã inteiro; em ambientes multimonitor, todos os ecrãs são cobertos automaticamente',
    'Выбирайте режим прямо во время захвата: потяните, чтобы выбрать область, наведите и щёлкните, чтобы захватить окно, нажмите Пробел для всего экрана; при нескольких мониторах все экраны покрываются автоматически',
    'اختر الوضع أثناء الالتقاط: اسحب لتحديد منطقة، ومرّر وانقر لالتقاط نافذة، واضغط على مسافة للشاشة الكاملة؛ في بيئات الشاشات المتعددة تُغطى جميع الشاشات تلقائيًا',
    'कैप्चर के दौरान मोड चुनें: क्षेत्र चुनने के लिए खींचें, विंडो कैप्चर करने के लिए होवर करके क्लिक करें, पूरी स्क्रीन के लिए स्पेस दबाएँ; मल्टी-मॉनिटर वातावरण में सभी स्क्रीन अपने आप कवर हो जाती हैं',
    'เลือกโหมดขณะจับภาพ: ลากเพื่อเลือกพื้นที่, วางเมาส์แล้วคลิกเพื่อจับหน้าต่าง, กด Space เพื่อทั้งหน้าจอ; ในสภาพแวดล้อมหลายจอ จะครอบคลุมทุกหน้าจอโดยอัตโนมัติ',
    'Chọn chế độ trong lúc chụp: kéo để chọn vùng, di chuột và nhấp để chụp cửa sổ, nhấn Space cho toàn màn hình; trong môi trường đa màn hình, tất cả các màn hình được phủ tự động',
    'Pilih mode saat mengambil: seret untuk memilih area, arahkan dan klik untuk menangkap jendela, tekan Spasi untuk layar penuh; pada lingkungan multi-monitor semua layar tercakup otomatis',
    'Yakalama sırasında modu seçin: alan seçmek için sürükleyin, pencere yakalamak için imleci üzerine getirip tıklayın, tam ekran için boşluk tuşuna basın; çoklu monitör ortamlarında tüm ekranlar otomatik olarak kapsanır',
    'Kies de modus tijdens het vastleggen: sleep om een gebied te selecteren, beweeg en klik om een venster vast te leggen, druk op Spatie voor het volledige scherm; bij meerdere monitoren worden alle schermen automatisch afgedekt',
    'Wybierz tryb podczas przechwytywania: przeciągnij, aby zaznaczyć obszar, najedź i kliknij, aby przechwycić okno, naciśnij Spację dla pełnego ekranu; w środowiskach wielu monitorów wszystkie ekrany są obejmowane automatycznie',
    'Вибирайте режим під час захоплення: потягніть, щоб вибрати область, наведіть і клацніть, щоб захопити вікно, натисніть Пробіл для всього екрана; за кількох моніторів усі екрани покриваються автоматично',
    'Välj läge under fångsten: dra för att markera ett område, håll muspekaren över och klicka för att fånga ett fönster, tryck på mellanslag för helskärm; i miljöer med flera skärmar täcks alla skärmar automatiskt',
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
