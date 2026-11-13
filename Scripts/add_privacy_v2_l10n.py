#!/usr/bin/env python3
# 隐私政策 v2.0 新增 UI 词条（20 种目标语言）。
#
# 范围说明：
# - 本次补的是首次同意页 / 设置内协议页 / 声纹开关 / 撤回流程 / 错误提示的新文案；
# - 协议正文本身仍以简体中文为权威版本（页面内已明示），因此正文不进入本脚本；
# - 与既有 Scripts/add_*_l10n*.py 相同：zh-Hans 源文取 key 本身，校验 20 种目标语言
#   齐全且占位符一致，只新增/覆盖本脚本列出的 key。
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

PLACEHOLDER = re.compile(
    r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|L|q|z|j|t)?[@dfsl]')

T = {}


def placeholders(text):
    """占位符种类与数量（把 %1$@ 归一为 %@）。"""
    return sorted('%' + m[-1] for m in PLACEHOLDER.findall(text))


def add(key, vals):
    assert len(vals) == len(LANGS), (key, len(vals))
    expected = placeholders(key)
    for lang, val in zip(LANGS, vals):
        assert placeholders(val) == expected, f'占位符不一致 {key[:40]} / {lang}'
    T[key] = vals


add("声纹处理单独同意", [
    "聲紋處理單獨同意",
    "Separate consent for voiceprint processing",
    "声紋処理への個別同意",
    "음성 지문 처리 별도 동의",
    "Consentement distinct au traitement des empreintes vocales",
    "Gesonderte Einwilligung in die Stimmprofilverarbeitung",
    "Consentimiento separado para el tratamiento de huellas de voz",
    "Consenso separato al trattamento delle impronte vocali",
    "Consentimento separado para o tratamento de impressões vocais",
    "Отдельное согласие на обработку голосовых отпечатков",
    "موافقة منفصلة على معالجة البصمات الصوتية",
    "वॉयसप्रिंट प्रोसेसिंग के लिए अलग सहमति",
    "ความยินยอมแยกสำหรับการประมวลผลลายเสียง",
    "Đồng ý riêng cho xử lý dấu vân giọng nói",
    "Persetujuan terpisah untuk pemrosesan sidik suara",
    "Ses izi işleme için ayrı onay",
    "Aparte toestemming voor verwerking van spraakafdrukken",
    "Odrębna zgoda na przetwarzanie odcisków głosu",
    "Окрема згода на обробку голосових відбитків",
    "Separat samtycke till behandling av röstavtryck",
])

add("敏感个人信息，可单独拒绝；拒绝后仅声纹功能不可用", [
    "敏感個人資料，可單獨拒絕；拒絕後僅聲紋功能無法使用",
    "Sensitive personal information. You can decline this separately; only voiceprint features will be unavailable.",
    "機微な個人情報です。個別に拒否できます。拒否すると声紋機能のみ利用できなくなります。",
    "민감한 개인정보입니다. 별도로 거부할 수 있으며, 거부하면 음성 지문 기능만 사용할 수 없습니다.",
    "Données personnelles sensibles. Vous pouvez refuser séparément ; seule la fonction d’empreinte vocale sera indisponible.",
    "Sensible personenbezogene Daten. Sie können dies gesondert ablehnen; nur die Stimmprofilfunktionen sind dann nicht verfügbar.",
    "Datos personales sensibles. Puedes rechazarlo por separado; solo las funciones de huella de voz quedarán no disponibles.",
    "Dati personali sensibili. Puoi rifiutare separatamente; saranno non disponibili solo le funzioni delle impronte vocali.",
    "Dados pessoais sensíveis. Pode recusar em separado; apenas as funcionalidades de impressão vocal ficarão indisponíveis.",
    "Чувствительные персональные данные. Можно отказаться отдельно; будут недоступны только функции голосовых отпечатков.",
    "بيانات شخصية حساسة. يمكنك الرفض بشكل منفصل؛ لن تتوفر سوى ميزات البصمات الصوتية.",
    "संवेदनशील व्यक्तिगत जानकारी। आप इसे अलग से अस्वीकार कर सकते हैं; केवल वॉयसप्रिंट सुविधाएँ उपलब्ध नहीं होंगी।",
    "ข้อมูลส่วนบุคคลที่อ่อนไหว คุณสามารถปฏิเสธแยกได้ เฉพาะฟังก์ชันลายเสียงที่จะใช้ไม่ได้",
    "Thông tin cá nhân nhạy cảm. Bạn có thể từ chối riêng; chỉ các tính năng dấu vân giọng nói sẽ không khả dụng.",
    "Informasi pribadi sensitif. Anda dapat menolak secara terpisah; hanya fitur sidik suara yang tidak tersedia.",
    "Hassas kişisel veri. Bunu ayrıca reddedebilirsiniz; yalnızca ses izi özellikleri kullanılamaz.",
    "Gevoelige persoonsgegevens. U kunt dit apart weigeren; alleen de spraakafdrukfuncties zijn dan niet beschikbaar.",
    "Wrażliwe dane osobowe. Możesz odmówić osobno; niedostępne będą tylko funkcje odcisków głosu.",
    "Чутливі персональні дані. Можна відмовитися окремо; недоступними будуть лише функції голосових відбитків.",
    "Känsliga personuppgifter. Du kan avböja separat; endast röstavtrycksfunktionerna blir otillgängliga.",
])

add("勾选后才允许在本机生成并保存声纹特征；不勾选不影响录音、转写、总结与待办。你可以稍后在「设置 → 关于 → 隐私政策」更改。", [
    "勾選後才允許在本機產生並儲存聲紋特徵；不勾選不影響錄音、轉寫、總結與待辦。你可以稍後在「設定 → 關於 → 隱私權政策」變更。",
    "Voiceprints are generated and stored on this Mac only after you tick this box. Leaving it unticked does not affect recording, transcription, summaries or to-dos. You can change this later in Settings → About → Privacy Policy.",
    "チェックした場合にのみ、このMac上で声紋特徴を生成・保存します。チェックしなくても録音、文字起こし、要約、ToDoは利用できます。後で「設定 → このアプリについて → プライバシーポリシー」で変更できます。",
    "선택한 경우에만 이 Mac에서 음성 지문 특징을 생성하고 저장합니다. 선택하지 않아도 녹음, 전사, 요약, 할 일은 영향을 받지 않습니다. 나중에 설정 → 정보 → 개인정보 처리방침에서 변경할 수 있습니다.",
    "Les empreintes vocales ne sont générées et stockées sur ce Mac qu’après avoir coché cette case. Ne pas la cocher n’affecte pas l’enregistrement, la transcription, les résumés ni les tâches. Modifiable ultérieurement dans Réglages → À propos → Politique de confidentialité.",
    "Stimmprofilmerkmale werden nur nach Aktivieren dieses Kästchens auf diesem Mac erzeugt und gespeichert. Ohne Häkchen bleiben Aufnahme, Transkription, Zusammenfassungen und Aufgaben unberührt. Änderbar unter Einstellungen → Über → Datenschutzerklärung.",
    "Las huellas de voz solo se generan y guardan en este Mac si marcas esta casilla. No marcarla no afecta a la grabación, transcripción, resúmenes ni tareas. Puedes cambiarlo en Ajustes → Acerca de → Política de privacidad.",
    "Le impronte vocali vengono generate e salvate su questo Mac solo se selezioni questa casella. Se non la selezioni, registrazione, trascrizione, riepiloghi e attività non saranno interessati. Puoi modificarlo in Impostazioni → Info → Informativa sulla privacy.",
    "As impressões vocais só são geradas e guardadas neste Mac depois de marcar esta opção. Não a marcar não afeta a gravação, transcrição, resumos ou tarefas. Pode alterar em Ajustes → Sobre → Política de Privacidade.",
    "Голосовые отпечатки создаются и сохраняются на этом Mac только после установки флажка. Без флажка запись, расшифровка, резюме и задачи работают как обычно. Изменить можно в «Настройки → Об приложении → Политика конфиденциальности».",
    "لا تُنشأ بصمات الصوت وتُحفظ على هذا الـ Mac إلا بعد تحديد هذا المربع. عدم تحديده لا يؤثر على التسجيل أو التفريغ أو الملخصات أو المهام. يمكنك التغيير لاحقًا من الإعدادات → حول → سياسة الخصوصية.",
    "इस बॉक्स को चुनने के बाद ही इस Mac पर वॉयसप्रिंट विशेषताएँ बनाई और सहेजी जाएँगी। न चुनने पर रिकॉर्डिंग, ट्रांसक्रिप्शन, सारांश और कार्य प्रभावित नहीं होंगे। आप इसे बाद में सेटिंग्स → बारे में → गोपनीयता नीति में बदल सकते हैं।",
    "ระบบจะสร้างและบันทึกลายเสียงบน Mac เครื่องนี้เฉพาะเมื่อคุณติ๊กช่องนี้เท่านั้น การไม่ติ๊กไม่มีผลต่อการบันทึก การถอดความ สรุป หรืองาน เปลี่ยนได้ภายหลังที่การตั้งค่า → เกี่ยวกับ → นโยบายความเป็นส่วนตัว",
    "Dấu vân giọng nói chỉ được tạo và lưu trên Mac này sau khi bạn đánh dấu ô này. Không đánh dấu không ảnh hưởng đến ghi âm, chuyển ngữ, tóm tắt hay việc cần làm. Bạn có thể thay đổi sau trong Cài đặt → Giới thiệu → Chính sách quyền riêng tư.",
    "Sidik suara hanya dibuat dan disimpan di Mac ini setelah Anda mencentang kotak ini. Tidak mencentangnya tidak memengaruhi rekaman, transkripsi, ringkasan, atau tugas. Anda dapat mengubahnya nanti di Pengaturan → Tentang → Kebijakan Privasi.",
    "Ses izi özellikleri yalnızca bu kutuyu işaretlediğinizde bu Mac’te oluşturulur ve saklanır. İşaretlememek kayıt, çeviri yazı, özetler ve görevleri etkilemez. Daha sonra Ayarlar → Hakkında → Gizlilik Politikası’ndan değiştirebilirsiniz.",
    "Spraakafdrukken worden alleen op deze Mac aangemaakt en opgeslagen nadat u dit vakje aanvinkt. Niet aanvinken heeft geen invloed op opnemen, transcriberen, samenvattingen of taken. U kunt dit later wijzigen via Instellingen → Over → Privacybeleid.",
    "Odcisków głosu nie tworzy się ani nie zapisuje na tym Macu, dopóki nie zaznaczysz tego pola. Brak zaznaczenia nie wpływa na nagrywanie, transkrypcję, podsumowania ani zadania. Możesz to zmienić później w Ustawienia → Informacje → Polityka prywatności.",
    "Голосові відбитки створюються й зберігаються на цьому Mac лише після позначення цього поля. Якщо не позначити, запис, транскрипція, підсумки та завдання працюють як звичайно. Змінити можна в «Налаштування → Про застосунок → Політика конфіденційності».",
    "Röstavtryck skapas och lagras på den här Macen först när du markerar den här rutan. Om du inte markerar den påverkas inte inspelning, transkribering, sammanfattningar eller uppgifter. Du kan ändra detta senare i Inställningar → Om → Integritetspolicy.",
])

add("本政策以简体中文版本为准。", [
    "本政策以簡體中文版本為準。",
    "The Simplified Chinese version of this policy is the authoritative version.",
    "本ポリシーは簡体字中国語版を正文とします。",
    "본 정책은 중국어 간체 버전을 기준으로 합니다.",
    "La version en chinois simplifié de cette politique fait foi.",
    "Die vereinfachte chinesische Fassung dieser Erklärung ist maßgeblich.",
    "La versión en chino simplificado de esta política es la versión oficial.",
    "La versione in cinese semplificato della presente informativa è quella ufficiale.",
    "A versão em chinês simplificado desta política é a versão oficial.",
    "Основной считается версия настоящей политики на упрощённом китайском языке.",
    "النسخة الصينية المبسطة من هذه السياسة هي النسخة المعتمدة.",
    "इस नीति का सरलीकृत चीनी संस्करण ही आधिकारिक संस्करण है।",
    "ฉบับภาษาจีนตัวย่อของนโยบายนี้ถือเป็นฉบับอ้างอิง",
    "Phiên bản tiếng Trung giản thể của chính sách này là bản có hiệu lực.",
    "Versi bahasa Mandarin Sederhana dari kebijakan ini adalah versi yang berlaku.",
    "Bu politikanın Basitleştirilmiş Çince sürümü geçerli sürümdür.",
    "De vereenvoudigd-Chinese versie van dit beleid is de gezaghebbende versie.",
    "Wiążąca jest wersja niniejszej polityki w uproszczonym języku chińskim.",
    "Основною вважається версія цієї політики спрощеною китайською мовою.",
    "Den förenklade kinesiska versionen av denna policy är den giltiga versionen.",
])

add("需要重新确认本政策", [
    "需要重新確認本政策",
    "Please review this policy again",
    "本ポリシーの再確認が必要です",
    "본 정책을 다시 확인해야 합니다",
    "Veuillez à nouveau confirmer cette politique",
    "Diese Erklärung muss erneut bestätigt werden",
    "Es necesario volver a confirmar esta política",
    "È necessario confermare di nuovo la presente informativa",
    "É necessário confirmar novamente esta política",
    "Требуется повторное подтверждение политики",
    "يلزم تأكيد هذه السياسة مرة أخرى",
    "इस नीति की पुनः पुष्टि आवश्यक है",
    "ต้องยืนยันนโยบายนี้อีกครั้ง",
    "Cần xác nhận lại chính sách này",
    "Kebijakan ini perlu dikonfirmasi ulang",
    "Bu politikanın yeniden onaylanması gerekiyor",
    "Dit beleid moet opnieuw worden bevestigd",
    "Wymagane jest ponowne potwierdzenie polityki",
    "Потрібне повторне підтвердження політики",
    "Policyn behöver bekräftas igen",
])

add("已同意的版本与当前版本不一致。下次启动或重新打开应用时会再次展示同意页。", [
    "已同意的版本與目前版本不一致。下次啟動或重新開啟應用程式時會再次顯示同意頁。",
    "The version you agreed to differs from the current version. The consent screen will appear again the next time you launch or reopen the app.",
    "同意済みのバージョンが現在のバージョンと一致しません。次回の起動時またはアプリを開き直したときに、同意画面が再表示されます。",
    "동의한 버전이 현재 버전과 다릅니다. 다음에 앱을 실행하거나 다시 열 때 동의 화면이 다시 표시됩니다.",
    "La version acceptée diffère de la version actuelle. L’écran de consentement réapparaîtra au prochain lancement ou à la prochaine réouverture de l’app.",
    "Die bestätigte Version weicht von der aktuellen ab. Der Zustimmungsbildschirm erscheint beim nächsten Start oder erneuten Öffnen der App erneut.",
    "La versión aceptada no coincide con la actual. La pantalla de consentimiento volverá a aparecer al iniciar o reabrir la app.",
    "La versione accettata non corrisponde a quella attuale. La schermata di consenso ricomparirà al prossimo avvio o alla riapertura dell’app.",
    "A versão aceite não corresponde à atual. O ecrã de consentimento voltará a aparecer na próxima abertura da app.",
    "Подтверждённая версия отличается от текущей. Экран согласия появится снова при следующем запуске или открытии приложения.",
    "النسخة التي وافقت عليها تختلف عن النسخة الحالية. ستظهر شاشة الموافقة مرة أخرى عند تشغيل التطبيق أو إعادة فتحه في المرة القادمة.",
    "आपकी सहमति वाला संस्करण वर्तमान संस्करण से भिन्न है। अगली बार ऐप खोलने या फिर से खोलने पर सहमति स्क्रीन दोबारा दिखेगी।",
    "เวอร์ชันที่คุณยอมรับไม่ตรงกับเวอร์ชันปัจจุบัน หน้าจอความยินยอมจะแสดงอีกครั้งเมื่อเปิดแอปในครั้งถัดไป",
    "Phiên bản bạn đã đồng ý khác với phiên bản hiện tại. Màn hình đồng ý sẽ hiện lại vào lần mở ứng dụng tiếp theo.",
    "Versi yang Anda setujui berbeda dari versi saat ini. Layar persetujuan akan muncul lagi saat aplikasi dibuka berikutnya.",
    "Onayladığınız sürüm geçerli sürümden farklı. Uygulamayı bir sonraki açılışınızda onay ekranı yeniden gösterilecek.",
    "De versie die u hebt geaccepteerd verschilt van de huidige versie. Het toestemmingsscherm verschijnt opnieuw bij de volgende keer openen van de app.",
    "Zaakceptowana wersja różni się od bieżącej. Ekran zgody pojawi się ponownie przy następnym uruchomieniu aplikacji.",
    "Підтверджена версія відрізняється від поточної. Екран згоди з’явиться знову під час наступного запуску або відкриття застосунку.",
    "Versionen du godkände skiljer sig från den aktuella. Samtyckesskärmen visas igen nästa gång du startar eller öppnar appen.",
])

add("已同意当前版本", [
    "已同意目前版本",
    "Current version accepted",
    "現在のバージョンに同意済み",
    "현재 버전에 동의함",
    "Version actuelle acceptée",
    "Aktuelle Version bestätigt",
    "Versión actual aceptada",
    "Versione attuale accettata",
    "Versão atual aceite",
    "Текущая версия подтверждена",
    "تمت الموافقة على النسخة الحالية",
    "वर्तमान संस्करण स्वीकृत है",
    "ยอมรับเวอร์ชันปัจจุบันแล้ว",
    "Đã đồng ý phiên bản hiện tại",
    "Versi saat ini telah disetujui",
    "Geçerli sürüm onaylandı",
    "Huidige versie geaccepteerd",
    "Bieżąca wersja zaakceptowana",
    "Поточну версію підтверджено",
    "Aktuell version godkänd",
])

add("同意时间：%@", [
    "同意時間：%@",
    "Consented at: %@",
    "同意日時：%@",
    "동의 시간: %@",
    "Consentement donné le : %@",
    "Zugestimmt am: %@",
    "Consentimiento otorgado: %@",
    "Consenso prestato il: %@",
    "Consentimento dado em: %@",
    "Согласие дано: %@",
    "وقت الموافقة: %@",
    "सहमति का समय: %@",
    "เวลาที่ยินยอม: %@",
    "Thời điểm đồng ý: %@",
    "Waktu persetujuan: %@",
    "Onay zamanı: %@",
    "Toestemming gegeven op: %@",
    "Czas wyrażenia zgody: %@",
    "Час надання згоди: %@",
    "Samtycke gavs: %@",
])

add("敏感个人信息，可单独撤回", [
    "敏感個人資料，可單獨撤回",
    "Sensitive personal information; can be withdrawn separately",
    "機微な個人情報です。個別に撤回できます",
    "민감한 개인정보이며 별도로 철회할 수 있습니다",
    "Données personnelles sensibles, révocables séparément",
    "Sensible personenbezogene Daten; gesondert widerrufbar",
    "Datos personales sensibles; se puede retirar por separado",
    "Dati personali sensibili; revocabili separatamente",
    "Dados pessoais sensíveis; pode ser retirado em separado",
    "Чувствительные персональные данные; можно отозвать отдельно",
    "بيانات شخصية حساسة؛ يمكن سحبها بشكل منفصل",
    "संवेदनशील व्यक्तिगत जानकारी; अलग से वापस ली जा सकती है",
    "ข้อมูลส่วนบุคคลที่อ่อนไหว สามารถถอนแยกได้",
    "Thông tin cá nhân nhạy cảm; có thể rút lại riêng",
    "Informasi pribadi sensitif; dapat ditarik secara terpisah",
    "Hassas kişisel veri; ayrıca geri alınabilir",
    "Gevoelige persoonsgegevens; apart intrekbaar",
    "Wrażliwe dane osobowe; można wycofać osobno",
    "Чутливі персональні дані; можна відкликати окремо",
    "Känsliga personuppgifter; kan återkallas separat",
])

add("已允许在本机生成并保存声纹特征，用于下次转写时识别说话人。", [
    "已允許在本機產生並儲存聲紋特徵，用於下次轉寫時辨識說話人。",
    "You have allowed voiceprints to be generated and stored on this Mac for identifying speakers in future transcriptions.",
    "このMac上での声紋特徴の生成・保存を許可しました。次回以降の文字起こしで話者を識別するために使用します。",
    "이 Mac에서 음성 지문 특징을 생성하고 저장하도록 허용했습니다. 다음 전사 시 화자를 식별하는 데 사용됩니다.",
    "Vous avez autorisé la génération et le stockage d’empreintes vocales sur ce Mac pour identifier les intervenants lors des prochaines transcriptions.",
    "Sie haben die Erzeugung und Speicherung von Stimmprofilmerkmalen auf diesem Mac erlaubt, um Sprecher bei künftigen Transkriptionen zu erkennen.",
    "Has permitido generar y guardar huellas de voz en este Mac para identificar a los hablantes en futuras transcripciones.",
    "Hai consentito la generazione e il salvataggio delle impronte vocali su questo Mac per identificare gli interlocutori nelle prossime trascrizioni.",
    "Autorizou a criação e o armazenamento de impressões vocais neste Mac para identificar os intervenientes em transcrições futuras.",
    "Вы разрешили создание и хранение голосовых отпечатков на этом Mac для распознавания говорящих при будущих расшифровках.",
    "سمحت بإنشاء بصمات الصوت وحفظها على هذا الـ Mac للتعرف على المتحدثين في عمليات التفريغ التالية.",
    "आपने भविष्य के ट्रांसक्रिप्शन में वक्ताओं को पहचानने के लिए इस Mac पर वॉयसप्रिंट विशेषताएँ बनाने और सहेजने की अनुमति दी है।",
    "คุณอนุญาตให้สร้างและบันทึกลายเสียงบน Mac เครื่องนี้เพื่อระบุผู้พูดในการถอดความครั้งถัดไป",
    "Bạn đã cho phép tạo và lưu dấu vân giọng nói trên Mac này để nhận diện người nói trong các lần chuyển ngữ sau.",
    "Anda telah mengizinkan pembuatan dan penyimpanan sidik suara di Mac ini untuk mengenali pembicara pada transkripsi berikutnya.",
    "Gelecekteki çeviri yazılarda konuşmacıları tanımak için bu Mac’te ses izi özelliklerinin oluşturulmasına ve saklanmasına izin verdiniz.",
    "U hebt toegestaan dat spraakafdrukken op deze Mac worden aangemaakt en opgeslagen om sprekers bij toekomstige transcripties te herkennen.",
    "Zezwolono na tworzenie i zapisywanie odcisków głosu na tym Macu w celu rozpoznawania mówców w przyszłych transkrypcjach.",
    "Ви дозволили створення й збереження голосових відбитків на цьому Mac для розпізнавання мовців у майбутніх транскрипціях.",
    "Du har tillåtit att röstavtryck skapas och lagras på den här Macen för att identifiera talare vid framtida transkriberingar.",
])

add("未同意：不会生成声纹，也不会用声纹库比对说话人。录音、转写、总结与待办不受影响。", [
    "未同意：不會產生聲紋，也不會用聲紋庫比對說話人。錄音、轉寫、總結與待辦不受影響。",
    "Not consented: no voiceprints will be generated and the library will not be used to match speakers. Recording, transcription, summaries and to-dos are unaffected.",
    "未同意：声紋は生成されず、声紋ライブラリとの話者照合も行いません。録音、文字起こし、要約、ToDoは影響を受けません。",
    "미동의: 음성 지문을 생성하지 않으며 음성 지문 라이브러리로 화자를 대조하지 않습니다. 녹음, 전사, 요약, 할 일은 영향을 받지 않습니다.",
    "Non consenti : aucune empreinte vocale ne sera générée et la bibliothèque ne servira pas à identifier les intervenants. Enregistrement, transcription, résumés et tâches ne sont pas concernés.",
    "Nicht zugestimmt: Es werden keine Stimmprofile erzeugt und die Bibliothek wird nicht zum Abgleich von Sprechern verwendet. Aufnahme, Transkription, Zusammenfassungen und Aufgaben bleiben unberührt.",
    "Sin consentimiento: no se generarán huellas de voz ni se usará la biblioteca para identificar hablantes. La grabación, transcripción, resúmenes y tareas no se ven afectados.",
    "Nessun consenso: non verranno generate impronte vocali e la libreria non sarà usata per riconoscere gli interlocutori. Registrazione, trascrizione, riepiloghi e attività non sono interessati.",
    "Sem consentimento: não serão criadas impressões vocais nem será usada a biblioteca para identificar intervenientes. A gravação, transcrição, resumos e tarefas não são afetados.",
    "Согласие не дано: голосовые отпечатки не создаются, библиотека не используется для сопоставления говорящих. Запись, расшифровка, резюме и задачи не затрагиваются.",
    "لم تتم الموافقة: لن تُنشأ بصمات صوتية ولن تُستخدم المكتبة لمطابقة المتحدثين. لا يتأثر التسجيل أو التفريغ أو الملخصات أو المهام.",
    "सहमति नहीं: कोई वॉयसप्रिंट नहीं बनाया जाएगा और वक्ताओं के मिलान के लिए लाइब्रेरी का उपयोग नहीं होगा। रिकॉर्डिंग, ट्रांसक्रिप्शन, सारांश और कार्य प्रभावित नहीं होंगे।",
    "ยังไม่ยินยอม: ระบบจะไม่สร้างลายเสียงและจะไม่ใช้คลังลายเสียงเพื่อจับคู่ผู้พูด การบันทึก การถอดความ สรุป และงานไม่ได้รับผลกระทบ",
    "Chưa đồng ý: hệ thống sẽ không tạo dấu vân giọng nói và không dùng thư viện để đối chiếu người nói. Ghi âm, chuyển ngữ, tóm tắt và việc cần làm không bị ảnh hưởng.",
    "Belum disetujui: sidik suara tidak akan dibuat dan pustaka tidak akan digunakan untuk mencocokkan pembicara. Rekaman, transkripsi, ringkasan, dan tugas tidak terpengaruh.",
    "Onay yok: ses izi oluşturulmaz ve kitaplık konuşmacı eşleştirmesi için kullanılmaz. Kayıt, çeviri yazı, özetler ve görevler etkilenmez.",
    "Niet toegestemd: er worden geen spraakafdrukken aangemaakt en de bibliotheek wordt niet gebruikt om sprekers te matchen. Opnemen, transcriberen, samenvattingen en taken blijven onaangetast.",
    "Brak zgody: odciski głosu nie będą tworzone, a biblioteka nie będzie używana do dopasowywania mówców. Nagrywanie, transkrypcja, podsumowania i zadania pozostają bez zmian.",
    "Згоди немає: голосові відбитки не створюються, бібліотека не використовується для зіставлення мовців. Запис, транскрипція, підсумки й завдання не змінюються.",
    "Inget samtycke: inga röstavtryck skapas och biblioteket används inte för att matcha talare. Inspelning, transkribering, sammanfattningar och uppgifter påverkas inte.",
])

add("关闭后不会自动删除已有声纹；如需删除，请到「设置 → 声纹库」逐条移除。", [
    "關閉後不會自動刪除已有聲紋；如需刪除，請到「設定 → 聲紋庫」逐筆移除。",
    "Turning this off does not delete existing voiceprints. To delete them, remove them one by one in Settings → Voiceprint Library.",
    "オフにしても既存の声紋は自動削除されません。削除するには「設定 → 声紋ライブラリ」で1件ずつ削除してください。",
    "끄더라도 기존 음성 지문은 자동으로 삭제되지 않습니다. 삭제하려면 설정 → 음성 지문 라이브러리에서 하나씩 제거하세요.",
    "La désactivation ne supprime pas les empreintes existantes. Pour les supprimer, retirez-les une par une dans Réglages → Bibliothèque d’empreintes vocales.",
    "Beim Ausschalten werden vorhandene Stimmprofile nicht automatisch gelöscht. Zum Löschen entfernen Sie sie einzeln unter Einstellungen → Stimmprofil-Bibliothek.",
    "Desactivarlo no elimina las huellas existentes. Para borrarlas, elimínalas una a una en Ajustes → Biblioteca de huellas de voz.",
    "Disattivando non si eliminano le impronte esistenti. Per eliminarle, rimuovile una per una in Impostazioni → Libreria impronte vocali.",
    "Desativar não elimina as impressões existentes. Para as eliminar, remova-as uma a uma em Ajustes → Biblioteca de impressões vocais.",
    "При выключении существующие голосовые отпечатки не удаляются автоматически. Чтобы удалить их, удалите по одному в «Настройки → Библиотека голосовых отпечатков».",
    "إيقاف هذا لا يحذف البصمات الصوتية الموجودة. لحذفها، أزلها واحدة تلو الأخرى من الإعدادات → مكتبة البصمات الصوتية.",
    "इसे बंद करने से मौजूदा वॉयसप्रिंट स्वतः नहीं हटेंगे। हटाने के लिए सेटिंग्स → वॉयसप्रिंट लाइब्रेरी में एक-एक करके हटाएँ।",
    "การปิดจะไม่ลบลายเสียงที่มีอยู่โดยอัตโนมัติ หากต้องการลบ ให้ลบทีละรายการในการตั้งค่า → คลังลายเสียง",
    "Tắt tùy chọn này không tự động xóa dấu vân giọng nói hiện có. Để xóa, hãy xóa từng mục trong Cài đặt → Thư viện dấu vân giọng nói.",
    "Menonaktifkan ini tidak menghapus sidik suara yang ada. Untuk menghapusnya, hapus satu per satu di Pengaturan → Pustaka sidik suara.",
    "Bunu kapatmak mevcut ses izlerini silmez. Silmek için Ayarlar → Ses İzi Kitaplığı’nda tek tek kaldırın.",
    "Dit uitschakelen verwijdert bestaande spraakafdrukken niet. Verwijder ze een voor een via Instellingen → Spraakafdrukbibliotheek.",
    "Wyłączenie nie usuwa istniejących odcisków głosu. Aby je usunąć, usuń je pojedynczo w Ustawienia → Biblioteka odcisków głosu.",
    "Вимкнення не видаляє наявні голосові відбитки автоматично. Щоб видалити, видаліть їх по одному в «Налаштування → Бібліотека голосових відбитків».",
    "Att stänga av tar inte bort befintliga röstavtryck. Ta bort dem ett i taget i Inställningar → Röstavtrycksbibliotek.",
])

add("撤回隐私同意", [
    "撤回隱私權同意",
    "Withdraw privacy consent",
    "プライバシー同意を撤回",
    "개인정보 동의 철회",
    "Retirer le consentement à la confidentialité",
    "Datenschutzeinwilligung widerrufen",
    "Retirar el consentimiento de privacidad",
    "Revoca il consenso alla privacy",
    "Retirar o consentimento de privacidade",
    "Отозвать согласие на обработку данных",
    "سحب الموافقة على الخصوصية",
    "गोपनीयता सहमति वापस लें",
    "ถอนความยินยอมความเป็นส่วนตัว",
    "Rút lại đồng ý quyền riêng tư",
    "Tarik persetujuan privasi",
    "Gizlilik onayını geri al",
    "Toestemming voor privacy intrekken",
    "Wycofaj zgodę na prywatność",
    "Відкликати згоду на конфіденційність",
    "Återkalla integritetssamtycke",
])

add("撤回后应用将退出；已保存的本机数据不会被删除。", [
    "撤回後應用程式將結束；已儲存的本機資料不會被刪除。",
    "The app will quit after withdrawal; data already saved on this Mac will not be deleted.",
    "撤回後、アプリは終了します。このMacに保存済みのデータは削除されません。",
    "철회 후 앱이 종료됩니다. 이 Mac에 저장된 데이터는 삭제되지 않습니다.",
    "L’app quittera après le retrait ; les données déjà enregistrées sur ce Mac ne seront pas supprimées.",
    "Nach dem Widerruf wird die App beendet; bereits auf diesem Mac gespeicherte Daten werden nicht gelöscht.",
    "La app se cerrará tras la retirada; los datos ya guardados en este Mac no se eliminarán.",
    "Dopo la revoca l’app si chiuderà; i dati già salvati su questo Mac non verranno eliminati.",
    "A app encerrará após a retirada; os dados já guardados neste Mac não serão eliminados.",
    "После отзыва приложение закроется; данные, уже сохранённые на этом Mac, не будут удалены.",
    "سيتوقف التطبيق بعد السحب؛ لن تُحذف البيانات المحفوظة بالفعل على هذا الـ Mac.",
    "वापस लेने के बाद ऐप बंद हो जाएगा; इस Mac पर पहले से सहेजा गया डेटा नहीं हटाया जाएगा।",
    "แอปจะปิดหลังจากถอนความยินยอม ข้อมูลที่บันทึกไว้บน Mac นี้จะไม่ถูกลบ",
    "Ứng dụng sẽ thoát sau khi rút lại; dữ liệu đã lưu trên Mac này sẽ không bị xóa.",
    "Aplikasi akan keluar setelah penarikan; data yang sudah disimpan di Mac ini tidak akan dihapus.",
    "Geri almadan sonra uygulama kapanır; bu Mac’te zaten kayıtlı veriler silinmez.",
    "De app sluit na intrekking; gegevens die al op deze Mac zijn opgeslagen, worden niet verwijderd.",
    "Po wycofaniu aplikacja zostanie zamknięta; dane już zapisane na tym Macu nie zostaną usunięte.",
    "Після відкликання застосунок завершиться; дані, уже збережені на цьому Mac, не буде видалено.",
    "Appen avslutas efter återkallandet; data som redan sparats på den här Macen raderas inte.",
])

add("确认撤回隐私同意？", [
    "確認撤回隱私權同意？",
    "Withdraw privacy consent?",
    "プライバシー同意を撤回しますか？",
    "개인정보 동의를 철회하시겠습니까?",
    "Retirer le consentement à la confidentialité ?",
    "Datenschutzeinwilligung widerrufen?",
    "¿Retirar el consentimiento de privacidad?",
    "Revocare il consenso alla privacy?",
    "Retirar o consentimento de privacidade?",
    "Отозвать согласие на обработку данных?",
    "سحب الموافقة على الخصوصية؟",
    "गोपनीयता सहमति वापस लें?",
    "ถอนความยินยอมความเป็นส่วนตัวหรือไม่",
    "Rút lại đồng ý quyền riêng tư?",
    "Tarik persetujuan privasi?",
    "Gizlilik onayı geri alınsın mı?",
    "Toestemming voor privacy intrekken?",
    "Wycofać zgodę na prywatność?",
    "Відкликати згоду на конфіденційність?",
    "Återkalla integritetssamtycket?",
])

add("撤回并退出", [
    "撤回並結束",
    "Withdraw and Quit",
    "撤回して終了",
    "철회하고 종료",
    "Retirer et quitter",
    "Widerrufen und beenden",
    "Retirar y salir",
    "Revoca ed esci",
    "Retirar e sair",
    "Отозвать и выйти",
    "السحب والخروج",
    "वापस लें और बाहर निकलें",
    "ถอนและออก",
    "Rút lại và thoát",
    "Tarik dan keluar",
    "Geri al ve çık",
    "Intrekken en stoppen",
    "Wycofaj i zakończ",
    "Відкликати й вийти",
    "Återkalla och avsluta",
])

add("撤回后应用将退出，下次启动需要重新阅读并同意隐私政策。已保存在本机的数据不会因此删除。", [
    "撤回後應用程式將結束，下次啟動需要重新閱讀並同意隱私權政策。已儲存在本機的資料不會因此刪除。",
    "The app will quit after withdrawal. On next launch you must read and accept the privacy policy again. Data already saved on this Mac will not be deleted.",
    "撤回後、アプリは終了します。次回起動時にプライバシーポリシーを再度読み、同意する必要があります。このMacに保存済みのデータは削除されません。",
    "철회 후 앱이 종료됩니다. 다음 실행 시 개인정보 처리방침을 다시 읽고 동의해야 합니다. 이 Mac에 저장된 데이터는 삭제되지 않습니다.",
    "L’app quittera après le retrait. Au prochain lancement, vous devrez relire et accepter la politique de confidentialité. Les données déjà enregistrées sur ce Mac ne seront pas supprimées.",
    "Nach dem Widerruf wird die App beendet. Beim nächsten Start müssen Sie die Datenschutzerklärung erneut lesen und akzeptieren. Bereits auf diesem Mac gespeicherte Daten werden nicht gelöscht.",
    "La app se cerrará tras la retirada. En el próximo inicio deberás leer y aceptar de nuevo la política de privacidad. Los datos ya guardados en este Mac no se eliminarán.",
    "Dopo la revoca l’app si chiuderà. Al prossimo avvio dovrai leggere e accettare di nuovo l’informativa sulla privacy. I dati già salvati su questo Mac non verranno eliminati.",
    "A app encerrará após a retirada. No próximo arranque terá de ler e aceitar novamente a política de privacidade. Os dados já guardados neste Mac não serão eliminados.",
    "После отзыва приложение закроется. При следующем запуске потребуется снова прочитать и принять политику конфиденциальности. Данные, уже сохранённые на этом Mac, не будут удалены.",
    "سيتوقف التطبيق بعد السحب. عند التشغيل التالي يجب قراءة سياسة الخصوصية والموافقة عليها مرة أخرى. لن تُحذف البيانات المحفوظة بالفعل على هذا الـ Mac.",
    "वापस लेने के बाद ऐप बंद हो जाएगा। अगली बार खोलने पर गोपनीयता नीति फिर से पढ़कर स्वीकार करनी होगी। इस Mac पर पहले से सहेजा गया डेटा नहीं हटाया जाएगा।",
    "แอปจะปิดหลังจากถอนความยินยอม เมื่อเปิดครั้งถัดไปคุณต้องอ่านและยอมรับนโยบายความเป็นส่วนตัวอีกครั้ง ข้อมูลที่บันทึกไว้บน Mac นี้จะไม่ถูกลบ",
    "Ứng dụng sẽ thoát sau khi rút lại. Lần mở tiếp theo, bạn phải đọc và đồng ý lại chính sách quyền riêng tư. Dữ liệu đã lưu trên Mac này sẽ không bị xóa.",
    "Aplikasi akan keluar setelah penarikan. Saat dibuka berikutnya, Anda harus membaca dan menyetujui kebijakan privasi lagi. Data yang sudah disimpan di Mac ini tidak akan dihapus.",
    "Geri almadan sonra uygulama kapanır. Bir sonraki açılışta gizlilik politikasını yeniden okuyup kabul etmeniz gerekir. Bu Mac’te zaten kayıtlı veriler silinmez.",
    "De app sluit na intrekking. Bij de volgende start moet u het privacybeleid opnieuw lezen en accepteren. Gegevens die al op deze Mac zijn opgeslagen, worden niet verwijderd.",
    "Po wycofaniu aplikacja zostanie zamknięta. Przy następnym uruchomieniu trzeba ponownie przeczytać i zaakceptować politykę prywatności. Dane już zapisane na tym Macu nie zostaną usunięte.",
    "Після відкликання застосунок завершиться. Під час наступного запуску потрібно знову прочитати й прийняти політику конфіденційності. Дані, уже збережені на цьому Mac, не буде видалено.",
    "Appen avslutas efter återkallandet. Vid nästa start måste du läsa och godkänna integritetspolicyn igen. Data som redan sparats på den här Macen raderas inte.",
])

add("尚未同意声纹处理。请先在「设置 → 关于 → 隐私政策」开启「声纹处理单独同意」。", [
    "尚未同意聲紋處理。請先在「設定 → 關於 → 隱私權政策」開啟「聲紋處理單獨同意」。",
    "Voiceprint processing has not been consented to. Turn on “Separate consent for voiceprint processing” in Settings → About → Privacy Policy first.",
    "声紋処理に同意していません。先に「設定 → このアプリについて → プライバシーポリシー」で「声紋処理への個別同意」をオンにしてください。",
    "음성 지문 처리에 동의하지 않았습니다. 먼저 설정 → 정보 → 개인정보 처리방침에서 '음성 지문 처리 별도 동의'를 켜세요.",
    "Le traitement des empreintes vocales n’a pas été accepté. Activez d’abord « Consentement distinct au traitement des empreintes vocales » dans Réglages → À propos → Politique de confidentialité.",
    "Der Stimmprofilverarbeitung wurde nicht zugestimmt. Aktivieren Sie zuerst „Gesonderte Einwilligung in die Stimmprofilverarbeitung“ unter Einstellungen → Über → Datenschutzerklärung.",
    "No se ha aceptado el tratamiento de huellas de voz. Activa primero «Consentimiento separado para el tratamiento de huellas de voz» en Ajustes → Acerca de → Política de privacidad.",
    "Il trattamento delle impronte vocali non è stato accettato. Attiva prima «Consenso separato al trattamento delle impronte vocali» in Impostazioni → Info → Informativa sulla privacy.",
    "O tratamento de impressões vocais não foi aceite. Ative primeiro «Consentimento separado para o tratamento de impressões vocais» em Ajustes → Sobre → Política de Privacidade.",
    "Согласие на обработку голосовых отпечатков не дано. Сначала включите «Отдельное согласие на обработку голосовых отпечатков» в «Настройки → Об приложении → Политика конфиденциальности».",
    "لم تتم الموافقة على معالجة البصمات الصوتية. فعّل «موافقة منفصلة على معالجة البصمات الصوتية» أولًا من الإعدادات → حول → سياسة الخصوصية.",
    "वॉयसप्रिंट प्रोसेसिंग के लिए सहमति नहीं दी गई है। पहले सेटिंग्स → बारे में → गोपनीयता नीति में «वॉयसप्रिंट प्रोसेसिंग के लिए अलग सहमति» चालू करें।",
    "ยังไม่ได้ยินยอมให้ประมวลผลลายเสียง โปรดเปิด «ความยินยอมแยกสำหรับการประมวลผลลายเสียง» ในการตั้งค่า → เกี่ยวกับ → นโยบายความเป็นส่วนตัว ก่อน",
    "Chưa đồng ý xử lý dấu vân giọng nói. Trước tiên, bật «Đồng ý riêng cho xử lý dấu vân giọng nói» trong Cài đặt → Giới thiệu → Chính sách quyền riêng tư.",
    "Pemrosesan sidik suara belum disetujui. Aktifkan «Persetujuan terpisah untuk pemrosesan sidik suara» di Pengaturan → Tentang → Kebijakan Privasi terlebih dahulu.",
    "Ses izi işleme onayı verilmedi. Önce Ayarlar → Hakkında → Gizlilik Politikası’nda «Ses izi işleme için ayrı onay» seçeneğini açın.",
    "Er is geen toestemming gegeven voor de verwerking van spraakafdrukken. Schakel eerst ‘Aparte toestemming voor verwerking van spraakafdrukken’ in via Instellingen → Over → Privacybeleid.",
    "Nie wyrażono zgody na przetwarzanie odcisków głosu. Najpierw włącz «Odrębna zgoda na przetwarzanie odcisków głosu» w Ustawienia → Informacje → Polityka prywatności.",
    "Згоди на обробку голосових відбитків не надано. Спершу увімкніть «Окрема згода на обробку голосових відбитків» у «Налаштування → Про застосунок → Політика конфіденційності».",
    "Samtycke till behandling av röstavtryck har inte getts. Aktivera först ”Separat samtycke till behandling av röstavtryck” i Inställningar → Om → Integritetspolicy.",
])

add("需要选择具体麦克风或单独录制系统声音时，可以开启专业模式。", [
    "需要選擇具體麥克風或單獨錄製系統聲音時，可以開啟專業模式。",
    "Turn on Pro Mode when you need to pick a specific microphone or record system audio separately.",
    "特定のマイクを選ぶ、またはシステム音声を個別に録音する必要があるときは、プロモードをオンにします。",
    "특정 마이크를 선택하거나 시스템 오디오를 별도로 녹음해야 할 때 프로 모드를 켜세요.",
    "Activez le mode pro si vous devez choisir un microphone précis ou enregistrer séparément l’audio système.",
    "Aktivieren Sie den Profi-Modus, wenn Sie ein bestimmtes Mikrofon wählen oder Systemaudio separat aufnehmen möchten.",
    "Activa el modo profesional cuando necesites elegir un micrófono concreto o grabar el audio del sistema por separado.",
    "Attiva la modalità Pro quando devi scegliere un microfono specifico o registrare l’audio di sistema separatamente.",
    "Ative o modo Pro quando precisar de escolher um microfone específico ou gravar o áudio do sistema em separado.",
    "Включите профессиональный режим, если нужно выбрать конкретный микрофон или записывать системный звук отдельно.",
    "شغِّل الوضع الاحترافي عندما تحتاج إلى اختيار ميكروفون معيّن أو تسجيل صوت النظام على حدة.",
    "जब आपको विशिष्ट माइक्रोफ़ोन चुनना या सिस्टम ऑडियो अलग से रिकॉर्ड करना हो, तब प्रो मोड चालू करें।",
    "เปิดโหมดโปรเมื่อคุณต้องเลือกไมโครโฟนเฉพาะหรือบันทึกเสียงระบบแยก",
    "Bật Chế độ chuyên nghiệp khi bạn cần chọn micrô cụ thể hoặc ghi âm thanh hệ thống riêng.",
    "Aktifkan Mode Pro saat Anda perlu memilih mikrofon tertentu atau merekam audio sistem secara terpisah.",
    "Belirli bir mikrofon seçmeniz veya sistem sesini ayrı kaydetmeniz gerektiğinde Pro Mod’u açın.",
    "Schakel Pro-modus in wanneer u een specifieke microfoon wilt kiezen of systeemaudio apart wilt opnemen.",
    "Włącz tryb Pro, gdy chcesz wybrać konkretny mikrofon lub nagrywać dźwięk systemowy osobno.",
    "Увімкніть професійний режим, якщо потрібно вибрати конкретний мікрофон або записувати системний звук окремо.",
    "Aktivera proläge när du behöver välja en specifik mikrofon eller spela in systemljud separat.",
])

add("自动跟随会议软件静音（当前版本未启用）", [
    "自動跟隨會議軟體靜音（目前版本未啟用）",
    "Follow meeting app mute state (not enabled in this version)",
    "会議アプリのミュートに追従（現在のバージョンでは無効）",
    "회의 앱 음소거 연동(현재 버전에서는 사용 안 함)",
    "Suivre la sourdine de l’app de réunion (non activé dans cette version)",
    "Stummschaltung der Meeting-App übernehmen (in dieser Version nicht aktiviert)",
    "Seguir el silencio de la app de reuniones (no disponible en esta versión)",
    "Segui il mute dell’app di riunione (non attivo in questa versione)",
    "Seguir o silêncio da app de reuniões (não ativado nesta versão)",
    "Следовать отключению звука в приложении встречи (в этой версии не включено)",
    "متابعة كتم تطبيق الاجتماع (غير مفعّل في هذه النسخة)",
    "मीटिंग ऐप के म्यूट का अनुसरण करें (इस संस्करण में सक्षम नहीं)",
    "ตามการปิดเสียงของแอปประชุม (เวอร์ชันนี้ยังไม่เปิดใช้)",
    "Theo trạng thái tắt tiếng của ứng dụng họp (chưa bật trong phiên bản này)",
    "Ikuti bisu aplikasi rapat (belum diaktifkan di versi ini)",
    "Toplantı uygulamasının sessizliğini izle (bu sürümde etkin değil)",
    "Dempen van de vergaderapp volgen (niet ingeschakeld in deze versie)",
    "Podążaj za wyciszeniem aplikacji do spotkań (niewłączone w tej wersji)",
    "Стежити за вимкненням звуку в застосунку нарад (у цій версії не ввімкнено)",
    "Följ mötesappens tystläge (inte aktiverat i den här versionen)",
])

add("应用层静音检测依赖辅助功能权限；代码保留但当前版本未启动，因此该开关暂不生效。系统级静音仍可使用上方的「自动检测系统静音」。", [
    "應用程式層靜音偵測依賴輔助使用權限；程式碼保留但目前版本未啟動，因此此開關暫不生效。系統層靜音仍可使用上方的「自動檢測系統靜音」。",
    "App-level mute detection requires Accessibility permission. The code is retained but not started in this version, so this switch has no effect for now. System-level mute detection is still available via “Auto-detect system mute” above.",
    "アプリ層のミュート検出にはアクセシビリティ権限が必要です。コードは残っていますが現在のバージョンでは起動しないため、このスイッチは一時的に無効です。システム層のミュート検出は上の「システムミュートを自動検出」で引き続き利用できます。",
    "앱 수준 음소거 감지는 손쉬운 사용 권한이 필요합니다. 코드는 남아 있지만 현재 버전에서는 시작되지 않아 이 스위치는 당분간 작동하지 않습니다. 시스템 수준 음소거 감지는 위의 '시스템 음소거 자동 감지'를 계속 사용할 수 있습니다.",
    "La détection du silence au niveau de l’app nécessite l’autorisation Accessibilité. Le code est conservé mais n’est pas démarré dans cette version ; ce réglage est donc sans effet pour l’instant. La détection du silence système reste disponible via « Détecter automatiquement la sourdine système » ci-dessus.",
    "Die Stummschaltungserkennung auf App-Ebene benötigt die Bedienungshilfen-Berechtigung. Der Code bleibt erhalten, wird in dieser Version aber nicht gestartet; der Schalter hat daher vorerst keine Wirkung. Die Erkennung auf Systemebene ist weiterhin über „Systemstummschaltung automatisch erkennen“ oben verfügbar.",
    "La detección de silencio a nivel de app requiere permiso de Accesibilidad. El código se conserva pero no se inicia en esta versión, por lo que este ajuste no tiene efecto por ahora. La detección de silencio del sistema sigue disponible en «Detectar automáticamente el silencio del sistema».",
    "Il rilevamento del mute a livello di app richiede l’autorizzazione Accessibilità. Il codice è conservato ma non viene avviato in questa versione, quindi questo interruttore per ora non ha effetto. Il rilevamento del mute di sistema resta disponibile con «Rileva automaticamente il silenzio di sistema» sopra.",
    "A deteção de silêncio ao nível da app requer a permissão de Acessibilidade. O código é mantido, mas não é iniciado nesta versão, pelo que este interruptor não tem efeito por agora. A deteção de silêncio do sistema continua disponível em «Detetar automaticamente o silêncio do sistema».",
    "Определение отключения звука на уровне приложения требует разрешения «Универсальный доступ». Код сохранён, но в этой версии не запускается, поэтому переключатель пока не действует. Определение системного отключения звука по-прежнему доступно в разделе «Автоматически обнаруживать системное отключение звука».",
    "يتطلب اكتشاف الكتم على مستوى التطبيق إذن إمكانية الوصول. تم الاحتفاظ بالشيفرة لكنها لا تبدأ في هذه النسخة، لذا لا يعمل هذا المفتاح حاليًا. لا يزال اكتشاف كتم النظام متاحًا عبر «كشف كتم النظام تلقائيًا» أعلاه.",
    "ऐप-स्तरीय म्यूट पहचान के लिए एक्सेसिबिलिटी अनुमति आवश्यक है। कोड रखा गया है, लेकिन इस संस्करण में शुरू नहीं होता, इसलिए यह स्विच फ़िलहाल काम नहीं करता। सिस्टम-स्तरीय म्यूट पहचान ऊपर «सिस्टम म्यूट का स्वतः पता लगाएँ» से अभी भी उपलब्ध है।",
    "การตรวจจับการปิดเสียงระดับแอปต้องใช้สิทธิ์การเข้าถึง โค้ดยังคงอยู่แต่ไม่ได้เริ่มทำงานในเวอร์ชันนี้ สวิตช์นี้จึงยังไม่มีผล การตรวจจับการปิดเสียงระดับระบบยังใช้ได้จาก «ตรวจจับการปิดเสียงระบบอัตโนมัติ» ด้านบน",
    "Phát hiện tắt tiếng ở cấp ứng dụng cần quyền Trợ năng. Mã được giữ lại nhưng không khởi động trong phiên bản này, nên công tắc này hiện chưa có tác dụng. Phát hiện tắt tiếng ở cấp hệ thống vẫn dùng được qua «Tự động phát hiện tắt tiếng hệ thống» ở trên.",
    "Deteksi bisu tingkat aplikasi memerlukan izin Aksesibilitas. Kode dipertahankan tetapi tidak dijalankan di versi ini, jadi sakelar ini belum berdampak. Deteksi bisu tingkat sistem masih tersedia melalui «Deteksi otomatis bisu sistem» di atas.",
    "Uygulama düzeyinde sessizlik algılama, Erişilebilirlik izni gerektirir. Kod korunmuştur ancak bu sürümde başlatılmaz; bu nedenle bu anahtar şimdilik etkisizdir. Sistem düzeyinde sessizlik algılama yukarıdaki «Sistem sessizini otomatik algıla» ile kullanılabilir.",
    "Detectie van demping op appniveau vereist toegankelijkheidstoestemming. De code blijft behouden maar wordt in deze versie niet gestart, dus deze schakelaar heeft voorlopig geen effect. Detectie op systeemniveau blijft beschikbaar via ‘Detecteer systeemdempen automatisch’ hierboven.",
    "Wykrywanie wyciszenia na poziomie aplikacji wymaga uprawnienia Dostępność. Kod pozostaje, ale nie jest uruchamiany w tej wersji, więc ten przełącznik na razie nie działa. Wykrywanie wyciszenia systemowego nadal jest dostępne w opcji „Automatycznie wykrywaj wyciszenie systemowe” powyżej.",
    "Виявлення вимкнення звуку на рівні застосунку потребує дозволу «Універсальний доступ». Код збережено, але в цій версії він не запускається, тому перемикач поки не діє. Виявлення системного вимкнення звуку й далі доступне в «Автоматично виявляти системне вимкнення звуку» вище.",
    "Identifiering av tystläge på appnivå kräver behörigheten Hjälpmedel. Koden finns kvar men startas inte i den här versionen, så reglaget har ingen effekt ännu. Identifiering på systemnivå finns fortfarande via ”Upptäck systemtystning automatiskt” ovan.",
])

add("系统静音检测：跟随系统静音自动暂停", [
    "系統靜音偵測：跟隨系統靜音自動暫停",
    "System mute detection: pause automatically when the system is muted",
    "システムミュート検出：システムのミュートに合わせて自動一時停止",
    "시스템 음소거 감지: 시스템이 음소거되면 자동 일시 정지",
    "Détection du silence système : mise en pause automatique lorsque le système est en sourdine",
    "Systemstummschaltung erkennen: automatisch pausieren, wenn das System stummgeschaltet ist",
    "Detección de silencio del sistema: pausa automática cuando el sistema está silenciado",
    "Rilevamento mute di sistema: pausa automatica quando il sistema è in muto",
    "Deteção de silêncio do sistema: pausa automática quando o sistema está sem som",
    "Определение системного отключения звука: автоматическая пауза при выключенном звуке",
    "اكتشاف كتم النظام: إيقاف مؤقت تلقائي عند كتم النظام",
    "सिस्टम म्यूट पहचान: सिस्टम म्यूट होने पर स्वतः रोकें",
    "ตรวจจับการปิดเสียงของระบบ: หยุดชั่วคราวอัตโนมัติเมื่อระบบปิดเสียง",
    "Phát hiện tắt tiếng hệ thống: tự động tạm dừng khi hệ thống tắt tiếng",
    "Deteksi bisu sistem: jeda otomatis saat sistem dibisukan",
    "Sistem sessizliği algılama: sistem sessizken otomatik duraklat",
    "Systeemdempen detecteren: automatisch pauzeren wanneer het systeem is gedempt",
    "Wykrywanie wyciszenia systemu: automatyczna pauza przy wyciszonym systemie",
    "Виявлення системного вимкнення звуку: автоматична пауза, коли систему вимкнено",
    "Identifiering av systemets tystläge: pausa automatiskt när systemet är tystat",
])

add("声纹处理需要单独同意。请到「设置 → 关于 → 隐私政策」开启「声纹处理单独同意」。", [
    "聲紋處理需要單獨同意。請到「設定 → 關於 → 隱私權政策」開啟「聲紋處理單獨同意」。",
    "Voiceprint processing requires separate consent. Turn on “Separate consent for voiceprint processing” in Settings → About → Privacy Policy.",
    "声紋処理には個別の同意が必要です。「設定 → このアプリについて → プライバシーポリシー」で「声紋処理への個別同意」をオンにしてください。",
    "음성 지문 처리에는 별도 동의가 필요합니다. 설정 → 정보 → 개인정보 처리방침에서 '음성 지문 처리 별도 동의'를 켜세요.",
    "Le traitement des empreintes vocales nécessite un consentement distinct. Activez « Consentement distinct au traitement des empreintes vocales » dans Réglages → À propos → Politique de confidentialité.",
    "Die Stimmprofilverarbeitung erfordert eine gesonderte Einwilligung. Aktivieren Sie „Gesonderte Einwilligung in die Stimmprofilverarbeitung“ unter Einstellungen → Über → Datenschutzerklärung.",
    "El tratamiento de huellas de voz requiere un consentimiento separado. Activa «Consentimiento separado para el tratamiento de huellas de voz» en Ajustes → Acerca de → Política de privacidad.",
    "Il trattamento delle impronte vocali richiede un consenso separato. Attiva «Consenso separato al trattamento delle impronte vocali» in Impostazioni → Info → Informativa sulla privacy.",
    "O tratamento de impressões vocais requer consentimento separado. Ative «Consentimento separado para o tratamento de impressões vocais» em Ajustes → Sobre → Política de Privacidade.",
    "Для обработки голосовых отпечатков требуется отдельное согласие. Включите «Отдельное согласие на обработку голосовых отпечатков» в «Настройки → Об приложении → Политика конфиденциальности».",
    "تتطلب معالجة البصمات الصوتية موافقة منفصلة. فعّل «موافقة منفصلة على معالجة البصمات الصوتية» من الإعدادات → حول → سياسة الخصوصية.",
    "वॉयसप्रिंट प्रोसेसिंग के लिए अलग सहमति आवश्यक है। सेटिंग्स → बारे में → गोपनीयता नीति में «वॉयसप्रिंट प्रोसेसिंग के लिए अलग सहमति» चालू करें।",
    "การประมวลผลลายเสียงต้องได้รับความยินยอมแยก โปรดเปิด «ความยินยอมแยกสำหรับการประมวลผลลายเสียง» ในการตั้งค่า → เกี่ยวกับ → นโยบายความเป็นส่วนตัว",
    "Xử lý dấu vân giọng nói cần sự đồng ý riêng. Bật «Đồng ý riêng cho xử lý dấu vân giọng nói» trong Cài đặt → Giới thiệu → Chính sách quyền riêng tư.",
    "Pemrosesan sidik suara memerlukan persetujuan terpisah. Aktifkan «Persetujuan terpisah untuk pemrosesan sidik suara» di Pengaturan → Tentang → Kebijakan Privasi.",
    "Ses izi işleme ayrı onay gerektirir. Ayarlar → Hakkında → Gizlilik Politikası’nda «Ses izi işleme için ayrı onay» seçeneğini açın.",
    "Verwerking van spraakafdrukken vereist aparte toestemming. Schakel ‘Aparte toestemming voor verwerking van spraakafdrukken’ in via Instellingen → Over → Privacybeleid.",
    "Przetwarzanie odcisków głosu wymaga odrębnej zgody. Włącz «Odrębna zgoda na przetwarzanie odcisków głosu» w Ustawienia → Informacje → Polityka prywatności.",
    "Для обробки голосових відбитків потрібна окрема згода. Увімкніть «Окрема згода на обробку голосових відбитків» у «Налаштування → Про застосунок → Політика конфіденційності».",
    "Behandling av röstavtryck kräver separat samtycke. Aktivera ”Separat samtycke till behandling av röstavtryck” i Inställningar → Om → Integritetspolicy.",
])

add("版本 %@ · 生效日期 %@", [
    "版本 %@ · 生效日期 %@",
    "Version %@ · Effective %@",
    "バージョン %@ · 発効日 %@",
    "버전 %@ · 시행일 %@",
    "Version %@ · Entrée en vigueur %@",
    "Version %@ · Gültig ab %@",
    "Versión %@ · En vigor %@",
    "Versione %@ · In vigore dal %@",
    "Versão %@ · Em vigor %@",
    "Версия %@ · Действует с %@",
    "الإصدار %@ · تاريخ السريان %@",
    "संस्करण %@ · प्रभावी %@",
    "เวอร์ชัน %@ · มีผล %@",
    "Phiên bản %@ · Có hiệu lực %@",
    "Versi %@ · Berlaku %@",
    "Sürüm %@ · Yürürlük %@",
    "Versie %@ · Van kracht %@",
    "Wersja %@ · Obowiązuje od %@",
    "Версія %@ · Чинна з %@",
    "Version %@ · Gäller från %@",
])


def main():
    with open(CATALOG, encoding='utf-8') as f:
        catalog = json.load(f)
    strings = catalog['strings']
    for key, vals in T.items():
        entry = strings.setdefault(key, {})
        entry['localizations'] = {
            'zh-Hans': {'stringUnit': {'state': 'translated', 'value': key}},
        }
        for lang, val in zip(LANGS, vals):
            entry['localizations'][lang] = {
                'stringUnit': {'state': 'translated', 'value': val}
            }
        entry.pop('extractionState', None)
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False,
                      separators=(',', ' : '))
    # 与 Xcode 写盘格式保持一致：空对象渲染为多行空块，避免重跑产生整份 diff
    text = re.sub(r'(^([ \t]*)"(?:[^"\\]|\\.)*"\s*: )\{\}(?=,?$)', r'\1{\n\n\2}', text, flags=re.M)
    with open(CATALOG, 'w', encoding='utf-8') as f:
        f.write(text)
    print(f'已写入 {len(T)} 个 key（含 zh-Hans 源语言）')


if __name__ == '__main__':
    main()
