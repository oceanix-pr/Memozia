#!/usr/bin/env python3
# 补齐批次 10：录屏、捕获会话、系统音频采集相关文案 20 种语言
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('工具栏「捕获」按钮、菜单栏「捕获屏幕」子菜单或全局热键均可启动；框选后可在工具栏选择保存截图或录制为视频', [
    '工具列「擷取」按鈕、選單列「擷取螢幕」子選單或全域熱鍵均可啟動；框選後可在工具列選擇儲存截圖或錄製為影片',
    'Start it from the toolbar “Capture” button, the menu bar “Capture Screen” submenu, or a global hotkey; after selecting a region, use the toolbar to save a screenshot or record it as a video',
    'ツールバーの「キャプチャ」ボタン、メニューバーの「画面キャプチャ」サブメニュー、またはグローバルホットキーから開始できます。範囲を選択したら、ツールバーでスクリーンショットを保存するか、動画として録画できます。',
    '도구 막대의 ‘캡처’ 버튼, 메뉴 막대의 ‘화면 캡처’ 하위 메뉴 또는 전역 단축키로 시작할 수 있습니다. 영역을 선택한 뒤 도구 막대에서 스크린샷을 저장하거나 동영상으로 녹화하세요.',
    "Lancez-le depuis le bouton « Capturer » de la barre d'outils, le sous-menu « Capturer l'écran » de la barre des menus ou un raccourci global ; après avoir sélectionné une zone, utilisez la barre d'outils pour enregistrer une capture ou la filmer",
    'Start über die Schaltfläche „Erfassen“ in der Werkzeugleiste, das Untermenü „Bildschirm erfassen“ in der Menüleiste oder ein globales Tastenkürzel; nach der Bereichsauswahl können Sie in der Werkzeugleiste einen Screenshot sichern oder als Video aufnehmen',
    'Inícialo con el botón «Capturar» de la barra de herramientas, el submenú «Capturar pantalla» de la barra de menús o un atajo global; tras seleccionar una región, usa la barra de herramientas para guardar una captura o grabarla como vídeo',
    'Avvialo dal pulsante «Acquisisci» della barra strumenti, dal sottomenu «Acquisisci schermo» della barra dei menu o con una scorciatoia globale; dopo aver selezionato un’area, usa la barra strumenti per salvare uno screenshot o registrarlo come video',
    'Inicie com o botão «Capturar» da barra de ferramentas, o submenu «Capturar ecrã» da barra de menus ou um atalho global; depois de selecionar uma região, use a barra de ferramentas para guardar uma captura ou gravá-la como vídeo',
    'Запускается кнопкой «Захват» на панели инструментов, подменю «Захват экрана» в строке меню или глобальным сочетанием клавиш; выбрав область, сохраните снимок или запишите видео через панель инструментов',
    'ابدأ من زر «التقاط» في شريط الأدوات، أو القائمة الفرعية «التقاط الشاشة» في شريط القوائم، أو مفتاح اختصار عام؛ وبعد تحديد منطقة استخدم شريط الأدوات لحفظ لقطة أو تسجيلها كفيديو',
    'टूलबार के «कैप्चर» बटन, मेन्यू बार के «स्क्रीन कैप्चर» उपमेन्यू या ग्लोबल हॉटकी से शुरू करें; क्षेत्र चुनने के बाद टूलबार से स्क्रीनशॉट सहेजें या वीडियो के रूप में रिकॉर्ड करें',
    'เริ่มได้จากปุ่ม «จับภาพ» ในแถบเครื่องมือ เมนูย่อย «จับภาพหน้าจอ» ในแถบเมนู หรือปุ่มลัดทั่วไป หลังจากเลือกพื้นที่แล้วใช้แถบเครื่องมือบันทึกภาพหรือบันทึกเป็นวิดีโอ',
    'Bắt đầu từ nút «Chụp» trên thanh công cụ, menu con «Chụp màn hình» trên thanh menu hoặc phím tắt toàn cục; sau khi chọn vùng, dùng thanh công cụ để lưu ảnh chụp hoặc ghi thành video',
    'Mulai dari tombol «Tangkap» di bilah alat, submenu «Tangkap Layar» di bilah menu, atau pintasan global; setelah memilih area, gunakan bilah alat untuk menyimpan tangkapan atau merekamnya sebagai video',
    'Araç çubuğundaki «Yakala» düğmesinden, menü çubuğundaki «Ekranı yakala» alt menüsünden veya genel kısayoldan başlatın; alanı seçtikten sonra araç çubuğundan ekran görüntüsü kaydedin ya da video olarak kaydedin',
    'Start via de knop «Vastleggen» in de werkbalk, het submenu «Scherm vastleggen» in de menubalk of een globale sneltoets; kies een gebied en gebruik daarna de werkbalk om een schermafbeelding op te slaan of als video op te nemen',
    'Uruchom przyciskiem „Przechwyć” na pasku narzędzi, podmenu „Przechwyć ekran” w pasku menu lub skrótem globalnym; po wybraniu obszaru zapisz zrzut lub nagraj go jako wideo',
    'Запускається кнопкою «Захоплення» на панелі інструментів, підменю «Захоплення екрана» в рядку меню або глобальною комбінацією клавіш; вибравши область, збережіть знімок або запишіть відео через панель інструментів',
    'Starta från knappen «Fånga» i verktygsfältet, undermenyn «Fånga skärm» i menyraden eller ett globalt kortkommando; markera ett område och använd sedan verktygsfältet för att spara en skärmbild eller spela in som video',
])

add('录全屏（鼠标所在屏）', [
    '錄全螢幕（滑鼠所在螢幕）',
    'Record full screen (screen with the pointer)',
    '全画面を録画（マウスがある画面）',
    '전체 화면 녹화(마우스가 있는 화면)',
    "Enregistrer tout l'écran (écran de la souris)",
    'Ganzes Display aufnehmen (Bildschirm mit dem Zeiger)',
    'Grabar pantalla completa (pantalla del ratón)',
    'Registra tutto lo schermo (schermo del mouse)',
    'Gravar ecrã inteiro (ecrã do rato)',
    'Запись всего экрана (экран с курсором)',
    'تسجيل الشاشة كاملة (الشاشة التي بها المؤشر)',
    'पूरी स्क्रीन रिकॉर्ड करें (माउस वाली स्क्रीन)',
    'บันทึกเต็มหน้าจอ (จอที่มีเมาส์)',
    'Ghi toàn màn hình (màn hình có con trỏ)',
    'Rekam seluruh layar (layar tempat kursor berada)',
    'Tam ekran kaydet (imlecin bulunduğu ekran)',
    'Volledig scherm opnemen (scherm met de cursor)',
    'Nagraj pełny ekran (ekran z kursorem)',
    'Запис усього екрана (екран зі вказівником)',
    'Spela in hela skärmen (skärmen med pekaren)',
])

add('录制当前选区为视频', [
    '錄製目前選區為影片',
    'Record the current selection as video',
    '現在の選択範囲を動画として録画',
    '현재 선택 영역을 동영상으로 녹화',
    "Enregistrer la sélection actuelle en vidéo",
    'Aktuelle Auswahl als Video aufnehmen',
    'Grabar la selección actual como vídeo',
    'Registra la selezione attuale come video',
    'Gravar a seleção atual como vídeo',
    'Записать текущую область как видео',
    'تسجيل المنطقة المحددة كفيديو',
    'चयनित क्षेत्र को वीडियो के रूप में रिकॉर्ड करें',
    'บันทึกพื้นที่ที่เลือกเป็นวิดีโอ',
    'Ghi vùng chọn hiện tại thành video',
    'Rekam pilihan saat ini sebagai video',
    'Geçerli seçimi video olarak kaydet',
    'Huidige selectie als video opnemen',
    'Nagraj bieżące zaznaczenie jako wideo',
    'Записати поточну область як відео',
    'Spela in aktuellt urval som video',
])

add('录制支持全屏/选区/窗口：选定目标后点工具栏「录制」，3 秒倒计时开录，与录音共用停止链路，产物为视频+音频同文件夹入库', [
    '錄製支援全螢幕/選區/視窗：選定目標後點工具列「錄製」，3 秒倒數開錄，與錄音共用停止鏈路，產物為影片+音訊同資料夾入庫',
    'Recording supports full screen / region / window: pick a target, click “Record” in the toolbar, and recording starts after a 3-second countdown; it shares the stop chain with audio recording, and the result is filed as video + audio in the same folder',
    '録画は全画面/範囲/ウインドウに対応：対象を選び、ツールバーの「録画」をクリックすると 3 秒のカウントダウン後に録画が始まります。録音と同じ停止処理を使い、動画＋音声として同じフォルダに保存されます。',
    '녹화는 전체 화면/영역/윈도우를 지원합니다. 대상을 선택한 뒤 도구 막대의 ‘녹화’를 누르면 3초 카운트다운 후 녹화가 시작되며, 녹음과 같은 중지 흐름을 사용하고 결과물은 동영상+오디오로 같은 폴더에 저장됩니다.',
    "L'enregistrement prend en charge tout l'écran / une zone / une fenêtre : choisissez une cible, cliquez sur « Enregistrer » dans la barre d'outils ; après un décompte de 3 secondes, l'enregistrement démarre. Il partage la chaîne d'arrêt avec l'enregistrement audio et le résultat est classé dans le même dossier (vidéo + audio).",
    'Die Aufnahme unterstützt Vollbild/Bereich/Fenster: Ziel wählen, in der Werkzeugleiste „Aufnehmen“ klicken, nach 3 Sekunden Countdown startet die Aufnahme; sie nutzt dieselbe Stopp-Kette wie die Audioaufnahme, das Ergebnis wird als Video + Audio im selben Ordner abgelegt.',
    'La grabación admite pantalla completa/región/ventana: elige un objetivo y pulsa «Grabar» en la barra de herramientas; tras 3 segundos de cuenta atrás comienza, comparte la cadena de detención con la grabación de audio y el resultado se guarda en la misma carpeta como vídeo + audio.',
    'La registrazione supporta tutto lo schermo/area/finestra: scegli un obiettivo e fai clic su «Registra» nella barra strumenti; dopo 3 secondi di conto alla rovescia inizia, condivide la catena di arresto con la registrazione audio e il risultato viene archiviato nella stessa cartella come video + audio.',
    'A gravação suporta ecrã inteiro/região/janela: escolha um alvo e clique em «Gravar» na barra de ferramentas; após uma contagem de 3 segundos começa, partilha a cadeia de paragem com a gravação de áudio e o resultado é guardado na mesma pasta como vídeo + áudio.',
    'Запись поддерживает весь экран/область/окно: выберите цель и нажмите «Запись» на панели инструментов; после 3-секундного отсчёта запись начнётся, остановка общая с аудиозаписью, а результат сохраняется в ту же папку как видео + аудио.',
    'يدعم التسجيل الشاشة كاملة/منطقة/نافذة: اختر الهدف ثم اضغط «تسجيل» في شريط الأدوات، وتبدأ بعد عدّ تنازلي 3 ثوانٍ، ويشارك مسار الإيقاف مع تسجيل الصوت، وتُحفظ النتيجة في المجلد نفسه كفيديو وصوت.',
    'रिकॉर्डिंग पूरी स्क्रीन/क्षेत्र/विंडो का समर्थन करती है: लक्ष्य चुनें और टूलबार में «रिकॉर्ड करें» दबाएँ; 3 सेकंड की उलटी गिनती के बाद रिकॉर्डिंग शुरू होती है, रोकने की प्रक्रिया ऑडियो रिकॉर्डिंग के साथ साझा है, और परिणाम उसी फ़ोल्डर में वीडियो + ऑडियो के रूप में सहेजा जाता है',
    'การบันทึกรองรับเต็มหน้าจอ/พื้นที่/หน้าต่าง: เลือกเป้าหมายแล้วกด «บันทึก» ในแถบเครื่องมือ หลังนับถอยหลัง 3 วินาทีจะเริ่มบันทึก ใช้เส้นทางหยุดร่วมกับการบันทึกเสียง และผลลัพธ์ถูกเก็บในโฟลเดอร์เดียวกันเป็นวิดีโอ+เสียง',
    'Ghi hỗ trợ toàn màn hình/vùng/cửa sổ: chọn mục tiêu rồi bấm «Ghi» trên thanh công cụ; sau 3 giây đếm ngược sẽ bắt đầu, dùng chung luồng dừng với ghi âm và kết quả được lưu vào cùng thư mục dưới dạng video + âm thanh',
    'Perekaman mendukung seluruh layar/area/jendela: pilih target lalu klik «Rekam» di bilah alat; setelah hitungan 3 detik dimulai, berbagi alur berhenti dengan perekaman audio, dan hasilnya disimpan di folder yang sama sebagai video + audio',
    'Kayıt tam ekran/alan/pencere destekler: hedefi seçip araç çubuğunda «Kaydet»e basın; 3 saniyelik geri sayımdan sonra başlar, ses kaydıyla aynı durdurma zincirini kullanır ve sonuç aynı klasöre video + ses olarak kaydedilir',
    'Opnemen ondersteunt volledig scherm/gebied/venster: kies een doel en klik op «Opnemen» in de werkbalk; na een aftelling van 3 seconden start de opname, met dezelfde stopketen als audio-opname, en het resultaat wordt in dezelfde map opgeslagen als video + audio',
    'Nagrywanie obsługuje pełny ekran/obszar/okno: wybierz cel i kliknij „Nagraj” na pasku narzędzi; po 3-sekundowym odliczaniu rozpoczyna się nagrywanie, zatrzymywanie jest wspólne z nagrywaniem dźwięku, a wynik trafia do tego samego folderu jako wideo + dźwięk',
    'Запис підтримує весь екран/область/вікно: виберіть ціль і натисніть «Запис» на панелі інструментів; після 3-секундного зворотного відліку запис почнеться, зупинка спільна з аудіозаписом, а результат зберігається в ту саму папку як відео + аудіо',
    'Inspelning stöder helskärm/område/fönster: välj ett mål och klicka på «Spela in» i verktygsfältet; efter en nedräkning på 3 sekunder startar inspelningen, den delar stoppkedja med ljudinspelningen och resultatet sparas i samma mapp som video + ljud',
])

add('录屏偏好', [
    '錄屏偏好',
    'Screen Recording Preferences',
    '画面収録の設定',
    '화면 기록 설정',
    "Préférences d'enregistrement d'écran",
    'Aufnahme-Einstellungen',
    'Preferencias de grabación de pantalla',
    'Preferenze di registrazione schermo',
    'Preferências de gravação de ecrã',
    'Параметры записи экрана',
    'إعدادات تسجيل الشاشة',
    'स्क्रीन रिकॉर्डिंग प्राथमिकताएँ',
    'การตั้งค่าการบันทึกหน้าจอ',
    'Tùy chọn ghi màn hình',
    'Preferensi perekaman layar',
    'Ekran kaydı tercihleri',
    'Voorkeuren voor schermopname',
    'Preferencje nagrywania ekranu',
    'Параметри запису екрана',
    'Inställningar för skärminspelning',
])

add('录窗口…', [
    '錄視窗…',
    'Record window…',
    'ウインドウを録画…',
    '윈도우 녹화…',
    'Enregistrer une fenêtre…',
    'Fenster aufnehmen…',
    'Grabar ventana…',
    'Registra finestra…',
    'Gravar janela…',
    'Запись окна…',
    'تسجيل نافذة…',
    'विंडो रिकॉर्ड करें…',
    'บันทึกหน้าต่าง…',
    'Ghi cửa sổ…',
    'Rekam jendela…',
    'Pencere kaydet…',
    'Venster opnemen…',
    'Nagraj okno…',
    'Запис вікна…',
    'Spela in fönster…',
])

add('录选区…', [
    '錄選區…',
    'Record region…',
    '範囲を録画…',
    '영역 녹화…',
    'Enregistrer une zone…',
    'Bereich aufnehmen…',
    'Grabar región…',
    'Registra area…',
    'Gravar região…',
    'Запись области…',
    'تسجيل منطقة…',
    'क्षेत्र रिकॉर्ड करें…',
    'บันทึกพื้นที่…',
    'Ghi vùng…',
    'Rekam area…',
    'Alan kaydet…',
    'Gebied opnemen…',
    'Nagraj obszar…',
    'Запис області…',
    'Spela in område…',
])

add('录音/录屏进行中，请先停止后再开始录屏', [
    '錄音/錄屏進行中，請先停止後再開始錄屏',
    'Audio or screen recording is in progress; stop it before starting a new screen recording',
    '録音/画面収録の実行中です。停止してから画面収録を開始してください',
    '녹음/화면 기록이 진행 중입니다. 먼저 중지한 뒤 화면 기록을 시작하세요',
    "Un enregistrement audio ou d'écran est en cours ; arrêtez-le avant de lancer un nouvel enregistrement d'écran",
    'Audio- oder Bildschirmaufnahme läuft; bitte zuerst stoppen, dann eine neue Bildschirmaufnahme starten',
    'Hay una grabación de audio o pantalla en curso; detenla antes de iniciar una nueva grabación de pantalla',
    "Una registrazione audio o schermo è in corso; interrompila prima di avviarne una nuova",
    'Está a decorrer uma gravação de áudio ou ecrã; pare-a antes de iniciar uma nova gravação de ecrã',
    'Идёт запись звука или экрана; остановите её, прежде чем начинать новую запись экрана',
    'هناك تسجيل صوتي أو تسجيل شاشة جارٍ؛ أوقفه قبل بدء تسجيل شاشة جديد',
    'ऑडियो या स्क्रीन रिकॉर्डिंग चल रही है; नई स्क्रीन रिकॉर्डिंग शुरू करने से पहले उसे रोकें',
    'กำลังบันทึกเสียงหรือหน้าจออยู่ โปรดหยุดก่อนเริ่มบันทึกหน้าจอใหม่',
    'Đang ghi âm hoặc ghi màn hình; hãy dừng trước khi bắt đầu ghi màn hình mới',
    'Perekaman audio atau layar sedang berjalan; hentikan dulu sebelum memulai perekaman layar baru',
    'Ses veya ekran kaydı sürüyor; yeni bir ekran kaydı başlatmadan önce durdurun',
    'Audio- of schermopname is bezig; stop eerst voordat je een nieuwe schermopname start',
    'Trwa nagrywanie dźwięku lub ekranu; zatrzymaj je przed rozpoczęciem nowego nagrywania ekranu',
    'Триває запис звуку або екрана; зупиніть його, перш ніж починати новий запис екрана',
    'Ljud- eller skärminspelning pågår; stoppa den innan du startar en ny skärminspelning',
])

add('捕获', [
    '擷取',
    'Capture',
    'キャプチャ',
    '캡처',
    'Capturer',
    'Erfassen',
    'Capturar',
    'Acquisisci',
    'Capturar',
    'Захват',
    'التقاط',
    'कैप्चर',
    'จับภาพ',
    'Chụp',
    'Tangkap',
    'Yakala',
    'Vastleggen',
    'Przechwyć',
    'Захоплення',
    'Fånga',
])

add('捕获会话进行中，请先完成或取消当前会话再开始录屏。', [
    '擷取工作階段進行中，請先完成或取消目前工作階段再開始錄屏。',
    'A capture session is in progress; finish or cancel it before starting screen recording.',
    'キャプチャセッションの実行中です。完了またはキャンセルしてから画面収録を開始してください。',
    '캡처 세션이 진행 중입니다. 완료하거나 취소한 뒤 화면 기록을 시작하세요.',
    "Une session de capture est en cours ; terminez-la ou annulez-la avant de lancer l'enregistrement d'écran.",
    'Eine Erfassungssitzung läuft; schließen oder verwerfen Sie sie, bevor Sie die Bildschirmaufnahme starten.',
    'Hay una sesión de captura en curso; termínala o cancélala antes de iniciar la grabación de pantalla.',
    "È in corso una sessione di acquisizione; completala o annullala prima di avviare la registrazione schermo.",
    'Está a decorrer uma sessão de captura; conclua-a ou cancele-a antes de iniciar a gravação de ecrã.',
    'Идёт сеанс захвата; завершите или отмените его, прежде чем начинать запись экрана.',
    'هناك جلسة التقاط جارية؛ أكملها أو ألغها قبل بدء تسجيل الشاشة.',
    'कैप्चर सत्र चल रहा है; स्क्रीन रिकॉर्डिंग शुरू करने से पहले उसे पूरा करें या रद्द करें।',
    'กำลังมีเซสชันจับภาพอยู่ โปรดทำให้เสร็จหรือยกเลิกก่อนเริ่มบันทึกหน้าจอ',
    'Đang có phiên chụp; hãy hoàn tất hoặc hủy phiên hiện tại trước khi bắt đầu ghi màn hình.',
    'Sesi tangkapan sedang berjalan; selesaikan atau batalkan dulu sebelum memulai perekaman layar.',
    'Bir yakalama oturumu sürüyor; ekran kaydını başlatmadan önce oturumu tamamlayın veya iptal edin.',
    'Er is een vastleggingssessie bezig; voltooi of annuleer deze voordat je schermopname start.',
    'Trwa sesja przechwytywania; zakończ ją lub anuluj przed rozpoczęciem nagrywania ekranu.',
    'Триває сеанс захоплення; завершіть або скасуйте його, перш ніж починати запис екрана.',
    'En fångstsession pågår; slutför eller avbryt den innan du startar skärminspelning.',
])

add('捕获屏幕', [
    '擷取螢幕',
    'Capture Screen',
    '画面キャプチャ',
    '화면 캡처',
    "Capturer l'écran",
    'Bildschirm erfassen',
    'Capturar pantalla',
    'Acquisisci schermo',
    'Capturar ecrã',
    'Захват экрана',
    'التقاط الشاشة',
    'स्क्रीन कैप्चर',
    'จับภาพหน้าจอ',
    'Chụp màn hình',
    'Tangkap Layar',
    'Ekranı yakala',
    'Scherm vastleggen',
    'Przechwyć ekran',
    'Захоплення екрана',
    'Fånga skärm',
])

add('捕获屏幕：拖拽选区域、单击选窗口、空格全屏；悬浮工具栏可保存截图或录制为视频（全局热键 ⌃⌘S）', [
    '擷取螢幕：拖曳選區域、單擊選視窗、空格全螢幕；懸浮工具列可儲存截圖或錄製為影片（全域熱鍵 ⌃⌘S）',
    'Capture Screen: drag to select a region, click to pick a window, press Space for full screen; the floating toolbar lets you save a screenshot or record it as a video (global hotkey ⌃⌘S)',
    '画面キャプチャ：ドラッグで範囲、クリックでウインドウ、スペースで全画面を選択。フローティングツールバーでスクリーンショットを保存したり動画として録画できます（グローバルホットキー ⌃⌘S）',
    '화면 캡처: 드래그로 영역, 클릭으로 윈도우, 스페이스로 전체 화면을 선택합니다. 떠 있는 도구 막대에서 스크린샷을 저장하거나 동영상으로 녹화할 수 있습니다(전역 단축키 ⌃⌘S).',
    "Capturer l'écran : glissez pour une zone, cliquez pour une fenêtre, Espace pour tout l'écran ; la barre d'outils flottante permet d'enregistrer une capture ou de la filmer (raccourci global ⌃⌘S)",
    'Bildschirm erfassen: Ziehen für einen Bereich, Klicken für ein Fenster, Leertaste für Vollbild; in der schwebenden Werkzeugleiste können Sie einen Screenshot sichern oder als Video aufnehmen (globales Tastenkürzel ⌃⌘S)',
    'Capturar pantalla: arrastra para una región, haz clic para una ventana, pulsa Espacio para pantalla completa; la barra de herramientas flotante permite guardar una captura o grabarla como vídeo (atajo global ⌃⌘S)',
    "Acquisisci schermo: trascina per un'area, fai clic per una finestra, premi Spazio per tutto lo schermo; la barra strumenti flottante consente di salvare uno screenshot o registrarlo come video (scorciatoia globale ⌃⌘S)",
    'Capturar ecrã: arraste para uma região, clique para uma janela, prima Espaço para o ecrã inteiro; a barra de ferramentas flutuante permite guardar uma captura ou gravá-la como vídeo (atalho global ⌃⌘S)',
    'Захват экрана: перетащите для выбора области, щёлкните для окна, пробел — весь экран; на плавающей панели можно сохранить снимок или записать видео (глобальное сочетание ⌃⌘S)',
    'التقاط الشاشة: اسحب لتحديد منطقة، وانقر لاختيار نافذة، ومسافة للشاشة كاملة؛ ويتيح شريط الأدوات العائم حفظ لقطة أو تسجيلها كفيديو (مفتاح اختصار عام ⌃⌘S)',
    'स्क्रीन कैप्चर: खींचकर क्षेत्र चुनें, क्लिक से विंडो चुनें, स्पेस से पूरी स्क्रीन; फ़्लोटिंग टूलबार से स्क्रीनशॉट सहेजें या वीडियो के रूप में रिकॉर्ड करें (ग्लोबल हॉटकी ⌃⌘S)',
    'จับภาพหน้าจอ: ลากเพื่อเลือกพื้นที่ คลิกเพื่อเลือกหน้าต่าง กด Space เพื่อเต็มหน้าจอ แถบเครื่องมือลอยช่วยบันทึกภาพหรือบันทึกเป็นวิดีโอ (ปุ่มลัดทั่วไป ⌃⌘S)',
    'Chụp màn hình: kéo để chọn vùng, nhấp để chọn cửa sổ, nhấn Space để toàn màn hình; thanh công cụ nổi cho phép lưu ảnh chụp hoặc ghi thành video (phím tắt toàn cục ⌃⌘S)',
    'Tangkap Layar: seret untuk memilih area, klik untuk memilih jendela, tekan Spasi untuk seluruh layar; bilah alat mengambang memungkinkan menyimpan tangkapan atau merekamnya sebagai video (pintasan global ⌃⌘S)',
    'Ekranı yakala: alan seçmek için sürükleyin, pencere için tıklayın, tam ekran için Boşluk tuşuna basın; yüzen araç çubuğundan ekran görüntüsü kaydedebilir veya video olarak kaydedebilirsiniz (genel kısayol ⌃⌘S)',
    'Scherm vastleggen: sleep voor een gebied, klik voor een venster, druk op de spatiebalk voor volledig scherm; met de zwevende werkbalk sla je een schermafbeelding op of neem je op als video (globale sneltoets ⌃⌘S)',
    'Przechwyć ekran: przeciągnij, aby wybrać obszar, kliknij, aby wybrać okno, naciśnij Spację, aby uchwycić pełny ekran; pływający pasek narzędzi pozwala zapisać zrzut lub nagrać go jako wideo (skrót globalny ⌃⌘S)',
    'Захоплення екрана: перетягніть, щоб вибрати область, клацніть для вікна, пробіл — увесь екран; на плаваючій панелі можна зберегти знімок або записати відео (глобальна комбінація ⌃⌘S)',
    'Fånga skärm: dra för att välja ett område, klicka för ett fönster, tryck på mellanslag för helskärm; med det flytande verktygsfältet kan du spara en skärmbild eller spela in den som video (globalt kortkommando ⌃⌘S)',
])

add('正在录音/录屏，请先停止后再开始新的录屏。', [
    '正在錄音/錄屏，請先停止後再開始新的錄屏。',
    'Audio or screen recording is running; stop it before starting a new screen recording.',
    '録音/画面収録中です。停止してから新しい画面収録を開始してください。',
    '녹음/화면 기록 중입니다. 먼저 중지한 뒤 새 화면 기록을 시작하세요.',
    "Un enregistrement audio ou d'écran est en cours ; arrêtez-le avant de lancer un nouvel enregistrement.",
    'Audio- oder Bildschirmaufnahme läuft; bitte zuerst stoppen, dann eine neue Bildschirmaufnahme starten.',
    'Se está grabando audio o pantalla; detenlo antes de iniciar una nueva grabación de pantalla.',
    'Registrazione audio o schermo in corso; interrompila prima di avviarne una nuova.',
    'Está a gravar áudio ou ecrã; pare antes de iniciar uma nova gravação de ecrã.',
    'Идёт запись звука или экрана; остановите её, прежде чем начинать новую запись.',
    'يجري تسجيل صوتي أو تسجيل شاشة؛ أوقفه قبل بدء تسجيل شاشة جديد.',
    'ऑडियो या स्क्रीन रिकॉर्डिंग चल रही है; नई स्क्रीन रिकॉर्डिंग शुरू करने से पहले रोकें।',
    'กำลังบันทึกเสียงหรือหน้าจอ โปรดหยุดก่อนเริ่มบันทึกหน้าจอใหม่',
    'Đang ghi âm hoặc ghi màn hình; hãy dừng trước khi bắt đầu ghi màn hình mới.',
    'Sedang merekam audio atau layar; hentikan dulu sebelum memulai perekaman layar baru.',
    'Ses veya ekran kaydı sürüyor; yeni bir ekran kaydı başlatmadan önce durdurun.',
    'Audio- of schermopname loopt; stop eerst voordat je een nieuwe schermopname start.',
    'Trwa nagrywanie dźwięku lub ekranu; zatrzymaj je przed rozpoczęciem nowego nagrywania.',
    'Триває запис звуку або екрана; зупиніть його, перш ніж починати новий запис.',
    'Ljud- eller skärminspelning pågår; stoppa den innan du startar en ny skärminspelning.',
])

add('点击工具栏「捕获」按钮或触发热键时使用的默认模式', [
    '點擊工具列「擷取」按鈕或觸發熱鍵時使用的預設模式',
    'The default mode used when you click the toolbar “Capture” button or trigger the hotkey',
    'ツールバーの「キャプチャ」ボタンやホットキーを実行したときの既定モード',
    '도구 막대 ‘캡처’ 버튼을 누르거나 단축키를 실행할 때 사용할 기본 모드',
    "Mode par défaut utilisé lors d'un clic sur « Capturer » dans la barre d'outils ou du déclenchement du raccourci",
    'Standardmodus beim Klicken auf „Erfassen“ in der Werkzeugleiste oder beim Auslösen des Tastenkürzels',
    'Modo predeterminado al pulsar «Capturar» en la barra de herramientas o al usar el atajo',
    'Modalità predefinita quando si fa clic su «Acquisisci» nella barra strumenti o si usa la scorciatoia',
    'Modo predefinido ao clicar em «Capturar» na barra de ferramentas ou ao usar o atalho',
    'Режим по умолчанию для кнопки «Захват» на панели инструментов и сочетания клавиш',
    'الوضع الافتراضي عند الضغط على زر «التقاط» في شريط الأدوات أو استخدام مفتاح الاختصار',
    'टूलबार के «कैप्चर» बटन या हॉटकी चलाने पर उपयोग होने वाला डिफ़ॉल्ट मोड',
    'โหมดเริ่มต้นเมื่อกดปุ่ม «จับภาพ» ในแถบเครื่องมือหรือใช้ปุ่มลัด',
    'Chế độ mặc định khi bấm nút «Chụp» trên thanh công cụ hoặc dùng phím tắt',
    'Mode default saat menekan tombol «Tangkap» di bilah alat atau memicu pintasan',
    'Araç çubuğundaki «Yakala» düğmesine veya kısayola basıldığında kullanılan varsayılan mod',
    'Standaardmodus bij het klikken op «Vastleggen» in de werkbalk of bij de sneltoets',
    'Tryb domyślny używany po kliknięciu „Przechwyć” na pasku narzędzi lub użyciu skrótu',
    'Режим за замовчуванням для кнопки «Захоплення» та комбінації клавіш',
    'Standardläge när du klickar på «Fånga» i verktygsfältet eller använder kortkommandot',
])

add('点击立即开始 · Esc 取消', [
    '點擊立即開始 · Esc 取消',
    'Click to start now · Esc to cancel',
    'クリックで即開始 · Esc でキャンセル',
    '클릭하면 바로 시작 · Esc로 취소',
    'Cliquez pour démarrer · Échap pour annuler',
    'Klicken zum sofortigen Start · Esc zum Abbrechen',
    'Clic para empezar ya · Esc para cancelar',
    'Fai clic per iniziare subito · Esc per annullare',
    'Clique para começar já · Esc para cancelar',
    'Нажмите, чтобы начать · Esc — отмена',
    'انقر للبدء فورًا · Esc للإلغاء',
    'शुरू करने के लिए क्लिक करें · Esc रद्द करें',
    'คลิกเพื่อเริ่มทันที · Esc เพื่อยกเลิก',
    'Nhấp để bắt đầu ngay · Esc để hủy',
    'Klik untuk mulai sekarang · Esc untuk membatalkan',
    'Hemen başlamak için tıklayın · İptal için Esc',
    'Klik om nu te starten · Esc om te annuleren',
    'Kliknij, aby rozpocząć · Esc anuluje',
    'Натисніть, щоб почати · Esc — скасувати',
    'Klicka för att börja nu · Esc för att avbryta',
])

add('用于全部录屏入口（会话工具栏「录制」与菜单栏「捕获屏幕」直达项）；独立于会议录音设置，不影响普通录音。', [
    '用於全部錄屏入口（工作階段工具列「錄製」與選單列「擷取螢幕」直達項）；獨立於會議錄音設定，不影響一般錄音。',
    'Applies to all screen recording entry points (the “Record” button in the session toolbar and the “Capture Screen” items in the menu bar); it is independent of meeting recording settings and does not affect normal audio recording.',
    'すべての画面収録の入口（セッションのツールバー「録画」とメニューバー「画面キャプチャ」の直行項目）に適用されます。会議録音の設定とは独立しており、通常の録音には影響しません。',
    '모든 화면 기록 진입점(세션 도구 막대의 ‘녹화’와 메뉴 막대 ‘화면 캡처’ 바로 실행 항목)에 적용됩니다. 회의 녹음 설정과 별개이며 일반 녹음에는 영향을 주지 않습니다.',
    "S'applique à toutes les entrées d'enregistrement d'écran (le bouton « Enregistrer » de la barre d'outils de session et les éléments « Capturer l'écran » de la barre des menus) ; indépendant des réglages d'enregistrement de réunion et sans effet sur l'enregistrement audio classique.",
    'Gilt für alle Einstiege der Bildschirmaufnahme (die Schaltfläche „Aufnehmen“ in der Sitzungs-Werkzeugleiste und die Einträge „Bildschirm erfassen“ in der Menüleiste); unabhängig von den Meeting-Aufnahmeeinstellungen und ohne Einfluss auf normale Audioaufnahmen.',
    'Se aplica a todos los accesos de grabación de pantalla (el botón «Grabar» de la barra de la sesión y los elementos «Capturar pantalla» de la barra de menús); es independiente de los ajustes de grabación de reuniones y no afecta a la grabación de audio normal.',
    'Vale per tutti gli accessi alla registrazione schermo (il pulsante «Registra» nella barra della sessione e le voci «Acquisisci schermo» nella barra dei menu); è indipendente dalle impostazioni di registrazione riunioni e non influisce sulla registrazione audio normale.',
    'Aplica-se a todos os acessos de gravação de ecrã (o botão «Gravar» da barra da sessão e os itens «Capturar ecrã» da barra de menus); é independente das definições de gravação de reuniões e não afeta a gravação de áudio normal.',
    'Действует для всех точек входа записи экрана (кнопка «Запись» на панели сеанса и пункты «Захват экрана» в строке меню); не зависит от настроек записи совещаний и не влияет на обычную аудиозапись.',
    'ينطبق على جميع مداخل تسجيل الشاشة (زر «تسجيل» في شريط الجلسة وعناصر «التقاط الشاشة» في شريط القوائم)؛ وهو مستقل عن إعدادات تسجيل الاجتماعات ولا يؤثر على التسجيل الصوتي العادي.',
    'सभी स्क्रीन रिकॉर्डिंग प्रवेश बिंदुओं (सत्र टूलबार का «रिकॉर्ड करें» और मेन्यू बार की «स्क्रीन कैप्चर» प्रविष्टियाँ) पर लागू; यह मीटिंग रिकॉर्डिंग सेटिंग्स से स्वतंत्र है और सामान्य ऑडियो रिकॉर्डिंग को प्रभावित नहीं करता।',
    'ใช้กับทุกทางเข้าของการบันทึกหน้าจอ (ปุ่ม «บันทึก» ในแถบเครื่องมือของเซสชัน และรายการ «จับภาพหน้าจอ» ในแถบเมนู) เป็นอิสระจากการตั้งค่าการบันทึกการประชุมและไม่มีผลต่อการบันทึกเสียงปกติ',
    'Áp dụng cho mọi lối vào ghi màn hình (nút «Ghi» trên thanh công cụ của phiên và mục «Chụp màn hình» trên thanh menu); độc lập với cài đặt ghi âm cuộc họp và không ảnh hưởng đến ghi âm thông thường.',
    'Berlaku untuk semua titik masuk perekaman layar (tombol «Rekam» di bilah alat sesi dan item «Tangkap Layar» di bilah menu); independen dari pengaturan perekaman rapat dan tidak memengaruhi perekaman audio biasa.',
    'Tüm ekran kaydı girişleri için geçerlidir (oturum araç çubuğundaki «Kaydet» ve menü çubuğundaki «Ekranı yakala» öğeleri); toplantı kaydı ayarlarından bağımsızdır ve normal ses kaydını etkilemez.',
    'Geldt voor alle schermopname-ingangen (de knop «Opnemen» in de sessiewerkbalk en de items «Scherm vastleggen» in de menubalk); onafhankelijk van de vergaderopname-instellingen en zonder invloed op normale audio-opname.',
    'Dotyczy wszystkich miejsc rozpoczęcia nagrywania ekranu (przycisk „Nagraj” na pasku sesji i pozycje „Przechwyć ekran” w pasku menu); jest niezależne od ustawień nagrywania spotkań i nie wpływa na zwykłe nagrywanie dźwięku.',
    'Застосовується до всіх точок входу запису екрана (кнопка «Запис» на панелі сеансу та пункти «Захоплення екрана» в рядку меню); не залежить від налаштувань запису зустрічей і не впливає на звичайний аудіозапис.',
    'Gäller för alla ingångar för skärminspelning (knappen «Spela in» i sessionsverktygsfältet och objekten «Fånga skärm» i menyraden); oberoende av inställningarna för mötesinspelning och påverkar inte vanlig ljudinspelning.',
])

add('系统音频采集在启动过程中被中断', [
    '系統音訊擷取在啟動過程中被中斷',
    'System audio capture was interrupted while starting',
    'システム音声の取り込みが起動中に中断されました',
    '시스템 오디오 캡처가 시작 중에 중단되었습니다',
    "La capture de l'audio système a été interrompue pendant le démarrage",
    'Die Systemaudio-Erfassung wurde beim Start unterbrochen',
    'La captura de audio del sistema se interrumpió durante el inicio',
    "L'acquisizione dell'audio di sistema è stata interrotta durante l'avvio",
    'A captura de áudio do sistema foi interrompida durante o arranque',
    'Захват системного звука был прерван при запуске',
    'تمت مقاطعة التقاط صوت النظام أثناء بدء التشغيل',
    'सिस्टम ऑडियो कैप्चर शुरू होते समय बाधित हुआ',
    'การจับเสียงระบบถูกขัดจังหวะระหว่างเริ่มทำงาน',
    'Việc thu âm thanh hệ thống bị gián đoạn khi khởi động',
    'Penangkapan audio sistem terputus saat memulai',
    'Sistem sesi yakalama başlatılırken kesildi',
    'Vastleggen van systeemaudio is onderbroken tijdens het starten',
    'Przechwytywanie dźwięku systemowego zostało przerwane podczas uruchamiania',
    'Захоплення системного звуку перервано під час запуску',
    'Inspelning av systemljud avbröts vid start',
])

add('系统音频采集已在运行或正在收尾', [
    '系統音訊擷取已在執行或正在收尾',
    'System audio capture is already running or is wrapping up',
    'システム音声の取り込みはすでに実行中か終了処理中です',
    '시스템 오디오 캡처가 이미 실행 중이거나 마무리 중입니다',
    "La capture de l'audio système est déjà en cours ou en cours de finalisation",
    'Die Systemaudio-Erfassung läuft bereits oder wird gerade beendet',
    'La captura de audio del sistema ya está en marcha o finalizando',
    "L'acquisizione dell'audio di sistema è già in corso o in fase di chiusura",
    'A captura de áudio do sistema já está em execução ou a terminar',
    'Захват системного звука уже выполняется или завершается',
    'التقاط صوت النظام قيد التشغيل بالفعل أو قيد الإنهاء',
    'सिस्टम ऑडियो कैप्चर पहले से चल रहा है या समाप्त हो रहा है',
    'การจับเสียงระบบกำลังทำงานอยู่แล้วหรือกำลังสิ้นสุด',
    'Việc thu âm thanh hệ thống đang chạy hoặc đang kết thúc',
    'Penangkapan audio sistem sudah berjalan atau sedang diakhiri',
    'Sistem sesi yakalama zaten çalışıyor veya sonlandırılıyor',
    'Vastleggen van systeemaudio is al actief of wordt afgerond',
    'Przechwytywanie dźwięku systemowego już trwa lub się kończy',
    'Захоплення системного звуку вже виконується або завершується',
    'Inspelning av systemljud körs redan eller avslutas',
])

add('默认捕获模式', [
    '預設擷取模式',
    'Default Capture Mode',
    '既定のキャプチャモード',
    '기본 캡처 모드',
    'Mode de capture par défaut',
    'Standard-Erfassungsmodus',
    'Modo de captura predeterminado',
    'Modalità di acquisizione predefinita',
    'Modo de captura predefinido',
    'Режим захвата по умолчанию',
    'وضع الالتقاط الافتراضي',
    'डिफ़ॉल्ट कैप्चर मोड',
    'โหมดจับภาพเริ่มต้น',
    'Chế độ chụp mặc định',
    'Mode tangkapan default',
    'Varsayılan yakalama modu',
    'Standaard vastleggingsmodus',
    'Domyślny tryb przechwytywania',
    'Режим захоплення за замовчуванням',
    'Standardläge för fångst',
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
    print(f'批次10 完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
