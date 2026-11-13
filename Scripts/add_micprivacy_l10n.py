#!/usr/bin/env python3
# 麦克风设备选择：隐私政策新增两节 文案 20 种语言
# 与 add_microphone_l10n.py 同一合并策略（补全已被自动抽取的空条目）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('麦克风设备选择', [
    '麥克風裝置選擇',
    'Microphone Device Selection',
    'マイクデバイスの選択',
    '마이크 장치 선택',
    "Choix du périphérique d'entrée",
    'Auswahl des Mikrofons',
    'Selección del dispositivo de micrófono',
    'Scelta del dispositivo microfono',
    'Seleção do dispositivo de microfone',
    'Выбор устройства ввода',
    'اختيار جهاز الميكروفون',
    'माइक्रोफ़ोन डिवाइस चयन',
    'การเลือกอุปกรณ์ไมโครโฟน',
    'Chọn thiết bị micrô',
    'Pemilihan Perangkat Mikrofon',
    'Mikrofon Aygıtı Seçimi',
    'Keuze van microfoonapparaat',
    'Wybór urządzenia mikrofonowego',
    'Вибір пристрою мікрофона',
    'Val av mikrofonenhet',
])

add('录音使用的输入设备可自行指定（「设置 → 录音 → 输入设备」，或菜单栏「麦克风」）。可选范围与系统「声音 → 输入」一致，包含外接麦克风与虚拟/回环设备。该选择只保存在本机、只作用于本应用，不会修改系统默认输入设备。', [
    '錄音使用的輸入裝置可自行指定（「設定 → 錄音 → 輸入裝置」，或選單列「麥克風」）。可選範圍與系統「聲音 → 輸入」一致，包含外接麥克風與虛擬/回環裝置。該選擇只保存在本機、只作用於本應用程式，不會修改系統預設輸入裝置。',
    "You can choose which input device is used for recording (Settings → Recording → Input Device, or the menu bar’s Microphone). The available list matches the system’s Sound → Input list, including external microphones and virtual/loopback devices. The choice is stored only on this Mac and applies only to this app; it never changes the system default input device.",
    '録音に使う入力デバイスは指定できます（「設定 → 録音 → 入力デバイス」またはメニューバーの「マイク」）。選択肢はシステムの「サウンド → 入力」と同じで、外付けマイクや仮想/ループバックデバイスも含みます。この選択は本機にのみ保存され、本アプリにのみ適用され、システムのデフォルト入力デバイスは変更しません。',
    '녹음에 사용할 입력 장치를 지정할 수 있습니다(‘설정 → 녹음 → 입력 장치’ 또는 메뉴 막대 ‘마이크’). 선택 목록은 시스템 ‘사운드 → 입력’과 같으며 외장 마이크와 가상/루프백 장치를 포함합니다. 이 선택은 이 Mac에만 저장되고 이 앱에만 적용되며 시스템 기본 입력 장치는 변경하지 않습니다.',
    "Vous pouvez choisir le périphérique d'entrée utilisé pour l'enregistrement (Réglages → Enregistrement → Périphérique d'entrée, ou barre des menus « Microphone »). La liste proposée correspond à celle de « Son → Entrée » du système, micros externes et périphériques virtuels/loopback inclus. Ce choix est stocké uniquement sur ce Mac, ne s'applique qu'à cette app et ne modifie jamais le périphérique d'entrée par défaut du système.",
    'Das für die Aufnahme verwendete Eingabegerät lässt sich wählen (Einstellungen → Aufnahme → Eingabegerät oder Menüleiste „Mikrofon“). Die Liste entspricht „Ton → Eingabe“ des Systems und umfasst externe Mikrofone sowie virtuelle/Loopback-Geräte. Die Auswahl wird nur auf diesem Mac gespeichert, gilt nur für diese App und ändert den Systemstandard nicht.',
    'Puedes elegir el dispositivo de entrada usado para grabar (Ajustes → Grabación → Dispositivo de entrada, o barra de menús «Micrófono»). La lista coincide con «Sonido → Entrada» del sistema e incluye micrófonos externos y dispositivos virtuales/loopback. La elección se guarda solo en este equipo, se aplica solo a esta app y nunca cambia el dispositivo de entrada predeterminado del sistema.',
    'Puoi scegliere il dispositivo di input usato per la registrazione (Impostazioni → Registrazione → Dispositivo di input, oppure barra dei menu «Microfono»). L’elenco coincide con «Suono → Ingresso» del sistema e include microfoni esterni e dispositivi virtuali/loopback. La scelta è salvata solo su questo Mac, vale solo per questa app e non modifica mai il dispositivo di input predefinito del sistema.',
    'Pode escolher o dispositivo de entrada usado na gravação (Definições → Gravação → Dispositivo de entrada, ou barra de menus «Microfone»). A lista corresponde a «Som → Entrada» do sistema e inclui microfones externos e dispositivos virtuais/loopback. A escolha é guardada apenas neste Mac, aplica-se apenas a esta app e nunca altera o dispositivo de entrada padrão do sistema.',
    'Можно выбрать устройство ввода для записи («Настройки → Запись → Устройство ввода» или «Микрофон» в строке меню). Список совпадает с системным «Звук → Вход» и включает внешние микрофоны и виртуальные/loopback-устройства. Выбор хранится только на этом Mac, действует лишь в этом приложении и не меняет системное устройство ввода по умолчанию.',
    'يمكنك تحديد جهاز الإدخال المستخدم للتسجيل («الإعدادات → التسجيل → جهاز الإدخال» أو «الميكروفون» في شريط القوائم). تتطابق القائمة مع «الصوت → الإدخال» في النظام وتشمل الميكروفونات الخارجية والأجهزة الافتراضية/المرتجعة. يُحفظ الاختيار على هذا الجهاز فقط ويُطبَّق على هذا التطبيق فقط ولا يغيّر جهاز الإدخال الافتراضي للنظام.',
    'रिकॉर्डिंग के लिए इस्तेमाल होने वाला इनपुट डिवाइस चुना जा सकता है («सेटिंग्स → रिकॉर्डिंग → इनपुट डिवाइस», या मेन्यू बार का «माइक्रोफ़ोन»)। सूची सिस्टम के «साउंड → इनपुट» जैसी है और इसमें बाहरी माइक तथा वर्चुअल/लूपबैक डिवाइस शामिल हैं। यह चयन केवल इस Mac पर सहेजा जाता है, केवल इस ऐप पर लागू होता है और सिस्टम का डिफ़ॉल्ट इनपुट डिवाइस नहीं बदलता।',
    'เลือกอุปกรณ์อินพุตที่ใช้บันทึกได้ («การตั้งค่า → การบันทึก → อุปกรณ์อินพุต» หรือ «ไมโครโฟน» ในแถบเมนู) รายการจะตรงกับ «เสียง → อินพุต» ของระบบ รวมไมค์ภายนอกและอุปกรณ์เสมือน/ลูปแบ็ก ตัวเลือกนี้เก็บไว้ในเครื่องนี้เท่านั้น มีผลกับแอปนี้เท่านั้น และไม่เปลี่ยนอุปกรณ์อินพุตเริ่มต้นของระบบ',
    'Bạn có thể chọn thiết bị đầu vào dùng để ghi âm («Cài đặt → Ghi âm → Thiết bị đầu vào», hoặc «Micrô» trên thanh menu). Danh sách tương ứng với «Âm thanh → Đầu vào» của hệ thống, gồm micrô ngoài và thiết bị ảo/loopback. Lựa chọn chỉ lưu trên máy này, chỉ áp dụng cho ứng dụng này và không thay đổi thiết bị đầu vào mặc định của hệ thống.',
    'Anda dapat memilih perangkat input untuk perekaman («Pengaturan → Perekaman → Perangkat Input», atau «Mikrofon» di bilah menu). Daftarnya sama dengan «Suara → Input» sistem, termasuk mikrofon eksternal dan perangkat virtual/loopback. Pilihan hanya disimpan di Mac ini, hanya berlaku untuk aplikasi ini, dan tidak mengubah perangkat input default sistem.',
    'Kayıt için kullanılacak giriş aygıtını seçebilirsiniz («Ayarlar → Kayıt → Giriş Aygıtı» veya menü çubuğunda «Mikrofon»). Liste sistemin «Ses → Giriş» listesiyle aynıdır; harici mikrofonlar ve sanal/loopback aygıtlar dahildir. Seçim yalnızca bu Mac’te saklanır, yalnızca bu uygulama için geçerlidir ve sistem varsayılan giriş aygıtını değiştirmez.',
    'Je kunt kiezen welk invoerapparaat voor opnemen wordt gebruikt («Instellingen → Opnemen → Invoerapparaat», of «Microfoon» in de menubalk). De lijst komt overeen met «Geluid → Invoer» van het systeem, inclusief externe microfoons en virtuele/loopback-apparaten. De keuze wordt alleen op deze Mac opgeslagen, geldt alleen voor deze app en wijzigt nooit het systeemstandaard invoerapparaat.',
    'Możesz wybrać urządzenie wejściowe używane do nagrywania („Ustawienia → Nagrywanie → Urządzenie wejściowe” lub „Mikrofon” w pasku menu). Lista odpowiada systemowej „Dźwięk → Wejście” i obejmuje mikrofony zewnętrzne oraz urządzenia wirtualne/loopback. Wybór jest zapisywany tylko na tym Macu, dotyczy tylko tej aplikacji i nigdy nie zmienia domyślnego urządzenia wejściowego systemu.',
    'Можна вибрати пристрій введення для запису («Налаштування → Запис → Пристрій введення» або «Мікрофон» у рядку меню). Список збігається із системним «Звук → Вхід» і містить зовнішні мікрофони та віртуальні/loopback-пристрої. Вибір зберігається лише на цьому Mac, діє тільки в цьому застосунку й не змінює системний пристрій введення за замовчуванням.',
    'Du kan välja vilken indataenhet som används för inspelning («Inställningar → Inspelning → Indataenhet», eller «Mikrofon» i menyraden). Listan motsvarar systemets «Ljud → In» och omfattar externa mikrofoner och virtuella/loopback-enheter. Valet sparas bara på den här Macen, gäller bara den här appen och ändrar aldrig systemets standardenhet.',
])

add('录屏与视频数据', [
    '螢幕錄製與影片資料',
    'Screen Recording and Video Data',
    '画面収録と動画データ',
    '화면 녹화 및 동영상 데이터',
    "Enregistrement d'écran et données vidéo",
    'Bildschirmaufnahme und Videodaten',
    'Grabación de pantalla y datos de vídeo',
    'Registrazione schermo e dati video',
    'Gravação de ecrã e dados de vídeo',
    'Запись экрана и видеоданные',
    'تسجيل الشاشة وبيانات الفيديو',
    'स्क्रीन रिकॉर्डिंग और वीडियो डेटा',
    'การบันทึกหน้าจอและข้อมูลวิดีโอ',
    'Ghi màn hình và dữ liệu video',
    'Perekaman Layar dan Data Video',
    'Ekran Kaydı ve Video Verileri',
    'Schermopname en videogegevens',
    'Nagrywanie ekranu i dane wideo',
    'Запис екрана та відеодані',
    'Skärminspelning och videodata',
])

add('录屏产生的视频文件与导入的原始视频都只保存在本机数据文件夹中，不会上传到我们的服务器。打开视频条目可在「画面」页随时「清理视频」删除原始视频，关键帧与画面要点保留。', [
    '螢幕錄製產生的影片檔案與匯入的原始影片都只保存在本機資料資料夾中，不會上傳到我們的伺服器。開啟影片項目可在「畫面」頁隨時「清理影片」刪除原始影片，關鍵影格與畫面要點保留。',
    'Video files produced by screen recording, and the original videos you import, are stored only in the local data folder and are never uploaded to our servers. Open a video item and use “Clean up video” on the Picture tab to delete the original video at any time; keyframes and visual notes are kept.',
    '画面収録で作成された動画ファイルと取り込んだ元の動画は、本機のデータフォルダにのみ保存され、当社のサーバーには送信されません。動画項目を開き「画面」タブの「動画を整理」で元の動画をいつでも削除できます（キーフレームと画面メモは保持されます）。',
    '화면 녹화로 만들어진 동영상 파일과 가져온 원본 동영상은 이 Mac의 데이터 폴더에만 저장되며 당사 서버로 업로드되지 않습니다. 동영상 항목을 열고 ‘화면’ 탭에서 ‘동영상 정리’를 눌러 언제든 원본 동영상을 삭제할 수 있습니다(키프레임과 화면 요약은 유지).',
    "Les fichiers vidéo issus de l'enregistrement d'écran et les vidéos d'origine que vous importez sont stockés uniquement dans le dossier de données local et ne sont jamais envoyés à nos serveurs. Ouvrez un élément vidéo et utilisez « Nettoyer la vidéo » dans l'onglet Image pour supprimer la vidéo d'origine à tout moment ; les images clés et le résumé visuel sont conservés.",
    'Von der Bildschirmaufnahme erzeugte Videodateien und importierte Originalvideos werden nur im lokalen Datenordner gespeichert und nie auf unsere Server hochgeladen. In einem Videoeintrag können Sie im Tab „Bild“ jederzeit „Video aufräumen“ wählen, um das Originalvideo zu löschen; Keyframes und visuelle Notizen bleiben erhalten.',
    'Los archivos de vídeo generados por la grabación de pantalla y los vídeos originales que importas se guardan solo en la carpeta de datos local y nunca se suben a nuestros servidores. Abre un elemento de vídeo y usa «Limpiar vídeo» en la pestaña «Imagen» para borrar el vídeo original cuando quieras; los fotogramas clave y las notas visuales se conservan.',
    'I file video creati dalla registrazione schermo e i video originali che importi sono salvati solo nella cartella dati locale e non vengono mai caricati sui nostri server. Apri un elemento video e usa «Pulisci video» nella scheda «Immagine» per eliminare il video originale quando vuoi; fotogrammi chiave e note visive vengono conservati.',
    'Os ficheiros de vídeo criados pela gravação de ecrã e os vídeos originais que importa são guardados apenas na pasta de dados local e nunca são enviados para os nossos servidores. Abra um item de vídeo e use «Limpar vídeo» no separador «Imagem» para eliminar o vídeo original quando quiser; os fotogramas-chave e as notas visuais são mantidos.',
    'Видеофайлы, созданные при записи экрана, и импортированные оригинальные видео хранятся только в локальной папке данных и никогда не загружаются на наши серверы. Откройте видеоэлемент и в разделе «Изображение» выберите «Очистить видео», чтобы в любой момент удалить оригинал; ключевые кадры и визуальные заметки сохраняются.',
    'تُحفظ ملفات الفيديو الناتجة عن تسجيل الشاشة ومقاطع الفيديو الأصلية التي تستوردها في مجلد البيانات المحلي فقط، ولا تُرفع إلى خوادمنا. افتح عنصر الفيديو واستخدم «تنظيف الفيديو» في تبويب «الصورة» لحذف الفيديو الأصلي في أي وقت، مع الاحتفاظ بالإطارات الرئيسية والملاحظات المرئية.',
    'स्क्रीन रिकॉर्डिंग से बनी वीडियो फ़ाइलें और आपके आयातित मूल वीडियो केवल स्थानीय डेटा फ़ोल्डर में रखे जाते हैं और हमारे सर्वर पर कभी अपलोड नहीं होते। वीडियो आइटम खोलकर «चित्र» टैब में «वीडियो साफ़ करें» से मूल वीडियो कभी भी हटा सकते हैं; कीफ़्रेम और दृश्य नोट्स सुरक्षित रहते हैं।',
    'ไฟล์วิดีโอที่เกิดจากการบันทึกหน้าจอและวิดีโอต้นฉบับที่นำเข้า จะถูกเก็บไว้ในโฟลเดอร์ข้อมูลในเครื่องนี้เท่านั้น และไม่ถูกอัปโหลดไปยังเซิร์ฟเวอร์ของเรา เปิดรายการวิดีโอแล้วใช้ «ล้างวิดีโอ» ในแท็บ «ภาพ» เพื่อลบวิดีโอต้นฉบับได้ทุกเมื่อ โดยคีย์เฟรมและบันทึกภาพยังคงอยู่',
    'Tệp video tạo bởi tính năng ghi màn hình và video gốc bạn nhập chỉ được lưu trong thư mục dữ liệu trên máy này, không bao giờ tải lên máy chủ của chúng tôi. Mở mục video và dùng «Dọn video» trong tab «Hình ảnh» để xóa video gốc bất cứ lúc nào; khung hình chính và ghi chú hình ảnh vẫn được giữ.',
    'File video hasil perekaman layar dan video asli yang Anda impor hanya disimpan di folder data lokal dan tidak pernah diunggah ke server kami. Buka item video dan gunakan «Bersihkan video» di tab «Gambar» untuk menghapus video asli kapan saja; keyframe dan catatan visual tetap disimpan.',
    'Ekran kaydıyla oluşturulan video dosyaları ve içe aktardığınız orijinal videolar yalnızca yerel veri klasöründe saklanır ve sunucularımıza hiçbir zaman yüklenmez. Bir video öğesini açıp «Görüntü» sekmesinde «Videoyu temizle» ile orijinal videoyu istediğiniz zaman silebilirsiniz; kare ve görsel notlar korunur.',
    'Videobestanden van schermopname en de originele video’s die je importeert worden alleen in de lokale gegevensmap opgeslagen en nooit naar onze servers geüpload. Open een video-item en gebruik «Video opruimen» op het tabblad «Beeld» om de originele video op elk moment te verwijderen; keyframes en visuele notities blijven bewaard.',
    'Pliki wideo powstałe przy nagrywaniu ekranu oraz importowane oryginalne filmy są przechowywane wyłącznie w lokalnym folderze danych i nigdy nie są wysyłane na nasze serwery. Otwórz element wideo i użyj „Wyczyść wideo” na karcie „Obraz”, aby w każdej chwili usunąć oryginalny film; klatki kluczowe i notatki wizualne pozostają.',
    'Відеофайли, створені записом екрана, та імпортовані оригінальні відео зберігаються лише в локальній папці даних і ніколи не завантажуються на наші сервери. Відкрийте відеоелемент і скористайтеся «Очистити відео» на вкладці «Зображення», щоб будь-коли видалити оригінал; ключові кадри та візуальні нотатки зберігаються.',
    'Videofiler från skärminspelning och de originalvideor du importerar sparas bara i den lokala datamappen och laddas aldrig upp till våra servrar. Öppna ett videoobjekt och använd «Rensa video» på fliken «Bild» för att ta bort originalvideon när som helst; nyckelbildrutor och visuella anteckningar behålls.',
])


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
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')
    print(f'完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
