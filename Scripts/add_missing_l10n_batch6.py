import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'

LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add(
    "选择视觉模型后点击「分析画面」；不支持图片的模型会先在本机 OCR，只把带时间标记的文字发给模型",
    [
        "選擇視覺模型後點擊「分析畫面」；不支援圖片的模型會先在本機 OCR，只把帶時間標記的文字發給模型",
        "After selecting a vision model, click \"Analyze frames\"; models that don't support images will run OCR on this device first and send only timestamped text to the model",
        "視覚モデルを選択して「画面を分析」をクリックします。画像非対応のモデルは先に本機で OCR を実行し、タイムスタンプ付きのテキストだけをモデルに送信します",
        "비전 모델을 선택한 후 \"화면 분석\"을 클릭하세요. 이미지를 지원하지 않는 모델은 먼저 이 기기에서 OCR을 실행하고 시간 표시가 있는 텍스트만 모델로 전송합니다",
        "Après avoir sélectionné un modèle de vision, cliquez sur « Analyser l'image » ; les modèles qui ne prennent pas en charge les images effectuent d'abord l'OCR sur cet appareil et n'envoient au modèle que le texte horodaté",
        "Wählen Sie ein Vision-Modell und klicken Sie auf „Bild analysieren\"; Modelle ohne Bildunterstützung führen zuerst eine OCR auf diesem Gerät durch und senden nur den mit Zeitstempeln versehenen Text an das Modell",
        "Tras seleccionar un modelo de visión, haz clic en «Analizar imagen»; los modelos que no admiten imágenes realizan primero el OCR en este dispositivo y solo envían al modelo el texto con marcas de tiempo",
        "Dopo aver selezionato un modello di visione, fai clic su «Analizza immagine»; i modelli che non supportano le immagini eseguono prima l'OCR su questo dispositivo e inviano al modello solo il testo con marca temporale",
        "Após selecionar um modelo de visão, clique em \"Analisar imagem\"; modelos que não suportam imagens executam primeiro o OCR neste dispositivo e enviam ao modelo apenas o texto com marcação de tempo",
        "Выбрав модель компьютерного зрения, нажмите «Проанализировать изображение»; модели без поддержки изображений сначала выполняют OCR на этом устройстве и отправляют модели только текст с отметками времени",
        "بعد اختيار نموذج الرؤية، انقر على «تحليل الصورة»؛ النماذج التي لا تدعم الصور تُجري أولاً التعرف الضوئي على هذا الجهاز وترسل إلى النموذج النص المرفق بطوابع زمنية فقط",
        "विज़न मॉडल चुनने के बाद «छवि का विश्लेषण करें» पर क्लिक करें; जो मॉडल छवियों का समर्थन नहीं करते वे पहले इस डिवाइस पर OCR करते हैं और मॉडल को केवल टाइमस्टैम्प वाला टेक्स्ट भेजते हैं",
        "หลังจากเลือกโมเดลวิชันแล้ว ให้คลิก «วิเคราะห์ภาพ» โมเดลที่ไม่รองรับรูปภาพจะทำ OCR บนอุปกรณ์นี้ก่อน แล้วส่งเฉพาะข้อความที่มีการประทับเวลาไปยังโมเดล",
        "Sau khi chọn mô hình thị giác, hãy nhấp vào «Phân tích hình ảnh»; các mô hình không hỗ trợ hình ảnh sẽ chạy OCR trên thiết bị này trước và chỉ gửi văn bản có dấu thời gian cho mô hình",
        "Setelah memilih model visi, klik \"Analisis gambar\"; model yang tidak mendukung gambar akan menjalankan OCR di perangkat ini terlebih dahulu dan hanya mengirim teks bertanda waktu ke model",
        "Bir görüntü modeli seçtikten sonra «Görüntüyü analiz et»e tıklayın; görüntüleri desteklemeyen modeller önce bu cihazda OCR çalıştırır ve modele yalnızca zaman damgalı metni gönderir",
        "Nadat je een visiemodel hebt geselecteerd, klik je op 'Afbeelding analyseren'; modellen die geen afbeeldingen ondersteunen, voeren eerst OCR op dit apparaat uit en sturen alleen tekst met tijdstempels naar het model",
        "Po wybraniu modelu wizyjnego kliknij „Analizuj obraz”; modele nieobsługujące obrazów najpierw wykonują OCR na tym urządzeniu i wysyłają do modelu tylko tekst ze znacznikami czasu",
        "Вибравши модель комп'ютерного зору, натисніть «Проаналізувати зображення»; моделі без підтримки зображень спершу виконують OCR на цьому пристрої й надсилають моделі лише текст із позначками часу",
        "När du har valt en bildmodell klickar du på \"Analysera bild\"; modeller som inte stöder bilder kör OCR på den här enheten först och skickar bara tidsstämplad text till modellen",
    ],
)

add(
    "支持 m4a、mp3、wav，也支持 mp4、mov、m4v 视频导入（自动抽取音轨，原始视频同文件夹保留）",
    [
        "支援 m4a、mp3、wav，也支援 mp4、mov、m4v 影片匯入（自動擷取音軌，原始影片同資料夾保留）",
        "Supports m4a, mp3, and wav, as well as mp4, mov, and m4v video imports (audio track extracted automatically; the original video is kept in the same folder)",
        "m4a、mp3、wav に対応し、mp4、mov、m4v 動画の読み込みにも対応します（音声トラックを自動抽出し、元の動画は同じフォルダに保持されます）",
        "m4a, mp3, wav를 지원하며 mp4, mov, m4v 동영상 가져오기도 지원합니다(오디오 트랙을 자동 추출하고 원본 동영상은 같은 폴더에 보관됩니다)",
        "Prend en charge les formats m4a, mp3 et wav, ainsi que l'import de vidéos mp4, mov et m4v (la piste audio est extraite automatiquement et la vidéo d'origine est conservée dans le même dossier)",
        "Unterstützt m4a, mp3 und wav sowie den Import von mp4-, mov- und m4v-Videos (Audiospur wird automatisch extrahiert, das Originalvideo bleibt im selben Ordner erhalten)",
        "Compatible con m4a, mp3 y wav, y también con la importación de vídeos mp4, mov y m4v (la pista de audio se extrae automáticamente y el vídeo original se conserva en la misma carpeta)",
        "Supporta m4a, mp3 e wav, oltre all'importazione di video mp4, mov e m4v (la traccia audio viene estratta automaticamente e il video originale viene conservato nella stessa cartella)",
        "Suporta m4a, mp3 e wav, além da importação de vídeos mp4, mov e m4v (a faixa de áudio é extraída automaticamente e o vídeo original é mantido na mesma pasta)",
        "Поддерживаются m4a, mp3 и wav, а также импорт видео mp4, mov и m4v (звуковая дорожка извлекается автоматически, исходное видео сохраняется в той же папке)",
        "يدعم m4a وmp3 وwav، وكذلك استيراد فيديو mp4 وmov وm4v (يُستخرج المسار الصوتي تلقائيًا ويُحتفظ بالفيديو الأصلي في المجلد نفسه)",
        "m4a, mp3 और wav के साथ-साथ mp4, mov और m4v वीडियो आयात का समर्थन करता है (ऑडियो ट्रैक स्वतः निकाला जाता है, मूल वीडियो उसी फ़ोल्डर में सुरक्षित रहता है)",
        "รองรับ m4a, mp3 และ wav รวมถึงการนำเข้าวิดีโอ mp4, mov และ m4v (ดึงแทร็กเสียงออกโดยอัตโนมัติ และเก็บวิดีโอต้นฉบับไว้ในโฟลเดอร์เดียวกัน)",
        "Hỗ trợ m4a, mp3 và wav, cũng như nhập video mp4, mov và m4v (tự động trích xuất âm thanh, video gốc được giữ trong cùng thư mục)",
        "Mendukung m4a, mp3, dan wav, serta impor video mp4, mov, dan m4v (trek audio diekstrak otomatis, video asli disimpan di folder yang sama)",
        "m4a, mp3 ve wav ile birlikte mp4, mov ve m4v video içe aktarmayı destekler (ses kanalı otomatik çıkarılır, orijinal video aynı klasörde saklanır)",
        "Ondersteunt m4a, mp3 en wav, evenals het importeren van mp4-, mov- en m4v-video's (audiospoor wordt automatisch geëxtraheerd, de originele video blijft in dezelfde map bewaard)",
        "Obsługuje m4a, mp3 i wav oraz import wideo mp4, mov i m4v (ścieżka audio jest wyodrębniana automatycznie, oryginalne wideo pozostaje w tym samym folderze)",
        "Підтримує m4a, mp3 і wav, а також імпорт відео mp4, mov і m4v (звукову доріжку вилучено автоматично, оригінальне відео зберігається в тій самій теці)",
        "Stöder m4a, mp3 och wav samt import av mp4-, mov- och m4v-video (ljudspåret extraheras automatiskt och originalvideon sparas i samma mapp)",
    ],
)

add(
    "磁盘剩余空间不足 200MB（PCM 分片约 1GB/小时），已自动停止录音以保全已录内容。请清理磁盘后重新录制。",
    [
        "磁碟剩餘空間不足 200MB（PCM 分片約 1GB/小時），已自動停止錄音以保全已錄內容。請清理磁碟後重新錄製。",
        "Less than 200 MB of disk space left (PCM chunks use about 1 GB per hour). Recording was stopped automatically to preserve what has already been captured. Free up disk space and start a new recording.",
        "ディスクの空き容量が 200MB 未満です（PCM チャンクは 1 時間あたり約 1GB）。録音済みの内容を保護するため録音を自動停止しました。ディスクを空けてから録音し直してください。",
        "디스크 여유 공간이 200MB 미만입니다(PCM 청크는 시간당 약 1GB). 이미 녹음된 내용을 보호하기 위해 녹음을 자동으로 중지했습니다. 디스크를 정리한 후 다시 녹음하세요.",
        "Moins de 200 Mo d'espace disque disponible (les segments PCM occupent environ 1 Go par heure). L'enregistrement a été arrêté automatiquement pour préserver ce qui a déjà été capturé. Libérez de l'espace disque, puis relancez l'enregistrement.",
        "Weniger als 200 MB freier Speicherplatz (PCM-Segmente belegen etwa 1 GB pro Stunde). Die Aufnahme wurde automatisch gestoppt, um das bereits Aufgezeichnete zu sichern. Schaffe Speicherplatz frei und starte eine neue Aufnahme.",
        "Quedan menos de 200 MB de espacio en disco (los segmentos PCM ocupan unos 1 GB por hora). La grabación se detuvo automáticamente para conservar lo ya capturado. Libera espacio en disco y vuelve a grabar.",
        "Meno di 200 MB di spazio su disco disponibile (i segmenti PCM occupano circa 1 GB all'ora). La registrazione è stata interrotta automaticamente per preservare quanto già acquisito. Libera spazio su disco e registra di nuovo.",
        "Restam menos de 200 MB de espaço em disco (os segmentos PCM ocupam cerca de 1 GB por hora). A gravação foi interrompida automaticamente para preservar o que já foi capturado. Libere espaço em disco e grave novamente.",
        "Осталось менее 200 МБ свободного места (сегменты PCM занимают около 1 ГБ в час). Запись была остановлена автоматически, чтобы сохранить уже записанное. Освободите место на диске и начните запись заново.",
        "المساحة المتبقية على القرص أقل من 200 ميغابايت (تستهلك مقاطع PCM نحو 1 غيغابايت في الساعة). تم إيقاف التسجيل تلقائيًا للحفاظ على ما تم تسجيله. حرّر مساحة على القرص ثم ابدأ التسجيل من جديد.",
        "डिस्क में 200MB से कम जगह बची है (PCM खंड लगभग 1GB/घंटा लेते हैं)। पहले से रिकॉर्ड की गई सामग्री बचाने के लिए रिकॉर्डिंग स्वतः रोक दी गई है। डिस्क खाली करके दोबारा रिकॉर्ड करें।",
        "พื้นที่ว่างบนดิสก์เหลือน้อยกว่า 200MB (ไฟล์ PCM ใช้ประมาณ 1GB ต่อชั่วโมง) ระบบหยุดบันทึกเสียงอัตโนมัติเพื่อรักษาสิ่งที่บันทึกไว้แล้ว โปรดเพิ่มพื้นที่ว่างบนดิสก์แล้วบันทึกใหม่",
        "Dung lượng trống trên đĩa còn dưới 200 MB (các đoạn PCM chiếm khoảng 1 GB mỗi giờ). Quá trình ghi âm đã tự động dừng để bảo toàn nội dung đã ghi. Hãy giải phóng dung lượng đĩa rồi ghi lại.",
        "Ruang disk tersisa kurang dari 200 MB (potongan PCM memakan sekitar 1 GB per jam). Perekaman dihentikan otomatis untuk menjaga apa yang sudah terekam. Kosongkan ruang disk lalu rekam ulang.",
        "Disk alanı 200 MB'ın altında (PCM parçaları saatte yaklaşık 1 GB). Kaydedilenleri korumak için kayıt otomatik olarak durduruldu. Diskte yer açıp yeniden kaydedin.",
        "Minder dan 200 MB schijfruimte over (PCM-fragmenten gebruiken ongeveer 1 GB per uur). De opname is automatisch gestopt om het al opgenomen materiaal te behouden. Maak schijfruimte vrij en neem opnieuw op.",
        "Mniej niż 200 MB wolnego miejsca na dysku (fragmenty PCM zajmują około 1 GB na godzinę). Nagrywanie zostało automatycznie zatrzymane, aby zachować już zarejestrowany materiał. Zwolnij miejsce na dysku i nagraj ponownie.",
        "Залишилося менше 200 МБ вільного місця (сегменти PCM займають близько 1 ГБ на годину). Запис автоматично зупинено, щоб зберегти вже записане. Звільніть місце на диску й почніть запис знову.",
        "Mindre än 200 MB ledigt diskutrymme kvar (PCM-segment tar cirka 1 GB per timme). Inspelningen stoppades automatiskt för att bevara det som redan spelats in. Frigör diskutrymme och spela in igen.",
    ],
)

add(
    "共抽取 %1$d 个关键帧（已存入条目文件夹，可重复使用），将分约 %2$d 批分析。是否继续？关键帧将上传当前模型。",
    [
        "共擷取 %1$d 個關鍵影格（已存入條目資料夾，可重複使用），將分約 %2$d 批分析。是否繼續？關鍵影格將上傳當前模型。",
        "Extracted %1$d keyframes (saved in the item folder and reusable); they will be analyzed in about %2$d batches. Continue? The keyframes will be uploaded to the current model.",
        "合計 %1$d 個のキーフレームを抽出しました（エントリフォルダに保存され再利用可能）。約 %2$d バッチに分けて分析します。続行しますか？キーフレームは現在のモデルにアップロードされます。",
        "총 %1$d개의 키프레임을 추출했습니다(항목 폴더에 저장되어 재사용 가능). 약 %2$d개 배치로 나누어 분석합니다. 계속할까요? 키프레임은 현재 모델로 업로드됩니다.",
        "%1$d images clés extraites (enregistrées dans le dossier de l'élément et réutilisables) ; elles seront analysées en environ %2$d lots. Continuer ? Les images clés seront téléversées vers le modèle actuel.",
        "%1$d Keyframes extrahiert (im Elementordner gespeichert und wiederverwendbar); sie werden in etwa %2$d Stapeln analysiert. Fortfahren? Die Keyframes werden auf das aktuelle Modell hochgeladen.",
        "Se extrajeron %1$d fotogramas clave (guardados en la carpeta del elemento y reutilizables); se analizarán en unos %2$d lotes. ¿Continuar? Los fotogramas clave se subirán al modelo actual.",
        "Estratti %1$d fotogrammi chiave (salvati nella cartella dell'elemento e riutilizzabili); verranno analizzati in circa %2$d lotti. Continuare? I fotogrammi chiave saranno caricati sul modello corrente.",
        "Foram extraídos %1$d quadros-chave (salvos na pasta do item e reutilizáveis); serão analisados em cerca de %2$d lotes. Continuar? Os quadros-chave serão enviados ao modelo atual.",
        "Извлечено %1$d ключевых кадров (сохранены в папке элемента и могут использоваться повторно); анализ пройдёт примерно в %2$d пакетах. Продолжить? Ключевые кадры будут загружены в текущую модель.",
        "تم استخراج %1$d إطارًا رئيسيًا (محفوظة في مجلد العنصر وقابلة لإعادة الاستخدام)، وستُحلَّل على نحو %2$d دفعة. هل تريد المتابعة؟ ستُرفع الإطارات الرئيسية إلى النموذج الحالي.",
        "कुल %1$d कीफ़्रेम निकाले गए (आइटम फ़ोल्डर में सहेजे गए, दोबारा उपयोग योग्य), लगभग %2$d बैच में विश्लेषण होगा। जारी रखें? कीफ़्रेम मौजूदा मॉडल पर अपलोड किए जाएँगे।",
        "ดึงคีย์เฟรมได้ %1$d ภาพ (บันทึกไว้ในโฟลเดอร์รายการ ใช้ซ้ำได้) จะแบ่งวิเคราะห์ประมาณ %2$d ชุด ดำเนินการต่อหรือไม่ คีย์เฟรมจะถูกอัปโหลดไปยังโมเดลปัจจุบัน",
        "Đã trích xuất %1$d khung hình chính (lưu trong thư mục mục và có thể tái sử dụng), sẽ phân tích theo khoảng %2$d lô. Tiếp tục? Các khung hình chính sẽ được tải lên mô hình hiện tại.",
        "Mengekstrak %1$d keyframe (disimpan di folder item dan dapat digunakan ulang), akan dianalisis dalam sekitar %2$d batch. Lanjutkan? Keyframe akan diunggah ke model saat ini.",
        "%1$d kare anahtarı çıkarıldı (öğe klasörüne kaydedildi, yeniden kullanılabilir); yaklaşık %2$d grupta analiz edilecek. Devam edilsin mi? Kare anahtarları geçerli modele yüklenecek.",
        "%1$d keyframes geëxtraheerd (opgeslagen in de itemmap en herbruikbaar); ze worden in ongeveer %2$d batches geanalyseerd. Doorgaan? De keyframes worden naar het huidige model geüpload.",
        "Wyodrębniono %1$d klatek kluczowych (zapisane w folderze elementu i wielokrotnego użytku); zostaną przeanalizowane w około %2$d partiach. Kontynuować? Klatki kluczowe zostaną przesłane do bieżącego modelu.",
        "Вилучено %1$d ключових кадрів (збережено в теці елемента, можна використовувати повторно); їх буде проаналізовано приблизно в %2$d пакетах. Продовжити? Ключові кадри буде завантажено до поточної моделі.",
        "Extraherade %1$d nyckelbildrutor (sparade i objektmappen och återanvändbara); de analyseras i cirka %2$d omgångar. Fortsätta? Nyckelbildrutorna laddas upp till den aktuella modellen.",
    ],
)

add(
    "将数据文件夹重置为默认路径：%@\n\n注意：自定义路径下的现有数据不会迁移，仍保留在原文件夹。重置后需要重启应用以重新加载数据。",
    [
        "將資料資料夾重設為預設路徑：%@\n\n注意：自訂路徑下的現有資料不會搬移，仍保留在原資料夾。重設後需要重新啟動應用程式以重新載入資料。",
        "Reset the data folder to the default path: %@\n\nNote: existing data in the custom path will not be migrated and remains in the original folder. You must restart the app after resetting to reload the data.",
        "データフォルダを既定のパスにリセットします：%@\n\n注意：カスタムパスにある既存のデータは移行されず、元のフォルダに残ります。リセット後はデータを再読み込みするためにアプリを再起動する必要があります。",
        "데이터 폴더를 기본 경로로 재설정합니다: %@\n\n참고: 사용자 지정 경로의 기존 데이터는 이전되지 않고 원래 폴더에 남아 있습니다. 재설정 후 데이터를 다시 불러오려면 앱을 재시작해야 합니다.",
        "Réinitialiser le dossier de données au chemin par défaut : %@\n\nRemarque : les données existantes dans le chemin personnalisé ne seront pas migrées et resteront dans le dossier d'origine. Vous devez redémarrer l'application après la réinitialisation pour recharger les données.",
        "Datenordner auf den Standardpfad zurücksetzen: %@\n\nHinweis: Vorhandene Daten im benutzerdefinierten Pfad werden nicht migriert und bleiben im ursprünglichen Ordner. Nach dem Zurücksetzen muss die App neu gestartet werden, um die Daten neu zu laden.",
        "Restablecer la carpeta de datos a la ruta predeterminada: %@\n\nNota: los datos existentes en la ruta personalizada no se migrarán y permanecerán en la carpeta original. Debes reiniciar la app tras restablecer para volver a cargar los datos.",
        "Reimposta la cartella dati sul percorso predefinito: %@\n\nNota: i dati esistenti nel percorso personalizzato non verranno migrati e rimarranno nella cartella originale. Dopo la reimpostazione è necessario riavviare l'app per ricaricare i dati.",
        "Redefinir a pasta de dados para o caminho padrão: %@\n\nObservação: os dados existentes no caminho personalizado não serão migrados e permanecerão na pasta original. É preciso reiniciar o app após a redefinição para recarregar os dados.",
        "Сбросить папку данных на путь по умолчанию: %@\n\nПримечание: существующие данные по пользовательскому пути не будут перенесены и останутся в исходной папке. После сброса потребуется перезапустить приложение, чтобы заново загрузить данные.",
        "إعادة تعيين مجلد البيانات إلى المسار الافتراضي: %@\n\nملاحظة: لن تُنقل البيانات الموجودة في المسار المخصص وستبقى في المجلد الأصلي. يجب إعادة تشغيل التطبيق بعد إعادة التعيين لإعادة تحميل البيانات.",
        "डेटा फ़ोल्डर को डिफ़ॉल्ट पथ पर रीसेट करें: %@\n\nध्यान दें: कस्टम पथ में मौजूद डेटा स्थानांतरित नहीं होगा और मूल फ़ोल्डर में ही रहेगा। रीसेट के बाद डेटा दोबारा लोड करने के लिए ऐप को पुनः आरंभ करना होगा।",
        "รีเซ็ตโฟลเดอร์ข้อมูลกลับเป็นพาธเริ่มต้น: %@\n\nหมายเหตุ: ข้อมูลที่มีอยู่ในพาธที่กำหนดเองจะไม่ถูกย้าย และจะยังคงอยู่ในโฟลเดอร์เดิม หลังรีเซ็ตต้องรีสตาร์ทแอปเพื่อโหลดข้อมูลใหม่",
        "Đặt lại thư mục dữ liệu về đường dẫn mặc định: %@\n\nLưu ý: dữ liệu hiện có ở đường dẫn tùy chỉnh sẽ không được di chuyển và vẫn nằm trong thư mục gốc. Sau khi đặt lại, bạn cần khởi động lại ứng dụng để tải lại dữ liệu.",
        "Setel ulang folder data ke jalur default: %@\n\nCatatan: data yang ada di jalur kustom tidak akan dipindahkan dan tetap berada di folder asal. Setelah disetel ulang, Anda perlu memulai ulang aplikasi untuk memuat ulang data.",
        "Veri klasörünü varsayılan yola sıfırla: %@\n\nNot: Özel yoldaki mevcut veriler taşınmaz ve özgün klasörde kalır. Sıfırlamadan sonra verileri yeniden yüklemek için uygulamayı yeniden başlatmanız gerekir.",
        "De gegevensmap terugzetten op het standaardpad: %@\n\nLet op: bestaande gegevens in het aangepaste pad worden niet gemigreerd en blijven in de oorspronkelijke map staan. Na het terugzetten moet je de app opnieuw starten om de gegevens opnieuw te laden.",
        "Przywróć folder danych do ścieżki domyślnej: %@\n\nUwaga: istniejące dane w ścieżce niestandardowej nie zostaną przeniesione i pozostaną w oryginalnym folderze. Po przywróceniu musisz ponownie uruchomić aplikację, aby ponownie wczytać dane.",
        "Скинути теку даних до стандартного шляху: %@\n\nПримітка: наявні дані в користувацькому шляху не буде перенесено, вони залишаться у вихідній теці. Після скидання потрібно перезапустити застосунок, щоб заново завантажити дані.",
        "Återställ datamappen till standardsökvägen: %@\n\nObs! Befintliga data på den anpassade sökvägen migreras inte och finns kvar i den ursprungliga mappen. Du måste starta om appen efter återställningen för att läsa in data igen.",
    ],
)

add(
    "切换后现有录音、转写与总结不会自动迁移，仍保留在原文件夹（切回原路径即可恢复显示）。新数据将保存到：\n\n%@\n\n确认切换并重启应用。",
    [
        "切換後現有錄音、轉寫與總結不會自動搬移，仍保留在原資料夾（切回原路徑即可恢復顯示）。新資料將儲存到：\n\n%@\n\n確認切換並重新啟動應用程式。",
        "Existing recordings, transcripts, and summaries will not be migrated after switching and will remain in the original folder (switch back to the original path to restore them). New data will be saved to:\n\n%@\n\nConfirm the switch and restart the app.",
        "切り替え後、既存の録音・文字起こし・要約は自動的に移行されず、元のフォルダに残ります（元のパスに戻せば再表示できます）。新しいデータは次に保存されます：\n\n%@\n\n切り替えを確認してアプリを再起動してください。",
        "전환 후 기존 녹음, 전사 및 요약은 자동으로 이전되지 않고 원래 폴더에 남습니다(원래 경로로 되돌리면 다시 표시됩니다). 새 데이터는 다음 위치에 저장됩니다:\n\n%@\n\n전환을 확인하고 앱을 재시작하세요.",
        "Après le changement, les enregistrements, transcriptions et résumés existants ne seront pas migrés et resteront dans le dossier d'origine (revenez au chemin d'origine pour les réafficher). Les nouvelles données seront enregistrées dans :\n\n%@\n\nConfirmez le changement et redémarrez l'application.",
        "Nach dem Wechsel werden vorhandene Aufnahmen, Transkripte und Zusammenfassungen nicht automatisch migriert und bleiben im ursprünglichen Ordner (zurück zum ursprünglichen Pfad wechseln, um sie wieder anzuzeigen). Neue Daten werden gespeichert unter:\n\n%@\n\nWechsel bestätigen und App neu starten.",
        "Tras el cambio, las grabaciones, transcripciones y resúmenes existentes no se migrarán y permanecerán en la carpeta original (vuelve a la ruta original para volver a mostrarlos). Los nuevos datos se guardarán en:\n\n%@\n\nConfirma el cambio y reinicia la app.",
        "Dopo il cambio, le registrazioni, le trascrizioni e i riepiloghi esistenti non verranno migrati e resteranno nella cartella originale (torna al percorso originale per visualizzarli di nuovo). I nuovi dati saranno salvati in:\n\n%@\n\nConferma il cambio e riavvia l'app.",
        "Após a troca, as gravações, transcrições e resumos existentes não serão migrados e permanecerão na pasta original (volte ao caminho original para exibi-los novamente). Os novos dados serão salvos em:\n\n%@\n\nConfirme a troca e reinicie o app.",
        "После переключения существующие записи, расшифровки и сводки не будут перенесены и останутся в исходной папке (вернитесь к исходному пути, чтобы снова их увидеть). Новые данные будут сохраняться в:\n\n%@\n\nПодтвердите переключение и перезапустите приложение.",
        "بعد التبديل، لن تُنقل التسجيلات والنصوص والملخصات الموجودة تلقائيًا وستبقى في المجلد الأصلي (عُد إلى المسار الأصلي لإعادة عرضها). ستُحفظ البيانات الجديدة في:\n\n%@\n\nأكّد التبديل وأعد تشغيل التطبيق.",
        "स्विच करने के बाद मौजूदा रिकॉर्डिंग, ट्रांसक्रिप्ट और सारांश स्वतः स्थानांतरित नहीं होंगे और मूल फ़ोल्डर में ही रहेंगे (वापस मूल पथ पर जाने से फिर दिखने लगेंगे)। नया डेटा यहाँ सहेजा जाएगा:\n\n%@\n\nस्विच की पुष्टि करें और ऐप को पुनः आरंभ करें।",
        "หลังสลับ ตอนนี้การบันทึก ถอดเสียง และสรุปที่มีอยู่จะไม่ถูกย้ายโดยอัตโนมัติ และจะยังอยู่ในโฟลเดอร์เดิม (สลับกลับไปยังพาธเดิมเพื่อแสดงอีกครั้ง) ข้อมูลใหม่จะถูกบันทึกไปที่:\n\n%@\n\nยืนยันการสลับและรีสตาร์ทแอป",
        "Sau khi chuyển, các bản ghi âm, bản gỡ băng và bản tóm tắt hiện có sẽ không được di chuyển tự động và vẫn ở trong thư mục gốc (chuyển lại đường dẫn gốc để hiển thị lại). Dữ liệu mới sẽ được lưu vào:\n\n%@\n\nXác nhận chuyển và khởi động lại ứng dụng.",
        "Setelah beralih, rekaman, transkrip, dan ringkasan yang ada tidak akan dipindahkan otomatis dan tetap berada di folder asal (beralih kembali ke jalur asal untuk menampilkannya lagi). Data baru akan disimpan ke:\n\n%@\n\nKonfirmasi peralihan dan mulai ulang aplikasi.",
        "Geçişten sonra mevcut kayıtlar, dökümler ve özetler otomatik olarak taşınmaz ve özgün klasörde kalır (yeniden görüntülemek için özgün yola geri dönün). Yeni veriler şuraya kaydedilecek:\n\n%@\n\nGeçişi onaylayın ve uygulamayı yeniden başlatın.",
        "Na het wisselen worden bestaande opnamen, transcripties en samenvattingen niet automatisch gemigreerd en blijven ze in de oorspronkelijke map staan (schakel terug naar het oorspronkelijke pad om ze weer te tonen). Nieuwe gegevens worden opgeslagen in:\n\n%@\n\nBevestig de wisseling en herstart de app.",
        "Po przełączeniu istniejące nagrania, transkrypcje i podsumowania nie zostaną automatycznie przeniesione i pozostaną w oryginalnym folderze (wróć do oryginalnej ścieżki, aby je ponownie wyświetlić). Nowe dane zostaną zapisane w:\n\n%@\n\nPotwierdź przełączenie i uruchom ponownie aplikację.",
        "Після перемикання наявні записи, розшифровки та підсумки не буде перенесено автоматично, вони залишаться у вихідній теці (поверніться до вихідного шляху, щоб знову їх побачити). Нові дані зберігатимуться до:\n\n%@\n\nПідтвердьте перемикання та перезапустіть застосунок.",
        "Efter bytet migreras inte befintliga inspelningar, transkriptioner och sammanfattningar automatiskt utan ligger kvar i den ursprungliga mappen (byt tillbaka till den ursprungliga sökvägen för att visa dem igen). Nya data sparas i:\n\n%@\n\nBekräfta bytet och starta om appen.",
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
