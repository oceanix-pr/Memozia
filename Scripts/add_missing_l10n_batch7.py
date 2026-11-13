import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'

LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add(
    "您可以随时：\n• 删除任意录音及其转写\n• 在系统设置中撤销麦克风和屏幕录制访问权限\n• 在「数据管理」中导出备份或恢复数据\n• 卸载应用以清除所有数据",
    [
        "您可以隨時：\n• 刪除任意錄音及其轉寫\n• 在系統設定中撤銷麥克風和螢幕錄製存取權限\n• 在「資料管理」中匯出備份或還原資料\n• 解除安裝應用程式以清除所有資料",
        "You can at any time:\n• Delete any recording and its transcript\n• Revoke microphone and screen recording access in System Settings\n• Export a backup or restore data in \"Data Management\"\n• Uninstall the app to erase all data",
        "いつでも次のことができます：\n• 任意の録音とその文字起こしを削除\n• システム設定でマイクと画面収録のアクセス権を取り消す\n• 「データ管理」でバックアップを書き出すかデータを復元\n• アプリをアンインストールしてすべてのデータを消去",
        "언제든지 다음을 할 수 있습니다:\n• 모든 녹음과 전사본 삭제\n• 시스템 설정에서 마이크 및 화면 기록 접근 권한 취소\n• \"데이터 관리\"에서 백업 내보내기 또는 데이터 복원\n• 앱을 제거하여 모든 데이터 삭제",
        "Vous pouvez à tout moment :\n• Supprimer tout enregistrement et sa transcription\n• Révoquer l'accès au microphone et à l'enregistrement d'écran dans les Réglages Système\n• Exporter une sauvegarde ou restaurer des données dans « Gestion des données »\n• Désinstaller l'application pour effacer toutes les données",
        "Sie können jederzeit:\n• Beliebige Aufnahmen und deren Transkript löschen\n• Den Zugriff auf Mikrofon und Bildschirmaufnahme in den Systemeinstellungen widerrufen\n• In „Datenverwaltung\" ein Backup exportieren oder Daten wiederherstellen\n• Die App deinstallieren, um alle Daten zu löschen",
        "Puedes en cualquier momento:\n• Eliminar cualquier grabación y su transcripción\n• Revocar el acceso al micrófono y a la grabación de pantalla en Ajustes del Sistema\n• Exportar una copia de seguridad o restaurar datos en «Gestión de datos»\n• Desinstalar la app para borrar todos los datos",
        "Puoi in qualsiasi momento:\n• Eliminare qualsiasi registrazione e la sua trascrizione\n• Revocare l'accesso a microfono e registrazione schermo nelle Impostazioni di Sistema\n• Esportare un backup o ripristinare i dati in «Gestione dati»\n• Disinstallare l'app per cancellare tutti i dati",
        "Você pode, a qualquer momento:\n• Excluir qualquer gravação e sua transcrição\n• Revogar o acesso ao microfone e à gravação de tela nos Ajustes do Sistema\n• Exportar um backup ou restaurar dados em \"Gerenciamento de dados\"\n• Desinstalar o app para apagar todos os dados",
        "Вы можете в любое время:\n• Удалить любую запись и её расшифровку\n• Отозвать доступ к микрофону и записи экрана в Системных настройках\n• Экспортировать резервную копию или восстановить данные в «Управлении данными»\n• Удалить приложение, чтобы стереть все данные",
        "يمكنك في أي وقت:\n• حذف أي تسجيل ونصه\n• إلغاء إذن الميكروفون وتسجيل الشاشة من إعدادات النظام\n• تصدير نسخة احتياطية أو استعادة البيانات في «إدارة البيانات»\n• إلغاء تثبيت التطبيق لمحو جميع البيانات",
        "आप कभी भी:\n• कोई भी रिकॉर्डिंग और उसका ट्रांसक्रिप्ट हटा सकते हैं\n• सिस्टम सेटिंग्स में माइक्रोफ़ोन और स्क्रीन रिकॉर्डिंग की अनुमति रद्द कर सकते हैं\n• «डेटा प्रबंधन» में बैकअप निर्यात या डेटा पुनर्स्थापित कर सकते हैं\n• सारा डेटा मिटाने के लिए ऐप अनइंस्टॉल कर सकते हैं",
        "คุณสามารถทำได้ทุกเมื่อ:\n• ลบการบันทึกใดก็ได้และข้อความถอดเสียง\n• เพิกถอนสิทธิ์การเข้าถึงไมโครโฟนและการบันทึกหน้าจอในตั้งค่าระบบ\n• ส่งออกข้อมูลสำรองหรือกู้คืนข้อมูลใน «การจัดการข้อมูล»\n• ถอนการติดตั้งแอปเพื่อลบข้อมูลทั้งหมด",
        "Bạn có thể bất cứ lúc nào:\n• Xóa mọi bản ghi âm và bản gỡ băng của nó\n• Thu hồi quyền truy cập micrô và ghi màn hình trong Cài đặt Hệ thống\n• Xuất bản sao lưu hoặc khôi phục dữ liệu trong «Quản lý dữ liệu»\n• Gỡ cài đặt ứng dụng để xóa toàn bộ dữ liệu",
        "Anda dapat kapan saja:\n• Menghapus rekaman apa pun dan transkripnya\n• Mencabut akses mikrofon dan perekaman layar di Pengaturan Sistem\n• Mengekspor cadangan atau memulihkan data di \"Manajemen data\"\n• Menghapus instalasi aplikasi untuk menghapus semua data",
        "Dilediğiniz zaman:\n• Herhangi bir kaydı ve dökümünü silebilirsiniz\n• Sistem Ayarları'ndan mikrofon ve ekran kaydı erişimini iptal edebilirsiniz\n• «Veri Yönetimi»nde yedek dışa aktarabilir veya verileri geri yükleyebilirsiniz\n• Tüm verileri silmek için uygulamayı kaldırabilirsiniz",
        "Je kunt op elk moment:\n• Elke opname en de bijbehorende transcriptie verwijderen\n• De toegang tot microfoon en schermopname intrekken in Systeeminstellingen\n• Een back-up exporteren of gegevens herstellen in 'Gegevensbeheer'\n• De app verwijderen om alle gegevens te wissen",
        "Możesz w dowolnym momencie:\n• Usunąć dowolne nagranie i jego transkrypcję\n• Odwołać dostęp do mikrofonu i nagrywania ekranu w Ustawieniach systemowych\n• Wyeksportować kopię zapasową lub przywrócić dane w „Zarządzaniu danymi”\n• Odinstalować aplikację, aby usunąć wszystkie dane",
        "Ви можете будь-коли:\n• Видалити будь-який запис та його розшифровку\n• Відкликати доступ до мікрофона й запису екрана в Системних налаштуваннях\n• Експортувати резервну копію або відновити дані в «Керуванні даними»\n• Видалити застосунок, щоб стерти всі дані",
        "Du kan när som helst:\n• Ta bort valfri inspelning och dess transkription\n• Återkalla åtkomst till mikrofon och skärminspelning i Systeminställningar\n• Exportera en säkerhetskopia eller återställa data i \"Datahantering\"\n• Avinstallera appen för att radera alla data",
    ],
)

add(
    "本次运行中有内容加密失败（Keychain 不可用或被锁定），为避免丢数据已以明文保存，这些内容仍可正常读写但不受加密保护。请确认钥匙串访问正常后重新启动应用。",
    [
        "本次執行中有內容加密失敗（Keychain 無法使用或被鎖定），為避免遺失資料已以明文儲存，這些內容仍可正常讀寫但不受加密保護。請確認鑰匙圈存取正常後重新啟動應用程式。",
        "Some content failed to encrypt during this session (Keychain unavailable or locked). To avoid data loss it was saved in plaintext; it can still be read and written normally but is not protected by encryption. Please make sure Keychain access works, then restart the app.",
        "今回の実行で一部のコンテンツの暗号化に失敗しました（Keychain が利用できないかロックされています）。データ消失を避けるため平文で保存されており、通常どおり読み書きできますが暗号化による保護は受けません。キーチェーンへのアクセスが正常であることを確認してからアプリを再起動してください。",
        "이번 실행 중 일부 콘텐츠 암호화에 실패했습니다(Keychain을 사용할 수 없거나 잠겨 있음). 데이터 손실을 막기 위해 평문으로 저장되었으며, 정상적으로 읽고 쓸 수 있지만 암호화로 보호되지는 않습니다. 키체인 접근이 정상인지 확인한 후 앱을 재시작하세요.",
        "Certains contenus n'ont pas pu être chiffrés lors de cette session (Keychain indisponible ou verrouillé). Pour éviter toute perte de données, ils ont été enregistrés en clair ; ils restent lisibles et modifiables normalement mais ne sont pas protégés par le chiffrement. Vérifiez que l'accès au trousseau fonctionne, puis redémarrez l'application.",
        "Bei diesem Lauf konnte ein Teil der Inhalte nicht verschlüsselt werden (Keychain nicht verfügbar oder gesperrt). Um Datenverlust zu vermeiden, wurden sie im Klartext gespeichert; sie lassen sich weiterhin normal lesen und schreiben, sind aber nicht durch Verschlüsselung geschützt. Prüfe den Keychain-Zugriff und starte die App neu.",
        "Parte del contenido no se pudo cifrar en esta sesión (Keychain no disponible o bloqueado). Para evitar la pérdida de datos se guardó en texto plano; se puede leer y escribir con normalidad, pero no está protegido por cifrado. Comprueba que el acceso al Llavero funcione y reinicia la app.",
        "Parte dei contenuti non è stata cifrata in questa sessione (Keychain non disponibile o bloccato). Per evitare la perdita di dati è stata salvata in chiaro; è ancora leggibile e scrivibile normalmente ma non è protetta dalla cifratura. Verifica che l'accesso al Portachiavi funzioni, poi riavvia l'app.",
        "Parte do conteúdo não pôde ser criptografada nesta sessão (Keychain indisponível ou bloqueado). Para evitar perda de dados, foi salvo em texto simples; ainda pode ser lido e gravado normalmente, mas não é protegido por criptografia. Verifique se o acesso ao Keychain funciona e reinicie o app.",
        "В этом сеансе часть содержимого не удалось зашифровать (Keychain недоступен или заблокирован). Во избежание потери данных оно сохранено в открытом виде; его по-прежнему можно читать и записывать, но оно не защищено шифрованием. Убедитесь, что доступ к связке ключей работает, и перезапустите приложение.",
        "تعذّر تشفير بعض المحتوى في هذه الجلسة (سلسلة المفاتيح غير متاحة أو مقفلة). لتجنب فقدان البيانات حُفظ كنص عادي، ويمكن قراءته وكتابته بشكل طبيعي لكنه غير محميّ بالتشفير. تأكد من أن الوصول إلى سلسلة المفاتيح يعمل ثم أعد تشغيل التطبيق.",
        "इस सत्र में कुछ सामग्री एन्क्रिप्ट नहीं हो सकी (Keychain अनुपलब्ध या लॉक है)। डेटा खोने से बचाने के लिए इसे सादे टेक्स्ट में सहेजा गया है; इसे सामान्य रूप से पढ़ा और लिखा जा सकता है लेकिन यह एन्क्रिप्शन से सुरक्षित नहीं है। कृपया कीचेन पहुँच सही होने की पुष्टि करें, फिर ऐप को पुनः आरंभ करें।",
        "ในการทำงานครั้งนี้มีเนื้อหาบางส่วนเข้ารหัสไม่สำเร็จ (Keychain ใช้งานไม่ได้หรือถูกล็อก) เพื่อป้องกันข้อมูลสูญหายจึงบันทึกเป็นข้อความธรรมดา ยังอ่านและเขียนได้ตามปกติแต่ไม่ได้รับการป้องกันด้วยการเข้ารหัส โปรดตรวจสอบว่าการเข้าถึงพวงกุญแจทำงานปกติ แล้วรีสตาร์ทแอป",
        "Trong lần chạy này, một số nội dung không thể mã hóa (Keychain không khả dụng hoặc bị khóa). Để tránh mất dữ liệu, nội dung đã được lưu ở dạng văn bản thuần; vẫn có thể đọc và ghi bình thường nhưng không được bảo vệ bằng mã hóa. Vui lòng kiểm tra quyền truy cập Keychain hoạt động bình thường rồi khởi động lại ứng dụng.",
        "Sebagian konten gagal dienkripsi pada sesi ini (Keychain tidak tersedia atau terkunci). Untuk mencegah kehilangan data, konten disimpan sebagai teks biasa; masih dapat dibaca dan ditulis normal tetapi tidak dilindungi enkripsi. Pastikan akses Keychain berfungsi, lalu mulai ulang aplikasi.",
        "Bu oturumda bazı içerikler şifrelenemedi (Keychain kullanılamıyor veya kilitli). Veri kaybını önlemek için düz metin olarak kaydedildi; normal şekilde okunup yazılabilir ancak şifrelemeyle korunmuyor. Keychain erişiminin çalıştığından emin olun ve uygulamayı yeniden başlatın.",
        "In deze sessie kon een deel van de inhoud niet worden versleuteld (Keychain niet beschikbaar of vergrendeld). Om gegevensverlies te voorkomen is het als platte tekst opgeslagen; het kan nog normaal worden gelezen en geschreven, maar is niet beschermd door versleuteling. Controleer of de Keychain-toegang werkt en herstart de app.",
        "W tej sesji nie udało się zaszyfrować części treści (Keychain niedostępny lub zablokowany). Aby uniknąć utraty danych, zapisano ją jako zwykły tekst; nadal można ją normalnie odczytywać i zapisywać, ale nie jest chroniona szyfrowaniem. Sprawdź, czy dostęp do pęku kluczy działa, i uruchom ponownie aplikację.",
        "У цьому сеансі частину вмісту не вдалося зашифрувати (Keychain недоступний або заблокований). Щоб уникнути втрати даних, його збережено у відкритому вигляді; його й надалі можна читати й записувати, але воно не захищене шифруванням. Переконайтеся, що доступ до в'язки ключів працює, і перезапустіть застосунок.",
        "En del innehåll kunde inte krypteras under denna körning (Keychain är otillgänglig eller låst). För att undvika dataförlust sparades det som klartext; det kan fortfarande läsas och skrivas normalt men skyddas inte av kryptering. Kontrollera att Keychain-åtkomsten fungerar och starta om appen.",
    ],
)

add(
    "打开导入的视频并切换到「画面」Tab，可播放原视频、手动分析画面并查看关键帧时间轴。视觉模型读取关键帧；普通文本模型会先在本机 OCR。点击任一关键帧即可跳到对应时间。",
    [
        "打開匯入的影片並切換到「畫面」Tab，可播放原始影片、手動分析畫面並檢視關鍵影格時間軸。視覺模型讀取關鍵影格；一般文字模型會先在本機 OCR。點擊任一關鍵影格即可跳到對應時間。",
        "Open an imported video and switch to the \"Frames\" tab to play the original video, manually analyze frames, and view the keyframe timeline. Vision models read the keyframes; plain text models run OCR on this device first. Click any keyframe to jump to that timestamp.",
        "読み込んだ動画を開き「画面」タブに切り替えると、元の動画の再生、手動での画面分析、キーフレームのタイムライン表示ができます。視覚モデルはキーフレームを読み取り、通常のテキストモデルは先に本機で OCR を実行します。任意のキーフレームをクリックするとその時点にジャンプします。",
        "가져온 동영상을 열고 \"화면\" 탭으로 전환하면 원본 동영상 재생, 수동 화면 분석, 키프레임 타임라인 확인이 가능합니다. 비전 모델은 키프레임을 읽고, 일반 텍스트 모델은 먼저 이 기기에서 OCR을 실행합니다. 아무 키프레임이나 클릭하면 해당 시점으로 이동합니다.",
        "Ouvrez une vidéo importée et basculez sur l'onglet « Images » pour lire la vidéo d'origine, analyser manuellement les images et consulter la chronologie des images clés. Les modèles de vision lisent les images clés ; les modèles de texte simples effectuent d'abord l'OCR sur cet appareil. Cliquez sur une image clé pour accéder à l'instant correspondant.",
        "Öffne ein importiertes Video und wechsle zum Tab „Bilder\", um das Originalvideo abzuspielen, Bilder manuell zu analysieren und die Keyframe-Zeitleiste anzuzeigen. Vision-Modelle lesen die Keyframes; reine Textmodelle führen zuerst eine OCR auf diesem Gerät durch. Klicke auf einen Keyframe, um zu diesem Zeitpunkt zu springen.",
        "Abre un vídeo importado y cambia a la pestaña «Imagen» para reproducir el vídeo original, analizar imágenes manualmente y ver la línea de tiempo de fotogramas clave. Los modelos de visión leen los fotogramas clave; los modelos de solo texto realizan primero el OCR en este dispositivo. Haz clic en cualquier fotograma clave para ir a ese momento.",
        "Apri un video importato e passa alla scheda «Immagine» per riprodurre il video originale, analizzare manualmente i fotogrammi e vedere la sequenza temporale dei fotogrammi chiave. I modelli di visione leggono i fotogrammi chiave; i modelli di solo testo eseguono prima l'OCR su questo dispositivo. Fai clic su un fotogramma chiave per passare a quel momento.",
        "Abra um vídeo importado e mude para a aba \"Imagem\" para reproduzir o vídeo original, analisar quadros manualmente e ver a linha do tempo dos quadros-chave. Modelos de visão leem os quadros-chave; modelos apenas de texto executam primeiro o OCR neste dispositivo. Clique em qualquer quadro-chave para ir ao momento correspondente.",
        "Откройте импортированное видео и перейдите на вкладку «Кадры», чтобы воспроизвести исходное видео, вручную проанализировать кадры и просмотреть шкалу ключевых кадров. Модели зрения читают ключевые кадры; обычные текстовые модели сначала выполняют OCR на этом устройстве. Щёлкните любой ключевой кадр, чтобы перейти к соответствующему моменту.",
        "افتح الفيديو المستورد وانتقل إلى تبويب «الصورة» لتشغيل الفيديو الأصلي وتحليل الإطارات يدويًا وعرض المخطط الزمني للإطارات الرئيسية. تقرأ نماذج الرؤية الإطارات الرئيسية، أما نماذج النص العادية فتُجري أولاً التعرف الضوئي على هذا الجهاز. انقر أي إطار رئيسي للانتقال إلى الوقت المقابل.",
        "आयातित वीडियो खोलें और «फ़्रेम» टैब पर जाएँ ताकि मूल वीडियो चला सकें, फ़्रेम मैन्युअल रूप से विश्लेषित कर सकें और कीफ़्रेम टाइमलाइन देख सकें। विज़न मॉडल कीफ़्रेम पढ़ते हैं; सामान्य टेक्स्ट मॉडल पहले इस डिवाइस पर OCR करते हैं। किसी भी कीफ़्रेम पर क्लिक करके उस समय पर जाएँ।",
        "เปิดวิดีโอที่นำเข้าแล้วสลับไปแท็บ «ภาพ» เพื่อเล่นวิดีโอต้นฉบับ วิเคราะห์ภาพด้วยตนเอง และดูไทม์ไลน์คีย์เฟรม โมเดลวิชันอ่านคีย์เฟรม ส่วนโมเดลข้อความทั่วไปจะทำ OCR บนอุปกรณ์นี้ก่อน คลิกคีย์เฟรมใดก็ได้เพื่อข้ามไปยังเวลานั้น",
        "Mở video đã nhập và chuyển sang tab «Hình ảnh» để phát video gốc, phân tích khung hình thủ công và xem dòng thời gian khung hình chính. Mô hình thị giác đọc khung hình chính; mô hình văn bản thuần sẽ chạy OCR trên thiết bị này trước. Nhấp vào bất kỳ khung hình chính nào để chuyển đến thời điểm tương ứng.",
        "Buka video yang diimpor dan beralih ke tab \"Gambar\" untuk memutar video asli, menganalisis gambar secara manual, dan melihat linimasa keyframe. Model visi membaca keyframe; model teks biasa menjalankan OCR di perangkat ini terlebih dahulu. Klik keyframe mana pun untuk melompat ke waktu tersebut.",
        "İçe aktarılan bir videoyu açıp «Görüntü» sekmesine geçerek orijinal videoyu oynatabilir, görüntüleri elle analiz edebilir ve kare anahtarı zaman çizelgesini görüntüleyebilirsiniz. Görüntü modelleri kare anahtarlarını okur; salt metin modelleri önce bu cihazda OCR çalıştırır. İlgili ana kareye atlamak için herhangi bir kare anahtarına tıklayın.",
        "Open een geïmporteerde video en schakel over naar het tabblad 'Beeld' om de originele video af te spelen, beelden handmatig te analyseren en de tijdlijn met keyframes te bekijken. Visiemodellen lezen de keyframes; modellen met alleen tekst voeren eerst OCR op dit apparaat uit. Klik op een keyframe om naar dat tijdstip te springen.",
        "Otwórz zaimportowane wideo i przełącz się na kartę „Obraz”, aby odtworzyć oryginalne wideo, ręcznie analizować klatki i wyświetlić oś czasu klatek kluczowych. Modele wizyjne odczytują klatki kluczowe; modele czysto tekstowe najpierw wykonują OCR na tym urządzeniu. Kliknij dowolną klatkę kluczową, aby przejść do danego momentu.",
        "Відкрийте імпортоване відео та перейдіть на вкладку «Кадри», щоб відтворити оригінальне відео, вручну проаналізувати кадри й переглянути шкалу ключових кадрів. Моделі зору читають ключові кадри; звичайні текстові моделі спершу виконують OCR на цьому пристрої. Натисніть будь-який ключовий кадр, щоб перейти до відповідного моменту.",
        "Öppna en importerad video och byt till fliken \"Bild\" för att spela upp originalvideon, analysera bilder manuellt och visa tidslinjen för nyckelbildrutor. Bildmodeller läser nyckelbildrutorna; vanliga textmodeller kör OCR på den här enheten först. Klicka på en nyckelbildruta för att hoppa till den tiden.",
    ],
)

add(
    "悬浮层工具条可复制到剪贴板或保存归档（微信截图风格）；「保存为文件…」会弹出保存窗让你选择保存位置与文件名，默认落在上次保存的目录（首次为桌面），取消保存窗不影响已绘标注",
    [
        "懸浮層工具條可複製到剪貼簿或儲存歸檔（微信截圖風格）；「儲存為檔案…」會彈出儲存窗讓你選擇儲存位置與檔案名稱，預設落在上次儲存的目錄（首次為桌面），取消儲存窗不影響已繪標註",
        "The overlay toolbar can copy to the clipboard or save to the archive (WeChat-screenshot style); \"Save to File…\" opens a save dialog where you choose the location and file name, defaulting to the last saved folder (the Desktop the first time). Canceling the dialog does not affect the annotations you have drawn",
        "オーバーレイのツールバーはクリップボードへのコピーやアーカイブへの保存ができます（WeChat のスクリーンショット風）。「ファイルとして保存…」を選ぶと保存ダイアログが開き、保存先とファイル名を選択できます。既定では前回保存したフォルダ（初回はデスクトップ）になります。ダイアログをキャンセルしても描いた注釈は失われません",
        "오버레이 도구 모음은 클립보드에 복사하거나 보관함에 저장할 수 있습니다(WeChat 스크린샷 스타일). \"파일로 저장…\"은 저장 위치와 파일 이름을 선택하는 저장 대화상자를 엽니다. 기본값은 마지막 저장 폴더(처음에는 바탕 화면)입니다. 대화상자를 취소해도 그린 주석은 그대로 유지됩니다",
        "La barre d'outils de la superposition permet de copier dans le presse-papiers ou d'enregistrer dans les archives (style capture d'écran WeChat) ; « Enregistrer dans un fichier… » ouvre une boîte de dialogue où vous choisissez l'emplacement et le nom du fichier, par défaut le dernier dossier d'enregistrement (le Bureau la première fois). Annuler la boîte de dialogue ne supprime pas les annotations déjà dessinées",
        "Die Symbolleiste der Überlagerung kann in die Zwischenablage kopieren oder ins Archiv speichern (WeChat-Screenshot-Stil); „Als Datei sichern…\" öffnet einen Speicherdialog, in dem du Speicherort und Dateinamen auswählst, standardmäßig der zuletzt gespeicherte Ordner (beim ersten Mal der Schreibtisch). Abbrechen des Dialogs lässt die gezeichneten Anmerkungen unberührt",
        "La barra de herramientas de la capa superpuesta permite copiar al portapapeles o guardar en el archivo (estilo captura de WeChat); «Guardar como archivo…» abre un cuadro de diálogo donde eliges la ubicación y el nombre del archivo, y usa por defecto la última carpeta guardada (el Escritorio la primera vez). Cancelar el cuadro de diálogo no afecta a las anotaciones ya dibujadas",
        "La barra degli strumenti della sovrapposizione può copiare negli appunti o salvare nell'archivio (stile screenshot di WeChat); «Salva come file…» apre una finestra di salvataggio in cui scegli posizione e nome del file, con impostazione predefinita l'ultima cartella salvata (la Scrivania la prima volta). Annullare la finestra non modifica le annotazioni già disegnate",
        "A barra de ferramentas da sobreposição pode copiar para a área de transferência ou salvar no arquivo (estilo captura do WeChat); \"Salvar como arquivo…\" abre uma caixa de diálogo onde você escolhe o local e o nome do arquivo, usando por padrão a última pasta salva (a Área de Trabalho na primeira vez). Cancelar a caixa de diálogo não afeta as anotações já desenhadas",
        "Панель инструментов оверлея позволяет копировать в буфер обмена или сохранять в архив (в стиле скриншотов WeChat); «Сохранить как файл…» открывает диалог, где вы выбираете место и имя файла, по умолчанию — последняя папка сохранения (в первый раз — Рабочий стол). Отмена диалога не влияет на уже нарисованные пометки",
        "يمكن لشريط أدوات الطبقة العائمة النسخ إلى الحافظة أو الحفظ في الأرشيف (بأسلوب لقطات WeChat)؛ يفتح «حفظ كملف…» مربع حوار لحفظ تختار فيه الموقع واسم الملف، ويُفترض افتراضيًا آخر مجلد حفظ (سطح المكتب في المرة الأولى). إلغاء مربع الحوار لا يؤثر على التعليقات المرسومة",
        "ओवरले टूलबार क्लिपबोर्ड पर कॉपी कर सकता है या संग्रह में सहेज सकता है (WeChat स्क्रीनशॉट शैली); «फ़ाइल के रूप में सहेजें…» एक सेव डायलॉग खोलता है जिसमें आप स्थान और फ़ाइल नाम चुनते हैं, डिफ़ॉल्ट रूप से पिछला सहेजा फ़ोल्डर (पहली बार डेस्कटॉप)। डायलॉग रद्द करने पर बनाए गए एनोटेशन प्रभावित नहीं होते",
        "แถบเครื่องมือของเลเยอร์ลอยสามารถคัดลอกไปยังคลิปบอร์ดหรือบันทึกเข้าคลัง (สไตล์สกรีนช็อต WeChat) «บันทึกเป็นไฟล์…» จะเปิดหน้าต่างบันทึกให้เลือกตำแหน่งและชื่อไฟล์ โดยค่าเริ่มต้นคือโฟลเดอร์ที่บันทึกล่าสุด (ครั้งแรกคือเดสก์ท็อป) การยกเลิกหน้าต่างไม่กระทบคำอธิบายที่วาดไว้",
        "Thanh công cụ lớp phủ có thể sao chép vào clipboard hoặc lưu vào kho lưu trữ (kiểu ảnh chụp WeChat); «Lưu thành tệp…» mở hộp thoại lưu để bạn chọn vị trí và tên tệp, mặc định là thư mục đã lưu lần trước (lần đầu là Màn hình nền). Hủy hộp thoại không ảnh hưởng đến chú thích đã vẽ",
        "Bilah alat overlay dapat menyalin ke papan klip atau menyimpan ke arsip (gaya tangkapan layar WeChat); \"Simpan sebagai file…\" membuka dialog penyimpanan untuk memilih lokasi dan nama file, default ke folder terakhir yang disimpan (Desktop saat pertama kali). Membatalkan dialog tidak memengaruhi anotasi yang sudah digambar",
        "Yer paylaşımı araç çubuğu panoya kopyalayabilir veya arşive kaydedebilir (WeChat ekran görüntüsü tarzı); «Dosya olarak kaydet…» konum ve dosya adını seçeceğiniz bir kaydetme iletişim kutusu açar; varsayılan olarak son kaydedilen klasör (ilk seferde Masaüstü). İletişim kutusunu iptal etmek çizilen açıklamaları etkilemez",
        "De werkbalk van de overlay kan naar het klembord kopiëren of naar het archief opslaan (WeChat-screenshotstijl); 'Opslaan als bestand…' opent een opslagvenster waarin je de locatie en bestandsnaam kiest, standaard de laatst opgeslagen map (de eerste keer het bureaublad). Het venster annuleren laat de getekende annotaties ongemoeid",
        "Pasek narzędzi nakładki umożliwia kopiowanie do schowka lub zapisanie w archiwum (styl zrzutów WeChat); „Zapisz jako plik…” otwiera okno zapisu, w którym wybierasz lokalizację i nazwę pliku — domyślnie ostatni zapisany folder (za pierwszym razem Pulpit). Anulowanie okna nie wpływa na narysowane adnotacje",
        "Панель інструментів накладинки дає змогу копіювати в буфер обміну або зберігати в архів (у стилі скриншотів WeChat); «Зберегти як файл…» відкриває вікно збереження, де ви вибираєте місце та ім'я файлу, за замовчуванням — остання збережена тека (уперше — Робочий стіл). Скасування вікна не впливає на намальовані позначки",
        "Overläggets verktygsfält kan kopiera till urklipp eller spara till arkivet (WeChat-skärmbildsstil); \"Spara som fil…\" öppnar en sparadialog där du väljer plats och filnamn, och standardvärdet är den senast sparade mappen (skrivbordet första gången). Att avbryta dialogen påverkar inte de ritade anteckningarna",
    ],
)

add(
    "工具栏「钉住」按钮可将截图置顶常驻屏幕并继续标注，点击保存后入库归档；「OCR识别」按钮则先钉住截图，并在钉住窗口右侧弹出识别文字面板，可直接编辑或复制（单纯钉住时没有这块文字）",
    [
        "工具列「釘住」按鈕可將截圖置頂常駐螢幕並繼續標註，點擊儲存後入庫歸檔；「OCR 識別」按鈕則先釘住截圖，並在釘住視窗右側彈出識別文字面板，可直接編輯或複製（單純釘住時沒有這塊文字）",
        "The toolbar's \"Pin\" button keeps the screenshot on top of the screen so you can keep annotating, and saving it files it into the archive; the \"OCR\" button first pins the screenshot and pops up a recognized-text panel on the right of the pinned window, where you can edit or copy the text directly (pinning alone shows no such text)",
        "ツールバーの「ピン留め」ボタンはスクリーンショットを画面の最前面に常駐させ、そのまま注釈を続けられます。保存するとアーカイブに登録されます。「OCR 認識」ボタンはまずスクリーンショットをピン留めし、ピン留めウィンドウの右側に認識テキストのパネルを表示します。テキストはその場で編集またはコピーできます（ピン留めのみの場合はこのテキストは表示されません）",
        "도구 모음의 \"고정\" 버튼은 스크린샷을 화면 맨 위에 고정해 계속 주석을 달 수 있게 하고, 저장하면 보관함에 등록됩니다. \"OCR 인식\" 버튼은 먼저 스크린샷을 고정하고 고정 창 오른쪽에 인식된 텍스트 패널을 띄우며, 여기서 바로 편집하거나 복사할 수 있습니다(고정만 하면 이 텍스트는 표시되지 않습니다)",
        "Le bouton « Épingler » de la barre d'outils garde la capture d'écran au premier plan pour continuer à annoter, et l'enregistrement l'archive ; le bouton « OCR » épingle d'abord la capture puis affiche un panneau de texte reconnu à droite de la fenêtre épinglée, où vous pouvez modifier ou copier le texte directement (un simple épinglage n'affiche pas ce texte)",
        "Die Schaltfläche „Anheften\" in der Symbolleiste hält den Screenshot oben auf dem Bildschirm, sodass du weiter annotieren kannst; beim Sichern wird er ins Archiv übernommen. Die Schaltfläche „OCR\" heftet den Screenshot zuerst an und zeigt rechts am angehefteten Fenster ein Panel mit erkanntem Text, den du direkt bearbeiten oder kopieren kannst (beim reinen Anheften erscheint dieser Text nicht)",
        "El botón «Fijar» de la barra de herramientas mantiene la captura en primer plano para seguir anotando, y al guardarla se archiva; el botón «OCR» primero fija la captura y muestra un panel de texto reconocido a la derecha de la ventana fijada, donde puedes editar o copiar el texto directamente (si solo la fijas, no aparece ese texto)",
        "Il pulsante «Fissa» della barra degli strumenti mantiene lo screenshot in primo piano per continuare ad annotare, e salvandolo lo archivia; il pulsante «OCR» fissa prima lo screenshot e mostra un pannello di testo riconosciuto a destra della finestra fissata, dove puoi modificare o copiare il testo direttamente (con la sola fissatura questo testo non compare)",
        "O botão \"Fixar\" da barra de ferramentas mantém a captura de tela em primeiro plano para continuar anotando, e ao salvar ela é arquivada; o botão \"OCR\" primeiro fixa a captura e exibe um painel de texto reconhecido à direita da janela fixada, onde você pode editar ou copiar o texto diretamente (ao apenas fixar, esse texto não aparece)",
        "Кнопка «Закрепить» на панели инструментов удерживает снимок поверх экрана, чтобы можно было продолжать разметку, а при сохранении он попадает в архив; кнопка «OCR» сначала закрепляет снимок и показывает справа от закреплённого окна панель распознанного текста, который можно сразу редактировать или копировать (при простом закреплении этого текста нет)",
        "يُبقي زر «تثبيت» في شريط الأدوات لقطة الشاشة فوق سطح المكتب لتواصل التعليق، وعند الحفظ تُؤرشف؛ أما زر «التعرف الضوئي» فيثبّت اللقطة أولاً ويعرض لوحة النص المتعرَّف عليه على يمين النافذة المثبتة، حيث يمكنك تحرير النص أو نسخه مباشرة (التثبيت وحده لا يُظهر هذا النص)",
        "टूलबार का «पिन» बटन स्क्रीनशॉट को स्क्रीन के ऊपर बनाए रखता है ताकि आप एनोटेट करते रह सकें, और सहेजने पर वह संग्रह में दर्ज हो जाता है; «OCR» बटन पहले स्क्रीनशॉट को पिन करता है और पिन की गई विंडो के दाईं ओर पहचाने गए टेक्स्ट का पैनल दिखाता है, जहाँ आप सीधे टेक्स्ट संपादित या कॉपी कर सकते हैं (केवल पिन करने पर यह टेक्स्ट नहीं दिखता)",
        "ปุ่ม «ปักหมุด» บนแถบเครื่องมือจะตรึงสกรีนช็อตให้อยู่บนสุดของหน้าจอเพื่อให้คุณใส่คำอธิบายต่อ และเมื่อบันทึกจะถูกจัดเก็บเข้าคลัง ส่วนปุ่ม «OCR» จะปักหมุดสกรีนช็อตก่อน แล้วแสดงแผงข้อความที่รู้จำได้ทางด้านขวาของหน้าต่างที่ปักหมุด ซึ่งแก้ไขหรือคัดลอกข้อความได้ทันที (การปักหมุดอย่างเดียวจะไม่มีข้อความนี้)",
        "Nút «Ghim» trên thanh công cụ giữ ảnh chụp màn hình nổi trên cùng để bạn tiếp tục chú thích, và khi lưu sẽ được đưa vào kho lưu trữ; nút «OCR» trước tiên ghim ảnh chụp rồi hiện bảng văn bản nhận dạng ở bên phải cửa sổ đã ghim, nơi bạn có thể chỉnh sửa hoặc sao chép văn bản trực tiếp (chỉ ghim thì không có văn bản này)",
        "Tombol \"Sematkan\" di bilah alat menahan tangkapan layar tetap di atas layar agar Anda bisa terus menganotasi, dan saat disimpan akan diarsipkan; tombol \"OCR\" lebih dulu menyematkan tangkapan layar lalu menampilkan panel teks yang dikenali di sisi kanan jendela yang disematkan, tempat Anda bisa langsung mengedit atau menyalin teks (menyematkan saja tidak menampilkan teks ini)",
        "Araç çubuğundaki «Sabitle» düğmesi ekran görüntüsünü ekranın üstünde tutarak açıklama eklemeye devam etmenizi sağlar; kaydettiğinizde arşive girer. «OCR» düğmesi ise önce ekran görüntüsünü sabitler ve sabitlenen pencerenin sağında tanınan metin panelini açar; metni doğrudan düzenleyebilir veya kopyalayabilirsiniz (yalnızca sabitlemede bu metin görünmez)",
        "Met de knop 'Vastmaken' in de werkbalk blijft de schermafbeelding bovenaan in beeld zodat je kunt blijven annoteren, en bij opslaan wordt deze gearchiveerd; de knop 'OCR' maakt de schermafbeelding eerst vast en toont rechts van het vastgemaakte venster een paneel met herkende tekst, waarin je de tekst direct kunt bewerken of kopiëren (bij alleen vastmaken verschijnt deze tekst niet)",
        "Przycisk „Przypnij” na pasku narzędzi utrzymuje zrzut ekranu na wierzchu, abyś mógł dalej dodawać adnotacje, a po zapisaniu trafia on do archiwum; przycisk „OCR” najpierw przypina zrzut i pokazuje po prawej stronie przypiętego okna panel rozpoznanego tekstu, w którym możesz go bezpośrednio edytować lub skopiować (samo przypięcie nie pokazuje tego tekstu)",
        "Кнопка «Закріпити» на панелі інструментів утримує знімок екрана поверх інших вікон, щоб можна було продовжити позначати, а після збереження він потрапляє до архіву; кнопка «OCR» спершу закріплює знімок і показує праворуч від закріпленого вікна панель розпізнаного тексту, де його можна одразу редагувати чи копіювати (за простого закріплення цього тексту немає)",
        "Knappen \"Fäst\" i verktygsfältet håller skärmbilden överst på skärmen så att du kan fortsätta anteckna, och när du sparar arkiveras den; knappen \"OCR\" fäster först skärmbilden och visar en panel med igenkänd text till höger om det fästa fönstret, där du kan redigera eller kopiera texten direkt (vid enbart fästning visas ingen sådan text)",
    ],
)


def main():
    with open(CATALOG, encoding='utf-8') as f:
        catalog = json.load(f)
    existing = catalog['strings']
    filled = missing_key = 0
    for key, vals in T.items():
        entry = existing.get(key)
        if entry is None:
            print(f'⚠️ 目录中无此 key，跳过：{key[:30]}')
            missing_key += 1
            continue
        locs = entry.setdefault('localizations', {})
        if 'zh-Hans' not in locs:
            locs['zh-Hans'] = {'stringUnit': {'state': 'translated', 'value': key}}
        for lang, val in zip(LANGS, vals):
            if lang in locs:
                continue
            locs[lang] = {'stringUnit': {'state': 'translated', 'value': val}}
            filled += 1
    with open(CATALOG, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')
    print(f'完成：{len(T)} 条 key，新增 {filled} 条译文（缺失 key {missing_key} 条）')


if __name__ == '__main__':
    main()
