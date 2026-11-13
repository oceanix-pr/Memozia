#!/usr/bin/env python3
"""Add the 9.5.1 help and onboarding translations without changing existing keys."""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

TRANSLATIONS = {
    '菜单栏使用「截图框 + 麦克风文稿」图标，自动适配深浅色。': [
        '選單列使用「截圖框 + 麥克風文稿」圖示，自動適應淺色與深色。',
        'The menu bar uses a capture-frame, microphone and transcript icon that adapts to light and dark appearances.',
        'メニューバーにはキャプチャ枠・マイク・文書のアイコンが表示され、ライト／ダーク表示に自動対応します。',
        '메뉴 막대의 캡처 프레임·마이크·문서 아이콘은 밝은 모드와 어두운 모드에 자동으로 맞춰집니다.',
        'La barre des menus affiche une icône cadre de capture, microphone et document, adaptée aux modes clair et sombre.',
        'Das Menüleistensymbol mit Aufnahmerahmen, Mikrofon und Dokument passt sich dem hellen und dunklen Erscheinungsbild an.',
        'El icono de marco de captura, micrófono y documento de la barra de menús se adapta al modo claro y oscuro.',
        'L’icona con cornice di cattura, microfono e documento nella barra dei menu si adatta all’aspetto chiaro e scuro.',
        'O ícone de moldura de captura, microfone e documento na barra de menus adapta-se aos modos claro e escuro.',
        'Значок рамки захвата, микрофона и документа в строке меню адаптируется к светлому и тёмному оформлению.',
        'تتكيف أيقونة إطار الالتقاط والميكروفون والمستند في شريط القوائم تلقائيًا مع المظهر الفاتح والداكن.',
        'मेन्यू बार का कैप्चर फ़्रेम, माइक्रोफ़ोन और दस्तावेज़ वाला आइकन हल्के और गहरे रूप के अनुसार बदलता है।',
        'ไอคอนกรอบจับภาพ ไมโครโฟน และเอกสารในแถบเมนูจะปรับตามโหมดสว่างและมืดโดยอัตโนมัติ',
        'Biểu tượng khung chụp, micrô và tài liệu trên thanh menu tự thích ứng với giao diện sáng và tối.',
        'Ikon bingkai tangkapan, mikrofon, dan dokumen di bilah menu menyesuaikan tampilan terang dan gelap.',
        'Menü çubuğundaki yakalama çerçevesi, mikrofon ve belge simgesi açık ve koyu görünüme uyum sağlar.',
        'Het menubalksymbool met opnamekader, microfoon en document past zich aan de lichte en donkere weergave aan.',
        'Ikona ramki przechwytywania, mikrofonu i dokumentu na pasku menu dostosowuje się do jasnego i ciemnego wyglądu.',
        'Значок рамки захоплення, мікрофона й документа в рядку меню адаптується до світлого й темного оформлення.',
        'Menyradens symbol med fångstram, mikrofon och dokument anpassas till ljust och mörkt utseende.',
    ],
    '当前不自动跟随会议软件静音，请在 Memozia 中手动静音或解除静音。': [
        '目前不會自動跟隨會議軟體靜音，請在 Memozia 中手動靜音或取消靜音。',
        'Muting in meeting apps is not followed automatically. Mute or unmute manually in Memozia.',
        '会議アプリのミュートには自動連動しません。Memoziaで手動でミュート／解除してください。',
        '회의 앱의 음소거 상태를 자동으로 따르지 않습니다. Memozia에서 직접 음소거하거나 해제하세요.',
        'La mise en sourdine des applications de réunion n’est pas suivie automatiquement. Coupez ou réactivez le micro dans Memozia.',
        'Die Stummschaltung von Meeting-Apps wird nicht automatisch übernommen. Schalten Sie das Mikrofon in Memozia manuell stumm oder ein.',
        'El silencio de las apps de reunión no se sigue automáticamente. Silencia o activa el micrófono manualmente en Memozia.',
        'La disattivazione del microfono nelle app di riunione non viene seguita automaticamente. Gestiscila manualmente in Memozia.',
        'O estado de silêncio das aplicações de reunião não é seguido automaticamente. Ative ou silencie o microfone no Memozia.',
        'Отключение микрофона в приложениях для встреч не отслеживается автоматически. Управляйте микрофоном вручную в Memozia.',
        'لا تتم متابعة كتم الصوت في تطبيقات الاجتماعات تلقائيًا. اكتم الميكروفون أو ألغِ كتمه يدويًا في Memozia.',
        'मीटिंग ऐप्स की म्यूट स्थिति अपने आप लागू नहीं होती। Memozia में माइक्रोफ़ोन को मैन्युअल रूप से म्यूट या अनम्यूट करें।',
        'ระบบจะไม่ปรับการปิดเสียงตามแอปประชุมโดยอัตโนมัติ โปรดปิดหรือเปิดเสียงด้วยตนเองใน Memozia',
        'Không tự động theo trạng thái tắt tiếng của ứng dụng họp. Hãy tự tắt hoặc bật micrô trong Memozia.',
        'Status bisu aplikasi rapat tidak diikuti otomatis. Bisukan atau aktifkan mikrofon secara manual di Memozia.',
        'Toplantı uygulamalarındaki sessize alma durumu otomatik izlenmez. Memozia’da mikrofonu elle kapatın veya açın.',
        'Dempen in vergaderapps wordt niet automatisch gevolgd. Demp de microfoon of schakel deze handmatig in via Memozia.',
        'Wyciszenie w aplikacjach do spotkań nie jest śledzone automatycznie. Wyciszaj i włączaj mikrofon ręcznie w Memozia.',
        'Вимкнення мікрофона в програмах для зустрічей не відстежується автоматично. Керуйте мікрофоном вручну в Memozia.',
        'Ljudavstängning i mötesappar följs inte automatiskt. Stäng av eller slå på mikrofonen manuellt i Memozia.',
    ],
    'macOS 26 及以上默认使用系统语音识别；专业模式可选择 WhisperKit 或云端转写。': [
        'macOS 26 及以上預設使用系統語音辨識；專業模式可選擇 WhisperKit 或雲端轉寫。',
        'macOS 26 and later use system speech recognition by default. Pro mode also offers WhisperKit or cloud transcription.',
        'macOS 26以降では標準でシステム音声認識を使います。プロモードではWhisperKitやクラウド文字起こしも選べます。',
        'macOS 26 이상에서는 기본적으로 시스템 음성 인식을 사용합니다. 프로 모드에서는 WhisperKit 또는 클라우드 전사도 선택할 수 있습니다.',
        'macOS 26 et versions ultérieures utilisent la reconnaissance vocale du système par défaut. Le mode Pro propose aussi WhisperKit ou la transcription cloud.',
        'Ab macOS 26 wird standardmäßig die Systemspracherkennung verwendet. Im Pro-Modus stehen auch WhisperKit und Cloud-Transkription zur Wahl.',
        'macOS 26 y posteriores usan el reconocimiento de voz del sistema por defecto. El modo Pro también ofrece WhisperKit o transcripción en la nube.',
        'Da macOS 26 viene usato di default il riconoscimento vocale di sistema. La modalità Pro offre anche WhisperKit o la trascrizione cloud.',
        'O macOS 26 e posterior usa o reconhecimento de voz do sistema por predefinição. O modo Pro também oferece WhisperKit ou transcrição na nuvem.',
        'В macOS 26 и новее по умолчанию используется системное распознавание речи. В режиме Pro доступны также WhisperKit и облачная расшифровка.',
        'يستخدم macOS 26 والإصدارات الأحدث التعرف على الكلام في النظام افتراضيًا. ويوفر الوضع الاحترافي أيضًا WhisperKit أو التفريغ السحابي.',
        'macOS 26 और बाद के संस्करण डिफ़ॉल्ट रूप से सिस्टम वाक् पहचान का उपयोग करते हैं। प्रो मोड में WhisperKit या क्लाउड ट्रांसक्रिप्शन भी चुन सकते हैं।',
        'macOS 26 ขึ้นไปใช้การรู้จำเสียงของระบบเป็นค่าเริ่มต้น โหมด Pro ยังเลือก WhisperKit หรือการถอดเสียงบนคลาวด์ได้',
        'macOS 26 trở lên mặc định dùng nhận dạng giọng nói của hệ thống. Chế độ Pro còn cho phép chọn WhisperKit hoặc phiên âm đám mây.',
        'macOS 26 dan lebih baru menggunakan pengenalan ucapan sistem secara default. Mode Pro juga menawarkan WhisperKit atau transkripsi cloud.',
        'macOS 26 ve sonrası varsayılan olarak sistem konuşma tanımayı kullanır. Pro modunda WhisperKit veya bulut transkripsiyonu da seçilebilir.',
        'macOS 26 en nieuwer gebruiken standaard systeemspraakherkenning. De Pro-modus biedt ook WhisperKit of cloudtranscriptie.',
        'macOS 26 i nowszy domyślnie korzysta z systemowego rozpoznawania mowy. Tryb Pro oferuje też WhisperKit lub transkrypcję w chmurze.',
        'У macOS 26 і новіших типово використовується системне розпізнавання мовлення. У режимі Pro також доступні WhisperKit і хмарна транскрипція.',
        'macOS 26 och senare använder systemets taligenkänning som standard. Pro-läget erbjuder även WhisperKit eller molntranskribering.',
    ],
    '从菜单栏「捕获屏幕」或全局快捷键启动截图；专业模式另提供窗口、全屏与录屏。': [
        '從選單列「擷取螢幕」或全域快捷鍵啟動截圖；專業模式另提供視窗、全螢幕與螢幕錄製。',
        'Start a screenshot from Capture Screen in the menu bar or a global shortcut. Pro mode also offers window, full-screen and video capture.',
        'メニューバーの「画面キャプチャ」かグローバルショートカットでスクリーンショットを開始します。プロモードではウインドウ・全画面・画面収録も使えます。',
        '메뉴 막대의 화면 캡처 또는 전역 단축키로 스크린샷을 시작하세요. 프로 모드에서는 창, 전체 화면, 화면 녹화도 제공합니다.',
        'Lancez une capture via Capturer l’écran dans la barre des menus ou un raccourci global. Le mode Pro ajoute la capture de fenêtre, plein écran et vidéo.',
        'Starten Sie Screenshots über „Bildschirm erfassen“ in der Menüleiste oder einen globalen Kurzbefehl. Pro bietet zusätzlich Fenster-, Vollbild- und Videoaufnahmen.',
        'Inicia una captura desde Capturar pantalla en la barra de menús o con un atajo global. El modo Pro añade ventanas, pantalla completa y vídeo.',
        'Avvia una schermata da Cattura schermo nella barra dei menu o con una scorciatoia globale. Pro aggiunge finestre, schermo intero e registrazione video.',
        'Inicie uma captura em Capturar ecrã na barra de menus ou com um atalho global. O modo Pro acrescenta janelas, ecrã inteiro e gravação de vídeo.',
        'Начните снимок через «Захват экрана» в строке меню или глобальное сочетание клавиш. Pro также предлагает захват окна, всего экрана и запись видео.',
        'ابدأ لقطة شاشة من «التقاط الشاشة» في شريط القوائم أو باختصار عام. ويضيف الوضع الاحترافي التقاط نافذة أو الشاشة كاملة وتسجيل الفيديو.',
        'मेन्यू बार में स्क्रीन कैप्चर या ग्लोबल शॉर्टकट से स्क्रीनशॉट लें। प्रो मोड में विंडो, पूरी स्क्रीन और वीडियो रिकॉर्डिंग भी उपलब्ध हैं।',
        'เริ่มจับภาพจากเมนูจับภาพหน้าจอในแถบเมนูหรือปุ่มลัดส่วนกลาง โหมด Pro ยังจับภาพหน้าต่าง เต็มหน้าจอ และบันทึกวิดีโอได้',
        'Chụp ảnh từ Chụp màn hình trên thanh menu hoặc phím tắt toàn cục. Chế độ Pro còn hỗ trợ chụp cửa sổ, toàn màn hình và quay video.',
        'Mulai tangkapan layar dari Tangkap Layar di bilah menu atau pintasan global. Mode Pro juga menawarkan jendela, layar penuh, dan perekaman video.',
        'Menü çubuğundaki Ekranı Yakala’dan veya genel kısayoldan ekran görüntüsü alın. Pro modu ayrıca pencere, tam ekran ve video yakalama sunar.',
        'Start een schermafbeelding via Scherm vastleggen in de menubalk of een algemene sneltoets. Pro biedt ook venster-, volledig-scherm- en video-opnamen.',
        'Uruchom zrzut przez Przechwyć ekran na pasku menu lub skrót globalny. Tryb Pro dodaje przechwytywanie okna, pełnego ekranu i nagrywanie wideo.',
        'Почніть знімок через «Захоплення екрана» в рядку меню або глобальне сполучення клавіш. Pro також пропонує захоплення вікна, всього екрана й запис відео.',
        'Starta en skärmbild via Fånga skärm i menyraden eller ett globalt kortkommando. Pro erbjuder även fönster, helskärm och videoinspelning.',
    ],
    '原始音频、视频、图片与导出文件不额外加密，请妥善保护数据文件夹。': [
        '原始音訊、影片、圖片與匯出檔案不另行加密，請妥善保護資料資料夾。',
        'Original audio, video, images and exported files are not additionally encrypted. Protect your data folder.',
        '元の音声・動画・画像と書き出したファイルには追加の暗号化を行いません。データフォルダを適切に保護してください。',
        '원본 오디오, 동영상, 이미지 및 내보낸 파일은 별도로 암호화되지 않습니다. 데이터 폴더를 안전하게 보호하세요.',
        'Les fichiers audio, vidéo, images d’origine et fichiers exportés ne sont pas chiffrés en plus. Protégez votre dossier de données.',
        'Originale Audio-, Video- und Bilddateien sowie Exporte werden nicht zusätzlich verschlüsselt. Schützen Sie Ihren Datenordner.',
        'El audio, vídeo e imágenes originales y los archivos exportados no tienen cifrado adicional. Protege la carpeta de datos.',
        'Audio, video e immagini originali e file esportati non vengono ulteriormente crittografati. Proteggi la cartella dei dati.',
        'Áudio, vídeo, imagens originais e ficheiros exportados não têm encriptação adicional. Proteja a pasta de dados.',
        'Исходные аудио, видео, изображения и экспортированные файлы дополнительно не шифруются. Защитите папку данных.',
        'لا تُشفّر ملفات الصوت والفيديو والصور الأصلية والملفات المصدّرة تشفيرًا إضافيًا. احمِ مجلد بياناتك.',
        'मूल ऑडियो, वीडियो, चित्र और निर्यात की गई फ़ाइलों पर अतिरिक्त एन्क्रिप्शन नहीं होता। अपने डेटा फ़ोल्डर को सुरक्षित रखें।',
        'ไฟล์เสียง วิดีโอ รูปภาพต้นฉบับ และไฟล์ที่ส่งออกไม่มีการเข้ารหัสเพิ่มเติม โปรดปกป้องโฟลเดอร์ข้อมูลของคุณ',
        'Âm thanh, video, ảnh gốc và tệp xuất không được mã hóa thêm. Hãy bảo vệ thư mục dữ liệu của bạn.',
        'Audio, video, gambar asli, dan file ekspor tidak dienkripsi tambahan. Lindungi folder data Anda.',
        'Özgün ses, video, görseller ve dışa aktarılan dosyalar ayrıca şifrelenmez. Veri klasörünüzü koruyun.',
        'Oorspronkelijke audio, video, afbeeldingen en geëxporteerde bestanden worden niet extra versleuteld. Bescherm uw gegevensmap.',
        'Oryginalne pliki audio, wideo, obrazy i pliki eksportu nie są dodatkowo szyfrowane. Chroń folder danych.',
        'Вихідні аудіо, відео, зображення й експортовані файли додатково не шифруються. Захистіть папку даних.',
        'Ursprungligt ljud, video, bilder och exporterade filer krypteras inte ytterligare. Skydda din datamapp.',
    ],
    '云端文本请求会先在本机去标识化；音频、截图和视频帧不做文本脱敏。': [
        '雲端文字請求會先在本機去識別化；音訊、截圖與影片影格不進行文字去識別化。',
        'Cloud text requests are de-identified locally first. Audio, screenshots and video frames do not receive text redaction.',
        'クラウドへのテキスト送信前に本機で識別情報を置換します。音声・スクリーンショット・動画フレームにはテキスト匿名化を行いません。',
        '클라우드 텍스트 요청은 먼저 기기에서 비식별화됩니다. 오디오, 스크린샷, 동영상 프레임에는 텍스트 비식별화를 적용하지 않습니다.',
        'Les requêtes textuelles cloud sont d’abord désidentifiées localement. L’audio, les captures et les images vidéo ne bénéficient pas de masquage textuel.',
        'Cloud-Textanfragen werden zunächst lokal de-identifiziert. Audio, Screenshots und Videoframes erhalten keine Textschwärzung.',
        'El texto enviado a la nube se desidentifica primero en el dispositivo. El audio, las capturas y los fotogramas no reciben ocultación de texto.',
        'Il testo inviato al cloud viene prima de-identificato in locale. Audio, schermate e fotogrammi non ricevono oscuramento del testo.',
        'O texto enviado à nuvem é primeiro desidentificado localmente. Áudio, capturas e fotogramas não recebem ocultação de texto.',
        'Текстовые запросы в облако сначала обезличиваются локально. Для аудио, снимков экрана и видеокадров текстовая маскировка не выполняется.',
        'تُزال البيانات المُعرِّفة من الطلبات النصية السحابية محليًا أولًا. ولا يُطبّق تنقيح النص على الصوت أو لقطات الشاشة أو إطارات الفيديو.',
        'क्लाउड पर भेजे जाने वाले टेक्स्ट से पहले डिवाइस पर पहचान संबंधी जानकारी हटाई जाती है। ऑडियो, स्क्रीनशॉट और वीडियो फ़्रेम पर टेक्स्ट रिडैक्शन लागू नहीं होता।',
        'คำขอข้อความไปยังคลาวด์จะถูกแทนที่ข้อมูลระบุตัวตนในเครื่องก่อน เสียง ภาพหน้าจอ และเฟรมวิดีโอจะไม่ผ่านการปกปิดข้อความ',
        'Văn bản gửi lên đám mây được khử định danh trên máy trước. Âm thanh, ảnh chụp màn hình và khung hình video không được che thông tin dạng chữ.',
        'Permintaan teks cloud dideidentifikasi secara lokal terlebih dahulu. Audio, tangkapan layar, dan bingkai video tidak mendapat penyamaran teks.',
        'Buluta gönderilen metinler önce cihazda kimliksizleştirilir. Ses, ekran görüntüleri ve video karelerine metin gizleme uygulanmaz.',
        'Tekstverzoeken aan de cloud worden eerst lokaal gedeïdentificeerd. Audio, schermafbeeldingen en videoframes krijgen geen tekstredactie.',
        'Tekst wysyłany do chmury jest najpierw deidentyfikowany lokalnie. Dźwięk, zrzuty ekranu i klatki wideo nie są poddawane maskowaniu tekstu.',
        'Текстові запити до хмари спочатку знеособлюються локально. Для аудіо, знімків екрана й відеокадрів текстове маскування не виконується.',
        'Textförfrågningar till molnet avidentifieras först lokalt. Ljud, skärmbilder och videobildrutor får ingen textmaskering.',
    ],
    '可在「设置 → 关于」检查更新；安装须确认，录音或处理任务进行中会延后。': [
        '可在「設定 → 關於」檢查更新；安裝須確認，錄音或處理工作進行中會延後。',
        'Check for updates in Settings → About. Installation requires confirmation and is deferred while recording or processing tasks are active.',
        '「設定 → このアプリについて」で更新を確認できます。インストールには確認が必要で、録音や処理中は延期されます。',
        '설정 → 정보에서 업데이트를 확인하세요. 설치에는 확인이 필요하며 녹음 또는 처리 작업 중에는 연기됩니다.',
        'Vérifiez les mises à jour dans Réglages → À propos. L’installation nécessite une confirmation et est différée pendant un enregistrement ou un traitement.',
        'Suchen Sie unter Einstellungen → Über nach Updates. Die Installation erfordert eine Bestätigung und wird während Aufnahmen oder Verarbeitungen verschoben.',
        'Busca actualizaciones en Ajustes → Acerca de. La instalación requiere confirmación y se aplaza durante grabaciones o tareas de procesamiento.',
        'Controlla gli aggiornamenti in Impostazioni → Info. L’installazione richiede conferma ed è rimandata durante registrazioni o elaborazioni.',
        'Procure atualizações em Definições → Sobre. A instalação exige confirmação e é adiada durante gravações ou tarefas de processamento.',
        'Проверяйте обновления в «Настройки → Об приложении». Установка требует подтверждения и откладывается во время записи или обработки.',
        'تحقق من التحديثات في الإعدادات ← حول. يتطلب التثبيت تأكيدًا ويؤجَّل أثناء التسجيل أو مهام المعالجة.',
        'सेटिंग्स → बारे में में अपडेट जाँचें। इंस्टॉलेशन के लिए पुष्टि आवश्यक है और रिकॉर्डिंग या प्रोसेसिंग के दौरान इसे टाल दिया जाता है।',
        'ตรวจสอบการอัปเดตได้ใน การตั้งค่า → เกี่ยวกับ การติดตั้งต้องได้รับการยืนยันและจะเลื่อนออกไปขณะบันทึกหรือประมวลผล',
        'Kiểm tra cập nhật tại Cài đặt → Giới thiệu. Cài đặt cần xác nhận và sẽ hoãn khi đang ghi hoặc xử lý tác vụ.',
        'Periksa pembaruan di Pengaturan → Tentang. Instalasi memerlukan konfirmasi dan ditunda selama perekaman atau pemrosesan berlangsung.',
        'Ayarlar → Hakkında bölümünden güncellemeleri denetleyin. Kurulum onay gerektirir; kayıt veya işleme sürerken ertelenir.',
        'Controleer op updates via Instellingen → Info. Installatie vereist bevestiging en wordt uitgesteld tijdens opnemen of verwerken.',
        'Sprawdź aktualizacje w Ustawienia → Informacje. Instalacja wymaga potwierdzenia i jest odkładana podczas nagrywania lub przetwarzania.',
        'Перевіряйте оновлення в «Параметри → Про програму». Встановлення потребує підтвердження й відкладається під час запису або обробки.',
        'Sök efter uppdateringar i Inställningar → Om. Installationen kräver bekräftelse och skjuts upp under inspelning eller bearbetning.',
    ],
    '菜单栏使用「截图框 + 麦克风文稿」图标，可控制录音、捕获屏幕和显示主窗口。共享屏幕时可隐藏主窗口与 Dock 图标。': [
        '選單列使用「截圖框 + 麥克風文稿」圖示，可控制錄音、擷取螢幕和顯示主視窗。共享螢幕時可隱藏主視窗與 Dock 圖示。',
        'Use the capture-frame, microphone and transcript icon in the menu bar to control recording, capture the screen or show the main window. Hide the main window and Dock icon while sharing your screen.',
        'メニューバーのキャプチャ枠・マイク・文書アイコンから録音、画面キャプチャ、メインウインドウの表示を操作できます。画面共有中はメインウインドウとDockアイコンを隠せます。',
        '메뉴 막대의 캡처 프레임·마이크·문서 아이콘으로 녹음, 화면 캡처, 기본 창 표시를 제어하세요. 화면 공유 중에는 기본 창과 Dock 아이콘을 숨길 수 있습니다.',
        'L’icône cadre de capture, microphone et document permet de contrôler l’enregistrement, capturer l’écran ou afficher la fenêtre principale. Masquez la fenêtre et l’icône du Dock pendant le partage d’écran.',
        'Über das Menüleistensymbol mit Aufnahmerahmen, Mikrofon und Dokument steuern Sie Aufnahmen, erfassen den Bildschirm und öffnen das Hauptfenster. Bei Bildschirmfreigaben können Sie Hauptfenster und Dock-Symbol ausblenden.',
        'El icono de marco de captura, micrófono y documento de la barra de menús permite controlar grabaciones, capturar la pantalla y mostrar la ventana principal. Puedes ocultar la ventana y el icono del Dock al compartir pantalla.',
        'L’icona con cornice, microfono e documento nella barra dei menu controlla registrazione, cattura dello schermo e finestra principale. Durante la condivisione puoi nascondere la finestra e l’icona del Dock.',
        'O ícone de moldura, microfone e documento na barra de menus controla gravações, capturas e a janela principal. Pode ocultar a janela e o ícone do Dock ao partilhar o ecrã.',
        'Значок рамки захвата, микрофона и документа в строке меню позволяет управлять записью, захватывать экран и открывать главное окно. При демонстрации экрана можно скрыть окно и значок Dock.',
        'استخدم أيقونة إطار الالتقاط والميكروفون والمستند في شريط القوائم للتحكم بالتسجيل والتقاط الشاشة وإظهار النافذة الرئيسية. ويمكن إخفاء النافذة وأيقونة Dock عند مشاركة الشاشة.',
        'मेन्यू बार के कैप्चर फ़्रेम, माइक्रोफ़ोन और दस्तावेज़ वाले आइकन से रिकॉर्डिंग, स्क्रीन कैप्चर और मुख्य विंडो नियंत्रित करें। स्क्रीन शेयर करते समय मुख्य विंडो और Dock आइकन छिपा सकते हैं।',
        'ใช้ไอคอนกรอบจับภาพ ไมโครโฟน และเอกสารในแถบเมนูเพื่อควบคุมการบันทึก จับภาพหน้าจอ หรือแสดงหน้าต่างหลัก ขณะแชร์หน้าจอสามารถซ่อนหน้าต่างหลักและไอคอน Dock ได้',
        'Dùng biểu tượng khung chụp, micrô và tài liệu trên thanh menu để điều khiển ghi, chụp màn hình hoặc mở cửa sổ chính. Có thể ẩn cửa sổ chính và biểu tượng Dock khi chia sẻ màn hình.',
        'Gunakan ikon bingkai tangkapan, mikrofon, dan dokumen di bilah menu untuk mengontrol perekaman, menangkap layar, atau menampilkan jendela utama. Sembunyikan jendela dan ikon Dock saat berbagi layar.',
        'Menü çubuğundaki yakalama çerçevesi, mikrofon ve belge simgesiyle kaydı, ekran yakalamayı ve ana pencereyi yönetin. Ekran paylaşırken ana pencereyi ve Dock simgesini gizleyebilirsiniz.',
        'Gebruik het menubalksymbool met opnamekader, microfoon en document om opnamen te bedienen, het scherm vast te leggen of het hoofdvenster te openen. Verberg het hoofdvenster en Dock-symbool tijdens schermdeling.',
        'Ikona ramki przechwytywania, mikrofonu i dokumentu na pasku menu pozwala sterować nagrywaniem, przechwytywać ekran i otwierać główne okno. Podczas udostępniania ekranu możesz ukryć okno i ikonę Docka.',
        'Значок рамки захоплення, мікрофона й документа в рядку меню дає змогу керувати записом, захоплювати екран і відкривати головне вікно. Під час демонстрації можна приховати вікно й значок Dock.',
        'Använd menyradens symbol med fångstram, mikrofon och dokument för inspelning, skärmfångst och huvudfönstret. Dölj huvudfönstret och Dock-symbolen vid skärmdelning.',
    ],
    '默认在本机录音和转写。总结与待办由你配置的智能服务生成；使用云端服务会发送相应内容。': [
        '預設在本機錄音和轉寫。總結與待辦由你設定的智慧服務產生；使用雲端服務會傳送對應內容。',
        'Recording and transcription run locally by default. Your configured AI service generates summaries and to-dos; using a cloud service sends the relevant content to it.',
        '録音と文字起こしは標準で本機上で行います。要約とToDoは設定したAIサービスが生成します。クラウドサービスを使う場合は対象の内容を送信します。',
        '기본적으로 기기에서 녹음하고 전사합니다. 요약과 할 일은 설정한 AI 서비스가 생성하며, 클라우드 서비스를 사용하면 해당 콘텐츠가 전송됩니다.',
        'L’enregistrement et la transcription sont locaux par défaut. Le service d’IA configuré génère résumés et tâches ; un service cloud reçoit le contenu concerné.',
        'Aufnahme und Transkription erfolgen standardmäßig lokal. Ihr konfigurierter KI-Dienst erstellt Zusammenfassungen und Aufgaben; bei einem Cloud-Dienst werden die betreffenden Inhalte übertragen.',
        'La grabación y transcripción se ejecutan localmente por defecto. El servicio de IA configurado genera resúmenes y tareas; si usas la nube, se envía el contenido correspondiente.',
        'Registrazione e trascrizione avvengono in locale per default. Il servizio IA configurato genera riepiloghi e attività; usando il cloud viene inviato il contenuto pertinente.',
        'A gravação e transcrição são locais por predefinição. O serviço de IA configurado gera resumos e tarefas; ao usar a nuvem, o conteúdo relevante é enviado.',
        'Запись и расшифровка по умолчанию выполняются локально. Настроенный ИИ-сервис создаёт резюме и задачи; при использовании облака ему передаётся соответствующее содержимое.',
        'يعمل التسجيل والتفريغ محليًا افتراضيًا. وتنشئ خدمة الذكاء الاصطناعي التي تضبطها الملخصات والمهام؛ وعند استخدام خدمة سحابية يُرسل إليها المحتوى المعني.',
        'रिकॉर्डिंग और ट्रांसक्रिप्शन डिफ़ॉल्ट रूप से डिवाइस पर होते हैं। आपके कॉन्फ़िगर किए गए AI सेवा से सारांश और कार्य बनते हैं; क्लाउड सेवा उपयोग करने पर संबंधित सामग्री भेजी जाती है।',
        'การบันทึกและถอดเสียงทำในเครื่องเป็นค่าเริ่มต้น บริการ AI ที่คุณตั้งค่าไว้จะสร้างสรุปและงาน โดยจะส่งเนื้อหาที่เกี่ยวข้องเมื่อใช้บริการคลาวด์',
        'Ghi âm và phiên âm mặc định chạy trên máy. Dịch vụ AI bạn cấu hình tạo tóm tắt và việc cần làm; khi dùng đám mây, nội dung liên quan sẽ được gửi đi.',
        'Perekaman dan transkripsi berjalan lokal secara default. Layanan AI yang Anda konfigurasikan membuat ringkasan dan tugas; layanan cloud menerima konten terkait.',
        'Kayıt ve transkripsiyon varsayılan olarak cihazda çalışır. Yapılandırdığınız yapay zekâ hizmeti özet ve görevler üretir; bulut hizmeti kullanıldığında ilgili içerik gönderilir.',
        'Opnemen en transcriberen gebeurt standaard lokaal. De ingestelde AI-dienst maakt samenvattingen en taken; bij een clouddienst wordt de betreffende inhoud verzonden.',
        'Nagrywanie i transkrypcja są domyślnie lokalne. Skonfigurowana usługa AI tworzy podsumowania i zadania; przy korzystaniu z chmury wysyłana jest odpowiednia treść.',
        'Запис і транскрипція типово виконуються локально. Налаштований ШІ-сервіс створює підсумки й завдання; під час використання хмари йому надсилається відповідний вміст.',
        'Inspelning och transkribering körs lokalt som standard. Din konfigurerade AI-tjänst skapar sammanfattningar och uppgifter; med en molntjänst skickas det relevanta innehållet dit.',
    ],
    '需单独同意后才能注册和比对声纹。声纹仅保存在本机，可在「设置 → 声纹库」删除。': [
        '需單獨同意後才能註冊和比對聲紋。聲紋僅保存在本機，可在「設定 → 聲紋庫」刪除。',
        'Registering and matching voiceprints requires separate consent. Voiceprints stay on this Mac and can be deleted in Settings → Voiceprint Library.',
        '声紋の登録と照合には個別の同意が必要です。声紋は本機にのみ保存され、「設定 → 声紋ライブラリ」で削除できます。',
        '음성 지문 등록과 대조에는 별도 동의가 필요합니다. 음성 지문은 이 기기에만 저장되며 설정 → 음성 지문 라이브러리에서 삭제할 수 있습니다.',
        'L’enregistrement et la comparaison des empreintes vocales nécessitent un consentement distinct. Elles restent sur ce Mac et se suppriment dans Réglages → Bibliothèque vocale.',
        'Für das Registrieren und Abgleichen von Stimmprofilen ist eine gesonderte Einwilligung nötig. Sie bleiben auf diesem Mac und lassen sich unter Einstellungen → Stimmprofilbibliothek löschen.',
        'Registrar y comparar huellas de voz requiere consentimiento separado. Se guardan solo en este Mac y se eliminan en Ajustes → Biblioteca de voces.',
        'Registrazione e confronto delle impronte vocali richiedono un consenso separato. Restano su questo Mac e si eliminano in Impostazioni → Libreria vocale.',
        'Registar e comparar impressões vocais exige consentimento separado. Ficam neste Mac e podem ser apagadas em Definições → Biblioteca de vozes.',
        'Для регистрации и сравнения голосовых отпечатков нужно отдельное согласие. Они хранятся только на этом Mac; удалить их можно в «Настройки → Библиотека голосов».',
        'يتطلب تسجيل البصمات الصوتية ومطابقتها موافقة منفصلة. وتبقى على هذا الـ Mac ويمكن حذفها من الإعدادات ← مكتبة البصمات الصوتية.',
        'वॉयसप्रिंट पंजीकरण और मिलान के लिए अलग सहमति चाहिए। वॉयसप्रिंट केवल इस Mac पर रहते हैं और सेटिंग्स → वॉयसप्रिंट लाइब्रेरी से हटाए जा सकते हैं।',
        'การลงทะเบียนและเปรียบเทียบลายเสียงต้องได้รับความยินยอมแยก ลายเสียงเก็บเฉพาะใน Mac นี้และลบได้ที่ การตั้งค่า → คลังลายเสียง',
        'Đăng ký và đối chiếu dấu vân giọng nói cần đồng ý riêng. Dữ liệu chỉ lưu trên máy Mac này và có thể xóa tại Cài đặt → Thư viện giọng nói.',
        'Pendaftaran dan pencocokan sidik suara memerlukan persetujuan terpisah. Sidik suara hanya disimpan di Mac ini dan dapat dihapus di Pengaturan → Pustaka Sidik Suara.',
        'Ses izi kaydı ve eşleştirmesi ayrı onay gerektirir. Ses izleri yalnızca bu Mac’te saklanır; Ayarlar → Ses İzi Kitaplığı’ndan silinebilir.',
        'Voor het registreren en vergelijken van stemprofielen is aparte toestemming nodig. Ze blijven op deze Mac en kunnen worden verwijderd via Instellingen → Stemprofielbibliotheek.',
        'Rejestrowanie i porównywanie odcisków głosu wymaga osobnej zgody. Pozostają na tym Macu i można je usunąć w Ustawienia → Biblioteka głosów.',
        'Для реєстрації та зіставлення голосових відбитків потрібна окрема згода. Вони зберігаються лише на цьому Mac; видалити їх можна в «Параметри → Бібліотека голосів».',
        'Registrering och matchning av röstavtryck kräver separat samtycke. De sparas bara på denna Mac och kan tas bort i Inställningar → Röstbibliotek.',
    ],
}


def main():
    catalog = json.loads(CATALOG.read_text())
    for key, values in TRANSLATIONS.items():
        assert len(values) == len(LANGS), (key, len(values))
        localizations = {'zh-Hans': {'stringUnit': {'state': 'translated', 'value': key}}}
        for lang, value in zip(LANGS, values):
            assert value.strip(), (key, lang)
            localizations[lang] = {'stringUnit': {'state': 'translated', 'value': value}}
        catalog['strings'][key] = {'localizations': dict(sorted(localizations.items()))}
    # Checkbox glyphs are language-independent labels, not untranslated prose.
    for key in ('☐', '☑'):
        catalog['strings'][key] = {'localizations': {
            lang: {'stringUnit': {'state': 'translated', 'value': key}}
            for lang in sorted(['zh-Hans'] + LANGS)
        }}
    raw = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(',', ' : '))
    lines = []
    for line in raw.split('\n'):
        match = re.match(r'^(\s*)"([^"]*)" : \{\}(,?)$', line)
        if match:
            indent, key, comma = match.groups()
            lines.extend([f'{indent}"{key}" : {{', '', f'{indent}}}{comma}'])
        else:
            lines.append(line)
    CATALOG.write_text('\n'.join(lines))
    print(f'Updated {len(TRANSLATIONS)} messages in 21 languages; completed 2 language-independent glyphs.')


if __name__ == '__main__':
    main()
