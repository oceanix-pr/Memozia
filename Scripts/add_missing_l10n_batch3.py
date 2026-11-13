#!/usr/bin/env python3
# 补齐缺失译文 · 第 3 批：21–33 字文案（12 条 × 20 语言）
#
# 合并策略同前：只补缺失语言，已存在的语言保持原样。
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('未找到目标显示屏（可能刚被拔出），请重试。', [
    '未找到目標顯示器（可能剛被拔出），請重試。',
    'Target display not found (it may have just been unplugged); please try again.',
    '対象のディスプレイが見つかりません（たった今外された可能性があります）。再試行してください。',
    '대상 디스플레이를 찾을 수 없습니다(방금 분리되었을 수 있음). 다시 시도하세요.',
    'Écran cible introuvable (il vient peut-être d’être débranché) ; réessayez.',
    'Zielbildschirm nicht gefunden (evtl. gerade getrennt); bitte erneut versuchen.',
    'No se encontró la pantalla de destino (puede que se acabe de desconectar); inténtalo de nuevo.',
    'Schermo di destinazione non trovato (potrebbe essere stato appena scollegato); riprova.',
    'Ecrã de destino não encontrado (pode ter sido desligado agora); tente novamente.',
    'Целевой дисплей не найден (возможно, его только что отключили); попробуйте снова.',
    'لم يُعثر على الشاشة الهدف (ربما فُصلت للتو)؛ حاول مرة أخرى.',
    'लक्ष्य डिस्प्ले नहीं मिला (शायद अभी हटाया गया है); फिर से कोशिश करें।',
    'ไม่พบจอเป้าหมาย (อาจเพิ่งถูกถอดออก) โปรดลองใหม่',
    'Không tìm thấy màn hình đích (có thể vừa bị ngắt); hãy thử lại.',
    'Layar target tidak ditemukan (mungkin baru dicabut); coba lagi.',
    'Hedef ekran bulunamadı (yeni çıkarılmış olabilir); yeniden deneyin.',
    'Doelscherm niet gevonden (mogelijk net losgekoppeld); probeer opnieuw.',
    'Nie znaleziono ekranu docelowego (mógł zostać właśnie odłączony); spróbuj ponownie.',
    'Цільовий дисплей не знайдено (можливо, його щойно від’єднали); спробуйте ще раз.',
    'Målskärmen hittades inte (den kanske nyss kopplades ur); försök igen.',
])

add('以下时间段的画面分析失败，可重新分析补齐：%@', [
    '以下時間段的畫面分析失敗，可重新分析補齊：%@',
    'Visual analysis failed for the following segments; re-analyze to fill them in: %@',
    '以下の時間帯の画面分析に失敗しました。再分析で補完できます：%@',
    '다음 구간의 화면 분석 실패. 다시 분석해 채울 수 있습니다: %@',
    'L’analyse visuelle a échoué pour les segments suivants ; réanalysez pour compléter : %@',
    'Die Bildanalyse ist für folgende Abschnitte fehlgeschlagen; zur Ergänzung erneut analysieren: %@',
    'El análisis visual falló en los siguientes tramos; vuelve a analizar para completarlos: %@',
    'Analisi visiva non riuscita per i seguenti intervalli; rianalizza per completarli: %@',
    'A análise visual falhou nos seguintes intervalos; reanalise para completar: %@',
    'Анализ изображений не удался для следующих отрезков; запустите анализ заново, чтобы дополнить: %@',
    'فشل تحليل المحتوى المرئي للفترات التالية؛ أعد التحليل لإكمالها: %@',
    'निम्न समय-खंडों का दृश्य विश्लेषण विफल; पूरा करने के लिए दोबारा विश्लेषण करें: %@',
    'วิเคราะห์ภาพช่วงเวลาต่อไปนี้ไม่สำเร็จ วิเคราะห์ใหม่เพื่อเติมให้ครบ: %@',
    'Phân tích hình ảnh cho các khoảng sau thất bại; phân tích lại để bổ sung: %@',
    'Analisis visual gagal untuk segmen berikut; analisis ulang untuk melengkapinya: %@',
    'Şu aralıklar için görsel analiz başarısız; tamamlamak için yeniden analiz edin: %@',
    'Beeldanalyse mislukte voor de volgende segmenten; analyseer opnieuw om aan te vullen: %@',
    'Analiza obrazu nie powiodła się dla następujących odcinków; przeanalizuj ponownie, aby uzupełnić: %@',
    'Аналіз зображень не вдався для таких відрізків; проаналізуйте знову, щоб доповнити: %@',
    'Bildanalysen misslyckades för följande avsnitt; analysera igen för att fylla i: %@',
])

add('系统音频写入失败，当前系统音频分片可能丢失。\n%@', [
    '系統音訊寫入失敗，目前系統音訊分片可能遺失。\n%@',
    'Failed to write system audio; the current system-audio segment may be lost.\n%@',
    'システム音声の書き込みに失敗しました。現在のシステム音声セグメントは失われる可能性があります。\n%@',
    '시스템 오디오 쓰기 실패. 현재 시스템 오디오 구간이 사라졌을 수 있습니다.\n%@',
    'Échec de l’écriture de l’audio système ; le segment actuel peut être perdu.\n%@',
    'Schreiben des Systemtons fehlgeschlagen; der aktuelle Systemton-Abschnitt geht möglicherweise verloren.\n%@',
    'Error al escribir el audio del sistema; el segmento actual podría perderse.\n%@',
    'Scrittura dell’audio di sistema non riuscita; il segmento attuale potrebbe andare perso.\n%@',
    'Falha ao escrever o áudio do sistema; o segmento atual pode perder-se.\n%@',
    'Не удалось записать системный звук; текущий фрагмент может быть потерян.\n%@',
    'فشل كتابة صوت النظام؛ قد يُفقد المقطع الحالي.\n%@',
    'सिस्टम ऑडियो लिखने में विफल; मौजूदा सिस्टम ऑडियो सेगमेंट खो सकता है।\n%@',
    'เขียนเสียงระบบไม่สำเร็จ ช่วงเสียงระบบปัจจุบันอาจสูญหาย\n%@',
    'Ghi âm thanh hệ thống thất bại; đoạn âm thanh hệ thống hiện tại có thể bị mất.\n%@',
    'Gagal menulis audio sistem; segmen audio sistem saat ini mungkin hilang.\n%@',
    'Sistem sesi yazılamadı; geçerli sistem sesi bölümü kaybolmuş olabilir.\n%@',
    'Kan systeemgeluid niet schrijven; het huidige systeemgeluidsegment kan verloren gaan.\n%@',
    'Nie udało się zapisać dźwięku systemowego; bieżący segment może zostać utracony.\n%@',
    'Не вдалося записати системний звук; поточний фрагмент може бути втрачено.\n%@',
    'Kunde inte skriva systemljudet; det aktuella systemljudssegmentet kan ha gått förlorat.\n%@',
])

add('视频轨保存异常，音频录音不受影响；条目以纯音频入库。', [
    '影片軌儲存異常，音訊錄音不受影響；項目以純音訊入庫。',
    'The video track could not be saved; the audio recording is unaffected and the item is saved as audio only.',
    '映像トラックの保存に失敗しました。音声録音には影響せず、項目は音声のみで保存されます。',
    '비디오 트랙 저장 실패. 오디오 녹음은 영향받지 않으며 항목은 오디오만 저장됩니다.',
    'Échec de l’enregistrement de la piste vidéo ; l’audio n’est pas affecté et l’élément est enregistré en audio seul.',
    'Die Videospur konnte nicht gespeichert werden; die Audioaufnahme ist nicht betroffen, der Eintrag wird nur als Audio gesichert.',
    'No se pudo guardar la pista de vídeo; el audio no se ve afectado y el elemento se guarda solo como audio.',
    'Salvataggio della traccia video non riuscito; l’audio non è interessato e l’elemento viene salvato solo come audio.',
    'Falha ao guardar a faixa de vídeo; o áudio não é afetado e o item é guardado apenas como áudio.',
    'Видеодорожку не удалось сохранить; аудиозапись не пострадала, элемент сохранён только как аудио.',
    'فشل حفظ مسار الفيديو؛ التسجيل الصوتي غير متأثر وسيُحفظ العنصر صوتيًا فقط.',
    'वीडियो ट्रैक सहेजा नहीं जा सका; ऑडियो रिकॉर्डिंग प्रभावित नहीं है और आइटम केवल ऑडियो के रूप में सहेजा गया।',
    'บันทึกแทรกวิดีโอไม่สำเร็จ การบันทึกเสียงไม่ได้รับผลกระทบ และรายการจะถูกบันทึกเป็นเสียงอย่างเดียว',
    'Lưu track video thất bại; bản ghi âm không bị ảnh hưởng, mục được lưu chỉ với âm thanh.',
    'Gagal menyimpan track video; rekaman audio tidak terpengaruh dan item disimpan hanya sebagai audio.',
    'Video kanalı kaydedilemedi; ses kaydı etkilenmedi ve öğe yalnızca ses olarak kaydedildi.',
    'Kan videospoor niet opslaan; de audio-opname is niet getroffen en het item wordt alleen als audio opgeslagen.',
    'Nie udało się zapisać ścieżki wideo; nagranie audio nie ucierpiało, element zapisano jako samo audio.',
    'Відеодоріжку не вдалося зберегти; аудіозапис не постраждав, елемент збережено лише як аудіо.',
    'Kunde inte spara videospåret; ljudinspelningen påverkas inte och objektet sparas endast som ljud.',
])

add('无法创建录屏文件（%@），请检查磁盘空间与文件夹权限。', [
    '無法建立螢幕錄製檔案（%@），請檢查磁碟空間與資料夾權限。',
    'Could not create the screen-recording file (%@); check disk space and folder permissions.',
    '画面収録ファイルを作成できません（%@）。ディスク容量とフォルダ権限を確認してください。',
    '화면 녹화 파일을 만들 수 없습니다(%@). 디스크 공간과 폴더 권한을 확인하세요.',
    'Impossible de créer le fichier d’enregistrement (%@) ; vérifiez l’espace disque et les permissions.',
    'Die Bildschirmaufnahmedatei konnte nicht erstellt werden (%@); prüfen Sie Speicherplatz und Ordnerrechte.',
    'No se pudo crear el archivo de grabación (%@); comprueba el espacio en disco y los permisos.',
    'Impossibile creare il file di registrazione (%@); controlla spazio su disco e permessi.',
    'Não foi possível criar o ficheiro de gravação (%@); verifique o espaço em disco e as permissões.',
    'Не удалось создать файл записи экрана (%@); проверьте место на диске и права доступа к папке.',
    'تعذّر إنشاء ملف تسجيل الشاشة (%@)؛ تحقق من مساحة القرص وأذونات المجلد.',
    'स्क्रीन रिकॉर्डिंग फ़ाइल नहीं बनाई जा सकी (%@); डिस्क स्थान और फ़ोल्डर अनुमतियाँ जाँचें।',
    'สร้างไฟล์บันทึกหน้าจอไม่ได้ (%@) โปรดตรวจสอบพื้นที่ดิสก์และสิทธิ์โฟลเดอร์',
    'Không tạo được tệp ghi màn hình (%@); hãy kiểm tra dung lượng đĩa và quyền thư mục.',
    'Tidak dapat membuat file perekaman layar (%@); periksa ruang disk dan izin folder.',
    'Ekran kaydı dosyası oluşturulamadı (%@); disk alanını ve klasör izinlerini kontrol edin.',
    'Kan het schermopnamebestand niet aanmaken (%@); controleer schijfruimte en maprechten.',
    'Nie można utworzyć pliku nagrania ekranu (%@); sprawdź miejsce na dysku i uprawnienia folderu.',
    'Не вдалося створити файл запису екрана (%@); перевірте місце на диску та права доступу до теки.',
    'Kunde inte skapa skärminspelningsfilen (%@); kontrollera diskutrymme och mappbehörigheter.',
])

add('未能从视频中抽到可用画面（抽到的帧全部重复或解码失败）', [
    '未能從影片中抽到可用畫面（抽到的影格全部重複或解碼失敗）',
    'No usable frames could be extracted from the video (all frames were duplicates or failed to decode).',
    '動画から有効な画面を抽出できませんでした（抽出したフレームがすべて重複かデコード失敗）。',
    '동영상에서 사용할 수 있는 화면을 추출하지 못했습니다(추출된 프레임이 모두 중복이거나 디코딩 실패).',
    'Aucune image exploitable n’a pu être extraite (images toutes en double ou décodage échoué).',
    'Aus dem Video konnten keine brauchbaren Bilder extrahiert werden (alle Frames doppelt oder Dekodierung fehlgeschlagen).',
    'No se pudo extraer ninguna imagen útil del vídeo (todos los fotogramas eran repetidos o fallaron al decodificar).',
    'Non è stato possibile estrarre immagini utilizzabili (fotogrammi tutti duplicati o decodifica non riuscita).',
    'Não foi possível extrair imagens utilizáveis do vídeo (fotogramas todos repetidos ou falha ao descodificar).',
    'Не удалось извлечь пригодные кадры (все кадры повторяются или не декодируются).',
    'تعذّر استخراج إطارات قابلة للاستخدام (كل الإطارات مكررة أو فشل فك ترميزها).',
    'वीडियो से उपयोगी फ़्रेम नहीं निकाले जा सके (सभी फ़्रेम दोहराव वाले या डिकोड विफल)।',
    'ดึงภาพที่ใช้งานได้จากวิดีโอไม่สำเร็จ (เฟรมที่ได้ซ้ำกันทั้งหมดหรือถอดรหัสไม่สำเร็จ)',
    'Không trích được hình ảnh dùng được từ video (các khung đều trùng lặp hoặc giải mã thất bại).',
    'Tidak dapat mengekstrak frame yang berguna dari video (semua frame duplikat atau gagal didekode).',
    'Videodan kullanılabilir kare çıkarılamadı (tüm kareler yinelenen veya kod çözme başarısız).',
    'Er konden geen bruikbare beelden uit de video worden gehaald (alle frames dubbel of decodering mislukt).',
    'Nie udało się wyodrębnić użytecznych klatek (wszystkie są duplikatami lub dekodowanie się nie powiodło).',
    'Не вдалося видобути придатні кадри (усі кадри повторюються або не декодуються).',
    'Inga användbara bildrutor kunde extraheras (alla var dubbletter eller kunde inte avkodas).',
])

add('选择模型并点击“分析画面”，生成带时间标记的视觉纪要。', [
    '選擇模型並點擊「分析畫面」，產生帶時間標記的視覺紀要。',
    'Choose a model and click “Analyze Visuals” to generate timestamped visual notes.',
    'モデルを選び「画面を分析」をクリックすると、時刻付きの映像要約を生成します。',
    '모델을 선택하고 ‘화면 분석’을 클릭하면 시간 표시가 있는 영상 요약을 만듭니다.',
    'Choisissez un modèle et cliquez sur « Analyser les visuels » pour générer un résumé visuel horodaté.',
    'Modell wählen und „Bildinhalte analysieren“ klicken, um zeitmarkierte visuelle Notizen zu erstellen.',
    'Elige un modelo y pulsa «Analizar imágenes» para generar un resumen visual con marcas de tiempo.',
    'Scegli un modello e fai clic su «Analizza contenuti visivi» per generare note visive con marca temporale.',
    'Escolha um modelo e clique em «Analisar imagens» para gerar um resumo visual com marcas temporais.',
    'Выберите модель и нажмите «Анализ изображений», чтобы создать визуальную сводку с отметками времени.',
    'اختر نموذجًا وانقر «تحليل المحتوى المرئي» لإنشاء ملخص مرئي بطوابع زمنية.',
    'मॉडल चुनें और «दृश्य विश्लेषण करें» पर क्लिक करें — समय-चिह्नित दृश्य सारांश बनेगा।',
    'เลือกโมเดลแล้วคลิก «วิเคราะห์ภาพ» เพื่อสร้างสรุปภาพพร้อมเวลากำกับ',
    'Chọn mô hình và nhấp «Phân tích hình ảnh» để tạo tóm tắt hình ảnh kèm mốc thời gian.',
    'Pilih model dan klik «Analisis Visual» untuk membuat ringkasan visual bertanda waktu.',
    'Bir model seçip «Görselleri Analiz Et» düğmesine tıklayın; zaman işaretli görsel özet oluşturulur.',
    'Kies een model en klik op «Beelden analyseren» voor een visuele samenvatting met tijdstempels.',
    'Wybierz model i kliknij „Analizuj obraz”, aby utworzyć podsumowanie obrazu ze znacznikami czasu.',
    'Виберіть модель і натисніть «Аналіз зображень», щоб створити візуальний підсумок із позначками часу.',
    'Välj en modell och klicka på «Analysera bilder» för att skapa en visuell sammanfattning med tidsstämplar.',
])

add('无法读取视频画面，可能文件已损坏、不含视频轨道或已被移动', [
    '無法讀取影片畫面，可能檔案已損壞、不含影片軌或已被移動',
    'Cannot read the video picture; the file may be damaged, lack a video track, or have been moved.',
    '動画の映像を読み込めません。ファイルが壊れている、映像トラックがない、または移動された可能性があります。',
    '동영상 화면을 읽을 수 없습니다. 파일이 손상되었거나 비디오 트랙이 없거나 이동되었을 수 있습니다.',
    'Impossible de lire l’image vidéo ; le fichier est peut-être endommagé, sans piste vidéo ou déplacé.',
    'Das Videobild kann nicht gelesen werden; die Datei ist evtl. beschädigt, hat keine Videospur oder wurde verschoben.',
    'No se puede leer la imagen del vídeo; el archivo puede estar dañado, sin pista de vídeo o movido.',
    'Impossibile leggere il video; il file potrebbe essere danneggiato, senza traccia video o spostato.',
    'Não é possível ler a imagem do vídeo; o ficheiro pode estar danificado, sem faixa de vídeo ou ter sido movido.',
    'Не удалось прочитать видеоизображение; файл может быть повреждён, без видеодорожки или перемещён.',
    'تعذّرت قراءة صورة الفيديو؛ قد يكون الملف تالفًا أو بلا مسار فيديو أو قد نُقل.',
    'वीडियो का चित्र पढ़ा नहीं जा सका; फ़ाइल ख़राब हो सकती है, वीडियो ट्रैक न हो, या स्थान बदल गया हो।',
    'อ่านภาพจากวิดีโอไม่ได้ ไฟล์อาจเสียหาย ไม่มีแทรกวิดีโอ หรือถูกย้ายไปแล้ว',
    'Không đọc được hình ảnh video; tệp có thể đã hỏng, không có track video hoặc đã bị di chuyển.',
    'Tidak dapat membaca gambar video; file mungkin rusak, tidak punya track video, atau telah dipindahkan.',
    'Video görüntüsü okunamıyor; dosya bozulmuş, video kanalı yok ya da taşınmış olabilir.',
    'Kan het videobeeld niet lezen; het bestand is mogelijk beschadigd, heeft geen videospoor of is verplaatst.',
    'Nie można odczytać obrazu wideo; plik może być uszkodzony, bez ścieżki wideo lub przeniesiony.',
    'Не вдалося прочитати відеозображення; файл може бути пошкоджений, без відеодоріжки або переміщений.',
    'Kan inte läsa videobilden; filen kan vara skadad, sakna videospår eller ha flyttats.',
])

add('系统睡眠约 %d 分钟，已自动恢复录音（睡眠时段为静音）。', [
    '系統睡眠約 %d 分鐘，已自動恢復錄音（睡眠時段為靜音）。',
    'The system slept for about %d minutes; recording resumed automatically (that period is silent).',
    'システムが約 %d 分間スリープしました。録音は自動的に再開しました（その区間は無音です）。',
    '시스템이 약 %d분간 잠자기 상태였습니다. 녹음이 자동으로 재개되었습니다(해당 구간은 무음).',
    'Le système a été en veille environ %d minutes ; l’enregistrement a repris automatiquement (silence sur cette période).',
    'Das System war etwa %d Minuten im Ruhezustand; die Aufnahme wurde automatisch fortgesetzt (dieser Abschnitt ist stumm).',
    'El sistema estuvo suspendido unos %d minutos; la grabación se reanudó automáticamente (ese tramo queda en silencio).',
    'Il sistema è rimasto sospeso circa %d minuti; la registrazione è ripresa automaticamente (quel tratto è muto).',
    'O sistema esteve suspenso cerca de %d minutos; a gravação retomou automaticamente (esse período fica em silêncio).',
    'Система была в спящем режиме около %d минут; запись продолжилась автоматически (этот отрезок — тишина).',
    'كان النظام في وضع النوم نحو %d دقيقة؛ استُئنف التسجيل تلقائيًا (تلك الفترة صامتة).',
    'सिस्टम लगभग %d मिनट स्लीप में रहा; रिकॉर्डिंग अपने-आप फिर शुरू हुई (उस दौरान आवाज़ नहीं है)।',
    'ระบบหลับไปประมาณ %d นาที การบันทึกกลับมาทำงานอัตโนมัติ (ช่วงนั้นเป็นเสียงเงียบ)',
    'Hệ thống ngủ khoảng %d phút; bản ghi tự động tiếp tục (khoảng đó là im lặng).',
    'Sistem tidur sekitar %d menit; perekaman lanjut otomatis (periode itu senyap).',
    'Sistem yaklaşık %d dakika uyudu; kayıt otomatik sürdü (o aralık sessiz).',
    'Het systeem sliep ongeveer %d minuten; de opname werd automatisch hervat (dat deel is stil).',
    'System był uśpiony około %d min; nagrywanie wznowiło się automatycznie (ten okres jest ciszą).',
    'Система була в режимі сну близько %d хвилин; запис поновився автоматично (цей відрізок — тиша).',
    'Systemet sov i cirka %d minuter; inspelningen återupptogs automatiskt (den perioden är tyst).',
])

add('点击工具栏「笔记」新建快捷笔记，或点击「导入」添加音频和视频', [
    '點擊工具列「筆記」新增快捷筆記，或點擊「匯入」加入音訊與影片',
    'Click “Note” in the toolbar to create a quick note, or “Import” to add audio and video.',
    'ツールバーの「ノート」で新しいクイックノートを作成、または「読み込む」で音声・動画を追加できます。',
    '도구 막대의 ‘노트’로 빠른 노트를 만들거나 ‘가져오기’로 오디오와 동영상을 추가하세요.',
    'Cliquez sur « Note » dans la barre d’outils pour créer une note rapide, ou sur « Importer » pour ajouter audio et vidéo.',
    'Klicken Sie in der Symbolleiste auf „Notiz“ für eine Kurznotiz oder auf „Importieren“ für Audio und Video.',
    'Pulsa «Nota» en la barra de herramientas para crear una nota rápida, o «Importar» para añadir audio y vídeo.',
    'Fai clic su «Nota» nella barra degli strumenti per una nota rapida, o su «Importa» per aggiungere audio e video.',
    'Clique em «Nota» na barra de ferramentas para criar uma nota rápida, ou «Importar» para adicionar áudio e vídeo.',
    'Нажмите «Заметка» на панели инструментов, чтобы создать быструю заметку, или «Импорт» — чтобы добавить аудио и видео.',
    'انقر «ملاحظة» في شريط الأدوات لإنشاء ملاحظة سريعة، أو «استيراد» لإضافة الصوت والفيديو.',
    'त्वरित नोट बनाने के लिए टूलबार में «नोट» पर क्लिक करें, या ऑडियो-वीडियो जोड़ने के लिए «आयात करें» पर।',
    'คลิก «โน้ต» ในแถบเครื่องมือเพื่อสร้างโน้ตด่วน หรือ «นำเข้า» เพื่อเพิ่มเสียงและวิดีโอ',
    'Nhấp «Ghi chú» trên thanh công cụ để tạo ghi chú nhanh, hoặc «Nhập» để thêm âm thanh và video.',
    'Klik «Catatan» di bilah alat untuk membuat catatan cepat, atau «Impor» untuk menambahkan audio dan video.',
    'Hızlı not için araç çubuğundaki «Not» öğesine, ses ve video eklemek için «İçe Aktar» öğesine tıklayın.',
    'Klik op «Notitie» in de werkbalk voor een snelle notitie, of op «Importeren» om audio en video toe te voegen.',
    'Kliknij „Notatka” na pasku narzędzi, aby utworzyć szybką notatkę, lub „Importuj”, aby dodać audio i wideo.',
    'Натисніть «Нотатка» на панелі інструментів, щоб створити швидку нотатку, або «Імпорт», щоб додати аудіо та відео.',
    'Klicka på «Anteckning» i verktygsfältet för en snabbanteckning, eller «Importera» för att lägga till ljud och video.',
])

add('已自动恢复 %d 条崩溃遗留的录音：%@。转写与总结需重新发起', [
    '已自動恢復 %d 條崩潰遺留的錄音：%@。轉寫與總結需重新發起',
    'Automatically recovered %d recordings left by a crash: %@. Transcription and summaries must be started again.',
    'クラッシュで残された %d 件の録音を自動復元しました：%@。文字起こしと要約は再実行が必要です。',
    '충돌로 남은 녹음 %d개를 자동 복구했습니다: %@. 전사와 요약은 다시 시작해야 합니다.',
    'Récupération automatique de %d enregistrements laissés par un plantage : %@. La transcription et les résumés doivent être relancés.',
    '%d nach einem Absturz verbliebene Aufnahmen wurden automatisch wiederhergestellt: %@. Transkription und Zusammenfassungen müssen neu gestartet werden.',
    'Se recuperaron automáticamente %d grabaciones dejadas por un fallo: %@. La transcripción y los resúmenes deben reiniciarse.',
    'Recuperate automaticamente %d registrazioni lasciate da un crash: %@. Trascrizione e riepiloghi vanno riavviati.',
    'Foram recuperadas automaticamente %d gravações deixadas por uma falha: %@. A transcrição e os resumos têm de ser reiniciados.',
    'Автоматически восстановлено записей после сбоя: %d — %@. Транскрипцию и итоги нужно запустить заново.',
    'تم استرجاع %d تسجيلًا خلّفه انهيار تلقائيًا: %@. يجب إعادة بدء النسخ والملخصات.',
    'क्रैश से बची %d रिकॉर्डिंग अपने-आप बहाल हुईं: %@। ट्रांसक्रिप्शन और सारांश फिर से शुरू करें।',
    'กู้คืนการบันทึกที่ตกค้างจากการล่ม %d รายการโดยอัตโนมัติ: %@ ต้องเริ่มถอดเสียงและสร้างสรุปใหม่',
    'Đã tự khôi phục %d bản ghi còn lại sau sự cố: %@. Cần bắt đầu lại phiên âm và tóm tắt.',
    'Berhasil memulihkan %d rekaman sisa crash: %@. Transkripsi dan ringkasan harus dimulai ulang.',
    'Çökmeden kalan %d kayıt otomatik kurtarıldı: %@. Deşifre ve özetlerin yeniden başlatılması gerekir.',
    '%d opnamen van een crash zijn automatisch hersteld: %@. Transcriptie en samenvattingen moeten opnieuw worden gestart.',
    'Automatycznie odzyskano %d nagrań pozostałych po awarii: %@. Transkrypcję i podsumowania trzeba uruchomić ponownie.',
    'Автоматично відновлено %d записів, що залишилися після збою: %@. Транскрибування й підсумки треба запустити знову.',
    'Återställde automatiskt %d inspelningar från en krasch: %@. Transkribering och sammanfattningar måste startas igen.',
])

add('磁盘空间不足：剩余 %@，本次录屏前请先清理或改用「省空间」质量。', [
    '磁碟空間不足：剩餘 %@，本次錄屏前請先清理或改用「省空間」畫質。',
    'Not enough disk space: %@ free. Free up space or switch to the “Space Saver” quality before recording.',
    'ディスク容量が不足しています：残り %@。収録前に空き容量を確保するか「省容量」品質に切り替えてください。',
    '디스크 공간 부족: %@ 남음. 녹화 전에 정리하거나 ‘공간 절약’ 화질로 바꾸세요.',
    'Espace disque insuffisant : %@ libres. Libérez de l’espace ou passez en qualité « Économe ».',
    'Nicht genügend Speicherplatz: %@ frei. Bitte aufräumen oder die Qualität „Speichersparend“ wählen.',
    'Espacio en disco insuficiente: %@ libres. Libera espacio o usa la calidad «Ahorro de espacio».',
    'Spazio su disco insufficiente: %@ liberi. Libera spazio o passa alla qualità «Risparmia spazio».',
    'Espaço em disco insuficiente: %@ livres. Liberte espaço ou use a qualidade «Poupar espaço».',
    'Недостаточно места на диске: свободно %@. Освободите место или выберите качество «Экономия места».',
    'مساحة القرص غير كافية: المتاح %@. حرّر مساحة أو اختر جودة «توفير المساحة».',
    'डिस्क स्थान अपर्याप्त: %@ खाली। जगह खाली करें या «कम जगह» गुणवत्ता चुनें।',
    'พื้นที่ดิสก์ไม่พอ: เหลือ %@ โปรดลบไฟล์หรือเปลี่ยนเป็นคุณภาพ «ประหยัดพื้นที่»',
    'Không đủ dung lượng đĩa: còn %@. Hãy dọn bớt hoặc chuyển sang chất lượng «Tiết kiệm dung lượng».',
    'Ruang disk tidak cukup: sisa %@. Kosongkan ruang atau pilih kualitas «Hemat Ruang».',
    'Disk alanı yetersiz: %@ boş. Yer açın veya «Alan Tasarrufu» kalitesine geçin.',
    'Onvoldoende schijfruimte: %@ vrij. Maak ruimte vrij of kies kwaliteit «Ruimtebesparend».',
    'Za mało miejsca na dysku: wolne %@. Zwolnij miejsce lub wybierz jakość „Oszczędzaj miejsce”.',
    'Недостатньо місця на диску: вільно %@. Звільніть місце або виберіть якість «Економія місця».',
    'Otillräckligt diskutrymme: %@ fritt. Frigör utrymme eller välj kvaliteten «Spara utrymme».',
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
    print(f'第 3 批完成：{len(T)} 条 key，新增 {filled} 条译文（缺失 key {missing_key} 条）')


if __name__ == '__main__':
    main()
