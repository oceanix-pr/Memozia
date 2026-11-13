#!/usr/bin/env python3
# 补齐缺失译文 · 第 2 批：剩余短串（9–20 字，22 条 × 20 语言）
#
# 合并策略同第 1 批：只补缺失语言，已存在的语言保持原样。
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('%lld/%lld', ['%lld/%lld'] * 20)

add('同步完成，无新内容', [
    '同步完成，無新內容', 'Sync complete, nothing new', '同期完了、新しい内容はありません',
    '동기화 완료, 새 내용 없음', 'Synchronisation terminée, rien de nouveau',
    'Synchronisierung abgeschlossen, nichts Neues', 'Sincronización completada, sin novedades',
    'Sincronizzazione completata, nessuna novità', 'Sincronização concluída, sem novidades',
    'Синхронизация завершена, нового нет', 'اكتملت المزامنة، لا جديد', 'सिंक पूरा, कुछ नया नहीं',
    'ซิงค์เสร็จ ไม่มีข้อมูลใหม่', 'Đồng bộ xong, không có gì mới', 'Sinkron selesai, tidak ada yang baru',
    'Eşitleme tamam, yeni içerik yok', 'Synchronisatie voltooid, niets nieuws',
    'Synchronizacja zakończona, brak nowości', 'Синхронізацію завершено, нового немає',
    'Synkronisering klar, inget nytt',
])

add('录屏启动失败：%@', [
    '螢幕錄製啟動失敗：%@', 'Failed to start screen recording: %@', '画面収録を開始できません：%@',
    '화면 녹화 시작 실패: %@', "Échec du démarrage de l'enregistrement d'écran : %@",
    'Bildschirmaufnahme konnte nicht gestartet werden: %@', 'No se pudo iniciar la grabación de pantalla: %@',
    'Avvio della registrazione schermo non riuscito: %@', 'Falha ao iniciar a gravação de ecrã: %@',
    'Не удалось начать запись экрана: %@', 'فشل بدء تسجيل الشاشة: %@',
    'स्क्रीन रिकॉर्डिंग शुरू नहीं हो सकी: %@', 'เริ่มบันทึกหน้าจอไม่สำเร็จ: %@',
    'Không bắt đầu được ghi màn hình: %@', 'Gagal memulai perekaman layar: %@',
    'Ekran kaydı başlatılamadı: %@', 'Kan schermopname niet starten: %@',
    'Nie udało się rozpocząć nagrywania ekranu: %@', 'Не вдалося почати запис екрана: %@',
    'Kunde inte starta skärminspelning: %@',
])

add('新载入 %d 个条目', [
    '新載入 %d 個項目', 'Loaded %d new items', '%d 件の新しい項目を読み込みました',
    '새 항목 %d개 로드됨', '%d nouveaux éléments chargés', '%d neue Einträge geladen',
    '%d elementos nuevos cargados', '%d nuovi elementi caricati', '%d novos itens carregados',
    'Загружено новых записей: %d', 'تم تحميل %d عنصرًا جديدًا', '%d नए आइटम लोड हुए',
    'โหลดรายการใหม่ %d รายการ', 'Đã tải %d mục mới', '%d item baru dimuat', '%d yeni öğe yüklendi',
    '%d nieuwe items geladen', 'Wczytano %d nowych elementów', 'Завантажено %d нових записів',
    '%d nya objekt laddades',
])

add('模型初始化未返回结果', [
    '模型初始化未傳回結果', 'Model Initialization Returned No Result',
    'モデルの初期化が結果を返しませんでした', '모델 초기화가 결과를 반환하지 않음',
    "L'initialisation du modèle n'a rien renvoyé", 'Modellinitialisierung lieferte kein Ergebnis',
    'La inicialización del modelo no devolvió resultado', "L'inizializzazione del modello non ha restituito risultati",
    'A inicialização do modelo não devolveu resultado', 'Инициализация модели не вернула результат',
    'لم تُرجع تهيئة النموذج أي نتيجة', 'मॉडल इनिशियलाइज़ेशन ने कोई परिणाम नहीं दिया',
    'การเริ่มต้นโมเดลไม่คืนผลลัพธ์', 'Khởi tạo mô hình không trả về kết quả',
    'Inisialisasi model tidak mengembalikan hasil', 'Model başlatma sonuç döndürmedi',
    'Modelinitialisatie gaf geen resultaat', 'Inicjalizacja modelu nie zwróciła wyniku',
    'Ініціалізація моделі не повернула результат', 'Modellinitiering gav inget resultat',
])

add('正在同步磁盘与数据库', [
    '正在同步磁碟與資料庫', 'Syncing Disk and Database', 'ディスクとデータベースを同期中',
    '디스크와 데이터베이스 동기화 중', 'Synchronisation du disque et de la base',
    'Datenträger und Datenbank werden synchronisiert', 'Sincronizando disco y base de datos',
    'Sincronizzazione di disco e database', 'A sincronizar disco e base de dados',
    'Синхронизация диска и базы данных', 'جارٍ مزامنة القرص وقاعدة البيانات',
    'डिस्क और डेटाबेस सिंक हो रहे हैं', 'กำลังซิงค์ดิสก์กับฐานข้อมูล',
    'Đang đồng bộ đĩa và cơ sở dữ liệu', 'Menyinkronkan disk dan basis data',
    'Disk ve veritabanı eşitleniyor', 'Schijf en database synchroniseren',
    'Synchronizowanie dysku i bazy danych', 'Синхронізація диска та бази даних',
    'Synkroniserar disk och databas',
])

add('正在请模型读取画面…', [
    '正在請模型讀取畫面…', 'Asking the Model to Read the Visuals…', 'モデルに画面を読ませています…',
    '모델이 화면을 읽는 중…', 'Lecture des visuels par le modèle…', 'Modell liest die Bilder…',
    'Pidiendo al modelo que lea las imágenes…', 'Lettura dei contenuti visivi da parte del modello…',
    'A pedir ao modelo que leia as imagens…', 'Модель читает изображения…',
    'جارٍ طلب قراءة المحتوى المرئي من النموذج…', 'मॉडल से दृश्य पढ़ने को कहा जा रहा है…',
    'กำลังให้โมเดลอ่านภาพ…', 'Đang yêu cầu mô hình đọc hình ảnh…', 'Meminta model membaca visual…',
    'Modelden görselleri okuması isteniyor…', 'Model laten lezen…', 'Model odczytuje obraz…',
    'Модель читає зображення…', 'Ber modellen läsa bilderna…',
])

add('释放以导入音频/视频', [
    '放開以匯入音訊/影片', 'Release to Import Audio/Video', '離して音声・動画を読み込む',
    '놓아서 오디오·동영상 가져오기', 'Relâcher pour importer', 'Loslassen zum Importieren',
    'Suelta para importar', 'Rilascia per importare', 'Solte para importar', 'Отпустите для импорта',
    'أفلت للاستيراد', 'छोड़ें और आयात करें', 'ปล่อยเพื่อนำเข้า', 'Thả để nhập', 'Lepaskan untuk mengimpor',
    'Bırakın ve içe aktarın', 'Loslaten om te importeren', 'Upuść, aby zaimportować',
    'Відпустіть для імпорту', 'Släpp för att importera',
])

add('把识别文字复制到剪贴板', [
    '把識別文字複製到剪貼簿', 'Copy Recognized Text to Clipboard', '認識した文字をクリップボードにコピー',
    '인식된 텍스트를 클립보드에 복사', 'Copier le texte reconnu', 'Erkannten Text kopieren',
    'Copiar el texto reconocido', 'Copia il testo riconosciuto', 'Copiar o texto reconhecido',
    'Скопировать распознанный текст', 'نسخ النص المتعرَّف عليه', 'पहचाना गया टेक्स्ट कॉपी करें',
    'คัดลอกข้อความที่รู้จำ', 'Sao chép văn bản đã nhận dạng', 'Salin teks yang dikenali',
    'Tanınan metni kopyala', 'Herkende tekst kopiëren', 'Kopiuj rozpoznany tekst',
    'Копіювати розпізнаний текст', 'Kopiera igenkänd text',
])

add('播放、关键帧与视觉纪要', [
    '播放、關鍵影格與視覺紀要', 'Playback, Keyframes and Visual Notes', '再生・キーフレーム・映像要約',
    '재생·키프레임·영상 요약', 'Lecture, images clés et résumé visuel',
    'Wiedergabe, Keyframes und visuelle Notizen', 'Reproducción, fotogramas clave y resumen visual',
    'Riproduzione, fotogrammi chiave e sintesi visiva', 'Reprodução, fotogramas-chave e resumo visual',
    'Воспроизведение, ключевые кадры и визуальная сводка', 'التشغيل والإطارات الرئيسية والملخص المرئي',
    'प्लेबैक, कीफ़्रेम और दृश्य सारांश', 'การเล่น คีย์เฟรม และสรุปภาพ',
    'Phát, khung hình chính và tóm tắt hình ảnh', 'Pemutaran, keyframe, dan ringkasan visual',
    'Oynatma, kareler ve görsel özet', 'Afspelen, keyframes en visuele notities',
    'Odtwarzanie, klatki i podsumowanie obrazu', 'Відтворення, ключові кадри та візуальний підсумок',
    'Uppspelning, nyckelbildrutor och visuell sammanfattning',
])

add('支持多种音频与视频格式', [
    '支援多種音訊與影片格式', 'Supports Many Audio and Video Formats', '多种の音声・動画形式に対応',
    '다양한 오디오·동영상 형식 지원', 'Prend en charge de nombreux formats audio et vidéo',
    'Unterstützt viele Audio- und Videoformate', 'Compatible con varios formatos de audio y vídeo',
    'Supporta molti formati audio e video', 'Suporta vários formatos de áudio e vídeo',
    'Поддержка разных аудио- и видеоформатов', 'يدعم صيغ صوت وفيديو متعددة',
    'कई ऑडियो और वीडियो प्रारूप समर्थित', 'รองรับรูปแบบเสียงและวิดีโอหลายแบบ',
    'Hỗ trợ nhiều định dạng âm thanh và video', 'Mendukung berbagai format audio dan video',
    'Birçok ses ve video formatını destekler', 'Ondersteunt vele audio- en videoformaten',
    'Obsługuje wiele formatów audio i wideo', 'Підтримує багато аудіо- та відеоформатів',
    'Stöder många ljud- och videoformat',
])

add('正在抽取并筛选关键帧…', [
    '正在擷取並篩選關鍵影格…', 'Extracting and Filtering Keyframes…', 'キーフレームを抽出・選別中…',
    '키프레임 추출 및 선별 중…', 'Extraction et filtrage des images clés…',
    'Keyframes werden extrahiert und gefiltert…', 'Extrayendo y filtrando fotogramas clave…',
    'Estrazione e selezione dei fotogrammi chiave…', 'A extrair e filtrar fotogramas-chave…',
    'Извлечение и отбор ключевых кадров…', 'جارٍ استخراج الإطارات الرئيسية وتصفيتها…',
    'कीफ़्रेम निकाले और छाँटे जा रहे हैं…', 'กำลังดึงและคัดกรองคีย์เฟรม…',
    'Đang trích và lọc khung hình chính…', 'Mengekstrak dan menyaring keyframe…',
    'Kareler çıkarılıyor ve seçiliyor…', 'Keyframes extraheren en filteren…',
    'Wyodrębnianie i filtrowanie klatek…', 'Видобуток і відбір ключових кадрів…',
    'Extraherar och filtrerar nyckelbildrutor…',
])

add('不支持的文件格式：.%@', [
    '不支援的檔案格式：.%@', 'Unsupported file format: .%@', '未対応のファイル形式：.%@',
    '지원하지 않는 파일 형식: .%@', 'Format de fichier non pris en charge : .%@',
    'Nicht unterstütztes Dateiformat: .%@', 'Formato de archivo no compatible: .%@',
    'Formato file non supportato: .%@', 'Formato de ficheiro não suportado: .%@',
    'Неподдерживаемый формат файла: .%@', 'تنسيق ملف غير مدعوم: .%@',
    'असमर्थित फ़ाइल प्रारूप: .%@', 'รูปแบบไฟล์ที่ไม่รองรับ: .%@',
    'Định dạng tệp không được hỗ trợ: .%@', 'Format file tidak didukung: .%@',
    'Desteklenmeyen dosya biçimi: .%@', 'Niet-ondersteund bestandsformaat: .%@',
    'Nieobsługiwany format pliku: .%@', 'Непідтримуваний формат файлу: .%@',
    'Filformat som inte stöds: .%@',
])

add('已有录屏在进行，请先停止。', [
    '已有螢幕錄製進行中，請先停止。', 'A screen recording is already running; stop it first.',
    '画面収録が進行中です。先に停止してください。', '화면 녹화가 진행 중입니다. 먼저 중지하세요.',
    "Un enregistrement d'écran est en cours ; arrêtez-le d'abord.",
    'Eine Bildschirmaufnahme läuft bereits; bitte zuerst beenden.',
    'Ya hay una grabación de pantalla en curso; deténla primero.',
    "C'è già una registrazione schermo in corso; interrompila prima.",
    'Já há uma gravação de ecrã em curso; pare-a primeiro.',
    'Запись экрана уже идёт — сначала остановите её.', 'يوجد تسجيل شاشة جارٍ بالفعل؛ أوقفه أولاً.',
    'पहले से स्क्रीन रिकॉर्डिंग चल रही है; पहले उसे रोकें।', 'กำลังบันทึกหน้าจออยู่ โปรดหยุดก่อน',
    'Đang có phiên ghi màn hình; hãy dừng trước.', 'Perekaman layar sedang berjalan; hentikan dulu.',
    'Ekran kaydı zaten sürüyor; önce durdurun.', 'Er loopt al een schermopname; stop die eerst.',
    'Nagrywanie ekranu już trwa; najpierw je zatrzymaj.', 'Запис екрана вже триває; спершу зупиніть його.',
    'En skärminspelning pågår redan; stoppa den först.',
])

add('生成于 %@ · 模型 %@', [
    '生成於 %@ · 模型 %@', 'Generated %@ · Model %@', '%@ に生成 · モデル %@', '%@ 생성 · 모델 %@',
    'Généré %@ · modèle %@', 'Erstellt %@ · Modell %@', 'Generado %@ · modelo %@',
    'Generato %@ · modello %@', 'Gerado %@ · modelo %@', 'Создано %@ · модель %@',
    'أُنشئ %@ · النموذج %@', '%@ को बनाया · मॉडल %@', 'สร้างเมื่อ %@ · โมเดล %@',
    'Tạo %@ · mô hình %@', 'Dibuat %@ · model %@', 'Oluşturulma %@ · model %@',
    'Gemaakt %@ · model %@', 'Utworzono %@ · model %@', 'Створено %@ · модель %@', 'Skapad %@ · modell %@',
])

add('录屏启动失败：%@，未开始录音。', [
    '螢幕錄製啟動失敗：%@，未開始錄音。', 'Failed to start screen recording: %@; recording did not begin.',
    '画面収録を開始できません：%@。録音は開始されていません。',
    '화면 녹화 시작 실패: %@, 녹음이 시작되지 않았습니다.',
    "Échec du démarrage de l'enregistrement d'écran : %@ ; aucun enregistrement n'a commencé.",
    'Bildschirmaufnahme konnte nicht gestartet werden: %@; Aufnahme wurde nicht begonnen.',
    'No se pudo iniciar la grabación de pantalla: %@; no se inició la grabación.',
    'Avvio della registrazione schermo non riuscito: %@; la registrazione non è iniziata.',
    'Falha ao iniciar a gravação de ecrã: %@; a gravação não começou.',
    'Не удалось начать запись экрана: %@; запись не началась.',
    'فشل بدء تسجيل الشاشة: %@؛ لم يبدأ التسجيل.',
    'स्क्रीन रिकॉर्डिंग शुरू नहीं हो सकी: %@; रिकॉर्डिंग शुरू नहीं हुई।',
    'เริ่มบันทึกหน้าจอไม่สำเร็จ: %@ ยังไม่ได้เริ่มบันทึก',
    'Không bắt đầu được ghi màn hình: %@; chưa bắt đầu ghi âm.',
    'Gagal memulai perekaman layar: %@; perekaman tidak dimulai.',
    'Ekran kaydı başlatılamadı: %@; kayıt başlamadı.',
    'Kan schermopname niet starten: %@; opname is niet begonnen.',
    'Nie udało się rozpocząć nagrywania ekranu: %@; nagrywanie nie zostało rozpoczęte.',
    'Не вдалося почати запис екрана: %@; запис не розпочато.',
    'Kunde inte starta skärminspelning: %@; inspelningen startade inte.',
])

add('更新于 %@ · %lld 个片段', [
    '更新於 %@ · %lld 個片段', 'Updated %@ · %lld clips', '%@ に更新 · %lld 個のセグメント',
    '%@ 업데이트 · 구간 %lld개', 'Mis à jour %@ · %lld segments', 'Aktualisiert %@ · %lld Abschnitte',
    'Actualizado %@ · %lld segmentos', 'Aggiornato %@ · %lld segmenti',
    'Atualizado %@ · %lld segmentos', 'Обновлено %@ · фрагментов: %lld',
    'حُدِّث %@ · %lld مقطعًا', '%@ पर अपडेट · %lld सेगमेंट', 'อัปเดต %@ · %lld ช่วง',
    'Cập nhật %@ · %lld đoạn', 'Diperbarui %@ · %lld segmen', 'Güncellendi %@ · %lld bölüm',
    'Bijgewerkt %@ · %lld segmenten', 'Zaktualizowano %@ · %lld segmentów',
    'Оновлено %@ · %lld фрагментів', 'Uppdaterad %@ · %lld segment',
])

add('文件「%@」不是支持的音频/视频格式', [
    '檔案「%@」不是支援的音訊/影片格式', '“%@” is not a supported audio/video format',
    '「%@」は対応している音声・動画形式ではありません', '‘%@’은(는) 지원하는 오디오·동영상 형식이 아닙니다',
    "« %@ » n'est pas un format audio/vidéo pris en charge", '„%@“ ist kein unterstütztes Audio-/Videoformat',
    '«%@» no es un formato de audio/vídeo compatible', '«%@» non è un formato audio/video supportato',
    '«%@» não é um formato de áudio/vídeo suportado', '«%@» — неподдерживаемый аудио-/видеоформат',
    '«%@» ليس صيغة صوت/فيديو مدعومة', '«%@» समर्थित ऑडियो/वीडियो प्रारूप नहीं है',
    '«%@» ไม่ใช่รูปแบบเสียง/วิดีโอที่รองรับ', '«%@» không phải định dạng âm thanh/video được hỗ trợ',
    '«%@» bukan format audio/video yang didukung', '«%@» desteklenen bir ses/video biçimi değil',
    '«%@» is geen ondersteund audio-/videoformaat', '„%@” nie jest obsługiwanym formatem audio/wideo',
    '«%@» — не підтримуваний аудіо-/відеоформат', '”%@” är inte ett ljud-/videoformat som stöds',
])

add('已识别 %lld 字，可直接编辑或复制', [
    '已識別 %lld 字，可直接編輯或複製', 'Recognized %lld characters; edit or copy directly',
    '%lld 文字を認識しました。直接編集・コピーできます', '%lld자를 인식했습니다. 바로 편집하거나 복사하세요',
    '%lld caractères reconnus ; modifiez ou copiez directement',
    '%lld Zeichen erkannt; direkt bearbeiten oder kopieren',
    'Se reconocieron %lld caracteres; edita o copia directamente',
    'Riconosciuti %lld caratteri; modifica o copia direttamente',
    '%lld caracteres reconhecidos; edite ou copie diretamente',
    'Распознано символов: %lld; можно править или копировать',
    'تم التعرّف على %lld حرفًا؛ يمكنك التحرير أو النسخ مباشرة',
    '%lld अक्षर पहचाने गए; सीधे संपादित या कॉपी करें', 'รู้จำ %lld ตัวอักษร แก้ไขหรือคัดลอกได้ทันที',
    'Đã nhận dạng %lld ký tự; có thể sửa hoặc sao chép ngay',
    'Mengenali %lld karakter; edit atau salin langsung', '%lld karakter tanındı; doğrudan düzenleyip kopyalayın',
    '%lld tekens herkend; direct bewerken of kopiëren', 'Rozpoznano %lld znaków; edytuj lub kopiuj bezpośrednio',
    'Розпізнано %lld символів; редагуйте або копіюйте одразу', '%lld tecken igenkända; redigera eller kopiera direkt',
])

add('目标窗口已关闭或不可录制，请重新选择。', [
    '目標視窗已關閉或無法錄製，請重新選擇。',
    'The target window was closed or cannot be recorded; please choose again.',
    '対象ウインドウが閉じられたか録画できません。選び直してください。',
    '대상 창이 닫혔거나 녹화할 수 없습니다. 다시 선택하세요.',
    "La fenêtre cible est fermée ou non enregistrable ; resélectionnez-la.",
    'Das Zielfenster wurde geschlossen oder ist nicht aufnehmbar; bitte neu wählen.',
    'La ventana de destino se cerró o no se puede grabar; elige otra.',
    "La finestra di destinazione è stata chiusa o non è registrabile; scegline un'altra.",
    'A janela de destino foi fechada ou não pode ser gravada; escolha outra.',
    'Целевое окно закрыто или недоступно для записи; выберите снова.',
    'تم إغلاق النافذة الهدف أو تعذّر تسجيلها؛ اختر مرة أخرى.',
    'लक्ष्य विंडो बंद हो गई या रिकॉर्ड नहीं हो सकती; फिर से चुनें।',
    'หน้าต่างเป้าหมายถูกปิดหรือบันทึกไม่ได้ โปรดเลือกใหม่',
    'Cửa sổ đích đã đóng hoặc không ghi được; hãy chọn lại.',
    'Jendela target ditutup atau tidak dapat direkam; pilih lagi.',
    'Hedef pencere kapatıldı veya kaydedilemiyor; yeniden seçin.',
    'Het doelvenster is gesloten of kan niet worden opgenomen; kies opnieuw.',
    'Okno docelowe zostało zamknięte lub nie można go nagrać; wybierz ponownie.',
    'Цільове вікно закрито або його не можна записати; виберіть знову.',
    'Målfönstret stängdes eller kan inte spelas in; välj igen.',
])

add('%lld 条录音疑似仍在录制，本轮未处理', [
    '%lld 個錄音疑似仍在錄製，本輪未處理', '%lld recordings may still be in progress; skipped this run',
    '%lld 件の録音がまだ進行中の可能性があるため、今回の処理から除外しました',
    '%lld개 녹음이 아직 진행 중인 것으로 보여 이번에는 건너뛰었습니다',
    '%lld enregistrements semblent en cours ; ignorés cette fois',
    '%lld Aufnahmen laufen möglicherweise noch; diesmal übersprungen',
    '%lld grabaciones parecen seguir en curso; omitidas esta vez',
    '%lld registrazioni potrebbero essere ancora in corso; saltate questa volta',
    '%lld gravações podem estar em curso; ignoradas nesta execução',
    'Похоже, %lld записей ещё идут; в этом проходе они пропущены',
    'يبدو أن %lld تسجيلًا لا يزال جاريًا؛ تم تخطيها هذه المرة',
    '%lld रिकॉर्डिंग अब भी चल रही हो सकती हैं; इस बार छोड़ी गईं',
    '%lld รายการอาจยังบันทึกอยู่ จึงข้ามในรอบนี้', '%lld bản ghi có thể vẫn đang chạy; bỏ qua lần này',
    '%lld rekaman mungkin masih berjalan; dilewati kali ini', '%lld kayıt hâlâ sürüyor olabilir; bu turda atlandı',
    '%lld opnamen lopen mogelijk nog; deze keer overgeslagen',
    '%lld nagrań może wciąż trwać; pominięto w tym przebiegu',
    '%lld записів, імовірно, ще тривають; цього разу пропущено',
    '%lld inspelningar pågår möjligen fortfarande; hoppades över denna gång',
])

add('上一条录音正在合并，请稍候再开始新录音。', [
    '上一條錄音正在合併，請稍候再開始新錄音。',
    'The previous recording is still merging; wait a moment before starting a new one.',
    '前の録音を統合中です。少し待ってから新しい録音を開始してください。',
    '이전 녹음을 병합하는 중입니다. 잠시 후 새 녹음을 시작하세요.',
    "L'enregistrement précédent est en cours de fusion ; attendez avant d'en démarrer un nouveau.",
    'Die vorherige Aufnahme wird noch zusammengeführt; bitte kurz warten.',
    'La grabación anterior se está combinando; espera antes de iniciar otra.',
    'La registrazione precedente è in fase di unione; attendi prima di iniziarne una nuova.',
    'A gravação anterior está a ser unida; aguarde antes de iniciar outra.',
    'Предыдущая запись ещё объединяется; подождите немного.',
    'التسجيل السابق قيد الدمج؛ انتظر قليلاً قبل بدء تسجيل جديد.',
    'पिछली रिकॉर्डिंग मर्ज हो रही है; नई शुरू करने से पहले प्रतीक्षा करें।',
    'กำลังรวมรายการบันทึกก่อนหน้า โปรดรอสักครู่ก่อนเริ่มใหม่',
    'Bản ghi trước đang được hợp nhất; hãy đợi rồi bắt đầu bản ghi mới.',
    'Rekaman sebelumnya sedang digabungkan; tunggu sebentar.',
    'Önceki kayıt birleştiriliyor; yenisini başlatmadan önce bekleyin.',
    'De vorige opname wordt nog samengevoegd; wacht even.',
    'Poprzednie nagranie jest scalane; poczekaj chwilę.',
    'Попередній запис ще об’єднується; зачекайте трохи.',
    'Den förra inspelningen sammanfogas fortfarande; vänta lite.',
])


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
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
    print(f'第 2 批完成：{len(T)} 条 key，新增 {filled} 条译文（缺失 key {missing_key} 条）')


if __name__ == '__main__':
    main()
