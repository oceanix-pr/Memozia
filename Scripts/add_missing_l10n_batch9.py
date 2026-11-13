#!/usr/bin/env python3
# 补齐批次 9：视频理解、关键帧与原始视频清理相关文案 20 种语言
# 术语对齐既有译文（关键帧/画面要点/清理视频/原始视频取自「录屏产生的视频文件…」那条的既定译法）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('原始视频不在本机', [
    '原始影片不在本機',
    "The original video isn't on this Mac",
    '元の動画がこの Mac にありません',
    '원본 동영상이 이 Mac에 없습니다',
    "La vidéo d'origine n'est pas sur ce Mac",
    'Das Originalvideo ist nicht auf diesem Mac',
    'El vídeo original no está en este Mac',
    'Il video originale non è su questo Mac',
    'O vídeo original não está neste Mac',
    'Оригинальное видео отсутствует на этом Mac',
    'الفيديو الأصلي غير موجود على هذا الجهاز',
    'मूल वीडियो इस Mac पर नहीं है',
    'วิดีโอต้นฉบับไม่อยู่ในเครื่องนี้',
    'Video gốc không có trên máy này',
    'Video asli tidak ada di Mac ini',
    'Orijinal video bu Mac’te değil',
    'De originele video staat niet op deze Mac',
    'Oryginalny film nie znajduje się na tym Macu',
    'Оригінальне відео відсутнє на цьому Mac',
    'Originalvideon finns inte på den här Macen',
])

add('原始视频已清理，且没有可复用的关键帧，无法分析画面（重新导入视频即可恢复）。', [
    '原始影片已清理，且沒有可重複使用的關鍵影格，無法分析畫面（重新匯入影片即可恢復）。',
    "The original video was cleaned up and no keyframes can be reused, so the picture can't be analyzed (import the video again to restore it).",
    '元の動画は整理済みで再利用できるキーフレームもないため、画面を分析できません（動画を再取り込みすれば復元できます）。',
    '원본 동영상이 정리되었고 재사용할 키프레임도 없어 화면을 분석할 수 없습니다(동영상을 다시 가져오면 복구됩니다).',
    "La vidéo d'origine a été nettoyée et aucune image clé n'est réutilisable : impossible d'analyser l'image (réimportez la vidéo pour la restaurer).",
    'Das Originalvideo wurde aufgeräumt und es gibt keine wiederverwendbaren Keyframes, daher kann das Bild nicht analysiert werden (Video erneut importieren, um es wiederherzustellen).',
    'El vídeo original se limpió y no hay fotogramas clave reutilizables, así que no se puede analizar la imagen (vuelve a importar el vídeo para restaurarlo).',
    "Il video originale è stato rimosso e non ci sono fotogrammi chiave riutilizzabili, quindi non è possibile analizzare l'immagine (reimporta il video per ripristinarlo).",
    'O vídeo original foi limpo e não há fotogramas-chave reutilizáveis, por isso não é possível analisar a imagem (importe o vídeo novamente para restaurar).',
    'Оригинальное видео очищено, а пригодных для повторного использования ключевых кадров нет, поэтому изображение нельзя проанализировать (импортируйте видео заново, чтобы восстановить).',
    'تم تنظيف الفيديو الأصلي ولا توجد إطارات رئيسية قابلة لإعادة الاستخدام، لذا لا يمكن تحليل الصورة (أعد استيراد الفيديو للاستعادة).',
    'मूल वीडियो साफ़ कर दिया गया है और पुनः उपयोग योग्य कीफ़्रेम नहीं हैं, इसलिए चित्र का विश्लेषण नहीं हो सकता (बहाल करने के लिए वीडियो फिर से आयात करें)।',
    'วิดีโอต้นฉบับถูกล้างแล้วและไม่มีคีย์เฟรมที่ใช้ซ้ำได้ จึงวิเคราะห์ภาพไม่ได้ (นำเข้าวิดีโออีกครั้งเพื่อกู้คืน)',
    'Video gốc đã được dọn và không còn khung hình chính dùng lại được nên không thể phân tích hình ảnh (nhập lại video để khôi phục).',
    'Video asli sudah dibersihkan dan tidak ada keyframe yang dapat dipakai ulang, sehingga gambar tidak dapat dianalisis (impor ulang video untuk memulihkannya).',
    'Orijinal video temizlendi ve yeniden kullanılabilir kare yok, bu yüzden görüntü analiz edilemiyor (geri getirmek için videoyu yeniden içe aktarın).',
    'De originele video is opgeruimd en er zijn geen herbruikbare keyframes, dus het beeld kan niet worden geanalyseerd (importeer de video opnieuw om dit te herstellen).',
    'Oryginalny film został wyczyszczony i nie ma klatek kluczowych do ponownego użycia, więc nie można analizować obrazu (zaimportuj film ponownie, aby go przywrócić).',
    'Оригінальне відео очищено, а ключових кадрів для повторного використання немає, тому зображення неможливо проаналізувати (імпортуйте відео знову, щоб відновити).',
    'Originalvideon har rensats och det finns inga återanvändbara nyckelbildrutor, så bilden kan inte analyseras (importera videon igen för att återställa).',
])

add('只删除原始视频文件，关键帧与画面要点保留', [
    '只刪除原始影片檔案，關鍵影格與畫面要點保留',
    'Only deletes the original video file; keyframes and visual notes are kept',
    '元の動画ファイルだけを削除し、キーフレームと画面メモは保持します',
    '원본 동영상 파일만 삭제하고 키프레임과 화면 요약은 유지됩니다',
    "Supprime uniquement le fichier vidéo d'origine ; les images clés et le résumé visuel sont conservés",
    'Löscht nur die Originalvideodatei; Keyframes und visuelle Notizen bleiben erhalten',
    'Elimina solo el archivo de vídeo original; los fotogramas clave y las notas visuales se conservan',
    'Elimina solo il file video originale; fotogrammi chiave e note visive vengono conservati',
    'Elimina apenas o ficheiro de vídeo original; os fotogramas-chave e as notas visuais são mantidos',
    'Удаляет только исходный видеофайл; ключевые кадры и визуальные заметки сохраняются',
    'يحذف ملف الفيديو الأصلي فقط، مع الاحتفاظ بالإطارات الرئيسية والملاحظات المرئية',
    'केवल मूल वीडियो फ़ाइल हटाता है; कीफ़्रेम और दृश्य नोट्स सुरक्षित रहते हैं',
    'ลบเฉพาะไฟล์วิดีโอต้นฉบับ โดยคีย์เฟรมและบันทึกภาพยังคงอยู่',
    'Chỉ xóa tệp video gốc; khung hình chính và ghi chú hình ảnh vẫn được giữ',
    'Hanya menghapus file video asli; keyframe dan catatan visual tetap disimpan',
    'Yalnızca orijinal video dosyasını siler; kare ve görsel notlar korunur',
    'Verwijdert alleen het originele videobestand; keyframes en visuele notities blijven bewaard',
    'Usuwa tylko oryginalny plik wideo; klatki kluczowe i notatki wizualne pozostają',
    'Видаляє лише оригінальний відеофайл; ключові кадри та візуальні нотатки зберігаються',
    'Tar bara bort originalvideofilen; nyckelbildrutor och visuella anteckningar behålls',
])

add('关键帧与画面要点已保留，仍可继续分析或重新分析；只是无法重新抽取关键帧。', [
    '關鍵影格與畫面要點已保留，仍可繼續分析或重新分析；只是無法重新擷取關鍵影格。',
    "Keyframes and visual notes are kept, so you can still continue or redo the analysis; you just can't extract keyframes again.",
    'キーフレームと画面メモは保持されているため、分析の続行・再分析は可能です。ただしキーフレームの再抽出はできません。',
    '키프레임과 화면 요약이 유지되어 분석을 계속하거나 다시 할 수 있습니다. 다만 키프레임을 다시 추출할 수는 없습니다.',
    "Les images clés et le résumé visuel sont conservés : vous pouvez continuer ou refaire l'analyse, mais pas réextraire les images clés.",
    'Keyframes und visuelle Notizen bleiben erhalten – Sie können die Analyse fortsetzen oder wiederholen, nur Keyframes lassen sich nicht erneut extrahieren.',
    'Los fotogramas clave y las notas visuales se conservan, así que puedes continuar o repetir el análisis; solo no puedes volver a extraer fotogramas clave.',
    "Fotogrammi chiave e note visive sono conservati, quindi puoi continuare o rifare l'analisi; non puoi però riestrarre i fotogrammi chiave.",
    'Os fotogramas-chave e as notas visuais foram mantidos, pelo que pode continuar ou refazer a análise; apenas não pode extrair novamente os fotogramas-chave.',
    'Ключевые кадры и визуальные заметки сохранены, поэтому анализ можно продолжить или повторить; заново извлечь ключевые кадры нельзя.',
    'تم الاحتفاظ بالإطارات الرئيسية والملاحظات المرئية، لذا يمكنك متابعة التحليل أو إعادته؛ لكن لا يمكن استخراج الإطارات الرئيسية مرة أخرى.',
    'कीफ़्रेम और दृश्य नोट्स सुरक्षित हैं, इसलिए विश्लेषण जारी रख सकते हैं या दोबारा कर सकते हैं; बस कीफ़्रेम दोबारा नहीं निकाले जा सकते।',
    'คีย์เฟรมและบันทึกภาพยังคงอยู่ จึงวิเคราะห์ต่อหรือวิเคราะห์ใหม่ได้ เพียงแต่แยกคีย์เฟรมซ้ำไม่ได้',
    'Khung hình chính và ghi chú hình ảnh vẫn được giữ nên bạn vẫn có thể tiếp tục hoặc phân tích lại; chỉ là không thể trích xuất lại khung hình chính.',
    'Keyframe dan catatan visual tetap disimpan, jadi Anda masih bisa melanjutkan atau mengulang analisis; hanya saja tidak dapat mengekstrak keyframe lagi.',
    'Kare ve görsel notlar korundu, bu nedenle analize devam edebilir veya yeniden yapabilirsiniz; yalnızca kareleri yeniden çıkaramazsınız.',
    'Keyframes en visuele notities blijven bewaard, dus je kunt de analyse voortzetten of opnieuw doen; alleen keyframes opnieuw extraheren kan niet.',
    'Klatki kluczowe i notatki wizualne zostały zachowane, więc możesz kontynuować lub powtórzyć analizę; nie można jednak ponownie wyodrębnić klatek kluczowych.',
    'Ключові кадри та візуальні нотатки збережено, тож аналіз можна продовжити або повторити; щоправда, повторно видобути ключові кадри не можна.',
    'Nyckelbildrutor och visuella anteckningar finns kvar, så du kan fortsätta eller göra om analysen; du kan bara inte extrahera nyckelbildrutor igen.',
])

add('关键帧抽取失败：%@', [
    '關鍵影格擷取失敗：%@',
    'Keyframe extraction failed: %@',
    'キーフレームの抽出に失敗：%@',
    '키프레임 추출 실패: %@',
    "Échec de l'extraction des images clés : %@",
    'Keyframe-Extraktion fehlgeschlagen: %@',
    'Error al extraer los fotogramas clave: %@',
    'Estrazione dei fotogrammi chiave non riuscita: %@',
    'Falha ao extrair os fotogramas-chave: %@',
    'Не удалось извлечь ключевые кадры: %@',
    'فشل استخراج الإطارات الرئيسية: %@',
    'कीफ़्रेम निकालना विफल: %@',
    'แยกคีย์เฟรมไม่สำเร็จ: %@',
    'Trích xuất khung hình chính thất bại: %@',
    'Ekstraksi keyframe gagal: %@',
    'Kare çıkarma başarısız: %@',
    'Keyframes extraheren mislukt: %@',
    'Wyodrębnianie klatek kluczowych nie powiodło się: %@',
    'Не вдалося видобути ключові кадри: %@',
    'Extrahering av nyckelbildrutor misslyckades: %@',
])

add('画面要点生成失败：%@', [
    '畫面要點產生失敗：%@',
    'Failed to generate visual notes: %@',
    '画面メモの生成に失敗：%@',
    '화면 요약 생성 실패: %@',
    'Échec de la génération du résumé visuel : %@',
    'Visuelle Notizen konnten nicht erstellt werden: %@',
    'Error al generar las notas visuales: %@',
    'Generazione delle note visive non riuscita: %@',
    'Falha ao gerar as notas visuais: %@',
    'Не удалось создать визуальные заметки: %@',
    'فشل إنشاء الملاحظات المرئية: %@',
    'दृश्य नोट्स बनाना विफल: %@',
    'สร้างบันทึกภาพไม่สำเร็จ: %@',
    'Tạo ghi chú hình ảnh thất bại: %@',
    'Gagal membuat catatan visual: %@',
    'Görsel notlar oluşturulamadı: %@',
    'Visuele notities genereren mislukt: %@',
    'Generowanie notatek wizualnych nie powiodło się: %@',
    'Не вдалося створити візуальні нотатки: %@',
    'Kunde inte skapa visuella anteckningar: %@',
])

add('空间紧张时可点「清理视频」：只删原始视频文件，关键帧与画面要点保留，仍可继续或重新分析', [
    '空間緊張時可點「清理影片」：只刪原始影片檔案，關鍵影格與畫面要點保留，仍可繼續或重新分析',
    'When space runs low, use “Clean up video”: it deletes only the original video file, keeps keyframes and visual notes, and you can still continue or redo the analysis',
    '容量が厳しいときは「動画を整理」を：元の動画ファイルだけを削除し、キーフレームと画面メモは残るため、分析の続行・再分析も可能です',
    '공간이 부족하면 ‘동영상 정리’를 사용하세요. 원본 동영상 파일만 삭제되고 키프레임과 화면 요약은 남아 분석을 계속하거나 다시 할 수 있습니다',
    "En cas de manque d'espace, utilisez « Nettoyer la vidéo » : seul le fichier vidéo d'origine est supprimé, les images clés et le résumé visuel restent, et l'analyse peut continuer ou être refaite",
    'Bei knappem Speicher „Video aufräumen“ wählen: nur die Originalvideodatei wird gelöscht, Keyframes und visuelle Notizen bleiben erhalten, die Analyse kann fortgesetzt oder wiederholt werden',
    'Si te falta espacio, usa «Limpiar vídeo»: solo se elimina el archivo de vídeo original, se conservan los fotogramas clave y las notas visuales, y puedes continuar o repetir el análisis',
    "Se lo spazio scarseggia, usa «Pulisci video»: elimina solo il file video originale, conserva fotogrammi chiave e note visive, e puoi continuare o rifare l'analisi",
    'Se faltar espaço, use «Limpar vídeo»: elimina apenas o ficheiro de vídeo original, mantém os fotogramas-chave e as notas visuais, e pode continuar ou refazer a análise',
    'Если места мало, нажмите «Очистить видео»: удалится только исходный видеофайл, ключевые кадры и визуальные заметки останутся, анализ можно продолжить или повторить',
    'عند ضيق المساحة استخدم «تنظيف الفيديو»: يحذف ملف الفيديو الأصلي فقط ويحتفظ بالإطارات الرئيسية والملاحظات المرئية، ويمكنك متابعة التحليل أو إعادته',
    'जगह कम होने पर «वीडियो साफ़ करें» दबाएँ: केवल मूल वीडियो फ़ाइल हटती है, कीफ़्रेम और दृश्य नोट्स सुरक्षित रहते हैं, विश्लेषण जारी रखा या दोबारा किया जा सकता है',
    'เมื่อพื้นที่ใกล้เต็ม ใช้ «ล้างวิดีโอ»: ลบเฉพาะไฟล์วิดีโอต้นฉบับ คีย์เฟรมและบันทึกภาพยังคงอยู่ และยังวิเคราะห์ต่อหรือวิเคราะห์ใหม่ได้',
    'Khi sắp hết dung lượng, hãy dùng «Dọn video»: chỉ xóa tệp video gốc, giữ lại khung hình chính và ghi chú hình ảnh, vẫn có thể tiếp tục hoặc phân tích lại',
    'Saat ruang menipis, gunakan «Bersihkan video»: hanya file video asli yang dihapus, keyframe dan catatan visual tetap ada, dan analisis masih bisa dilanjutkan atau diulang',
    'Yer azaldığında «Videoyu temizle»: yalnızca orijinal video dosyası silinir, kare ve görsel notlar korunur, analize devam edebilir veya yeniden yapabilirsiniz',
    'Bij weinig ruimte «Video opruimen»: alleen het originele videobestand wordt verwijderd, keyframes en visuele notities blijven bewaard en de analyse kan worden voortgezet of opnieuw gedaan',
    'Gdy brakuje miejsca, użyj „Wyczyść wideo”: usuwany jest tylko oryginalny plik wideo, klatki kluczowe i notatki wizualne pozostają, a analizę można kontynuować lub powtórzyć',
    'Якщо місця мало, натисніть «Очистити відео»: видалиться лише оригінальний відеофайл, ключові кадри та візуальні нотатки залишаться, аналіз можна продовжити або повторити',
    'När utrymmet börjar ta slut, använd «Rensa video»: bara originalvideofilen tas bort, nyckelbildrutor och visuella anteckningar finns kvar och analysen kan fortsätta eller göras om',
])

add('清理原始视频', [
    '清理原始影片',
    'Clean up original video',
    '元の動画を整理',
    '원본 동영상 정리',
    "Nettoyer la vidéo d'origine",
    'Originalvideo aufräumen',
    'Limpiar vídeo original',
    'Pulisci video originale',
    'Limpar vídeo original',
    'Очистить исходное видео',
    'تنظيف الفيديو الأصلي',
    'मूल वीडियो साफ़ करें',
    'ล้างวิดีโอต้นฉบับ',
    'Dọn video gốc',
    'Bersihkan video asli',
    'Orijinal videoyu temizle',
    'Originele video opruimen',
    'Wyczyść oryginalny film',
    'Очистити оригінальне відео',
    'Rensa originalvideo',
])

add('清理视频', [
    '清理影片',
    'Clean up video',
    '動画を整理',
    '동영상 정리',
    'Nettoyer la vidéo',
    'Video aufräumen',
    'Limpiar vídeo',
    'Pulisci video',
    'Limpar vídeo',
    'Очистить видео',
    'تنظيف الفيديو',
    'वीडियो साफ़ करें',
    'ล้างวิดีโอ',
    'Dọn video',
    'Bersihkan video',
    'Videoyu temizle',
    'Video opruimen',
    'Wyczyść wideo',
    'Очистити відео',
    'Rensa video',
])

add('还没有可复用的关键帧。请先抽取关键帧，再清理原始视频。', [
    '還沒有可重複使用的關鍵影格。請先擷取關鍵影格，再清理原始影片。',
    'There are no reusable keyframes yet. Extract keyframes first, then clean up the original video.',
    '再利用できるキーフレームがまだありません。先にキーフレームを抽出してから、元の動画を整理してください。',
    '재사용할 수 있는 키프레임이 아직 없습니다. 먼저 키프레임을 추출한 뒤 원본 동영상을 정리하세요.',
    "Aucune image clé réutilisable pour l'instant. Extrayez d'abord les images clés, puis nettoyez la vidéo d'origine.",
    'Es gibt noch keine wiederverwendbaren Keyframes. Extrahieren Sie zuerst Keyframes und räumen Sie dann das Originalvideo auf.',
    'Aún no hay fotogramas clave reutilizables. Extrae primero los fotogramas clave y luego limpia el vídeo original.',
    'Non ci sono ancora fotogrammi chiave riutilizzabili. Estrai prima i fotogrammi chiave, poi pulisci il video originale.',
    'Ainda não há fotogramas-chave reutilizáveis. Extraia primeiro os fotogramas-chave e depois limpe o vídeo original.',
    'Пригодных для повторного использования ключевых кадров пока нет. Сначала извлеките ключевые кадры, затем очистите исходное видео.',
    'لا توجد إطارات رئيسية قابلة لإعادة الاستخدام بعد. استخرج الإطارات الرئيسية أولاً ثم نظّف الفيديو الأصلي.',
    'अभी पुनः उपयोग योग्य कीफ़्रेम नहीं हैं। पहले कीफ़्रेम निकालें, फिर मूल वीडियो साफ़ करें।',
    'ยังไม่มีคีย์เฟรมที่ใช้ซ้ำได้ โปรดแยกคีย์เฟรมก่อน แล้วจึงล้างวิดีโอต้นฉบับ',
    'Chưa có khung hình chính nào dùng lại được. Hãy trích xuất khung hình chính trước, rồi dọn video gốc.',
    'Belum ada keyframe yang dapat dipakai ulang. Ekstrak keyframe dulu, lalu bersihkan video asli.',
    'Henüz yeniden kullanılabilir kare yok. Önce kareleri çıkarın, sonra orijinal videoyu temizleyin.',
    'Er zijn nog geen herbruikbare keyframes. Extraheer eerst keyframes en ruim daarna de originele video op.',
    'Nie ma jeszcze klatek kluczowych do ponownego użycia. Najpierw wyodrębnij klatki kluczowe, a potem wyczyść oryginalny film.',
    'Ще немає ключових кадрів для повторного використання. Спершу видобудьте ключові кадри, а потім очистіть оригінальне відео.',
    'Det finns inga återanvändbara nyckelbildrutor än. Extrahera nyckelbildrutor först och rensa sedan originalvideon.',
])

add('重新导入视频后才能抽取关键帧；已生成的画面要点仍会保留。', [
    '重新匯入影片後才能擷取關鍵影格；已產生的畫面要點仍會保留。',
    'Keyframes can only be extracted after importing the video again; visual notes that were already generated are kept.',
    'キーフレームを抽出するには動画を再取り込みする必要があります。生成済みの画面メモは保持されます。',
    '동영상을 다시 가져와야 키프레임을 추출할 수 있습니다. 이미 생성된 화면 요약은 유지됩니다.',
    "Les images clés ne peuvent être extraites qu'après avoir réimporté la vidéo ; le résumé visuel déjà généré est conservé.",
    'Keyframes lassen sich erst nach erneutem Import des Videos extrahieren; bereits erstellte visuelle Notizen bleiben erhalten.',
    'Solo se pueden extraer fotogramas clave tras volver a importar el vídeo; las notas visuales ya generadas se conservan.',
    'I fotogrammi chiave si possono estrarre solo dopo aver reimportato il video; le note visive già generate vengono conservate.',
    'Só é possível extrair fotogramas-chave depois de importar o vídeo novamente; as notas visuais já geradas são mantidas.',
    'Извлечь ключевые кадры можно только после повторного импорта видео; уже созданные визуальные заметки сохранятся.',
    'لا يمكن استخراج الإطارات الرئيسية إلا بعد إعادة استيراد الفيديو، وستبقى الملاحظات المرئية التي أُنشئت سابقًا.',
    'कीफ़्रेम केवल वीडियो दोबारा आयात करने के बाद ही निकाले जा सकते हैं; पहले से बने दृश्य नोट्स सुरक्षित रहेंगे।',
    'ต้องนำเข้าวิดีโออีกครั้งจึงจะแยกคีย์เฟรมได้ ส่วนบันทึกภาพที่สร้างไว้แล้วจะยังคงอยู่',
    'Chỉ có thể trích xuất khung hình chính sau khi nhập lại video; ghi chú hình ảnh đã tạo vẫn được giữ.',
    'Keyframe hanya dapat diekstrak setelah mengimpor ulang video; catatan visual yang sudah dibuat tetap disimpan.',
    'Kareler ancak video yeniden içe aktarıldıktan sonra çıkarılabilir; önceden oluşturulan görsel notlar korunur.',
    'Keyframes kunnen pas worden geëxtraheerd nadat de video opnieuw is geïmporteerd; al gemaakte visuele notities blijven bewaard.',
    'Klatki kluczowe można wyodrębnić dopiero po ponownym zaimportowaniu filmu; wygenerowane wcześniej notatki wizualne pozostaną.',
    'Ключові кадри можна видобути лише після повторного імпорту відео; уже створені візуальні нотатки збережуться.',
    'Nyckelbildrutor kan bara extraheras efter att videon importerats igen; redan skapade visuella anteckningar finns kvar.',
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
    print(f'批次9 完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
