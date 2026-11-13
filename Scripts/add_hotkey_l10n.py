#!/usr/bin/env python3
# 全局热键录制提示与失败原因文案（20 种语言）
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('请按下新的组合键（功能键 F1–F20 可单独使用，其余需包含 ⌘/⌥/⌃ 中至少一个修饰键），按 Esc 取消', [
    '請按下新的組合鍵（功能鍵 F1–F20 可單獨使用，其餘需包含 ⌘/⌥/⌃ 中至少一個修飾鍵），按 Esc 取消',
    'Press a new key combination (function keys F1–F20 can be used alone; otherwise at least one of ⌘/⌥/⌃ is required), press Esc to cancel',
    '新しい組み合わせを押してください（ファンクションキー F1〜F20 は単独で使用可能。それ以外は ⌘/⌥/⌃ のいずれか1つ以上が必要）。Esc でキャンセル',
    '새 조합을 누르세요(기능 키 F1–F20은 단독 사용 가능, 그 외에는 ⌘/⌥/⌃ 중 하나 이상 필요), Esc를 눌러 취소',
    'Appuyez sur une nouvelle combinaison (les touches de fonction F1–F20 peuvent être utilisées seules ; sinon au moins ⌘/⌥/⌃ est requis), appuyez sur Esc pour annuler',
    'Drücken Sie eine neue Tastenkombination (Funktionstasten F1–F20 können allein verwendet werden, sonst ist mindestens ⌘/⌥/⌃ erforderlich), Esc zum Abbrechen',
    'Pulse una nueva combinación (las teclas de función F1–F20 pueden usarse solas; en caso contrario se requiere al menos ⌘/⌥/⌃), pulse Esc para cancelar',
    "Premi una nuova combinazione (i tasti funzione F1–F20 possono essere usati da soli; altrimenti serve almeno ⌘/⌥/⌃), premi Esc per annullare",
    'Pressione uma nova combinação (as teclas de função F1–F20 podem ser usadas sozinhas; caso contrário, é necessário ao menos ⌘/⌥/⌃), pressione Esc para cancelar',
    'Нажмите новую комбинацию (функциональные клавиши F1–F20 можно использовать отдельно, иначе нужна хотя бы одна из ⌘/⌥/⌃), нажмите Esc для отмены',
    'اضغط تركيبة جديدة (يمكن استخدام مفاتيح الوظائف F1–F20 وحدها، وإلا يجب أن تتضمن ⌘/⌥/⌃ واحدة على الأقل)، اضغط Esc للإلغاء',
    'नया कुंजी संयोजन दबाएँ (फ़ंक्शन कुंजियाँ F1–F20 अकेले उपयोग की जा सकती हैं, अन्यथा कम से कम ⌘/⌥/⌃ में से एक आवश्यक है), रद्द करने के लिए Esc दबाएँ',
    'กดคีย์ผสมใหม่ (ปุ่มฟังก์ชัน F1–F20 ใช้เดี่ยวได้ นอกนั้นต้องมี ⌘/⌥/⌃ อย่างน้อยหนึ่งตัว) กด Esc เพื่อยกเลิก',
    'Nhấn tổ hợp phím mới (phím chức năng F1–F20 có thể dùng riêng, ngoài ra phải gồm ít nhất một trong ⌘/⌥/⌃), nhấn Esc để hủy',
    'Tekan kombinasi baru (tombol fungsi F1–F20 dapat digunakan sendiri, selain itu harus memuat setidaknya salah satu ⌘/⌥/⌃), tekan Esc untuk batal',
    "Yeni bir tuş kombinasyonuna basın (F1–F20 fonksiyon tuşları tek başına kullanılabilir; diğerleri en az bir ⌘/⌥/⌃ içermelidir), iptal için Esc'ye basın",
    'Druk een nieuwe toetscombinatie (functietoetsen F1–F20 kunnen alleen worden gebruikt, anders is minstens één van ⌘/⌥/⌃ vereist), druk op Esc om te annuleren',
    'Naciśnij nową kombinację (klawisze funkcyjne F1–F20 mogą być używane samodzielnie, w innym przypadku wymagany jest co najmniej jeden z ⌘/⌥/⌃), naciśnij Esc, aby anulować',
    'Натисніть нову комбінацію (функціональні клавіші F1–F20 можна використовувати окремо, інакше потрібна принаймні одна з ⌘/⌥/⌃), натисніть Esc для скасування',
    'Tryck en ny tangentkombination (funktionstangenterna F1–F20 kan användas ensamma, annars krävs minst en av ⌘/⌥/⌃), tryck Esc för att avbryta',
])

add('该组合键已被 Memozia 的另一条热键占用，请换一个组合键。', [
    '該組合鍵已被 Memozia 的另一條熱鍵占用，請換一個組合鍵。',
    'This key combination is already used by another Memozia hotkey. Please choose a different one.',
    'この組み合わせは Memozia の別のホットキーで使用されています。別の組み合わせを選んでください。',
    '이 조합은 Memozia의 다른 단축키에서 사용 중입니다. 다른 조합을 선택하세요.',
    'Cette combinaison est déjà utilisée par un autre raccourci de Memozia. Veuillez en choisir une autre.',
    'Diese Tastenkombination wird bereits von einem anderen Memozia-Kürzel verwendet. Bitte wählen Sie eine andere.',
    'Esta combinación ya la usa otro atajo de Memozia. Elija otra.',
    "Questa combinazione è già usata da un altro tasto di scelta rapida di Memozia. Scegline un'altra.",
    'Esta combinação já é usada por outro atalho do Memozia. Escolha outra.',
    'Эта комбинация уже используется другим сочетанием Memozia. Выберите другую.',
    'هذه التركيبة مستخدمة بالفعل في اختصار آخر في Memozia. اختر تركيبة أخرى.',
    'यह संयोजन Memozia के किसी अन्य हॉटकी द्वारा उपयोग में है। कोई दूसरा संयोजन चुनें।',
    'คีย์ผสมนี้ถูกใช้โดยฮอตคีย์อื่นของ Memozia แล้ว โปรดเลือกคีย์ผสมอื่น',
    'Tổ hợp này đã được một phím tắt khác của Memozia sử dụng. Vui lòng chọn tổ hợp khác.',
    'Kombinasi ini sudah digunakan hotkey Memozia lainnya. Silakan pilih kombinasi lain.',
    "Bu kombinasyon Memozia'nun başka bir kısayolu tarafından kullanılıyor. Lütfen başka bir kombinasyon seçin.",
    'Deze combinatie wordt al gebruikt door een andere Memozia-sneltoets. Kies een andere.',
    'Ta kombinacja jest już używana przez inny skrót Memozia. Wybierz inną.',
    'Ця комбінація вже використовується іншим сполученням Memozia. Виберіть інше.',
    'Den här kombinationen används redan av en annan Memozia-snabbkommando. Välj en annan.',
])

add('⌃⌘F 是系统「进入全屏幕」的快捷键，不能用作全局热键，请换一个组合键。', [
    '⌃⌘F 是系統「進入全螢幕」的快速鍵，不能用作全域熱鍵，請換一個組合鍵。',
    '⌃⌘F is the system shortcut for Enter Full Screen and cannot be used as a global hotkey. Please choose a different one.',
    '⌃⌘F はシステムの「フルスクリーンにする」ショートカットのため、グローバルホットキーには使用できません。別の組み合わせを選んでください。',
    "⌃⌘F는 시스템의 '전체 화면 시작' 단축키이므로 전역 단축키로 사용할 수 없습니다. 다른 조합을 선택하세요.",
    '⌃⌘F est le raccourci système « Passer en plein écran » et ne peut pas servir de raccourci global. Veuillez en choisir un autre.',
    '⌃⌘F ist das System-Kürzel „Vollbild einblenden“ und kann nicht als globales Tastenkürzel verwendet werden. Bitte wählen Sie eine andere Kombination.',
    '⌃⌘F es el atajo del sistema para «Entrar en pantalla completa» y no puede usarse como atajo global. Elija otra combinación.',
    "⌃⌘F è la scorciatoia di sistema «Attiva schermo intero» e non può essere usata come scorciatoia globale. Scegli un'altra combinazione.",
    '⌃⌘F é o atalho do sistema "Entrar em Tela Cheia" e não pode ser usado como atalho global. Escolha outra combinação.',
    '⌃⌘F — системное сочетание «Перейти в полноэкранный режим», его нельзя использовать как глобальное. Выберите другое сочетание.',
    '⌃⌘F هو اختصار النظام «الدخول إلى ملء الشاشة» ولا يمكن استخدامه كاختصار عام. اختر تركيبة أخرى.',
    '⌃⌘F सिस्टम का «पूर्ण स्क्रीन में जाएँ» शॉर्टकट है और इसे ग्लोबल हॉटकी के रूप में उपयोग नहीं किया जा सकता। कोई दूसरा संयोजन चुनें।',
    '⌃⌘F เป็นทางลัดของระบบ «เข้าสู่โหมดเต็มหน้าจอ» จึงใช้เป็นฮอตคีย์ส่วนกลางไม่ได้ โปรดเลือกคีย์ผสมอื่น',
    '⌃⌘F là phím tắt hệ thống «Vào toàn màn hình» nên không thể dùng làm phím tắt toàn cục. Vui lòng chọn tổ hợp khác.',
    '⌃⌘F adalah pintasan sistem «Masuk Layar Penuh» dan tidak dapat digunakan sebagai hotkey global. Silakan pilih kombinasi lain.',
    '⌃⌘F, sistemin «Tam Ekrana Geç» kısayoludur ve genel kısayol olarak kullanılamaz. Lütfen başka bir kombinasyon seçin.',
    "⌃⌘F is de systeemsneltoets 'Volledig scherm' en kan niet als algemene sneltoets worden gebruikt. Kies een andere combinatie.",
    '⌃⌘F to skrót systemowy „Przejdź w tryb pełnoekranowy” i nie może być używany jako skrót globalny. Wybierz inną kombinację.',
    '⌃⌘F — системне сполучення «Перейти на весь екран», його не можна використовувати як глобальне. Виберіть інше сполучення.',
    '⌃⌘F är systemgenvägen "Gå in i helskärm" och kan inte användas som global snabbkommando. Välj en annan kombination.',
])

add('该组合键不可注册：除功能键 F1–F20 外，需包含 ⌘/⌥/⌃ 中至少一个修饰键。', [
    '該組合鍵無法註冊：除功能鍵 F1–F20 外，需包含 ⌘/⌥/⌃ 中至少一個修飾鍵。',
    "This key combination can't be registered: apart from function keys F1–F20, at least one of ⌘/⌥/⌃ is required.",
    'この組み合わせは登録できません。ファンクションキー F1〜F20 以外は ⌘/⌥/⌃ のいずれか1つ以上が必要です。',
    '이 조합은 등록할 수 없습니다. 기능 키 F1–F20 외에는 ⌘/⌥/⌃ 중 하나 이상이 필요합니다.',
    'Cette combinaison ne peut pas être enregistrée : hormis les touches de fonction F1–F20, au moins ⌘/⌥/⌃ est requis.',
    'Diese Tastenkombination kann nicht registriert werden: außer bei den Funktionstasten F1–F20 ist mindestens ⌘/⌥/⌃ erforderlich.',
    'Esta combinación no se puede registrar: salvo las teclas de función F1–F20, se requiere al menos ⌘/⌥/⌃.',
    'Questa combinazione non può essere registrata: a parte i tasti funzione F1–F20, serve almeno ⌘/⌥/⌃.',
    'Esta combinação não pode ser registrada: exceto pelas teclas de função F1–F20, é necessário ao menos ⌘/⌥/⌃.',
    'Это сочетание нельзя зарегистрировать: кроме функциональных клавиш F1–F20, требуется хотя бы одна из ⌘/⌥/⌃.',
    'لا يمكن تسجيل هذه التركيبة: بخلاف مفاتيح الوظائف F1–F20، يجب تضمين ⌘/⌥/⌃ واحدة على الأقل.',
    'यह संयोजन पंजीकृत नहीं किया जा सकता: फ़ंक्शन कुंजियों F1–F20 के अलावा कम से कम ⌘/⌥/⌃ में से एक आवश्यक है।',
    'คีย์ผสมนี้ลงทะเบียนไม่ได้ นอกเหนือจากปุ่มฟังก์ชัน F1–F20 ต้องมี ⌘/⌥/⌃ อย่างน้อยหนึ่งตัว',
    'Không thể đăng ký tổ hợp này: ngoài các phím chức năng F1–F20, cần có ít nhất một trong ⌘/⌥/⌃.',
    'Kombinasi ini tidak dapat didaftarkan: selain tombol fungsi F1–F20, perlu setidaknya salah satu ⌘/⌥/⌃.',
    'Bu kombinasyon kaydedilemez: F1–F20 fonksiyon tuşları dışında en az bir ⌘/⌥/⌃ gereklidir.',
    'Deze combinatie kan niet worden geregistreerd: naast functietoetsen F1–F20 is minstens één van ⌘/⌥/⌃ vereist.',
    'Tej kombinacji nie można zarejestrować: poza klawiszami funkcyjnymi F1–F20 wymagany jest co najmniej jeden z ⌘/⌥/⌃.',
    'Цю комбінацію не можна зареєструвати: окрім функціональних клавіш F1–F20, потрібна принаймні одна з ⌘/⌥/⌃.',
    'Den här kombinationen kan inte registreras: förutom funktionstangenterna F1–F20 krävs minst en av ⌘/⌥/⌃.',
])


# 9.1.0：全局热键独立成「设置 → 热键」页 + 新增录音热键（默认 ⌃⌘R，冲突回退 ⇧⌃⌘R）
add('热键', [
    '熱鍵',
    'Hotkeys',
    'ホットキー',
    '단축키',
    'Raccourcis',
    'Tastenkürzel',
    'Atajos',
    'Scorciatoie',
    'Atalhos',
    'Горячие клавиши',
    'مفاتيح الاختصار',
    'हॉटकी',
    'ฮอตคีย์',
    'Phím tắt',
    'Hotkey',
    'Kısayollar',
    'Sneltoetsen',
    'Skróty',
    'Гарячі клавіші',
    'Snabbtangenter',
])

add('录音热键', [
    '錄音熱鍵',
    'Recording Hotkey',
    '録音ホットキー',
    '녹음 단축키',
    "Raccourci d'enregistrement",
    'Aufnahme-Tastenkürzel',
    'Atajo de grabación',
    'Scorciatoia di registrazione',
    'Atalho de gravação',
    'Горячая клавиша записи',
    'مفتاح اختصار التسجيل',
    'रिकॉर्डिंग हॉटकी',
    'ฮอตคีย์การบันทึก',
    'Phím tắt ghi âm',
    'Hotkey perekaman',
    'Kayıt kısayolu',
    'Sneltoets voor opnemen',
    'Skrót nagrywania',
    'Гаряча клавіша запису',
    'Snabbtangent för inspelning',
])

add('开始 / 停止会议录音，应用未激活时也可触发', [
    '開始 / 停止會議錄音，應用程式未啟用時也可觸發',
    "Start / stop meeting recording, works even when the app isn't active",
    '会議の録音を開始／停止。アプリが非アクティブでも動作します',
    '회의 녹음을 시작/중지합니다. 앱이 비활성 상태여도 동작합니다',
    "Démarre / arrête l'enregistrement de réunion, même lorsque l'app n'est pas active",
    'Startet / stoppt die Besprechungsaufnahme, auch wenn die App nicht aktiv ist',
    'Inicia / detiene la grabación de la reunión, incluso si la app no está activa',
    "Avvia / arresta la registrazione della riunione, anche quando l'app non è attiva",
    'Inicia / para a gravação da reunião, mesmo quando o app não está ativo',
    'Начать / остановить запись встречи — работает, даже когда приложение неактивно',
    'بدء / إيقاف تسجيل الاجتماع، حتى عندما لا يكون التطبيق نشطًا',
    'मीटिंग रिकॉर्डिंग शुरू / बंद करें, ऐप सक्रिय न होने पर भी काम करता है',
    'เริ่ม / หยุดบันทึกการประชุม ใช้ได้แม้แอปไม่ได้เปิดใช้งานอยู่',
    'Bắt đầu / dừng ghi âm cuộc họp, hoạt động ngay cả khi ứng dụng không ở trạng thái hoạt động',
    'Mulai / hentikan perekaman rapat, tetap berfungsi meski aplikasi tidak aktif',
    'Toplantı kaydını başlatır / durdurur; uygulama etkin değilken de çalışır',
    'Start / stop vergaderingopname, werkt ook als de app niet actief is',
    'Rozpoczyna / zatrzymuje nagrywanie spotkania, działa też gdy aplikacja jest nieaktywna',
    'Почати / зупинити запис зустрічі, працює навіть коли застосунок неактивний',
    'Startar / stoppar mötesinspelning, fungerar även när appen inte är aktiv',
])

# 注意：Key 必须与 HotkeySettingsView 里实际渲染的字符串逐字一致。
# 之前这里注册的是不含「；可点击…」结尾的短句，而视图用的是含该结尾的长句——
# 结果是短句永远用不上（被 Xcode 标成 stale），长句则只有自动抽取的空条目（所有语言都显示中文）
add('录音热键的默认组合 ⌃⌘R 已被其他应用占用，本次已自动改用 ⌃⇧⌘R；可点击「修改热键」自行更换。', [
    '錄音熱鍵的預設組合 ⌃⌘R 已被其他應用程式占用，本次已自動改用 ⌃⇧⌘R；可點擊「修改熱鍵」自行更換。',
    'The default recording hotkey ⌃⌘R is taken by another app, so ⌃⇧⌘R is used instead this time; click "Change Hotkey" to set your own.',
    '録音ホットキーの既定の組み合わせ ⌃⌘R は他のアプリで使用中のため、今回は ⌃⇧⌘R を使用します。「ホットキーを変更」から変更できます。',
    '녹음 단축키의 기본 조합 ⌃⌘R이 다른 앱에서 사용 중이어서 이번에는 ⌃⇧⌘R을 사용합니다. ‘단축키 변경’을 눌러 직접 바꿀 수 있습니다.',
    "La combinaison par défaut ⌃⌘R du raccourci d'enregistrement est utilisée par une autre app ; ⌃⇧⌘R est utilisée à la place cette fois. Cliquez sur « Modifier le raccourci » pour en choisir une autre.",
    'Die Standardkombination ⌃⌘R für das Aufnahme-Kürzel ist von einer anderen App belegt; diesmal wird stattdessen ⌃⇧⌘R verwendet. Klicken Sie auf „Kürzel ändern“, um ein eigenes festzulegen.',
    'La combinación predeterminada ⌃⌘R del atajo de grabación está ocupada por otra app; esta vez se usa ⌃⇧⌘R. Haz clic en «Cambiar atajo» para elegir otra.',
    "La combinazione predefinita ⌃⌘R della scorciatoia di registrazione è occupata da un'altra app; questa volta viene usata ⌃⇧⌘R. Fai clic su «Modifica scorciatoia» per sceglierne un'altra.",
    'A combinação padrão ⌃⌘R do atalho de gravação está em uso por outro app; desta vez é usado ⌃⇧⌘R. Clique em «Alterar atalho» para escolher outra.',
    'Комбинация по умолчанию ⌃⌘R для записи занята другим приложением; в этот раз используется ⌃⇧⌘R. Нажмите «Изменить сочетание», чтобы задать своё.',
    'التركيبة الافتراضية ⌃⌘R لمفتاح اختصار التسجيل مستخدمة في تطبيق آخر؛ لذا سيتم استخدام ⌃⇧⌘R هذه المرة. اضغط «تغيير مفتاح الاختصار» لتعيين تركيبة أخرى.',
    'रिकॉर्डिंग हॉटकी की डिफ़ॉल्ट संयोजन ⌃⌘R किसी अन्य ऐप द्वारा उपयोग में है, इसलिए इस बार ⌃⇧⌘R उपयोग किया जाएगा। अपनी संयोजन चुनने के लिए «हॉटकी बदलें» पर क्लिक करें।',
    'คีย์ผสมเริ่มต้น ⌃⌘R ของฮอตคีย์บันทึกถูกแอปอื่นใช้อยู่ ครั้งนี้จึงใช้ ⌃⇧⌘R แทน คลิก «เปลี่ยนฮอตคีย์» เพื่อกำหนดเอง',
    'Tổ hợp mặc định ⌃⌘R của phím tắt ghi âm đang bị ứng dụng khác chiếm, nên lần này dùng ⌃⇧⌘R thay thế. Nhấn «Đổi phím tắt» để tự đặt tổ hợp khác.',
    'Kombinasi default ⌃⌘R untuk hotkey perekaman dipakai aplikasi lain, jadi kali ini memakai ⌃⇧⌘R. Klik «Ubah hotkey» untuk memilih sendiri.',
    'Kayıt kısayolunun varsayılan kombinasyonu ⌃⌘R başka bir uygulama tarafından kullanılıyor; bu kez ⌃⇧⌘R kullanılıyor. Kendi kombinasyonunuzu belirlemek için «Kısayolu değiştir»e tıklayın.',
    "De standaardcombinatie ⌃⌘R van de opnamesneltoets is in gebruik door een andere app; deze keer wordt daarom ⌃⇧⌘R gebruikt. Klik op 'Sneltoets wijzigen' om er zelf een te kiezen.",
    'Domyślna kombinacja ⌃⌘R skrótu nagrywania jest zajęta przez inną aplikację, więc tym razem używana jest ⌃⇧⌘R. Kliknij „Zmień skrót”, aby ustawić własny.',
    'Комбінація ⌃⌘R за замовчуванням для запису зайнята іншим застосунком, тому цього разу використовується ⌃⇧⌘R. Натисніть «Змінити сполучення», щоб задати своє.',
    'Standardkombinationen ⌃⌘R för inspelningssnabbkommandot används av en annan app, så den här gången används ⌃⇧⌘R i stället. Klicka på "Ändra snabbtangent" för att ange en egen.',
])

# 上一版误注册的短句：视图从未使用，Xcode 已标为 stale，随本次运行一并清除
STALE_KEYS = [
    '录音热键的默认组合 ⌃⌘R 已被其他应用占用，本次已自动改用 ⌃⇧⌘R。',
]


def write_catalog(catalog):
    """按 Xcode 写回 Localizable.xcstrings 的实际格式落盘。

    `json.dump` 的默认写法与 Xcode 不一致（键值分隔符是 `": "` 而不是 `" : "`，
    空对象写成 `{}` 而不是展开为多一行），直接 dump 会让整个文件产生十万行级的
    无意义 diff——只新增几条键，看起来却像全文重写。这里逐行还原 Xcode 的格式：
    - 键值分隔符统一为 `" : "`
    - 空对象展开为 `{` / 空行 / `}` 三行（Apple 的写法）
    - 文件末尾不补换行（Xcode 也不补）
    - 每个条目的 `localizations` 子键按字母序排列：Xcode 就是这么写的，
      而我们按「zh-Hans 在前、其余按语言表顺序」插入，不排一下会把整条重写
    """
    # JSON 对象本身无序，但 git diff 与 Xcode 都按字母序看，这里对齐
    for entry in catalog.get('strings', {}).values():
        locs = entry.get('localizations')
        if isinstance(locs, dict):
            entry['localizations'] = {k: locs[k] for k in sorted(locs)}

    raw = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False)
    lines = []
    for line in raw.split('\n'):
        empty_object = re.match(r'^(\s*)"([^"]*)": \{\}(,?)$', line)
        if empty_object:
            indent, key, comma = empty_object.groups()
            lines.extend([f'{indent}"{key}" : {{', '', f'{indent}}}{comma}'])
            continue
        pair = re.match(r'^(\s*)"([^"]*)": (.*)$', line)
        if pair:
            indent, key, value = pair.groups()
            lines.append(f'{indent}"{key}" : {value}')
            continue
        lines.append(line)
    with open(CATALOG, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    added = filled = removed = 0
    for key, vals in T.items():
        entry = existing.get(key)
        if entry is None:
            entry = {}
            existing[key] = entry
            added += 1
        else:
            filled += 1
        # 源语言 zh-Hans 与既有条目格式一致（值 = Key 本身）。缺了它不算报错
        # （源语言会回退成 Key），但与文件里绝大多数条目的写法不一致，这里补齐
        entry['localizations'] = {
            'zh-Hans': {'stringUnit': {'state': 'translated', 'value': key}},
        }
        for lang, val in zip(LANGS, vals):
            entry['localizations'][lang] = {'stringUnit': {'state': 'translated', 'value': val}}
        entry.pop('extractionState', None)

    for key in STALE_KEYS:
        if existing.pop(key, None) is not None:
            removed += 1

    write_catalog(catalog)

    print(f'新增 {added} 个键，补译 {filled} 个键，清除 {removed} 个过期键，总计 {len(existing)} 个键')


if __name__ == '__main__':
    main()
