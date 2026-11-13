#!/usr/bin/env python3
# 补齐缺失译文 · 第 1 批：文本长度 ≤ 8 字的高频 UI 串（41 条 × 20 语言）
#
# 这些条目是 Xcode 抽取到、但从未翻译的（缺全部 20 种非源语言）。
# 合并策略：只补缺失语言，已存在的语言保持原样不清洗。
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('知道了', [
    '知道了', 'Got it', '了解しました', '알겠습니다', 'Compris', 'Verstanden', 'Entendido',
    'Ho capito', 'Entendido', 'Понятно', 'حسنًا', 'समझ गया', 'เข้าใจแล้ว', 'Đã hiểu',
    'Mengerti', 'Anladım', 'Begrepen', 'Rozumiem', 'Зрозуміло', 'Uppfattat',
])

add('会议总结', [
    '會議總結', 'Meeting Summary', '会議の要約', '회의 요약', 'Résumé de réunion',
    'Sitzungszusammenfassung', 'Resumen de la reunión', 'Riepilogo riunione',
    'Resumo da reunião', 'Итоги совещания', 'ملخص الاجتماع', 'मीटिंग सारांश',
    'สรุปการประชุม', 'Tóm tắt cuộc họp', 'Ringkasan Rapat', 'Toplantı Özeti',
    'Vergadersamenvatting', 'Podsumowanie spotkania', 'Підсумки зустрічі', 'Mötessammanfattning',
])

add('分析画面', [
    '分析畫面', 'Analyze Visuals', '画面を分析', '화면 분석', 'Analyser les visuels',
    'Bildinhalte analysieren', 'Analizar imágenes', 'Analizza contenuti visivi',
    'Analisar imagens', 'Анализ изображений', 'تحليل المحتوى المرئي', 'दृश्य विश्लेषण करें',
    'วิเคราะห์ภาพ', 'Phân tích hình ảnh', 'Analisis Visual', 'Görselleri Analiz Et',
    'Beelden analyseren', 'Analizuj obraz', 'Аналіз зображень', 'Analysera bilder',
])

add('合并结果', [
    '合併結果', 'Merge Result', '統合結果', '병합 결과', 'Résultat de la fusion',
    'Zusammenführungsergebnis', 'Resultado de la combinación', "Risultato dell'unione",
    'Resultado da junção', 'Результат объединения', 'نتيجة الدمج', 'मर्ज परिणाम',
    'ผลลัพธ์การรวม', 'Kết quả hợp nhất', 'Hasil Gabung', 'Birleştirme Sonucu',
    'Samenvoegresultaat', 'Wynik scalenia', 'Результат об’єднання', 'Sammanslagningsresultat',
])

add('同步中…', [
    '同步中…', 'Syncing…', '同期中…', '동기화 중…', 'Synchronisation…', 'Synchronisiere…',
    'Sincronizando…', 'Sincronizzazione…', 'A sincronizar…', 'Синхронизация…', 'جارٍ المزامنة…',
    'सिंक हो रहा है…', 'กำลังซิงค์…', 'Đang đồng bộ…', 'Menyinkronkan…', 'Eşitleniyor…',
    'Synchroniseren…', 'Synchronizowanie…', 'Синхронізація…', 'Synkroniserar…',
])

add('图片理解', [
    '圖片理解', 'Image Understanding', '画像理解', '이미지 이해', "Compréhension d'image",
    'Bildverständnis', 'Comprensión de imágenes', 'Comprensione immagini',
    'Compreensão de imagens', 'Понимание изображений', 'فهم الصور', 'छवि समझ',
    'การเข้าใจภาพ', 'Hiểu hình ảnh', 'Pemahaman Gambar', 'Görsel Anlama', 'Beeldbegrip',
    'Rozumienie obrazu', 'Розуміння зображень', 'Bildförståelse',
])

add('复制全部', [
    '複製全部', 'Copy All', 'すべてコピー', '모두 복사', 'Tout copier', 'Alles kopieren',
    'Copiar todo', 'Copia tutto', 'Copiar tudo', 'Копировать всё', 'نسخ الكل',
    'सभी कॉपी करें', 'คัดลอกทั้งหมด', 'Sao chép tất cả', 'Salin Semua', 'Tümünü Kopyala',
    'Alles kopiëren', 'Kopiuj wszystko', 'Копіювати все', 'Kopiera allt',
])

add('打开目录', [
    '打開目錄', 'Open Folder', 'フォルダを開く', '폴더 열기', 'Ouvrir le dossier',
    'Ordner öffnen', 'Abrir carpeta', 'Apri cartella', 'Abrir pasta', 'Открыть папку',
    'فتح المجلد', 'फ़ोल्डर खोलें', 'เปิดโฟลเดอร์', 'Mở thư mục', 'Buka Folder', 'Klasörü Aç',
    'Map openen', 'Otwórz folder', 'Відкрити теку', 'Öppna mapp',
])

add('暂不分析', [
    '暫不分析', 'Skip Analysis', '今は分析しない', '나중에 분석', 'Ne pas analyser',
    'Nicht analysieren', 'No analizar', 'Non analizzare', 'Não analisar', 'Не анализировать',
    'عدم التحليل الآن', 'अभी विश्लेषण नहीं', 'ยังไม่วิเคราะห์', 'Không phân tích',
    'Jangan analisis', 'Şimdilik Analiz Etme', 'Niet analyseren', 'Nie analizuj',
    'Не аналізувати', 'Analysera inte',
])

add('概要总结', [
    '概要總結', 'Brief Summary', '概要要約', '요약', 'Résumé bref', 'Kurzzusammenfassung',
    'Resumen breve', 'Sintesi breve', 'Resumo breve', 'Краткие итоги', 'ملخص موجز',
    'संक्षिप्त सारांश', 'สรุปย่อ', 'Tóm tắt ngắn', 'Ringkasan Singkat', 'Kısa Özet',
    'Korte samenvatting', 'Krótkie podsumowanie', 'Стислий підсумок', 'Kort sammanfattning',
])

add('画面要点', [
    '畫面要點', 'Visual Highlights', '画面の要点', '화면 요약', 'Points clés visuels', 'Bildpunkte',
    'Puntos visuales', 'Punti visivi', 'Destaques visuais', 'Визуальные тезисы', 'النقاط المرئية',
    'दृश्य मुख्य बिंदु', 'สรุปภาพ', 'Điểm hình ảnh', 'Poin Visual', 'Görsel Özetler',
    'Visuele hoogtepunten', 'Punkty obrazu', 'Візуальні тези', 'Visuella punkter',
])

add('视频理解', [
    '影片理解', 'Video Understanding', '動画理解', '동영상 이해', 'Compréhension vidéo',
    'Videoverständnis', 'Comprensión de vídeo', 'Comprensione video', 'Compreensão de vídeo',
    'Понимание видео', 'فهم الفيديو', 'वीडियो समझ', 'การเข้าใจวิดีโอ', 'Hiểu video',
    'Pemahaman Video', 'Video Anlama', 'Videobegrip', 'Rozumienie wideo', 'Розуміння відео',
    'Videoförståelse',
])

add('识别中…', [
    '識別中…', 'Recognizing…', '認識中…', '인식 중…', 'Reconnaissance…', 'Erkenne…',
    'Reconociendo…', 'Riconoscimento…', 'A reconhecer…', 'Распознавание…', 'جارٍ التعرّف…',
    'पहचान हो रही है…', 'กำลังรู้จำ…', 'Đang nhận dạng…', 'Mengenali…', 'Tanınıyor…',
    'Herkennen…', 'Rozpoznawanie…', 'Розпізнавання…', 'Tolkar…',
])

add('重新分析', [
    '重新分析', 'Analyze Again', '再分析', '다시 분석', 'Réanalyser', 'Erneut analysieren',
    'Analizar de nuevo', 'Analizza di nuovo', 'Analisar novamente', 'Анализировать заново',
    'إعادة التحليل', 'फिर से विश्लेषण करें', 'วิเคราะห์ใหม่', 'Phân tích lại', 'Analisis Ulang',
    'Yeniden Analiz Et', 'Opnieuw analyseren', 'Analizuj ponownie', 'Проаналізувати знову',
    'Analysera igen',
])

add('OCR识别', [
    'OCR 辨識', 'OCR', 'OCR 認識', 'OCR 인식', 'Reconnaissance OCR', 'OCR-Erkennung',
    'Reconocimiento OCR', 'Riconoscimento OCR', 'Reconhecimento OCR', 'Распознавание OCR',
    'التعرّف الضوئي OCR', 'OCR पहचान', 'การรู้จำ OCR', 'Nhận dạng OCR', 'Pengenalan OCR',
    'OCR Tanıma', 'OCR-herkenning', 'Rozpoznawanie OCR', 'Розпізнавання OCR', 'OCR-tolkning',
])

add('录屏 %@', [
    '螢幕錄製 %@', 'Screen Recording %@', '画面収録 %@', '화면 녹화 %@', "Enregistrement d'écran %@",
    'Bildschirmaufnahme %@', 'Grabación de pantalla %@', 'Registrazione schermo %@',
    'Gravação de ecrã %@', 'Запись экрана %@', 'تسجيل الشاشة %@', 'स्क्रीन रिकॉर्डिंग %@',
    'การบันทึกหน้าจอ %@', 'Ghi màn hình %@', 'Perekaman Layar %@', 'Ekran Kaydı %@',
    'Schermopname %@', 'Nagrywanie ekranu %@', 'Запис екрана %@', 'Skärminspelning %@',
])

add('抽取关键帧', [
    '擷取關鍵影格', 'Extract Keyframes', 'キーフレームを抽出', '키프레임 추출',
    'Extraire les images clés', 'Keyframes extrahieren', 'Extraer fotogramas clave',
    'Estrai fotogrammi chiave', 'Extrair fotogramas-chave', 'Извлечь ключевые кадры',
    'استخراج الإطارات الرئيسية', 'कीफ़्रेम निकालें', 'ดึงคีย์เฟรม', 'Trích khung hình chính',
    'Ekstrak Keyframe', 'Kare Çıkar', 'Keyframes extraheren', 'Wyodrębnij klatki kluczowe',
    'Видобути ключові кадри', 'Extrahera nyckelbildrutor',
])

add('%@（%@）', [
    '%@（%@）', '%@ (%@)', '%@（%@）', '%@(%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)',
    '%@ (%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)',
    '%@ (%@)', '%@ (%@)', '%@ (%@)', '%@ (%@)',
])

add('%lld 帧', [
    '%lld 影格', '%lld frames', '%lld フレーム', '%lld 프레임', '%lld images', '%lld Bilder',
    '%lld fotogramas', '%lld fotogrammi', '%lld fotogramas', '%lld кадров', '%lld إطار',
    '%lld फ़्रेम', '%lld เฟรม', '%lld khung', '%lld frame', '%lld kare', '%lld frames',
    '%lld klatek', '%lld кадрів', '%lld bildrutor',
])

add('保存为文件…', [
    '儲存為檔案…', 'Save as File…', 'ファイルとして保存…', '파일로 저장…',
    'Enregistrer dans un fichier…', 'Als Datei sichern…', 'Guardar como archivo…',
    'Salva come file…', 'Guardar como ficheiro…', 'Сохранить в файл…', 'حفظ كملف…',
    'फ़ाइल के रूप में सहेजें…', 'บันทึกเป็นไฟล์…', 'Lưu thành tệp…', 'Simpan sebagai File…',
    'Dosya Olarak Kaydet…', 'Opslaan als bestand…', 'Zapisz jako plik…', 'Зберегти як файл…',
    'Spara som fil…',
])

add('关键帧时间轴', [
    '關鍵影格時間軸', 'Keyframe Timeline', 'キーフレームタイムライン', '키프레임 타임라인',
    'Chronologie des images clés', 'Keyframe-Zeitleiste', 'Línea de tiempo de fotogramas',
    'Sequenza fotogrammi chiave', 'Linha temporal de fotogramas', 'Таймлайн ключевых кадров',
    'الجدول الزمني للإطارات الرئيسية', 'कीफ़्रेम टाइमलाइन', 'ไทม์ไลน์คีย์เฟรม',
    'Dòng thời gian khung hình', 'Linimasa Keyframe', 'Kare Zaman Çizelgesi',
    'Keyframe-tijdlijn', 'Oś czasu klatek', 'Часова шкала ключових кадрів',
    'Nyckelbildrutors tidslinje',
])

add('尚未分析画面', [
    '尚未分析畫面', 'Visuals Not Analyzed', '画面は未分析', '화면 미분석', 'Visuels non analysés',
    'Bilder noch nicht analysiert', 'Imágenes sin analizar', 'Contenuti visivi non analizzati',
    'Imagens não analisadas', 'Изображения не проанализированы', 'لم يُحلّل المحتوى المرئي',
    'दृश्य का विश्लेषण नहीं हुआ', 'ยังไม่ได้วิเคราะห์ภาพ', 'Chưa phân tích hình ảnh',
    'Visual belum dianalisis', 'Görseller analiz edilmedi', 'Beelden niet geanalyseerd',
    'Obraz nieprzeanalizowany', 'Зображення не проаналізовано', 'Bilder ej analyserade',
])

add('打开原始视频', [
    '打開原始影片', 'Open Original Video', '元の動画を開く', '원본 동영상 열기',
    "Ouvrir la vidéo d'origine", 'Originalvideo öffnen', 'Abrir vídeo original',
    'Apri video originale', 'Abrir vídeo original', 'Открыть исходное видео',
    'فتح الفيديو الأصلي', 'मूल वीडियो खोलें', 'เปิดวิดีโอต้นฉบับ', 'Mở video gốc',
    'Buka Video Asli', 'Orijinal Videoyu Aç', 'Originele video openen', 'Otwórz oryginalny film',
    'Відкрити оригінальне відео', 'Öppna originalvideo',
])

add('数据解密失败', [
    '資料解密失敗', 'Data Decryption Failed', 'データの復号に失敗', '데이터 복호화 실패',
    'Échec du déchiffrement', 'Entschlüsselung fehlgeschlagen', 'Error al descifrar los datos',
    'Decifratura non riuscita', 'Falha ao decifrar dados', 'Не удалось расшифровать данные',
    'فشل فك تشفير البيانات', 'डेटा डिक्रिप्शन विफल', 'ถอดรหัสข้อมูลไม่สำเร็จ',
    'Giải mã dữ liệu thất bại', 'Dekripsi Data Gagal', 'Veri Şifresi Çözülemedi',
    'Ontsleutelen mislukt', 'Odszyfrowanie nie powiodło się', 'Не вдалося розшифрувати дані',
    'Data dekrypterades inte',
])

add('未识别到文字', [
    '未識別到文字', 'No Text Detected', '文字を検出できません', '텍스트를 찾지 못함',
    'Aucun texte détecté', 'Kein Text erkannt', 'No se detectó texto', 'Nessun testo rilevato',
    'Nenhum texto detetado', 'Текст не обнаружен', 'لم يُعثر على نص', 'कोई टेक्स्ट नहीं मिला',
    'ไม่พบข้อความ', 'Không nhận ra văn bản', 'Tidak ada teks terdeteksi', 'Metin bulunamadı',
    'Geen tekst gevonden', 'Nie wykryto tekstu', 'Текст не виявлено', 'Ingen text hittades',
])

add('本地 OCR', [
    '本機 OCR', 'Local OCR', 'ローカル OCR', '로컬 OCR', 'OCR local', 'Lokales OCR', 'OCR local',
    'OCR locale', 'OCR local', 'Локальный OCR', 'OCR محلي', 'स्थानीय OCR', 'OCR ในเครื่อง',
    'OCR cục bộ', 'OCR Lokal', 'Yerel OCR', 'Lokale OCR', 'OCR lokalny', 'Локальний OCR', 'Lokal OCR',
])

add('关键帧抽取完成', [
    '關鍵影格擷取完成', 'Keyframes Extracted', 'キーフレームの抽出が完了', '키프레임 추출 완료',
    'Images clés extraites', 'Keyframes extrahiert', 'Fotogramas clave extraídos',
    'Fotogrammi chiave estratti', 'Fotogramas-chave extraídos', 'Ключевые кадры извлечены',
    'تم استخراج الإطارات الرئيسية', 'कीफ़्रेम निकाले गए', 'ดึงคีย์เฟรมเสร็จ',
    'Đã trích khung hình chính', 'Keyframe diekstrak', 'Kareler çıkarıldı',
    'Keyframes geëxtraheerd', 'Wyodrębniono klatki kluczowe', 'Ключові кадри видобуто',
    'Nyckelbildrutor extraherade',
])

add('加密保护未生效', [
    '加密保護未生效', 'Encryption Not Active', '暗号化が有効になっていません', '암호화 보호 비활성',
    'Chiffrement inactif', 'Verschlüsselung inaktiv', 'Cifrado no activo', 'Cifratura non attiva',
    'Cifra não ativa', 'Шифрование не действует', 'حماية التشفير غير مفعّلة',
    'एन्क्रिप्शन सुरक्षा सक्रिय नहीं', 'การเข้ารหัสไม่ทำงาน', 'Bảo vệ mã hóa chưa hoạt động',
    'Perlindungan enkripsi tidak aktif', 'Şifreleme etkin değil', 'Versleuteling niet actief',
    'Szyfrowanie nieaktywne', 'Шифрування не діє', 'Kryptering inaktiv',
])

add('闻墨集', [
    '聞墨達會議備忘錄', 'Memozia Meeting Memo', 'Memozia 会議メモ', 'Memozia 회의 메모',
    'Memozia — mémos de réunion', 'Memozia – Sitzungsnotizen', 'Memozia — notas de reunión',
    'Memozia — note di riunione', 'Memozia — notas de reunião', 'Memozia — заметки совещаний',
    'Memozia — مذكرات الاجتماعات', 'Memozia — मीटिंग मेमो', 'Memozia — บันทึกการประชุม',
    'Memozia — ghi chú cuộc họp', 'Memozia — catatan rapat', 'Memozia — toplantı notları',
    'Memozia — vergadernotities', 'Memozia — notatki ze spotkań', 'Memozia — нотатки зустрічей',
    'Memozia — mötesanteckningar',
])

add('导入音频与视频', [
    '匯入音訊與影片', 'Import Audio & Video', '音声と動画を読み込む', '오디오·동영상 가져오기',
    'Importer audio et vidéo', 'Audio und Video importieren', 'Importar audio y vídeo',
    'Importa audio e video', 'Importar áudio e vídeo', 'Импорт аудио и видео',
    'استيراد الصوت والفيديو', 'ऑडियो और वीडियो आयात करें', 'นำเข้าเสียงและวิดีโอ',
    'Nhập âm thanh và video', 'Impor Audio & Video', 'Ses ve Video İçe Aktar',
    'Audio en video importeren', 'Importuj audio i wideo', 'Імпорт аудіо та відео',
    'Importera ljud och video',
])

add('已复制到剪贴板', [
    '已複製到剪貼簿', 'Copied to Clipboard', 'クリップボードにコピーしました', '클립보드에 복사됨',
    'Copié dans le presse-papiers', 'In die Zwischenablage kopiert', 'Copiado al portapapeles',
    'Copiato negli appunti', 'Copiado para a área de transferência', 'Скопировано в буфер обмена',
    'تم النسخ إلى الحافظة', 'क्लिपबोर्ड पर कॉपी किया गया', 'คัดลอกไปยังคลิปบอร์ดแล้ว',
    'Đã sao chép vào bảng tạm', 'Disalin ke Papan Klip', 'Panoya kopyalandı',
    'Naar klembord gekopieerd', 'Skopiowano do schowka', 'Скопійовано в буфер обміну',
    'Kopierat till urklipp',
])

add('识别失败：%@', [
    '識別失敗：%@', 'Recognition failed: %@', '認識に失敗：%@', '인식 실패: %@',
    'Échec de la reconnaissance : %@', 'Erkennung fehlgeschlagen: %@', 'Error de reconocimiento: %@',
    'Riconoscimento non riuscito: %@', 'Falha no reconhecimento: %@', 'Не удалось распознать: %@',
    'فشل التعرّف: %@', 'पहचान विफल: %@', 'รู้จำไม่สำเร็จ: %@', 'Nhận dạng thất bại: %@',
    'Pengenalan gagal: %@', 'Tanıma başarısız: %@', 'Herkenning mislukt: %@',
    'Rozpoznawanie nie powiodło się: %@', 'Не вдалося розпізнати: %@', 'Tolkning misslyckades: %@',
])

add('，约 %d 分钟', [
    '，約 %d 分鐘', ', about %d min', '、約 %d 分', ', 약 %d분', ', environ %d min',
    ', ca. %d Min.', ', unos %d min', ', circa %d min', ', cerca de %d min', ', около %d мин',
    '، حوالي %d دقيقة', ', लगभग %d मिनट', ', ประมาณ %d นาที', ', khoảng %d phút',
    ', sekitar %d menit', ', yaklaşık %d dk', ', ongeveer %d min', ', około %d min',
    ', близько %d хв', ', cirka %d min',
])

add('%lld 个片段', [
    '%lld 個片段', '%lld clips', '%lld 個のセグメント', '%lld개 구간', '%lld segments',
    '%lld Abschnitte', '%lld segmentos', '%lld segmenti', '%lld segmentos', '%lld фрагментов',
    '%lld مقطعًا', '%lld सेगमेंट', '%lld ช่วง', '%lld đoạn', '%lld segmen', '%lld bölüm',
    '%lld segmenten', '%lld segmentów', '%lld фрагментів', '%lld segment',
])

add('点击跳转到此画面', [
    '點擊跳轉到此畫面', 'Click to Jump to This Frame', 'クリックでこの画面へ移動',
    '클릭하여 이 화면으로 이동', 'Cliquer pour y accéder', 'Klicken, um dorthin zu springen',
    'Clic para ir a esta imagen', 'Fai clic per andare qui', 'Clique para ir a esta imagem',
    'Нажмите, чтобы перейти', 'انقر للانتقال إلى هذه الصورة', 'इस दृश्य पर जाने के लिए क्लिक करें',
    'คลิกเพื่อไปยังภาพนี้', 'Nhấp để đến hình này', 'Klik untuk melompat ke sini',
    'Bu kareye gitmek için tıkla', 'Klik om hierheen te gaan', 'Kliknij, aby przejść',
    'Натисніть, щоб перейти', 'Klicka för att gå hit',
])

add('用系统播放器打开', [
    '用系統播放器打開', 'Open in System Player', 'システムのプレーヤーで開く', '시스템 플레이어로 열기',
    'Ouvrir avec le lecteur système', 'Im Systemplayer öffnen',
    'Abrir con el reproductor del sistema', 'Apri con il lettore di sistema',
    'Abrir no reprodutor do sistema', 'Открыть в системном плеере', 'الفتح في مشغّل النظام',
    'सिस्टम प्लेयर में खोलें', 'เปิดในโปรแกรมเล่นของระบบ', 'Mở bằng trình phát hệ thống',
    'Buka di Pemutar Sistem', 'Sistem Oynatıcıda Aç', 'Openen in systeemspeler',
    'Otwórz w odtwarzaczu systemowym', 'Відкрити в системному плеєрі', 'Öppna i systemspelaren',
])

add('选择截图保存位置', [
    '選擇截圖儲存位置', 'Choose Where to Save', '保存先を選択', '저장 위치 선택',
    "Choisir l'emplacement", 'Speicherort wählen', 'Elegir dónde guardar', 'Scegli dove salvare',
    'Escolher onde guardar', 'Выбрать место сохранения', 'اختيار مكان الحفظ', 'सहेजने का स्थान चुनें',
    'เลือกที่บันทึก', 'Chọn nơi lưu', 'Pilih lokasi simpan', 'Kayıt yerini seç', 'Kies opslaglocatie',
    'Wybierz miejsce zapisu', 'Вибрати місце збереження', 'Välj plats att spara',
])

add('部分改动未能保存', [
    '部分變更未能儲存', 'Some Changes Were Not Saved', '一部の変更を保存できませんでした',
    '일부 변경사항이 저장되지 않음', 'Certaines modifications non enregistrées',
    'Einige Änderungen nicht gespeichert', 'Algunos cambios no se guardaron',
    'Alcune modifiche non salvate', 'Algumas alterações não guardadas', 'Часть изменений не сохранена',
    'لم تُحفظ بعض التغييرات', 'कुछ बदलाव सहेजे नहीं जा सके', 'บางการเปลี่ยนแปลงไม่ได้บันทึก',
    'Một số thay đổi chưa được lưu', 'Sebagian perubahan tidak tersimpan',
    'Bazı değişiklikler kaydedilemedi', 'Sommige wijzigingen niet opgeslagen',
    'Nie zapisano części zmian', 'Частину змін не збережено', 'Vissa ändringar sparades inte',
])

add('重新生成会议总结', [
    '重新生成會議總結', 'Regenerate Meeting Summary', '会議の要約を再生成', '회의 요약 다시 생성',
    'Régénérer le résumé de réunion', 'Sitzungszusammenfassung neu erstellen',
    'Regenerar resumen de la reunión', 'Rigenera riepilogo riunione', 'Regenerar resumo da reunião',
    'Создать итоги совещания заново', 'إعادة إنشاء ملخص الاجتماع', 'मीटिंग सारांश फिर बनाएँ',
    'สร้างสรุปการประชุมใหม่', 'Tạo lại tóm tắt cuộc họp', 'Buat Ulang Ringkasan Rapat',
    'Toplantı Özetini Yeniden Oluştur', 'Vergadersamenvatting opnieuw maken',
    'Wygeneruj ponownie podsumowanie', 'Створити підсумки зустрічі заново',
    'Skapa mötessammanfattning igen',
])

add('重新生成概要总结', [
    '重新生成概要總結', 'Regenerate Brief Summary', '概要要約を再生成', '요약 다시 생성',
    'Régénérer le résumé bref', 'Kurzzusammenfassung neu erstellen', 'Regenerar resumen breve',
    'Rigenera sintesi breve', 'Regenerar resumo breve', 'Создать краткие итоги заново',
    'إعادة إنشاء الملخص الموجز', 'संक्षिप्त सारांश फिर बनाएँ', 'สร้างสรุปย่อใหม่',
    'Tạo lại tóm tắt ngắn', 'Buat Ulang Ringkasan Singkat', 'Kısa Özeti Yeniden Oluştur',
    'Korte samenvatting opnieuw maken', 'Wygeneruj ponownie krótkie podsumowanie',
    'Створити стислий підсумок заново', 'Skapa kort sammanfattning igen',
])

add('重新编辑文字内容', [
    '重新編輯文字內容', 'Edit Text Again', 'テキストを再編集', '텍스트 다시 편집',
    'Modifier à nouveau le texte', 'Text erneut bearbeiten', 'Editar texto de nuevo',
    'Modifica di nuovo il testo', 'Editar texto novamente', 'Редактировать текст заново',
    'إعادة تحرير النص', 'टेक्स्ट फिर संपादित करें', 'แก้ไขข้อความอีกครั้ง', 'Chỉnh sửa lại văn bản',
    'Edit Teks Lagi', 'Metni Yeniden Düzenle', 'Tekst opnieuw bewerken', 'Edytuj tekst ponownie',
    'Редагувати текст знову', 'Redigera text igen',
])


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    filled = missing_key = already = 0
    for key, vals in T.items():
        entry = existing.get(key)
        if entry is None:
            print(f'⚠️ 目录中无此 key，跳过：{key[:30]}')
            missing_key += 1
            continue
        locs = entry.setdefault('localizations', {})
        if 'zh-Hans' not in locs:
            locs['zh-Hans'] = {'stringUnit': {'state': 'translated', 'value': key}}
        n = 0
        for lang, val in zip(LANGS, vals):
            if lang in locs:      # 已有译文保持原样
                continue
            locs[lang] = {'stringUnit': {'state': 'translated', 'value': val}}
            n += 1
        filled += n
        if n == 0:
            already += 1

    with open(CATALOG, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')
    print(f'第 1 批完成：{len(T)} 条 key，新增 {filled} 条译文（已完整 {already} 条，缺失 key {missing_key} 条）')


if __name__ == '__main__':
    main()
