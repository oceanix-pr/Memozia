#!/usr/bin/env python3
# 补齐缺失译文 · 第 4 批：34–42 字（8 条 × 20 语言）
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


add('mp4 音轨混流失败（%@），回放可能无声或仅系统声，转写不受影响。', [
    'mp4 音軌混流失敗（%@），回放可能無聲或僅系統聲，轉寫不受影響。',
    'Failed to mux the audio track into the mp4 (%@); playback may be silent or contain only system audio. Transcription is unaffected.',
    'mp4 への音声トラックの多重化に失敗しました（%@）。再生時に無音、またはシステム音声のみになる可能性があります。文字起こしには影響しません。',
    'mp4 오디오 트랙 믹싱 실패(%@). 재생 시 무음이거나 시스템 오디오만 들릴 수 있습니다. 전사에는 영향이 없습니다.',
    'Échec du multiplexage de la piste audio dans le mp4 (%@) ; la lecture peut être muette ou ne contenir que l’audio système. La transcription n’est pas affectée.',
    'Die Audiospur konnte nicht in die mp4 eingefügt werden (%@); die Wiedergabe ist evtl. stumm oder enthält nur Systemton. Transkription ist nicht betroffen.',
    'Error al multiplexar la pista de audio en el mp4 (%@); la reproducción puede ser silenciosa o solo con audio del sistema. La transcripción no se ve afectada.',
    'Inserimento della traccia audio nell’mp4 non riuscito (%@); la riproduzione potrebbe essere muta o solo audio di sistema. La trascrizione non è interessata.',
    'Falha ao multiplexar a faixa de áudio no mp4 (%@); a reprodução pode ser silenciosa ou apenas com áudio do sistema. A transcrição não é afetada.',
    'Не удалось вставить звуковую дорожку в mp4 (%@); при воспроизведении может не быть звука или будет только системный звук. Транскрипция не затронута.',
    'فشل دمج المسار الصوتي في mp4 (%@)؛ قد يكون التشغيل صامتًا أو بصوت النظام فقط. النسخ غير متأثر.',
    'mp4 में ऑडियो ट्रैक जोड़ना विफल (%@); प्लेबैक में आवाज़ नहीं या केवल सिस्टम ऑडियो हो सकता है। ट्रांसक्रिप्शन प्रभावित नहीं।',
    'รวมแทรกเสียงเข้า mp4 ไม่สำเร็จ (%@) การเล่นอาจไม่มีเสียงหรือมีแต่เสียงระบบ การถอดเสียงไม่ได้รับผลกระทบ',
    'Ghép track âm thanh vào mp4 thất bại (%@); khi phát có thể im lặng hoặc chỉ có âm thanh hệ thống. Phiên âm không bị ảnh hưởng.',
    'Gagal menggabungkan track audio ke mp4 (%@); pemutaran mungkin tanpa suara atau hanya audio sistem. Transkripsi tidak terpengaruh.',
    'Ses kanalı mp4’e eklenemedi (%@); oynatmada ses olmayabilir veya yalnızca sistem sesi duyulabilir. Deşifre etkilenmez.',
    'Kan het audiospoor niet in de mp4 invoegen (%@); afspelen is mogelijk stil of alleen systeemgeluid. Transcriptie wordt niet beïnvloed.',
    'Nie udało się wstawić ścieżki audio do mp4 (%@); odtwarzanie może być ciche lub zawierać tylko dźwięk systemowy. Transkrypcja nie ucierpiała.',
    'Не вдалося вставити звукову доріжку в mp4 (%@); під час відтворення може бути тиша або лише системний звук. Транскрибування не зачеплено.',
    'Kunde inte lägga in ljudspåret i mp4 (%@); uppspelningen kan vara tyst eller bara innehålla systemljud. Transkribering påverkas inte.',
])

add('点击侧边栏工具栏的「导入」按钮选择媒体文件，也可直接把文件拖到侧边栏', [
    '點擊側邊欄工具列的「匯入」按鈕選擇媒體檔案，也可直接把檔案拖到側邊欄',
    'Click “Import” in the sidebar toolbar to choose media files, or drag files straight onto the sidebar.',
    'サイドバーのツールバーにある「読み込む」でメディアファイルを選択できます。ファイルをサイドバーに直接ドラッグしてもかまいません。',
    '사이드바 도구 막대의 ‘가져오기’로 미디어 파일을 선택하거나, 파일을 사이드바로 바로 끌어다 놓아도 됩니다.',
    'Cliquez sur « Importer » dans la barre d’outils latérale pour choisir des médias, ou glissez-déposez les fichiers dans la barre latérale.',
    'Klicken Sie in der Seitenleiste auf „Importieren“, um Mediendateien zu wählen — oder ziehen Sie die Dateien direkt in die Seitenleiste.',
    'Pulsa «Importar» en la barra de herramientas lateral para elegir archivos multimedia, o arrastra los archivos a la barra lateral.',
    'Fai clic su «Importa» nella barra strumenti laterale per scegliere i file multimediali, oppure trascina i file nella barra laterale.',
    'Clique em «Importar» na barra de ferramentas lateral para escolher ficheiros de multimédia, ou arraste os ficheiros para a barra lateral.',
    'Нажмите «Импорт» на панели бокового меню, чтобы выбрать медиафайлы, или просто перетащите файлы в боковое меню.',
    'انقر «استيراد» في شريط أدوات الشريط الجانبي لاختيار ملفات الوسائط، أو اسحب الملفات مباشرة إلى الشريط الجانبي.',
    'मीडिया फ़ाइल चुनने के लिए साइडबार टूलबार में «आयात करें» पर क्लिक करें, या फ़ाइलें सीधे साइडबार पर खींच लाएँ।',
    'คลิก «นำเข้า» ในแถบเครื่องมือด้านข้างเพื่อเลือกไฟล์มีเดีย หรือลากไฟล์มาวางที่แถบด้านข้างได้เลย',
    'Nhấp «Nhập» trên thanh công cụ bên trái để chọn tệp media, hoặc kéo tệp thẳng vào thanh bên.',
    'Klik «Impor» di bilah alat samping untuk memilih file media, atau seret file langsung ke bilah samping.',
    'Medya dosyalarını seçmek için kenar çubuğu araç çubuğundaki «İçe Aktar» öğesine tıklayın veya dosyaları doğrudan kenar çubuğuna sürükleyin.',
    'Klik op «Importeren» in de werkbalk van de zijbalk om mediabestanden te kiezen, of sleep bestanden direct naar de zijbalk.',
    'Kliknij „Importuj” na pasku narzędzi panelu bocznego, aby wybrać pliki multimedialne, lub przeciągnij pliki wprost do panelu.',
    'Натисніть «Імпорт» на панелі бічної колонки, щоб вибрати медіафайли, або просто перетягніть файли в бічну колонку.',
    'Klicka på «Importera» i sidofältets verktygsfält för att välja mediefiler, eller dra filerna direkt till sidofältet.',
])

add('点击关键帧可让播放器跳到对应时间；更换模型重新分析时会复用已抽取的关键帧', [
    '點擊關鍵影格可讓播放器跳到對應時間；更換模型重新分析時會重複使用已擷取的關鍵影格',
    'Click a keyframe to jump the player to that moment; switching models reuses the keyframes already extracted.',
    'キーフレームをクリックすると再生位置がその時刻に移動します。別のモデルで再分析しても抽出済みのキーフレームを再利用します。',
    '키프레임을 클릭하면 재생 위치가 해당 시점으로 이동합니다. 모델을 바꿔 다시 분석해도 이미 추출한 키프레임을 재사용합니다.',
    'Cliquez sur une image clé pour y déplacer le lecteur ; changer de modèle réutilise les images clés déjà extraites.',
    'Klicken Sie auf ein Keyframe, um im Player dorthin zu springen; beim Modellwechsel werden bereits extrahierte Keyframes wiederverwendet.',
    'Pulsa un fotograma clave para saltar a ese instante; al cambiar de modelo se reutilizan los fotogramas ya extraídos.',
    'Fai clic su un fotogramma chiave per spostare il lettore in quel momento; cambiando modello si riutilizzano i fotogrammi già estratti.',
    'Clique num fotograma-chave para saltar para esse instante; ao mudar de modelo, os fotogramas já extraídos são reutilizados.',
    'Нажмите на ключевой кадр, чтобы перейти к этому моменту; при смене модели уже извлечённые кадры используются повторно.',
    'انقر على إطار رئيسي لينتقل المشغّل إلى تلك اللحظة؛ وعند تغيير النموذج تُعاد استخدام الإطارات المستخرجة سابقًا.',
    'कीफ़्रेम पर क्लिक करने से प्लेयर उस समय पर पहुँच जाएगा; मॉडल बदलकर दोबारा विश्लेषण करने पर पहले निकाले गए कीफ़्रेम फिर इस्तेमाल होंगे।',
    'คลิกคีย์เฟรมเพื่อให้ตัวเล่นข้ามไปยังเวลานั้น เปลี่ยนโมเดลแล้ววิเคราะห์ใหม่จะใช้คีย์เฟรมที่ดึงไว้แล้วซ้ำ',
    'Nhấp vào khung hình chính để trình phát nhảy tới thời điểm đó; khi đổi mô hình phân tích lại sẽ dùng lại khung hình đã trích.',
    'Klik keyframe untuk melompat ke waktu tersebut; mengganti model dan menganalisis ulang akan memakai ulang keyframe yang sudah diekstrak.',
    'Bir kareye tıklayınca oynatıcı o ana atlar; model değiştirip yeniden analiz edildiğinde çıkarılmış kareler yeniden kullanılır.',
    'Klik op een keyframe om de speler naar dat moment te laten springen; bij een ander model worden eerder geëxtraheerde keyframes hergebruikt.',
    'Kliknięcie klatki kluczowej przewija odtwarzacz do tego momentu; zmiana modelu wykorzystuje już wyodrębnione klatki.',
    'Натисніть на ключовий кадр, щоб перейти до цього моменту; під час зміни моделі вже видобуті кадри використовуються повторно.',
    'Klicka på en nyckelbildruta för att hoppa dit i spelaren; vid modellbyte återanvänds redan extraherade bildrutor.',
])

add('磁盘剩余空间不足 1GB，按当前码率较快写满，请尽快停止录音或清理磁盘。', [
    '磁碟剩餘空間不足 1GB，按目前位元率會較快寫滿，請盡快停止錄音或清理磁碟。',
    'Less than 1 GB of disk space left; at the current bitrate it will fill up soon — stop recording or free up space.',
    'ディスクの空き容量が 1GB 未満です。現在のビットレートではすぐ一杯になります。録音を停止するか空き容量を確保してください。',
    '디스크 여유 공간이 1GB 미만입니다. 현재 비트레이트로는 곧 가득 찹니다. 녹음을 중지하거나 공간을 확보하세요.',
    'Moins de 1 Go d’espace disque ; au débit actuel, il sera vite saturé — arrêtez l’enregistrement ou libérez de l’espace.',
    'Weniger als 1 GB Speicherplatz frei; bei der aktuellen Bitrate ist er bald voll — Aufnahme stoppen oder Platz freigeben.',
    'Queda menos de 1 GB de disco; con la tasa actual se llenará pronto: detén la grabación o libera espacio.',
    'Meno di 1 GB di spazio libero; con il bitrate attuale si saturerà presto: interrompi la registrazione o libera spazio.',
    'Menos de 1 GB de espaço livre; com o débito atual enche rapidamente — pare a gravação ou liberte espaço.',
    'Свободно менее 1 ГБ; при текущем битрейте место скоро закончится — остановите запись или освободите место.',
    'المساحة المتاحة أقل من 1GB؛ وبالمعدل الحالي ستمتلئ قريبًا — أوقف التسجيل أو حرّر مساحة.',
    '1GB से कम जगह बची है; मौजूदा बिटरेट पर यह जल्दी भर जाएगी — रिकॉर्डिंग रोकें या जगह खाली करें।',
    'พื้นที่ดิสก์เหลือน้อยกว่า 1GB ที่บิตเรตปัจจุบันจะเต็มเร็ว โปรดหยุดบันทึกหรือลบไฟล์',
    'Còn dưới 1GB dung lượng; với bitrate hiện tại sẽ đầy nhanh — hãy dừng ghi hoặc dọn dung lượng.',
    'Ruang disk tersisa kurang dari 1GB; pada bitrate saat ini cepat penuh — hentikan perekaman atau kosongkan ruang.',
    '1GB’den az disk alanı kaldı; mevcut bit hızında kısa sürede dolar — kaydı durdurun veya yer açın.',
    'Minder dan 1 GB schijfruimte vrij; bij de huidige bitrate raakt het snel vol — stop de opname of maak ruimte vrij.',
    'Zostało mniej niż 1 GB miejsca; przy obecnym bitrate szybko się zapełni — zatrzymaj nagrywanie lub zwolnij miejsce.',
    'Вільно менше 1 ГБ; за поточного бітрейту місце швидко закінчиться — зупиніть запис або звільніть місце.',
    'Mindre än 1 GB ledigt; med nuvarande bitrate fylls det snart — stoppa inspelningen eller frigör utrymme.',
])

add('模型加载超时。请确认模型文件夹所在磁盘/网络卷可访问、模型文件完整后重试。', [
    '模型載入逾時。請確認模型資料夾所在磁碟/網路卷可存取、模型檔案完整後重試。',
    'Model loading timed out. Make sure the disk or network volume holding the model folder is reachable and the model files are complete, then try again.',
    'モデルの読み込みがタイムアウトしました。モデルフォルダのあるディスク／ネットワークボリュームにアクセスでき、モデルファイルが揃っていることを確認して再試行してください。',
    '모델 로딩 시간 초과. 모델 폴더가 있는 디스크/네트워크 볼륨에 접근 가능하고 모델 파일이 온전한지 확인한 뒤 다시 시도하세요.',
    'Délai dépassé lors du chargement du modèle. Vérifiez que le disque ou le volume réseau contenant le dossier du modèle est accessible et que les fichiers sont complets, puis réessayez.',
    'Zeitüberschreitung beim Laden des Modells. Prüfen Sie, ob der Datenträger bzw. das Netzwerkvolume mit dem Modellordner erreichbar und die Modelldateien vollständig sind.',
    'Se agotó el tiempo de carga del modelo. Comprueba que el disco o volumen de red con la carpeta del modelo sea accesible y que los archivos estén completos.',
    'Timeout durante il caricamento del modello. Verifica che il disco o il volume di rete con la cartella del modello sia accessibile e che i file siano completi.',
    'A carga do modelo excedeu o tempo limite. Confirme que o disco ou volume de rede com a pasta do modelo está acessível e que os ficheiros estão completos.',
    'Время загрузки модели истекло. Убедитесь, что диск или сетевой том с папкой модели доступен, а файлы модели целы, и повторите.',
    'انتهت مهلة تحميل النموذج. تأكد من إمكانية الوصول إلى القرص أو وحدة الشبكة التي تضم مجلد النموذج ومن اكتمال ملفاته، ثم أعد المحاولة.',
    'मॉडल लोड होने में समय समाप्त। जाँचें कि मॉडल फ़ोल्डर वाली डिस्क/नेटवर्क वॉल्यूम उपलब्ध है और मॉडल फ़ाइलें पूरी हैं, फिर कोशिश करें।',
    'โหลดโมเดลหมดเวลา โปรดตรวจสอบว่าดิสก์หรือโวลุ่มเครือข่ายที่มีโฟลเดอร์โมเดลเข้าถึงได้ และไฟล์โมเดลครบถ้วน แล้วลองใหม่',
    'Hết thời gian tải mô hình. Hãy kiểm tra ổ đĩa/ổ mạng chứa thư mục mô hình có truy cập được và tệp mô hình đầy đủ, rồi thử lại.',
    'Waktu memuat model habis. Pastikan disk atau volume jaringan berisi folder model dapat diakses dan file model lengkap, lalu coba lagi.',
    'Model yükleme zaman aşımına uğradı. Model klasörünün bulunduğu disk/ağ biriminin erişilebilir ve model dosyalarının eksiksiz olduğundan emin olup yeniden deneyin.',
    'Tijdens het laden van het model is de tijd verstreken. Controleer of de schijf of netwerkvolume met de modelmap bereikbaar is en de bestanden compleet zijn.',
    'Przekroczono czas wczytywania modelu. Upewnij się, że dysk lub wolumen sieciowy z folderem modelu jest dostępny, a pliki modelu są kompletne.',
    'Час завантаження моделі вичерпано. Переконайтеся, що диск або мережевий том із текою моделі доступний, а файли моделі цілі, і повторіть.',
    'Tidsgränsen för modelladdning överskreds. Kontrollera att disken eller nätverksvolymen med modellmappen är åtkomlig och att modellfilerna är kompletta.',
])

add('音频合并超时，导出已被中断。分片文件已保留在录音文件夹，重新刷新后可自动恢复。', [
    '音訊合併逾時，匯出已被中斷。分片檔案已保留在錄音資料夾，重新整理後可自動恢復。',
    'Audio merging timed out and the export was interrupted. The segment files remain in the recording folder and can be recovered automatically after a refresh.',
    '音声の結合がタイムアウトし、書き出しが中断されました。分割ファイルは録音フォルダに残っており、再読み込みで自動復元できます。',
    '오디오 병합 시간 초과로 내보내기가 중단되었습니다. 분할 파일은 녹음 폴더에 남아 있고 새로 고치면 자동 복구됩니다.',
    'La fusion audio a expiré et l’export a été interrompu. Les fragments restent dans le dossier d’enregistrement et peuvent être récupérés après un rafraîchissement.',
    'Das Zusammenführen des Audios hat zu lange gedauert, der Export wurde abgebrochen. Die Segmentdateien bleiben im Aufnahmeordner und werden nach dem Aktualisieren automatisch wiederhergestellt.',
    'La combinación de audio agotó el tiempo y la exportación se interrumpió. Los fragmentos siguen en la carpeta de grabación y se recuperan al refrescar.',
    'Unione audio scaduta, esportazione interrotta. I file suddivisi restano nella cartella di registrazione e si recuperano aggiornando.',
    'A junção de áudio excedeu o tempo e a exportação foi interrompida. Os fragmentos permanecem na pasta de gravação e recuperam-se ao atualizar.',
    'Время объединения аудио истекло, экспорт прерван. Фрагменты остались в папке записи и восстановятся после обновления.',
    'انتهت مهلة دمج الصوت وتوقف التصدير. تبقى الملفات المجزأة في مجلد التسجيل وتُستعاد تلقائيًا بعد التحديث.',
    'ऑडियो मर्ज का समय समाप्त, निर्यात बाधित हुआ। खंड फ़ाइलें रिकॉर्डिंग फ़ोल्डर में सुरक्षित हैं और रीफ़्रेश पर अपने-आप बहाल हो जाएँगी।',
    'รวมเสียงหมดเวลา การส่งออกถูกขัดจังหวะ ไฟล์แบ่งชิ้นยังอยู่ในโฟลเดอร์บันทึก และจะกู้คืนอัตโนมัติเมื่อรีเฟรช',
    'Hợp nhất âm thanh quá thời gian, xuất bị gián đoạn. Các tệp phân đoạn vẫn trong thư mục ghi và tự khôi phục sau khi làm mới.',
    'Penggabungan audio habis waktu dan ekspor terhenti. File segmen tetap di folder perekaman dan pulih otomatis setelah disegarkan.',
    'Ses birleştirme zaman aşımına uğradı, dışa aktarma kesildi. Bölüm dosyaları kayıt klasöründe duruyor ve yenilemede otomatik kurtarılır.',
    'Het samenvoegen van audio duurde te lang en de export is afgebroken. De segmentbestanden blijven in de opnamemap en worden na verversen automatisch hersteld.',
    'Przekroczono czas scalania dźwięku, eksport przerwano. Pliki segmentów pozostały w folderze nagrania i zostaną odzyskane po odświeżeniu.',
    'Час об’єднання аудіо вичерпано, експорт перервано. Фрагменти залишилися в теці запису й відновляться після оновлення.',
    'Sammanfogningen tog för lång tid och exporten avbröts. Segmentsfilerna finns kvar i inspelningsmappen och återställs vid uppdatering.',
])

add('没有可用的画面信息：未能从视频中找到可识别的帧（非视觉模型需要抽到的帧里有文字）', [
    '沒有可用的畫面資訊：未能從影片中找到可識別的影格（非視覺模型需要抽到的影格裡有文字）',
    'No usable visual information: no recognizable frames were found in the video (non-visual models need text visible in the extracted frames).',
    '利用できる画面情報がありません。動画から認識可能なフレームが見つかりませんでした（非視覚モデルは抽出フレーム内の文字が必要です）。',
    '사용할 수 있는 화면 정보가 없습니다. 동영상에서 인식 가능한 프레임을 찾지 못했습니다(비전 모델이 아니면 추출된 프레임에 텍스트가 있어야 합니다).',
    'Aucune information visuelle exploitable : aucune image reconnaissable n’a été trouvée (les modèles non visuels ont besoin de texte dans les images extraites).',
    'Keine verwertbaren Bildinformationen: Im Video wurden keine erkennbaren Frames gefunden (nicht-visuelle Modelle benötigen Text in den extrahierten Frames).',
    'No hay información visual utilizable: no se encontraron fotogramas reconocibles (los modelos no visuales necesitan texto en los fotogramas extraídos).',
    'Nessuna informazione visiva utilizzabile: non sono stati trovati fotogrammi riconoscibili (i modelli non visivi richiedono testo nei fotogrammi estratti).',
    'Sem informação visual utilizável: não foram encontrados fotogramas reconhecíveis (modelos não visuais precisam de texto nos fotogramas extraídos).',
    'Нет пригодной визуальной информации: в видео не найдено распознаваемых кадров (моделям без зрения нужен текст в извлечённых кадрах).',
    'لا توجد معلومات مرئية قابلة للاستخدام: لم يُعثر على إطارات قابلة للتعرّف في الفيديو (النماذج غير المرئية تحتاج إلى نص في الإطارات المستخرجة).',
    'कोई उपयोगी दृश्य जानकारी नहीं: वीडियो में पहचानने योग्य फ़्रेम नहीं मिले (गैर-दृश्य मॉडल को निकाले गए फ़्रेम में टेक्स्ट चाहिए)।',
    'ไม่มีข้อมูลภาพที่ใช้ได้ เพราะไม่พบเฟรมที่รู้จำได้ในวิดีโอ (โมเดลที่ไม่ใช่แบบเห็นภาพต้องมีข้อความในเฟรมที่ดึงมา)',
    'Không có thông tin hình ảnh dùng được: không tìm thấy khung hình nhận dạng được trong video (mô hình không thị giác cần có chữ trong khung đã trích).',
    'Tidak ada informasi visual yang berguna: tidak ditemukan frame yang dapat dikenali di video (model non-visual butuh teks di frame hasil ekstraksi).',
    'Kullanılabilir görsel bilgi yok: videoda tanınabilir kare bulunamadı (görsel olmayan modeller çıkarılan karelerde metin arar).',
    'Geen bruikbare beeldinformatie: er zijn geen herkenbare frames in de video gevonden (niet-visuele modellen hebben tekst in de frames nodig).',
    'Brak użytecznych informacji obrazowych: nie znaleziono rozpoznawalnych klatek (modele nieobrazowe potrzebują tekstu w wyodrębnionych klatkach).',
    'Немає придатної візуальної інформації: у відео не знайдено розпізнаваних кадрів (моделям без зору потрібен текст у видобутих кадрах).',
    'Ingen användbar bildinformation: inga igenkännbara bildrutor hittades (icke-visuella modeller behöver text i de extraherade bildrutorna).',
])

add('导入音频或视频（m4a / mp3 / wav / mp4 / mov / m4v）', [
    '匯入音訊或影片（m4a / mp3 / wav / mp4 / mov / m4v）',
    'Import audio or video (m4a / mp3 / wav / mp4 / mov / m4v)',
    '音声または動画を読み込む（m4a / mp3 / wav / mp4 / mov / m4v）',
    '오디오 또는 동영상 가져오기(m4a / mp3 / wav / mp4 / mov / m4v)',
    'Importer de l’audio ou de la vidéo (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Audio oder Video importieren (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Importar audio o vídeo (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Importa audio o video (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Importar áudio ou vídeo (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Импорт аудио или видео (m4a / mp3 / wav / mp4 / mov / m4v)',
    'استيراد الصوت أو الفيديو (m4a / mp3 / wav / mp4 / mov / m4v)',
    'ऑडियो या वीडियो आयात करें (m4a / mp3 / wav / mp4 / mov / m4v)',
    'นำเข้าเสียงหรือวิดีโอ (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Nhập âm thanh hoặc video (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Impor audio atau video (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Ses veya video içe aktar (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Audio of video importeren (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Importuj audio lub wideo (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Імпорт аудіо або відео (m4a / mp3 / wav / mp4 / mov / m4v)',
    'Importera ljud eller video (m4a / mp3 / wav / mp4 / mov / m4v)',
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
    print(f'第 4 批完成：{len(T)} 条 key，新增 {filled} 条译文（缺失 key {missing_key} 条）')


if __name__ == '__main__':
    main()
