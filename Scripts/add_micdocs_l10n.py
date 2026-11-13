#!/usr/bin/env python3
# 麦克风选择：帮助说明 + 首次使用引导 文案 20 种语言
# 与 add_microphone_l10n.py 同一合并策略（补全已被自动抽取的空条目）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('麦克风选择', [
    '麥克風選擇',
    'Microphone Selection',
    'マイクの選択',
    '마이크 선택',
    'Choix du microphone',
    'Mikrofonauswahl',
    'Selección de micrófono',
    'Scelta del microfono',
    'Seleção de microfone',
    'Выбор микрофона',
    'اختيار الميكروفون',
    'माइक्रोफ़ोन चयन',
    'การเลือกไมโครโฟน',
    'Chọn micrô',
    'Pemilihan Mikrofon',
    'Mikrofon Seçimi',
    'Microfoonkeuze',
    'Wybór mikrofonu',
    'Вибір мікрофона',
    'Val av mikrofon',
])

add('可在「设置 → 录音 → 输入设备」指定使用哪个麦克风（含外接麦与 Loopback 等虚拟设备）；未指定时跟随系统默认输入设备', [
    '可在「設定 → 錄音 → 輸入裝置」指定使用哪個麥克風（含外接麥與 Loopback 等虛擬裝置）；未指定時跟隨系統預設輸入裝置',
    'Choose which microphone to use in Settings → Recording → Input Device (external mics and virtual devices such as Loopback included); when unset, the system default input device is used',
    '「設定 → 録音 → 入力デバイス」で使用するマイクを指定できます（外付けマイクや Loopback などの仮想デバイスを含む）。未指定の場合はシステムのデフォルト入力デバイスに従います',
    '‘설정 → 녹음 → 입력 장치’에서 사용할 마이크를 지정할 수 있습니다(외장 마이크와 Loopback 등 가상 장치 포함). 지정하지 않으면 시스템 기본 입력 장치를 따릅니다',
    "Choisissez le microphone dans Réglages → Enregistrement → Périphérique d'entrée (micros externes et périphériques virtuels comme Loopback inclus) ; sans choix, le périphérique d'entrée par défaut du système est utilisé",
    'Unter Einstellungen → Aufnahme → Eingabegerät lässt sich das Mikrofon wählen (inklusive externer Mikrofone und virtueller Geräte wie Loopback); ohne Auswahl gilt der Systemstandard',
    'Elige el micrófono en Ajustes → Grabación → Dispositivo de entrada (incluye micrófonos externos y dispositivos virtuales como Loopback); si no eliges ninguno, se usa el dispositivo de entrada predeterminado del sistema',
    'Scegli il microfono in Impostazioni → Registrazione → Dispositivo di input (inclusi microfoni esterni e dispositivi virtuali come Loopback); se non scegli, viene usato il dispositivo di input predefinito del sistema',
    'Escolha o microfone em Definições → Gravação → Dispositivo de entrada (inclui microfones externos e dispositivos virtuais como o Loopback); sem escolha, é usado o dispositivo de entrada padrão do sistema',
    'Выбрать микрофон можно в «Настройки → Запись → Устройство ввода» (включая внешние микрофоны и виртуальные устройства вроде Loopback); если не выбрано, используется устройство ввода по умолчанию',
    'يمكنك تحديد الميكروفون من «الإعدادات → التسجيل → جهاز الإدخال» (بما في ذلك الميكروفونات الخارجية والأجهزة الافتراضية مثل Loopback)؛ وعند عدم التحديد يُستخدم جهاز الإدخال الافتراضي للنظام',
    '«सेटिंग्स → रिकॉर्डिंग → इनपुट डिवाइस» में चुनें कि कौन-सा माइक्रोफ़ोन इस्तेमाल होगा (बाहरी माइक और Loopback जैसे वर्चुअल डिवाइस सहित); न चुनने पर सिस्टम का डिफ़ॉल्ट इनपुट डिवाइस इस्तेमाल होता है',
    'เลือกไมโครโฟนได้ที่ «การตั้งค่า → การบันทึก → อุปกรณ์อินพุต» (รวมไมค์ภายนอกและอุปกรณ์เสมือนเช่น Loopback) หากไม่เลือกจะใช้อุปกรณ์อินพุตเริ่มต้นของระบบ',
    'Chọn micrô trong «Cài đặt → Ghi âm → Thiết bị đầu vào» (gồm micrô ngoài và thiết bị ảo như Loopback); nếu không chọn, dùng thiết bị đầu vào mặc định của hệ thống',
    'Pilih mikrofon di «Pengaturan → Perekaman → Perangkat Input» (termasuk mikrofon eksternal dan perangkat virtual seperti Loopback); jika tidak dipilih, perangkat input default sistem yang dipakai',
    'Mikrofonu «Ayarlar → Kayıt → Giriş Aygıtı» bölümünden seçin (harici mikrofonlar ve Loopback gibi sanal aygıtlar dahil); seçilmezse sistem varsayılan giriş aygıtı kullanılır',
    'Kies de microfoon in «Instellingen → Opnemen → Invoerapparaat» (inclusief externe microfoons en virtuele apparaten zoals Loopback); zonder keuze wordt het systeemstandaard invoerapparaat gebruikt',
    'Mikrofon wybierzesz w „Ustawienia → Nagrywanie → Urządzenie wejściowe” (także mikrofony zewnętrzne i urządzenia wirtualne, np. Loopback); bez wyboru używane jest domyślne urządzenie wejściowe systemu',
    'Мікрофон можна вибрати в «Налаштування → Запис → Пристрій введення» (зокрема зовнішні мікрофони та віртуальні пристрої як-от Loopback); якщо не вибрано — пристрій введення за замовчуванням',
    'Välj mikrofon i «Inställningar → Inspelning → Indataenhet» (inklusive externa mikrofoner och virtuella enheter som Loopback); utan val används systemets standardenhet',
])

add('菜单栏「麦克风」子菜单内可快速切换麦克风；截图会话工具栏「录制」旁也有麦克风按钮，倒计时会显示当前质量、声源与麦克风供最后确认', [
    '選單列「麥克風」子選單內可快速切換麥克風；截圖工作階段工具列「錄製」旁也有麥克風按鈕，倒數會顯示目前品質、音源與麥克風供最後確認',
    "Switch microphones quickly from the menu bar's Microphone submenu; the screenshot toolbar also has a microphone button next to Record, and the countdown shows the current quality, audio source and microphone for a final check",
    'メニューバーの「マイク」サブメニューから素早く切り替えられます。スクリーンショットのツールバー「録画」の隣にもマイクボタンがあり、カウントダウン中に現在の品質・音源・マイクを確認できます',
    '메뉴 막대 ‘마이크’ 하위 메뉴에서 빠르게 전환할 수 있습니다. 스크린샷 도구 막대의 ‘녹화’ 옆에도 마이크 버튼이 있고, 카운트다운에 현재 품질·음원·마이크가 표시됩니다',
    "Basculez rapidement depuis le sous-menu « Microphone » de la barre des menus ; la barre d'outils de capture a aussi un bouton micro à côté de « Enregistrer », et le compte à rebours affiche qualité, source et micro pour une dernière vérification",
    'Im Untermenü „Mikrofon“ der Menüleiste schnell umschalten; die Werkzeugleiste hat neben „Aufnehmen“ ebenfalls einen Mikrofon-Button, und der Countdown zeigt Qualität, Tonquelle und Mikrofon zur letzten Kontrolle',
    'Cambia rápidamente desde el submenú «Micrófono» de la barra de menús; la barra de herramientas de captura también tiene un botón de micrófono junto a «Grabar», y la cuenta atrás muestra la calidad, la fuente y el micrófono para una última comprobación',
    'Cambia rapidamente dal sottomenu «Microfono» della barra dei menu; la barra degli strumenti ha un pulsante microfono accanto a «Registra» e il conto alla rovescia mostra qualità, sorgente e microfono per l’ultima verifica',
    'Mude rapidamente no submenu «Microfone» da barra de menus; a barra de ferramentas também tem um botão de microfone junto a «Gravar», e a contagem decrescente mostra qualidade, fonte e microfone para confirmação final',
    'Быстро переключайте в подменю «Микрофон» в строке меню; на панели инструментов рядом с «Запись» тоже есть кнопка микрофона, а в обратном отсчёте показаны качество, источник звука и микрофон',
    'يمكنك التبديل بسرعة من القائمة الفرعية «الميكروفون» في شريط القوائم؛ ويوجد زر للميكروفون بجوار «تسجيل» في شريط أدوات لقطة الشاشة، ويعرض العدّ التنازلي الجودة ومصدر الصوت والميكروفون للتأكيد الأخير',
    'मेन्यू बार के «माइक्रोफ़ोन» सबमेनू से तुरंत बदलें; स्क्रीनशॉट टूलबार में «रिकॉर्ड» के पास भी माइक्रोफ़ोन बटन है, और काउंटडाउन में गुणवत्ता, ऑडियो स्रोत और माइक्रोफ़ोन दिखते हैं',
    'สลับได้อย่างรวดเร็วจากเมนูย่อย «ไมโครโฟน» ในแถบเมนู และมีปุ่มไมโครโฟนข้าง «บันทึก» ในแถบเครื่องมือสกรีนช็อต โดยการนับถอยหลังจะแสดงคุณภาพ แหล่งเสียง และไมโครโฟนให้ตรวจสอบครั้งสุดท้าย',
    'Chuyển nhanh từ menu phụ «Micrô» trên thanh menu; thanh công cụ chụp ảnh cũng có nút micrô cạnh «Ghi», và đếm ngược hiển thị chất lượng, nguồn âm và micrô để xác nhận lần cuối',
    'Beralih cepat dari submenu «Mikrofon» di bilah menu; bilah alat tangkapan juga punya tombol mikrofon di samping «Rekam», dan hitungan mundur menampilkan kualitas, sumber audio, dan mikrofon untuk konfirmasi akhir',
    'Menü çubuğundaki «Mikrofon» alt menüsünden hızlıca değiştirin; ekran görüntüsü araç çubuğunda «Kaydet» yanında mikrofon düğmesi de var ve geri sayım kalite, ses kaynağı ve mikrofonu son kontrol için gösterir',
    'Wissel snel via het submenu «Microfoon» in de menubalk; de werkbalk heeft ook een microfoonknop naast «Opnemen», en het aftellen toont kwaliteit, audiobron en microfoon voor een laatste controle',
    'Szybko przełączysz w podmenu „Mikrofon” w pasku menu; pasek narzędzi ma też przycisk mikrofonu obok „Nagraj”, a odliczanie pokazuje jakość, źródło dźwięku i mikrofon do ostatniej weryfikacji',
    'Швидко перемикайте в підменю «Мікрофон» в рядку меню; на панелі інструментів поруч із «Запис» теж є кнопка мікрофона, а зворотний відлік показує якість, джерело звуку й мікрофон',
    'Byt snabbt via undermenyn «Mikrofon» i menyraden; verktygsfältet har också en mikrofonknapp bredvid «Spela in», och nedräkningen visar kvalitet, ljudkälla och mikrofon för en sista kontroll',
])

add('麦克风选择只保存在本机并只作用于 Memozia，不会改变系统默认输入设备；所选设备被拔出时自动回退系统默认', [
    '麥克風選擇只保存在本機並只作用於 Memozia，不會改變系統預設輸入裝置；所選裝置被拔出時自動改回系統預設',
    'The microphone choice is stored only on this Mac and applies only to Memozia; it never changes the system default input device, and falls back to it automatically if the chosen device is unplugged',
    'マイクの選択は本機にのみ保存され Memozia にのみ適用されます。システムのデフォルト入力デバイスは変更されず、選択したデバイスを外すと自動的にデフォルトに戻ります',
    '마이크 선택은 이 Mac에만 저장되고 Memozia에만 적용됩니다. 시스템 기본 입력 장치는 바뀌지 않으며, 선택한 장치를 분리하면 자동으로 기본값으로 돌아갑니다',
    "Le choix du microphone est stocké uniquement sur ce Mac et ne s'applique qu'à Memozia ; il ne modifie jamais le périphérique d'entrée par défaut du système et y revient automatiquement si l'appareil choisi est débranché",
    'Die Mikrofonauswahl wird nur auf diesem Mac gespeichert und gilt nur für Memozia; der Systemstandard wird nie geändert, und bei getrenntem Gerät wird automatisch darauf zurückgefallen',
    'La elección del micrófono se guarda solo en este equipo y se aplica únicamente a Memozia; nunca cambia el dispositivo de entrada predeterminado del sistema y, si se desconecta el elegido, se vuelve a él automáticamente',
    'La scelta del microfono è salvata solo su questo Mac e vale solo per Memozia; non modifica mai il dispositivo di input predefinito del sistema e vi ritorna automaticamente se il dispositivo scelto viene scollegato',
    'A escolha do microfone é guardada apenas neste Mac e aplica-se apenas ao Memozia; nunca altera o dispositivo de entrada padrão do sistema e volta automaticamente a ele se o dispositivo escolhido for desligado',
    'Выбор микрофона хранится только на этом Mac и действует лишь в Memozia; системное устройство ввода по умолчанию не меняется, а при отключении выбранного устройства происходит автоматический возврат к нему',
    'يُحفظ اختيار الميكروفون على هذا الجهاز فقط ويُطبَّق على Memozia فقط؛ ولا يغيّر جهاز الإدخال الافتراضي للنظام، ويعود إليه تلقائيًا عند فصل الجهاز المحدد',
    'माइक्रोफ़ोन का चयन केवल इस Mac पर सहेजा जाता है और सिर्फ़ Memozia पर लागू होता है; यह सिस्टम का डिफ़ॉल्ट इनपुट डिवाइस नहीं बदलता, और चुना डिवाइस हटाने पर अपने-आप डिफ़ॉल्ट पर लौट आता है',
    'ตัวเลือกไมโครโฟนถูกเก็บไว้ในเครื่องนี้และมีผลกับ Memozia เท่านั้น ไม่เปลี่ยนอุปกรณ์อินพุตเริ่มต้นของระบบ และจะกลับไปใช้ค่าเริ่มต้นอัตโนมัติเมื่อถอดอุปกรณ์ที่เลือกออก',
    'Lựa chọn micrô chỉ lưu trên máy này và chỉ áp dụng cho Memozia; không thay đổi thiết bị đầu vào mặc định của hệ thống, và tự động quay về mặc định khi thiết bị đã chọn bị ngắt',
    'Pilihan mikrofon hanya disimpan di Mac ini dan hanya berlaku untuk Memozia; tidak mengubah perangkat input default sistem, dan otomatis kembali ke default jika perangkat yang dipilih dicabut',
    'Mikrofon seçimi yalnızca bu Mac’te saklanır ve yalnızca Memozia için geçerlidir; sistem varsayılan giriş aygıtını değiştirmez ve seçilen aygıt çıkarılırsa otomatik olarak varsayılana döner',
    'De microfoonkeuze wordt alleen op deze Mac opgeslagen en geldt alleen voor Memozia; het systeemstandaard invoerapparaat wordt nooit gewijzigd en bij loskoppelen van het gekozen apparaat wordt automatisch daarop teruggevallen',
    'Wybór mikrofonu jest zapisywany tylko na tym Macu i dotyczy tylko Memozia; nigdy nie zmienia domyślnego urządzenia wejściowego systemu, a po odłączeniu wybranego urządzenia następuje automatyczny powrót do niego',
    'Вибір мікрофона зберігається лише на цьому Mac і діє тільки в Memozia; системний пристрій введення за замовчуванням не змінюється, а в разі від’єднання вибраного пристрою відбувається автоматичне повернення до нього',
    'Mikrofonvalet sparas bara på den här Macen och gäller endast Memozia; systemets standardenhet ändras aldrig, och om den valda enheten kopplas bort återgår det automatiskt till standarden',
])

add('屏幕录制', [
    '螢幕錄製',
    'Screen Recording',
    '画面収録',
    '화면 녹화',
    "Enregistrement d'écran",
    'Bildschirmaufnahme',
    'Grabación de pantalla',
    'Registrazione schermo',
    'Gravação de ecrã',
    'Запись экрана',
    'تسجيل الشاشة',
    'स्क्रीन रिकॉर्डिंग',
    'การบันทึกหน้าจอ',
    'Ghi màn hình',
    'Perekaman Layar',
    'Ekran Kaydı',
    'Schermopname',
    'Nagrywanie ekranu',
    'Запис екрана',
    'Skärminspelning',
])

add('全屏 / 区域 / 窗口 + 可选麦克风', [
    '全螢幕 / 區域 / 視窗 + 可選麥克風',
    'Full screen / region / window + optional microphone',
    '全画面 / 領域 / ウインドウ + マイク選択可',
    '전체 화면 / 영역 / 창 + 마이크 선택',
    'Plein écran / zone / fenêtre + micro au choix',
    'Vollbild / Bereich / Fenster + optionales Mikrofon',
    'Pantalla completa / región / ventana + micrófono opcional',
    'Schermo intero / area / finestra + microfono opzionale',
    'Ecrã inteiro / região / janela + microfone opcional',
    'Весь экран / область / окно + выбор микрофона',
    'الشاشة كاملة / منطقة / نافذة + ميكروفون اختياري',
    'पूरी स्क्रीन / क्षेत्र / विंडो + वैकल्पिक माइक्रोफ़ोन',
    'เต็มหน้าจอ / พื้นที่ / หน้าต่าง + เลือกไมโครโฟนได้',
    'Toàn màn hình / vùng / cửa sổ + micrô tùy chọn',
    'Layar penuh / area / jendela + mikrofon opsional',
    'Tam ekran / bölge / pencere + isteğe bağlı mikrofon',
    'Volledig scherm / gebied / venster + optionele microfoon',
    'Cały ekran / obszar / okno + opcjonalny mikrofon',
    'Увесь екран / область / вікно + вибір мікрофона',
    'Hela skärmen / område / fönster + valfri mikrofon',
])

add('菜单栏「捕获屏幕」可选择全屏、区域或窗口录屏，画面与音频同步入库为视频条目，可播放、抽关键帧并生成视觉纪要。麦克风可在设置、菜单栏或截图工具栏中选择（含外接麦与虚拟设备）；声源选「仅系统音频」时只录系统声音。', [
    '從選單列「擷取螢幕」可錄製全螢幕、區域或視窗，畫面與音訊同步入庫為影片項目，可播放、擷取關鍵影格並產生視覺紀要。麥克風可在設定、選單列或截圖工具列中選擇（含外接麥與虛擬裝置）；音源選「僅系統音訊」時只錄系統聲音。',
    'Record the full screen, a region or a window from the menu bar’s Capture Screen; picture and audio are saved together as a video item you can play, extract keyframes from and summarize visually. Choose the microphone in Settings, the menu bar or the screenshot toolbar (external mics and virtual devices included); pick “System audio only” to record system sound alone.',
    'メニューバーの「画面キャプチャ」から全画面・領域・ウインドウを収録でき、映像と音声が一緒に動画項目として保存されます（再生・キーフレーム抽出・映像要約に対応）。マイクは設定・メニューバー・スクリーンショットのツールバーから選択できます（外付けマイクや仮想デバイスを含む）。音源で「システム音声のみ」を選ぶとシステム音だけを録音します。',
    '메뉴 막대 ‘화면 캡처’에서 전체 화면·영역·창을 녹화할 수 있고, 화면과 오디오가 함께 동영상 항목으로 저장되어 재생·키프레임 추출·영상 요약이 가능합니다. 마이크는 설정, 메뉴 막대, 스크린샷 도구 막대에서 선택할 수 있습니다(외장 마이크와 가상 장치 포함). 음원을 ‘시스템 오디오만’으로 선택하면 시스템 소리만 녹음합니다.',
    "Enregistrez l'écran entier, une zone ou une fenêtre depuis « Capturer l'écran » dans la barre des menus ; l'image et le son sont enregistrés ensemble comme un élément vidéo que vous pouvez lire, dont vous pouvez extraire des images clés et générer un résumé visuel. Choisissez le micro dans les réglages, la barre des menus ou la barre d'outils de capture (micros externes et appareils virtuels inclus) ; avec « Audio système uniquement », seul le son du système est enregistré.",
    'Über „Bildschirm erfassen“ in der Menüleiste lassen sich Vollbild, Bereich oder Fenster aufnehmen; Bild und Ton werden gemeinsam als Videoeintrag gespeichert, den Sie abspielen, aus dem Sie Keyframes extrahieren und eine visuelle Zusammenfassung erstellen können. Das Mikrofon wählen Sie in den Einstellungen, in der Menüleiste oder in der Symbolleiste (inkl. externer Mikrofone und virtueller Geräte); mit „Nur Systemaudio“ wird nur der Systemton aufgenommen.',
    'Graba la pantalla completa, una región o una ventana desde «Capturar pantalla» en la barra de menús; imagen y audio se guardan juntos como un elemento de vídeo que puedes reproducir, del que puedes extraer fotogramas clave y generar un resumen visual. Elige el micrófono en Ajustes, la barra de menús o la barra de herramientas (incluye micrófonos externos y dispositivos virtuales); con «Solo audio del sistema» se graba únicamente el sonido del sistema.',
    'Registra schermo intero, un’area o una finestra da «Acquisisci schermo» nella barra dei menu; immagine e audio vengono salvati insieme come elemento video che puoi riprodurre, da cui estrarre fotogrammi chiave e generare una sintesi visiva. Scegli il microfono nelle impostazioni, nella barra dei menu o nella barra degli strumenti (inclusi microfoni esterni e dispositivi virtuali); con «Solo audio di sistema» registri solo l’audio del sistema.',
    'Grave o ecrã inteiro, uma região ou uma janela a partir de «Capturar ecrã» na barra de menus; imagem e áudio são guardados juntos como um item de vídeo que pode reproduzir, do qual pode extrair fotogramas-chave e gerar um resumo visual. Escolha o microfone nas definições, na barra de menus ou na barra de ferramentas (inclui microfones externos e dispositivos virtuais); com «Apenas áudio do sistema» grava só o som do sistema.',
    'Записывайте весь экран, область или окно из меню «Захват экрана» в строке меню: изображение и звук сохраняются вместе как видеоэлемент, который можно воспроизвести, извлечь ключевые кадры и получить визуальную сводку. Микрофон выбирается в настройках, в строке меню или на панели инструментов (включая внешние микрофоны и виртуальные устройства); при выборе «Только системный звук» записывается лишь звук системы.',
    'سجّل الشاشة كاملة أو منطقة أو نافذة من «التقاط الشاشة» في شريط القوائم؛ تُحفظ الصورة والصوت معًا كعنصر فيديو يمكن تشغيله واستخراج الإطارات الرئيسية منه وإنشاء ملخص مرئي. اختر الميكروفون من الإعدادات أو شريط القوائم أو شريط أدوات لقطة الشاشة (بما في ذلك الميكروفونات الخارجية والأجهزة الافتراضية)؛ وعند اختيار «صوت النظام فقط» يُسجَّل صوت النظام وحده.',
    'मेन्यू बार के «स्क्रीन कैप्चर» से पूरी स्क्रीन, क्षेत्र या विंडो रिकॉर्ड करें; चित्र और ऑडियो साथ में वीडियो आइटम के रूप में सहेजे जाते हैं जिसे चला सकते हैं, कीफ़्रेम निकाल सकते हैं और दृश्य सारांश बना सकते हैं। माइक्रोफ़ोन सेटिंग्स, मेन्यू बार या स्क्रीनशॉट टूलबार से चुनें (बाहरी माइक और वर्चुअल डिवाइस सहित); «केवल सिस्टम ऑडियो» चुनने पर सिर्फ़ सिस्टम की आवाज़ रिकॉर्ड होती है।',
    'บันทึกเต็มหน้าจอ พื้นที่ หรือหน้าต่างได้จาก «จับภาพหน้าจอ» ในแถบเมนู ภาพและเสียงจะถูกบันทึกเป็นรายการวิดีโอเดียวกัน เปิดเล่นได้ ดึงคีย์เฟรมได้ และสร้างสรุปภาพได้ เลือกไมโครโฟนได้ในการตั้งค่า แถบเมนู หรือแถบเครื่องมือสกรีนช็อต (รวมไมค์ภายนอกและอุปกรณ์เสมือน) หากเลือก «เสียงระบบเท่านั้น» จะบันทึกเฉพาะเสียงของระบบ',
    'Ghi toàn màn hình, một vùng hoặc một cửa sổ từ «Chụp màn hình» trên thanh menu; hình ảnh và âm thanh được lưu cùng nhau thành mục video có thể phát, trích khung hình chính và tạo tóm tắt hình ảnh. Chọn micrô trong Cài đặt, thanh menu hoặc thanh công cụ chụp ảnh (gồm micrô ngoài và thiết bị ảo); nếu chọn «Chỉ âm thanh hệ thống» thì chỉ ghi âm thanh của hệ thống.',
    'Rekam layar penuh, area, atau jendela dari «Tangkap Layar» di bilah menu; gambar dan audio disimpan bersama sebagai item video yang bisa diputar, diekstrak keyframe, dan dibuat ringkasan visual. Pilih mikrofon di Pengaturan, bilah menu, atau bilah alat tangkapan (termasuk mikrofon eksternal dan perangkat virtual); dengan «Hanya audio sistem» hanya suara sistem yang direkam.',
    'Menü çubuğundaki «Ekranı yakala» ile tam ekranı, bir bölgeyi veya pencereyi kaydedin; görüntü ve ses birlikte, oynatabileceğiniz, kare çıkarabileceğiniz ve görsel özet oluşturabileceğiniz bir video öğesi olarak kaydedilir. Mikrofonu ayarlardan, menü çubuğundan veya ekran görüntüsü araç çubuğundan seçin (harici mikrofonlar ve sanal aygıtlar dahil); «Yalnızca sistem sesi» seçilirse yalnızca sistem sesi kaydedilir.',
    'Leg het volledige scherm, een gebied of een venster vast via «Scherm vastleggen» in de menubalk; beeld en geluid worden samen opgeslagen als een video-item dat je kunt afspelen, waaruit je keyframes kunt halen en een visuele samenvatting kunt maken. Kies de microfoon in Instellingen, de menubalk of de werkbalk (inclusief externe microfoons en virtuele apparaten); met «Alleen systeemaudio» wordt alleen systeemgeluid opgenomen.',
    'Nagraj cały ekran, obszar lub okno z „Przechwyć ekran” w pasku menu; obraz i dźwięk zapisują się razem jako element wideo, który można odtworzyć, wyodrębnić klatki kluczowe i wygenerować podsumowanie wizualne. Mikrofon wybierzesz w ustawieniach, pasku menu lub pasku narzędzi (także mikrofony zewnętrzne i urządzenia wirtualne); przy „Tylko dźwięk systemowy” nagrywany jest wyłącznie dźwięk systemu.',
    'Записуйте весь екран, область або вікно з «Захоплення екрана» в рядку меню; зображення та звук зберігаються разом як відеоелемент, який можна відтворити, видобути ключові кадри й отримати візуальний підсумок. Мікрофон вибирається в налаштуваннях, у рядку меню або на панелі інструментів (зокрема зовнішні мікрофони та віртуальні пристрої); за вибору «Лише системний звук» записується тільки звук системи.',
    'Spela in hela skärmen, ett område eller ett fönster från «Fånga skärm» i menyraden; bild och ljud sparas tillsammans som ett videoobjekt du kan spela upp, extrahera nyckelbildrutor från och skapa en visuell sammanfattning. Välj mikrofon i Inställningar, menyraden eller verktygsfältet (inklusive externa mikrofoner och virtuella enheter); med «Endast systemljud» spelas bara systemljudet in.',
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
