#!/usr/bin/env python3
# 补齐缺失译文 · 第 5 批：42–48 字（6 条 × 20 语言）
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


add('打开视频条目后切换到「画面」Tab，可一边播放原视频，一边查看视觉纪要和关键帧时间轴', [
    '打開影片項目後切換到「畫面」Tab，可一邊播放原影片，一邊查看視覺紀要和關鍵影格時間軸',
    'Open a video item and switch to the “Visuals” tab to play the original video while viewing the visual notes and keyframe timeline.',
    '動画項目を開いて「画面」タブに切り替えると、元の動画を再生しながら映像要約とキーフレームタイムラインを確認できます。',
    '동영상 항목을 열고 ‘화면’ 탭으로 전환하면 원본 동영상을 재생하면서 영상 요약과 키프레임 타임라인을 볼 수 있습니다.',
    'Ouvrez un élément vidéo et passez à l’onglet « Visuels » pour lire la vidéo d’origine tout en consultant le résumé visuel et la chronologie des images clés.',
    'Öffnen Sie einen Videoeintrag und wechseln Sie zum Tab „Bild“, um das Originalvideo abzuspielen und gleichzeitig visuelle Notizen und die Keyframe-Zeitleiste zu sehen.',
    'Abre un elemento de vídeo y cambia a la pestaña «Imagen» para reproducir el vídeo original mientras ves el resumen visual y la línea de tiempo de fotogramas.',
    'Apri un elemento video e passa alla scheda «Immagine» per riprodurre il video originale mentre consulti la sintesi visiva e la sequenza dei fotogrammi chiave.',
    'Abra um item de vídeo e mude para o separador «Imagem» para reproduzir o vídeo original enquanto vê o resumo visual e a linha temporal de fotogramas.',
    'Откройте видеоэлемент и перейдите на вкладку «Изображение»: можно воспроизводить исходное видео и одновременно смотреть визуальную сводку и таймлайн ключевых кадров.',
    'افتح عنصر الفيديو وانتقل إلى تبويب «الصورة» لتشغيل الفيديو الأصلي مع عرض الملخص المرئي والجدول الزمني للإطارات الرئيسية.',
    'वीडियो आइटम खोलकर «चित्र» टैब पर जाएँ — मूल वीडियो चलाते हुए दृश्य सारांश और कीफ़्रेम टाइमलाइन देख सकते हैं।',
    'เปิดรายการวิดีโอแล้วสลับไปแท็บ «ภาพ» เพื่อเล่นวิดีโอต้นฉบับพร้อมดูสรุปภาพและไทม์ไลน์คีย์เฟรม',
    'Mở mục video và chuyển sang tab «Hình ảnh» để vừa phát video gốc vừa xem tóm tắt hình ảnh và dòng thời gian khung hình.',
    'Buka item video dan beralih ke tab «Gambar» untuk memutar video asli sambil melihat ringkasan visual dan linimasa keyframe.',
    'Bir video öğesini açıp «Görüntü» sekmesine geçin; orijinal videoyu oynatırken görsel özeti ve kare zaman çizelgesini görebilirsiniz.',
    'Open een video-item en ga naar het tabblad «Beeld» om de originele video af te spelen terwijl je de visuele samenvatting en keyframe-tijdlijn bekijkt.',
    'Otwórz element wideo i przejdź do karty „Obraz”, aby odtwarzać oryginalny film i jednocześnie widzieć podsumowanie obrazu oraz oś czasu klatek.',
    'Відкрийте відеоелемент і перейдіть на вкладку «Зображення», щоб відтворювати оригінальне відео й одночасно бачити візуальний підсумок і часову шкалу ключових кадрів.',
    'Öppna ett videoobjekt och byt till fliken «Bild» för att spela upp originalvideon samtidigt som du ser den visuella sammanfattningen och nyckelbildrutors tidslinje.',
])

add('抽取代表性画面，按视频时间轴记录幻灯片、文档、代码和共享界面；重新分析会复用关键帧。', [
    '擷取代表性畫面，按影片時間軸記錄簡報、文件、程式碼和共享介面；重新分析會重複使用關鍵影格。',
    'Extracts representative frames and records slides, documents, code and shared screens along the video timeline; re-analysis reuses existing keyframes.',
    '代表的な画面を抽出し、動画のタイムラインに沿ってスライド・資料・コード・共有画面を記録します。再分析時は既存のキーフレームを再利用します。',
    '대표 화면을 추출해 동영상 타임라인에 따라 슬라이드·문서·코드·공유 화면을 기록합니다. 다시 분석할 때는 기존 키프레임을 재사용합니다.',
    'Extrait des images représentatives et consigne diapositives, documents, code et écrans partagés le long de la chronologie ; la réanalyse réutilise les images clés existantes.',
    'Extrahiert repräsentative Bilder und protokolliert Folien, Dokumente, Code und geteilte Bildschirme entlang der Zeitachse; eine erneute Analyse nutzt vorhandene Keyframes.',
    'Extrae imágenes representativas y registra diapositivas, documentos, código y pantallas compartidas a lo largo de la línea de tiempo; el reanálisis reutiliza los fotogramas existentes.',
    'Estrae immagini rappresentative e registra slide, documenti, codice e schermate condivise lungo la sequenza; la rianalisi riutilizza i fotogrammi esistenti.',
    'Extrai imagens representativas e registra diapositivos, documentos, código e ecrãs partilhados ao longo da linha temporal; a reanálise reutiliza os fotogramas existentes.',
    'Извлекает характерные кадры и фиксирует слайды, документы, код и общие экраны по таймлайну видео; при повторном анализе существующие кадры переиспользуются.',
    'يستخرج إطارات تمثيلية ويسجّل الشرائح والمستندات والشيفرة والشاشات المشتركة على طول الجدول الزمني؛ وعند إعادة التحليل تُعاد الإطارات الحالية.',
    'प्रतिनिधि फ़्रेम निकालकर वीडियो टाइमलाइन के अनुसार स्लाइड, दस्तावेज़, कोड और साझा स्क्रीन दर्ज करता है; दोबारा विश्लेषण में मौजूदा कीफ़्रेम फिर इस्तेमाल होते हैं।',
    'ดึงภาพตัวแทนและบันทึกสไลด์ เอกสาร โค้ด และหน้าจอที่แชร์ตามไทม์ไลน์วิดีโอ การวิเคราะห์ใหม่จะใช้คีย์เฟรมเดิมซ้ำ',
    'Trích các khung hình tiêu biểu và ghi lại slide, tài liệu, mã nguồn, màn hình chia sẻ theo dòng thời gian video; phân tích lại sẽ dùng lại khung hình sẵn có.',
    'Mengekstrak frame representatif dan mencatat slide, dokumen, kode, serta layar bersama sepanjang linimasa video; analisis ulang memakai kembali keyframe yang ada.',
    'Temsili kareleri çıkarır; slaytları, belgeleri, kodu ve paylaşılan ekranları video zaman çizelgesi boyunca kaydeder; yeniden analiz mevcut kareleri yeniden kullanır.',
    'Haalt representatieve frames op en legt dia’s, documenten, code en gedeelde schermen vast langs de tijdlijn; bij heranalyse worden bestaande keyframes hergebruikt.',
    'Wyodrębnia reprezentatywne klatki i zapisuje slajdy, dokumenty, kod oraz udostępniane ekrany na osi czasu; ponowna analiza wykorzystuje istniejące klatki.',
    'Видобуває характерні кадри й фіксує слайди, документи, код і спільні екрани за часовою шкалою відео; під час повторного аналізу наявні кадри використовуються повторно.',
    'Extraherar representativa bildrutor och registrerar bildspel, dokument, kod och delade skärmar längs videons tidslinje; vid ny analys återanvänds befintliga bildrutor.',
])

add('%d 条录音自动恢复失败：%@。\n分片文件已保留在录音文件夹，可用专业音频工具尝试修复。', [
    '%d 條錄音自動恢復失敗：%@。\n分片檔案已保留在錄音資料夾，可用專業音訊工具嘗試修復。',
    'Failed to auto-recover %d recordings: %@.\nThe segment files remain in the recording folder; try repairing them with professional audio tools.',
    '%d 件の録音の自動復元に失敗しました：%@。\n分割ファイルは録音フォルダに残っています。専門の音声ツールでの修復をお試しください。',
    '%d개 녹음 자동 복구 실패: %@.\n분할 파일은 녹음 폴더에 남아 있으며, 전문 오디오 도구로 복구를 시도할 수 있습니다.',
    'Échec de la récupération automatique de %d enregistrements : %@.\nLes fragments restent dans le dossier d’enregistrement ; essayez de les réparer avec un outil audio professionnel.',
    '%d Aufnahmen konnten nicht automatisch wiederhergestellt werden: %@.\nDie Segmentdateien bleiben im Aufnahmeordner; versuchen Sie eine Reparatur mit professionellen Audio-Tools.',
    'No se pudieron recuperar automáticamente %d grabaciones: %@.\nLos fragmentos siguen en la carpeta de grabación; prueba a repararlos con herramientas de audio profesionales.',
    'Recupero automatico di %d registrazioni non riuscito: %@.\nI file suddivisi restano nella cartella di registrazione; prova a ripararli con strumenti audio professionali.',
    'Falha ao recuperar automaticamente %d gravações: %@.\nOs fragmentos permanecem na pasta de gravação; tente repará-los com ferramentas de áudio profissionais.',
    'Не удалось автоматически восстановить записей: %d — %@.\nФрагменты остались в папке записи; попробуйте восстановить их профессиональным аудиоредактором.',
    'فشل الاسترجاع التلقائي لـ %d تسجيلًا: %@.\nتبقى الملفات المجزأة في مجلد التسجيل؛ جرّب إصلاحها بأدوات صوتية احترافية.',
    '%d रिकॉर्डिंग अपने-आप बहाल नहीं हो सकीं: %@।\nखंड फ़ाइलें रिकॉर्डिंग फ़ोल्डर में हैं; पेशेवर ऑडियो टूल से ठीक करने का प्रयास करें।',
    'กู้คืนการบันทึก %d รายการอัตโนมัติไม่สำเร็จ: %@\nไฟล์แบ่งชิ้นยังอยู่ในโฟลเดอร์บันทึก ลองซ่อมด้วยเครื่องมือเสียงระดับมืออาชีพ',
    'Khôi phục tự động %d bản ghi thất bại: %@.\nCác tệp phân đoạn vẫn trong thư mục ghi; hãy thử sửa bằng công cụ âm thanh chuyên nghiệp.',
    'Gagal memulihkan otomatis %d rekaman: %@.\nFile segmen tetap di folder perekaman; coba perbaiki dengan alat audio profesional.',
    '%d kayıt otomatik kurtarılamadı: %@.\nBölüm dosyaları kayıt klasöründe duruyor; profesyonel ses araçlarıyla onarmayı deneyin.',
    '%d opnamen konden niet automatisch worden hersteld: %@.\nDe segmentbestanden blijven in de opnamemap; probeer ze te repareren met professionele audiotools.',
    'Nie udało się automatycznie odzyskać %d nagrań: %@.\nPliki segmentów pozostały w folderze nagrania; spróbuj naprawić je profesjonalnym narzędziem audio.',
    'Не вдалося автоматично відновити %d записів: %@.\nФрагменти залишилися в теці запису; спробуйте відновити їх професійним аудіоінструментом.',
    'Kunde inte återställa %d inspelningar automatiskt: %@.\nSegmentsfilerna finns kvar i inspelningsmappen; försök reparera dem med professionella ljudverktyg.',
])

add('磁盘空间不足（剩余 %lldMB），录音至少需要 500MB 可用空间。请清理磁盘后重试。', [
    '磁碟空間不足（剩餘 %lldMB），錄音至少需要 500MB 可用空間。請清理磁碟後重試。',
    'Not enough disk space (%lld MB free); recording needs at least 500 MB. Free up space and try again.',
    'ディスク容量が不足しています（残り %lldMB）。録音には最低 500MB の空きが必要です。空き容量を確保して再試行してください。',
    '디스크 공간 부족(남은 %lldMB). 녹음에는 최소 500MB가 필요합니다. 공간을 확보한 뒤 다시 시도하세요.',
    'Espace disque insuffisant (%lld Mo libres) ; l’enregistrement nécessite au moins 500 Mo. Libérez de l’espace et réessayez.',
    'Nicht genügend Speicherplatz (%lld MB frei); die Aufnahme braucht mindestens 500 MB. Bitte Platz freigeben und erneut versuchen.',
    'Espacio en disco insuficiente (%lld MB libres); grabar necesita al menos 500 MB. Libera espacio e inténtalo de nuevo.',
    'Spazio su disco insufficiente (%lld MB liberi); la registrazione richiede almeno 500 MB. Libera spazio e riprova.',
    'Espaço em disco insuficiente (%lld MB livres); a gravação precisa de pelo menos 500 MB. Liberte espaço e tente novamente.',
    'Недостаточно места на диске (свободно %lld МБ); для записи нужно минимум 500 МБ. Освободите место и повторите.',
    'مساحة القرص غير كافية (%lldMB متاحة)؛ يحتاج التسجيل إلى 500MB على الأقل. حرّر مساحة وأعد المحاولة.',
    'डिस्क स्थान अपर्याप्त (%lldMB बचा है); रिकॉर्डिंग के लिए कम से कम 500MB चाहिए। जगह खाली करके फिर कोशिश करें।',
    'พื้นที่ดิสก์ไม่พอ (เหลือ %lldMB) การบันทึกต้องใช้อย่างน้อย 500MB โปรดลบไฟล์แล้วลองใหม่',
    'Không đủ dung lượng đĩa (còn %lldMB); ghi âm cần ít nhất 500MB. Hãy dọn dung lượng rồi thử lại.',
    'Ruang disk tidak cukup (sisa %lldMB); perekaman butuh setidaknya 500MB. Kosongkan ruang lalu coba lagi.',
    'Disk alanı yetersiz (%lldMB boş); kayıt için en az 500MB gerekir. Yer açıp yeniden deneyin.',
    'Onvoldoende schijfruimte (%lldMB vrij); opnemen vereist minstens 500MB. Maak ruimte vrij en probeer opnieuw.',
    'Za mało miejsca na dysku (wolne %lldMB); nagrywanie wymaga co najmniej 500MB. Zwolnij miejsce i spróbuj ponownie.',
    'Недостатньо місця на диску (вільно %lldМБ); для запису потрібно щонайменше 500 МБ. Звільніть місце й повторіть.',
    'Otillräckligt diskutrymme (%lldMB fritt); inspelning kräver minst 500MB. Frigör utrymme och försök igen.',
])

add('缺少屏幕录制权限，请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 Memozia。', [
    '缺少螢幕錄製權限，請在「系統設定 → 隱私權與安全性 → 螢幕錄製」中允許 Memozia。',
    'Screen Recording permission is missing. Allow Memozia in System Settings → Privacy & Security → Screen Recording.',
    '画面収録の権限がありません。「システム設定 → プライバシーとセキュリティ → 画面収録」で Memozia を許可してください。',
    '화면 기록 권한이 없습니다. ‘시스템 설정 → 개인정보 보호 및 보안 → 화면 기록’에서 Memozia를 허용하세요.',
    'L’autorisation d’enregistrement d’écran est manquante. Autorisez Memozia dans Réglages → Confidentialité et sécurité → Enregistrement de l’écran.',
    'Die Berechtigung „Bildschirmaufnahme“ fehlt. Erlauben Sie Memozia unter Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme.',
    'Falta el permiso de grabación de pantalla. Permite Memozia en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla.',
    'Manca il permesso di registrazione schermo. Consenti Memozia in Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo.',
    'Falta a permissão de gravação de ecrã. Permita o Memozia em Definições do Sistema → Privacidade e Segurança → Gravação de ecrã.',
    'Нет разрешения на запись экрана. Разрешите Memozia в «Системные настройки → Конфиденциальность и безопасность → Запись экрана».',
    'إذن تسجيل الشاشة مفقود. اسمح لـ Memozia من «إعدادات النظام → الخصوصية والأمان → تسجيل الشاشة».',
    'स्क्रीन रिकॉर्डिंग की अनुमति नहीं है। «सिस्टम सेटिंग्स → गोपनीयता और सुरक्षा → स्क्रीन रिकॉर्डिंग» में Memozia को अनुमति दें।',
    'ยังไม่ได้ให้สิทธิ์บันทึกหน้าจอ โปรดอนุญาต Memozia ที่ «การตั้งค่าระบบ → ความเป็นส่วนตัวและความปลอดภัย → การบันทึกหน้าจอ»',
    'Thiếu quyền ghi màn hình. Hãy cho phép Memozia trong «Cài đặt hệ thống → Quyền riêng tư và bảo mật → Ghi màn hình».',
    'Izin perekaman layar belum ada. Izinkan Memozia di «Pengaturan Sistem → Privasi & Keamanan → Perekaman Layar».',
    'Ekran kaydı izni yok. «Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı» bölümünde Memozia’ya izin verin.',
    'De machtiging Schermopname ontbreekt. Sta Memozia toe via Systeeminstellingen → Privacy en beveiliging → Schermopname.',
    'Brak uprawnienia do nagrywania ekranu. Zezwól aplikacji Memozia w „Ustawienia systemowe → Prywatność i bezpieczeństwo → Nagrywanie ekranu”.',
    'Немає дозволу на запис екрана. Дозвольте Memozia у «Системні налаштування → Конфіденційність і безпека → Запис екрана».',
    'Behörigheten för skärminspelning saknas. Tillåt Memozia i Systeminställningar → Integritet och säkerhet → Skärminspelning.',
])

add('磁盘可用空间不足：可用 %.1fGB，导入视频至少需要 %.1fGB（原片副本 + 音轨与余量）', [
    '磁碟可用空間不足：可用 %.1fGB，匯入影片至少需要 %.1fGB（原片副本 + 音軌與餘量）',
    'Not enough free disk space: %.1f GB available, but importing video needs at least %.1f GB (a copy of the original plus the audio track and headroom).',
    'ディスクの空き容量が不足しています：空き %.1fGB に対し、動画の読み込みには最低 %.1fGB 必要です（元動画のコピー + 音声トラックと余裕分）。',
    '디스크 여유 공간 부족: %.1fGB 사용 가능, 동영상 가져오기에는 최소 %.1fGB 필요(원본 사본 + 오디오 트랙과 여유).',
    'Espace disque insuffisant : %.1f Go disponibles, alors que l’import vidéo nécessite au moins %.1f Go (copie de l’original + piste audio et marge).',
    'Nicht genügend freier Speicherplatz: %.1f GB verfügbar, der Videoimport braucht aber mindestens %.1f GB (Kopie des Originals + Audiospur und Reserve).',
    'Espacio libre insuficiente: %.1f GB disponibles, pero importar vídeo necesita al menos %.1f GB (copia del original + pista de audio y margen).',
    'Spazio libero insufficiente: %.1f GB disponibili, ma l’importazione video richiede almeno %.1f GB (copia dell’originale + traccia audio e margine).',
    'Espaço livre insuficiente: %.1f GB disponíveis, mas importar vídeo exige pelo menos %.1f GB (cópia do original + faixa de áudio e margem).',
    'Недостаточно свободного места: доступно %.1f ГБ, а для импорта видео нужно минимум %.1f ГБ (копия оригинала + звуковая дорожка и запас).',
    'المساحة الحرة غير كافية: المتاح %.1fGB، بينما يحتاج استيراد الفيديو إلى %.1fGB على الأقل (نسخة من الأصل + المسار الصوتي وهامش).',
    'खाली डिस्क स्थान अपर्याप्त: %.1fGB उपलब्ध, जबकि वीडियो आयात के लिए कम से कम %.1fGB चाहिए (मूल की प्रति + ऑडियो ट्रैक और अतिरिक्त जगह)।',
    'พื้นที่ว่างไม่พอ: มี %.1fGB แต่การนำเข้าวิดีโอต้องใช้อย่างน้อย %.1fGB (สำเนาต้นฉบับ + แทรกเสียงและเผื่อ)',
    'Không đủ dung lượng trống: còn %.1fGB, nhưng nhập video cần ít nhất %.1fGB (bản sao gốc + track âm thanh và dự phòng).',
    'Ruang kosong tidak cukup: tersedia %.1fGB, sementara impor video butuh setidaknya %.1fGB (salinan asli + track audio dan cadangan).',
    'Yeterli boş disk alanı yok: %.1fGB mevcut, ancak video içe aktarma en az %.1fGB gerektirir (orijinalin kopyası + ses kanalı ve pay).',
    'Onvoldoende vrije schijfruimte: %.1fGB beschikbaar, maar video importeren vereist minstens %.1fGB (kopie van het origineel + audiospoor en marge).',
    'Za mało wolnego miejsca: dostępne %.1fGB, a import wideo wymaga co najmniej %.1fGB (kopia oryginału + ścieżka audio i zapas).',
    'Недостатньо вільного місця: доступно %.1fГБ, а для імпорту відео потрібно щонайменше %.1fГБ (копія оригіналу + звукова доріжка й запас).',
    'Otillräckligt ledigt utrymme: %.1fGB tillgängligt, men videoimport kräver minst %.1fGB (kopia av originalet + ljudspår och marginal).',
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
    print(f'第 5 批完成：{len(T)} 条 key，新增 {filled} 条译文（缺失 key {missing_key} 条）')


if __name__ == '__main__':
    main()
