#!/usr/bin/env python3
# 停录收尾阶段提示 + 事实性文案修正 + 错误码文案：20 种目标语言
# 与 add_echo_reduction_l10n.py 同一策略（键不存在则新增，存在则补全 21 种语言条目）。
#
# 本脚本同时删除被替换的旧键（源文案即键，改文案必须换键）：
#   - 正在合并录音分片，请稍候…（被四阶段提示取代）
#   - 两段“一键处理会重新转写”的引导文案
#   - 隐私页“在数据管理导出备份或恢复数据”的用户权利文案
#   - 隐私页“开源软件、源代码公开”的声明（改为「本地处理说明」）
#   - 关于页“文件夹备份同步”卖点
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}

REMOVE = [
    '正在合并录音分片，请稍候…',
    '在录音、录屏或笔记上点「一键处理」，自动按「转写 → 画面分析（录屏）→ 总结 → 拆解待办」依次完成（录音/录屏即使已转写也会重新转写）；录音与录屏默认会议总结，文字与图片按概要总结。所有处理任务（含模型下载）都在右上角「处理队列」中排队，最多 3 个并行；下载模型可暂停/继续，其余任务可取消。',
    '在录音或笔记上点「一键处理」：录音会先转写（已转写也会重跑），再自动生成总结并拆解待办。任务会在右上角「处理队列」里排队执行，可随时查看进度或取消。',
    '您可以随时：\n• 删除任意录音及其转写、总结与待办\n• 在系统设置中撤销麦克风、屏幕录制与语音识别访问权限\n• 在「数据管理」中导出备份或恢复数据\n• 手动删除数据文件夹以彻底清除本机数据',
    'Memozia 是开源软件，源代码公开可审计。你可以在源码中验证所有数据流向和处理逻辑。',
    '开源声明',
    '数据加密存储 + 文件夹备份同步',
]


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


# MARK: - 停录收尾四阶段 + 取消

add('正在检查录音分片…', [
    '正在檢查錄音片段…',
    'Checking recording segments…',
    '録音セグメントを確認中…',
    '녹음 세그먼트 확인 중…',
    "Vérification des segments d'enregistrement…",
    'Aufnahmesegmente werden geprüft…',
    'Comprobando los segmentos de grabación…',
    'Verifica dei segmenti di registrazione…',
    'A verificar os segmentos de gravação…',
    'Проверка сегментов записи…',
    'جارٍ فحص مقاطع التسجيل…',
    'रिकॉर्डिंग खंडों की जाँच हो रही है…',
    'กำลังตรวจสอบส่วนของการบันทึก…',
    'Đang kiểm tra các phân đoạn ghi âm…',
    'Memeriksa segmen rekaman…',
    'Kayıt parçaları denetleniyor…',
    'Opnamesegmenten worden gecontroleerd…',
    'Sprawdzanie segmentów nagrania…',
    'Перевірка сегментів запису…',
    'Kontrollerar inspelningssegment…',
])

add('正在消除回声…', [
    '正在消除回音…',
    'Removing echo…',
    'エコーを除去中…',
    '에코 제거 중…',
    "Suppression de l'écho…",
    'Echo wird entfernt…',
    'Eliminando el eco…',
    "Rimozione dell'eco…",
    'A remover o eco…',
    'Удаление эха…',
    'جارٍ إزالة الصدى…',
    'प्रतिध्वनि हटाई जा रही है…',
    'กำลังตัดเสียงสะท้อน…',
    'Đang khử tiếng vọng…',
    'Menghapus gema…',
    'Yankı kaldırılıyor…',
    'Echo wordt verwijderd…',
    'Usuwanie echa…',
    'Видалення відлуння…',
    'Tar bort eko…',
])

add('正在混音导出…', [
    '正在混音匯出…',
    'Mixing and exporting…',
    'ミックスして書き出し中…',
    '믹싱 및 내보내기 중…',
    'Mixage et export…',
    'Mischen und Exportieren…',
    'Mezclando y exportando…',
    'Missaggio ed esportazione…',
    'A misturar e exportar…',
    'Сведение и экспорт…',
    'جارٍ الدمج والتصدير…',
    'मिक्सिंग और निर्यात हो रहा है…',
    'กำลังมิกซ์และส่งออก…',
    'Đang trộn và xuất…',
    'Mencampur dan mengekspor…',
    'Miksleniyor ve dışa aktarılıyor…',
    'Mixen en exporteren…',
    'Miksowanie i eksportowanie…',
    'Зведення та експорт…',
    'Mixar och exporterar…',
])

add('正在保存录音…', [
    '正在儲存錄音…',
    'Saving recording…',
    '録音を保存中…',
    '녹음 저장 중…',
    "Enregistrement de l'audio…",
    'Aufnahme wird gespeichert…',
    'Guardando la grabación…',
    'Salvataggio della registrazione…',
    'A guardar a gravação…',
    'Сохранение записи…',
    'جارٍ حفظ التسجيل…',
    'रिकॉर्डिंग सहेजी जा रही है…',
    'กำลังบันทึกการอัดเสียง…',
    'Đang lưu bản ghi…',
    'Menyimpan rekaman…',
    'Kayıt kaydediliyor…',
    'Opname wordt opgeslagen…',
    'Zapisywanie nagrania…',
    'Збереження запису…',
    'Sparar inspelning…',
])

add('取消回声消除', [
    '取消回音消除',
    'Cancel echo cancellation',
    'エコー除去をキャンセル',
    '에코 제거 취소',
    "Annuler la suppression d'écho",
    'Echounterdrückung abbrechen',
    'Cancelar la cancelación de eco',
    "Annulla rimozione dell'eco",
    'Cancelar o cancelamento de eco',
    'Отменить подавление эха',
    'إلغاء إلغاء الصدى',
    'प्रतिध्वनि निवारण रद्द करें',
    'ยกเลิกการตัดเสียงสะท้อน',
    'Hủy khử tiếng vọng',
    'Batalkan pembatalan gema',
    'Yankı gidermeyi iptal et',
    'Echo-onderdrukking annuleren',
    'Anuluj eliminację echa',
    'Скасувати придушення відлуння',
    'Avbryt ekoutsläckning',
])

# MARK: - 错误码文案（UserFacingError）

add('网络连接不可用或无法连接服务器，请检查网络后重试。', [
    '網路連線無法使用或無法連線伺服器，請檢查網路後重試。',
    "The network is unavailable or the server can't be reached. Check your connection and try again.",
    'ネットワークに接続できないか、サーバーに接続できません。ネットワークを確認して再試行してください。',
    '네트워크를 사용할 수 없거나 서버에 연결할 수 없습니다. 네트워크를 확인한 후 다시 시도하세요.',
    'Le réseau est indisponible ou le serveur est injoignable. Vérifiez votre connexion et réessayez.',
    'Das Netzwerk ist nicht verfügbar oder der Server ist nicht erreichbar. Prüfen Sie die Verbindung und versuchen Sie es erneut.',
    'La red no está disponible o no se puede alcanzar el servidor. Comprueba la conexión e inténtalo de nuevo.',
    'La rete non è disponibile o il server non è raggiungibile. Controlla la connessione e riprova.',
    'A rede não está disponível ou o servidor não pode ser alcançado. Verifique a ligação e tente novamente.',
    'Сеть недоступна или сервер недостижим. Проверьте подключение и повторите попытку.',
    'الشبكة غير متاحة أو يتعذّر الوصول إلى الخادم. تحقق من الاتصال وأعد المحاولة.',
    'नेटवर्क उपलब्ध नहीं है या सर्वर तक नहीं पहुँचा जा सकता। कनेक्शन जाँचें और पुनः प्रयास करें।',
    'เครือข่ายใช้งานไม่ได้หรือเชื่อมต่อเซิร์ฟเวอร์ไม่ได้ โปรดตรวจสอบเครือข่ายแล้วลองใหม่',
    'Mạng không khả dụng hoặc không thể kết nối máy chủ. Hãy kiểm tra kết nối và thử lại.',
    'Jaringan tidak tersedia atau server tidak dapat dijangkau. Periksa koneksi dan coba lagi.',
    'Ağ kullanılamıyor veya sunucuya ulaşılamıyor. Bağlantıyı kontrol edip yeniden deneyin.',
    'Het netwerk is niet beschikbaar of de server is onbereikbaar. Controleer de verbinding en probeer het opnieuw.',
    'Sieć jest niedostępna lub nie można połączyć się z serwerem. Sprawdź połączenie i spróbuj ponownie.',
    'Мережа недоступна або сервер недосяжний. Перевірте з’єднання та повторіть спробу.',
    'Nätverket är otillgängligt eller servern kan inte nås. Kontrollera anslutningen och försök igen.',
])

add('服务鉴权失败，请在设置中检查 API Key 后重试。', [
    '服務驗證失敗，請在設定中檢查 API Key 後重試。',
    'Authentication failed. Check your API key in Settings and try again.',
    '認証に失敗しました。設定で API キーを確認して再試行してください。',
    '인증에 실패했습니다. 설정에서 API 키를 확인한 후 다시 시도하세요.',
    "Échec de l'authentification. Vérifiez votre clé API dans les réglages et réessayez.",
    'Authentifizierung fehlgeschlagen. Prüfen Sie den API-Schlüssel in den Einstellungen und versuchen Sie es erneut.',
    'La autenticación falló. Comprueba la clave de API en los ajustes e inténtalo de nuevo.',
    'Autenticazione non riuscita. Controlla la chiave API nelle impostazioni e riprova.',
    'A autenticação falhou. Verifique a chave de API nas definições e tente novamente.',
    'Ошибка аутентификации. Проверьте API-ключ в настройках и повторите попытку.',
    'فشلت المصادقة. تحقق من مفتاح API في الإعدادات وأعد المحاولة.',
    'प्रमाणीकरण विफल रहा। सेटिंग्स में API कुंजी जाँचें और पुनः प्रयास करें।',
    'การยืนยันตัวตนล้มเหลว โปรดตรวจสอบ API Key ในการตั้งค่าแล้วลองใหม่',
    'Xác thực thất bại. Hãy kiểm tra API Key trong Cài đặt và thử lại.',
    'Autentikasi gagal. Periksa kunci API di Pengaturan lalu coba lagi.',
    "Kimlik doğrulama başarısız. Ayarlar'daki API anahtarını kontrol edip yeniden deneyin.",
    'Verificatie mislukt. Controleer de API-sleutel in Instellingen en probeer het opnieuw.',
    'Uwierzytelnianie nie powiodło się. Sprawdź klucz API w Ustawieniach i spróbuj ponownie.',
    'Помилка автентифікації. Перевірте API-ключ у налаштуваннях і повторіть спробу.',
    'Autentiseringen misslyckades. Kontrollera API-nyckeln i Inställningar och försök igen.',
])

add('目标磁盘为只读，请更换存储位置。', [
    '目標磁碟為唯讀，請更換儲存位置。',
    'The destination disk is read-only. Choose a different storage location.',
    '保存先のディスクが読み取り専用です。別の保存先を選んでください。',
    '대상 디스크가 읽기 전용입니다. 다른 저장 위치를 선택하세요.',
    'Le disque de destination est en lecture seule. Choisissez un autre emplacement.',
    'Der Ziel-Datenträger ist schreibgeschützt. Wählen Sie einen anderen Speicherort.',
    'El disco de destino es de solo lectura. Elige otra ubicación de almacenamiento.',
    'Il disco di destinazione è di sola lettura. Scegli un\'altra posizione.',
    'O disco de destino é só de leitura. Escolha outro local de armazenamento.',
    'Целевой диск доступен только для чтения. Выберите другое место хранения.',
    'القرص الهدف للقراءة فقط. اختر موقع تخزين آخر.',
    'लक्ष्य डिस्क केवल-पढ़ने योग्य है। कोई अन्य संग्रहण स्थान चुनें।',
    'ดิสก์ปลายทางเป็นแบบอ่านอย่างเดียว โปรดเลือกตำแหน่งจัดเก็บอื่น',
    'Đĩa đích chỉ đọc. Hãy chọn vị trí lưu trữ khác.',
    'Disk tujuan hanya-baca. Pilih lokasi penyimpanan lain.',
    'Hedef disk salt okunur. Başka bir depolama konumu seçin.',
    'De doelschijf is alleen-lezen. Kies een andere opslaglocatie.',
    'Dysk docelowy jest tylko do odczytu. Wybierz inną lokalizację.',
    'Цільовий диск лише для читання. Виберіть інше місце збереження.',
    'Måldisken är skrivskyddad. Välj en annan lagringsplats.',
])

# MARK: - 引导：一键处理默认跳过已完成步骤

add('在录音、录屏或笔记上点「一键处理」，自动按「转写 → 画面分析（录屏）→ 总结 → 拆解待办」依次完成（已完成的步骤默认跳过；如需覆盖已有转写，可在预览中显式开启「重新转写」）；录音与录屏默认会议总结，文字与图片按概要总结。所有处理任务（含模型下载）都在右上角「处理队列」中排队，最多 3 个并行；下载模型可暂停/继续，其余任务可取消。', [
    '在錄音、錄屏或筆記上點「一鍵處理」，自動依「轉寫 → 畫面分析（錄屏）→ 總結 → 拆解待辦」依次完成（已完成的步驟預設跳過；如需覆蓋既有轉寫，可在預覽中明確開啟「重新轉寫」）；錄音與錄屏預設會議總結，文字與圖片按概要總結。所有處理任務（含模型下載）都在右上角「處理佇列」中排隊，最多 3 個並行；下載模型可暫停/繼續，其餘任務可取消。',
    'Tap “One-Click Process” on a recording, screen recording, or note; Memozia runs “Transcription → Visual analysis (screen recording) → Summary → Todo extraction” in order (completed steps are skipped by default; to overwrite an existing transcript, explicitly enable “Re-transcribe” in the preview). Recordings and screen recordings default to a meeting summary, while text and images use an outline summary. All tasks (including model downloads) queue in “Processing Queue” at the top right, up to 3 in parallel; model downloads can be paused/resumed, other tasks can be cancelled.',
    '録音・画面収録・ノートで「ワンクリック処理」を押すと、「文字起こし → 画面分析（画面収録）→ 要約 → ToDo 抽出」を順に実行します（完了済みの手順は既定でスキップ。既存の文字起こしを上書きするには、プレビューで「再文字起こし」を明示的に有効にします）。録音と画面収録は既定で会議要約、テキストと画像は概要要約です。すべての処理タスク（モデルのダウンロードを含む）は右上の「処理キュー」で最大 3 件まで並列実行され、モデルのダウンロードは一時停止/再開、その他のタスクはキャンセルできます。',
    '녹음, 화면 녹화 또는 노트에서 ‘원클릭 처리’를 누르면 ‘전사 → 화면 분석(화면 녹화) → 요약 → 할 일 추출’을 순서대로 실행합니다(완료된 단계는 기본적으로 건너뜀. 기존 전사를 덮어쓰려면 미리보기에서 ‘다시 전사’를 명시적으로 켜세요). 녹음과 화면 녹화는 기본적으로 회의 요약, 텍스트와 이미지는 개요 요약입니다. 모든 처리 작업(모델 다운로드 포함)은 오른쪽 위 ‘처리 대기열’에서 최대 3개까지 병렬로 실행되며, 모델 다운로드는 일시정지/재개, 나머지 작업은 취소할 수 있습니다.',
    "Appuyez sur « Traitement en un clic » sur un enregistrement, une capture vidéo ou une note : Memozia enchaîne « Transcription → Analyse visuelle (capture vidéo) → Résumé → Extraction des tâches » (les étapes terminées sont ignorées par défaut ; pour écraser une transcription existante, activez explicitement « Retranscrire » dans l'aperçu). Les enregistrements et captures vidéo utilisent par défaut un résumé de réunion, les textes et images un résumé synthétique. Toutes les tâches (y compris le téléchargement des modèles) sont mises en file dans « File de traitement » en haut à droite, jusqu'à 3 en parallèle ; les téléchargements peuvent être mis en pause/repris, les autres tâches annulées.",
    'Tippen Sie bei einer Aufnahme, Bildschirmaufnahme oder Notiz auf „Ein-Klick-Verarbeitung“: Memozia führt nacheinander „Transkription → Bildanalyse (Bildschirmaufnahme) → Zusammenfassung → To-do-Extraktion“ aus (abgeschlossene Schritte werden standardmäßig übersprungen; um ein vorhandenes Transkript zu überschreiben, aktivieren Sie im Vorschaufenster ausdrücklich „Neu transkribieren“). Aufnahmen und Bildschirmaufnahmen erhalten standardmäßig eine Besprechungszusammenfassung, Text und Bilder eine Kurzzusammenfassung. Alle Aufgaben (inkl. Modell-Downloads) werden oben rechts in der „Warteschlange“ eingereiht, bis zu 3 parallel; Downloads lassen sich pausieren/fortsetzen, andere Aufgaben abbrechen.',
    'Toca «Procesar con un clic» en una grabación, grabación de pantalla o nota: Memozia ejecuta «Transcripción → Análisis visual (grabación de pantalla) → Resumen → Extracción de tareas» en orden (los pasos completados se omiten de forma predeterminada; para sobrescribir una transcripción existente, activa explícitamente «Retranscribir» en la vista previa). Las grabaciones y grabaciones de pantalla usan por defecto un resumen de reunión; el texto y las imágenes, un resumen esquemático. Todas las tareas (incluidas las descargas de modelos) se encolan en «Cola de procesamiento» arriba a la derecha, hasta 3 en paralelo; las descargas pueden pausarse/reanudarse y las demás tareas cancelarse.',
    'Tocca «Elaborazione con un clic» su una registrazione, una cattura schermo o una nota: Memozia esegue in ordine «Trascrizione → Analisi visiva (cattura schermo) → Riassunto → Estrazione attività» (i passaggi completati vengono saltati per impostazione predefinita; per sovrascrivere una trascrizione esistente, attiva esplicitamente «Ritrascrivi» nell\'anteprima). Le registrazioni e le catture schermo usano per impostazione predefinita un riassunto di riunione; testo e immagini un riassunto schematico. Tutte le attività (incl. download dei modelli) sono in coda in «Coda di elaborazione» in alto a destra, fino a 3 in parallelo; i download possono essere sospesi/ripresi, le altre attività annullate.',
    'Toque em «Processamento com um clique» numa gravação, gravação de ecrã ou nota: o Memozia executa «Transcrição → Análise visual (gravação de ecrã) → Resumo → Extração de tarefas» por ordem (os passos concluídos são ignorados por predefinição; para substituir uma transcrição existente, ative explicitamente «Retranscrever» na pré-visualização). Gravações e gravações de ecrã usam por predefinição um resumo de reunião; texto e imagens, um resumo esquemático. Todas as tarefas (incl. transferências de modelos) entram na «Fila de processamento» no canto superior direito, até 3 em paralelo; as transferências podem ser pausadas/retomadas e as restantes tarefas canceladas.',
    'Нажмите «Обработка в один клик» для записи, записи экрана или заметки: Memozia по очереди выполнит «Транскрипция → Визуальный анализ (запись экрана) → Сводка → Извлечение задач» (завершённые шаги по умолчанию пропускаются; чтобы перезаписать существующую транскрипцию, явно включите «Повторная транскрипция» в окне предпросмотра). Для записей и записей экрана по умолчанию используется сводка встречи, для текста и изображений — краткая сводка. Все задачи (включая загрузку моделей) встают в «Очередь обработки» справа вверху, до 3 параллельно; загрузку можно приостановить/продолжить, остальные задачи — отменить.',
    'اضغط «معالجة بنقرة واحدة» على تسجيل أو تسجيل شاشة أو ملاحظة، وسينفّذ Memozia بالترتيب «النسخ → تحليل المشاهد (تسجيل الشاشة) → الملخص → استخراج المهام» (تُتخطّى الخطوات المكتملة افتراضيًا؛ وللاستبدال نسخة نصية موجودة، فعِّل «إعادة النسخ» صراحةً في المعاينة). تُنتج التسجيلات وتسجيلات الشاشة ملخص اجتماع افتراضيًا، ويُنتج النص والصور ملخصًا موجزًا. تُصفّ كل المهام (بما فيها تنزيل النماذج) في «قائمة المعالجة» أعلى اليمين، بحد أقصى ٣ بالتوازي؛ ويمكن إيقاف تنزيل النموذج مؤقتًا/استئنافه، وإلغاء بقية المهام.',
    'किसी रिकॉर्डिंग, स्क्रीन रिकॉर्डिंग या नोट पर «वन-क्लिक प्रोसेस» दबाएँ; Memozia क्रम से «प्रतिलेखन → दृश्य विश्लेषण (स्क्रीन रिकॉर्डिंग) → सारांश → कार्य निष्कर्षण» चलाता है (पूर्ण हुए चरण डिफ़ॉल्ट रूप से छोड़े जाते हैं; मौजूदा प्रतिलेखन को बदलने के लिए पूर्वावलोकन में «पुनः प्रतिलेखन» स्पष्ट रूप से चालू करें)। रिकॉर्डिंग और स्क्रीन रिकॉर्डिंग के लिए डिफ़ॉल्ट मीटिंग सारांश, टेक्स्ट और छवियों के लिए संक्षिप्त सारांश होता है। सभी कार्य (मॉडल डाउनलोड सहित) ऊपर दाईं ओर «प्रोसेसिंग कतार» में कतारबद्ध होते हैं, अधिकतम 3 समानांतर; डाउनलोड रोके/जारी रखे जा सकते हैं, अन्य कार्य रद्द किए जा सकते हैं।',
    'แตะ «ประมวลผลในคลิกเดียว» บนไฟล์บันทึก การบันทึกหน้าจอ หรือโน้ต Memozia จะทำตามลำดับ «ถอดเสียง → วิเคราะห์ภาพ (การบันทึกหน้าจอ) → สรุป → แยกงาน» (ขั้นตอนที่ทำเสร็จแล้วจะถูกข้ามโดยค่าเริ่มต้น หากต้องการเขียนทับข้อความถอดเสียงเดิม ให้เปิด «ถอดเสียงใหม่» อย่างชัดเจนในหน้าตัวอย่าง) การบันทึกเสียงและหน้าจอจะสรุปแบบประชุมโดยค่าเริ่มต้น ส่วนข้อความและรูปภาพจะสรุปแบบย่อ งานทั้งหมด (รวมการดาวน์โหลดโมเดล) จะเข้าคิวที่ «คิวประมวลผล» มุมขวาบน สูงสุด 3 งานพร้อมกัน ดาวน์โหลดหยุด/ทำต่อได้ งานอื่นยกเลิกได้',
    'Nhấn «Xử lý một chạm» trên bản ghi âm, bản ghi màn hình hoặc ghi chú; Memozia lần lượt chạy «Phiên âm → Phân tích hình ảnh (ghi màn hình) → Tóm tắt → Trích xuất việc cần làm» (các bước đã hoàn thành mặc định được bỏ qua; để ghi đè bản phiên âm hiện có, hãy bật rõ ràng «Phiên âm lại» trong bản xem trước). Bản ghi âm và ghi màn hình mặc định tóm tắt cuộc họp, văn bản và hình ảnh tóm tắt sơ lược. Mọi tác vụ (kể cả tải mô hình) được xếp vào «Hàng đợi xử lý» ở góc trên bên phải, tối đa 3 tác vụ song song; tải mô hình có thể tạm dừng/tiếp tục, các tác vụ khác có thể hủy.',
    'Ketuk «Proses Sekali Klik» pada rekaman, rekaman layar, atau catatan; Memozia menjalankan «Transkripsi → Analisis visual (rekaman layar) → Ringkasan → Ekstraksi tugas» secara berurutan (langkah yang selesai dilewati secara default; untuk menimpa transkripsi yang ada, aktifkan «Transkripsi ulang» secara eksplisit di pratinjau). Rekaman dan rekaman layar memakai ringkasan rapat secara default, teks dan gambar memakai ringkasan ringkas. Semua tugas (termasuk unduhan model) mengantre di «Antrean Pemrosesan» di kanan atas, maksimal 3 paralel; unduhan dapat dijeda/dilanjutkan, tugas lain dapat dibatalkan.',
    'Bir kayıt, ekran kaydı veya notta «Tek Tıkla İşle»\'ye dokunun; Memozia sırayla «Yazıya dökme → Görsel analiz (ekran kaydı) → Özet → Görev çıkarma» çalıştırır (tamamlanan adımlar varsayılan olarak atlanır; var olan bir yazıyı değiştirmek için önizlemede «Yeniden yazıya dök» seçeneğini açıkça etkinleştirin). Kayıtlar ve ekran kayıtları varsayılan olarak toplantı özeti, metin ve görseller özet taslak kullanır. Tüm görevler (model indirmeleri dahil) sağ üstteki «İşleme Kuyruğu»\'nda sıraya girer, en fazla 3 paralel; indirmeler duraklatılabilir/sürdürülebilir, diğer görevler iptal edilebilir.',
    'Tik op ‘Verwerking met één klik’ bij een opname, schermopname of notitie: Memozia voert ‘Transcriptie → Beeldanalyse (schermopname) → Samenvatting → Taken extraheren’ op volgorde uit (voltooide stappen worden standaard overgeslagen; om een bestaande transcriptie te overschrijven, schakel je in de voorvertoning expliciet ‘Opnieuw transcriberen’ in). Opnamen en schermopnamen krijgen standaard een vergadersamenvatting, tekst en afbeeldingen een beknopte samenvatting. Alle taken (incl. modeldownloads) komen in de ‘Verwerkingswachtrij’ rechtsboven, maximaal 3 parallel; downloads kunnen worden gepauzeerd/hervat, andere taken geannuleerd.',
    'Dotknij «Przetwarzanie jednym kliknięciem» na nagraniu, nagraniu ekranu lub notatce: Memozia wykonuje kolejno «Transkrypcja → Analiza obrazu (nagranie ekranu) → Podsumowanie → Wyodrębnianie zadań» (ukończone kroki są domyślnie pomijane; aby nadpisać istniejącą transkrypcję, włącz jawnie «Transkrybuj ponownie» w podglądzie). Nagrania i nagrania ekranu domyślnie otrzymują podsumowanie spotkania, a tekst i obrazy — podsumowanie zarysowe. Wszystkie zadania (w tym pobieranie modeli) trafiają do «Kolejki przetwarzania» w prawym górnym rogu, maks. 3 równolegle; pobieranie można wstrzymać/wznowić, a pozostałe zadania anulować.',
    'Натисніть «Обробка одним кліком» для запису, запису екрана чи нотатки: Memozia послідовно виконає «Транскрипція → Візуальний аналіз (запис екрана) → Підсумок → Вилучення завдань» (завершені кроки типово пропускаються; щоб перезаписати наявну транскрипцію, явно увімкніть «Повторна транскрипція» у вікні попереднього перегляду). Для записів і записів екрана типово використовується підсумок зустрічі, для тексту й зображень — стислий підсумок. Усі завдання (включно із завантаженням моделей) стають у «Чергу обробки» праворуч угорі, до 3 паралельно; завантаження можна призупинити/продовжити, решту завдань — скасувати.',
    'Tryck på ”Bearbeta med ett klick” på en inspelning, skärminspelning eller anteckning: Memozia kör i tur och ordning ”Transkribering → Bildanalys (skärminspelning) → Sammanfattning → Extrahera uppgifter” (slutförda steg hoppas över som standard; för att skriva över en befintlig transkribering aktiverar du uttryckligen ”Transkribera igen” i förhandsvisningen). Inspelningar och skärminspelningar får som standard en mötessammanfattning, text och bilder en översiktlig sammanfattning. Alla uppgifter (inkl. modellnedladdningar) köas i ”Bearbetningskö” uppe till höger, upp till 3 parallellt; nedladdningar kan pausas/återupptas, övriga uppgifter avbrytas.',
])

add('在录音或笔记上点「一键处理」：默认依次完成尚未处理的步骤（已完成的会跳过；需要时可在预览中显式开启「重新转写」），再生成总结并拆解待办。任务会在右上角「处理队列」里排队执行，可随时查看进度或取消。', [
    '在錄音或筆記上點「一鍵處理」：預設依序完成尚未處理的步驟（已完成的會跳過；需要時可在預覽中明確開啟「重新轉寫」），再產生總結並拆解待辦。任務會在右上角「處理佇列」裡排隊執行，可隨時查看進度或取消。',
    'Tap “One-Click Process” on a recording or note: it completes the steps that aren’t done yet (completed ones are skipped; when needed, explicitly enable “Re-transcribe” in the preview), then generates a summary and extracts todos. Tasks queue in “Processing Queue” at the top right, where you can check progress or cancel anytime.',
    '録音またはノートで「ワンクリック処理」を押すと、未処理の手順を順に実行し（完了済みはスキップ。必要ならプレビューで「再文字起こし」を明示的に有効化）、要約を作成して ToDo を抽出します。タスクは右上の「処理キュー」で実行され、いつでも進捗確認やキャンセルができます。',
    '녹음이나 노트에서 ‘원클릭 처리’를 누르면 아직 처리되지 않은 단계를 순서대로 완료하고(완료된 단계는 건너뜀. 필요하면 미리보기에서 ‘다시 전사’를 명시적으로 켜세요) 요약을 생성하고 할 일을 추출합니다. 작업은 오른쪽 위 ‘처리 대기열’에서 실행되며 언제든 진행 상황을 확인하거나 취소할 수 있습니다.',
    "Appuyez sur « Traitement en un clic » sur un enregistrement ou une note : les étapes non encore traitées sont réalisées dans l'ordre (celles déjà terminées sont ignorées ; au besoin, activez explicitement « Retranscrire » dans l'aperçu), puis un résumé est généré et les tâches extraites. Les tâches sont exécutées dans la « File de traitement » en haut à droite, où vous pouvez suivre la progression ou annuler à tout moment.",
    'Tippen Sie bei einer Aufnahme oder Notiz auf „Ein-Klick-Verarbeitung“: Noch offene Schritte werden der Reihe nach ausgeführt (abgeschlossene werden übersprungen; aktivieren Sie bei Bedarf im Vorschaufenster ausdrücklich „Neu transkribieren“), danach werden eine Zusammenfassung erstellt und To-dos extrahiert. Aufgaben laufen oben rechts in der „Warteschlange“, wo Sie jederzeit den Fortschritt sehen oder abbrechen können.',
    'Toca «Procesar con un clic» en una grabación o nota: se completan en orden los pasos pendientes (los ya completados se omiten; si hace falta, activa explícitamente «Retranscribir» en la vista previa), luego se genera un resumen y se extraen las tareas. Las tareas se ejecutan en «Cola de procesamiento» arriba a la derecha, donde puedes ver el progreso o cancelar en cualquier momento.',
    'Tocca «Elaborazione con un clic» su una registrazione o una nota: i passaggi non ancora completati vengono eseguiti in ordine (quelli già fatti vengono saltati; se serve, attiva esplicitamente «Ritrascrivi» nell\'anteprima), poi vengono generati un riassunto e le attività. Le attività sono eseguite in «Coda di elaborazione» in alto a destra, dove puoi vedere l\'avanzamento o annullare in qualsiasi momento.',
    'Toque em «Processamento com um clique» numa gravação ou nota: os passos ainda pendentes são concluídos por ordem (os já concluídos são ignorados; se necessário, ative explicitamente «Retranscrever» na pré-visualização), depois é gerado um resumo e extraídas as tarefas. As tarefas são executadas na «Fila de processamento» no canto superior direito, onde pode ver o progresso ou cancelar a qualquer momento.',
    'Нажмите «Обработка в один клик» для записи или заметки: по очереди выполняются ещё не завершённые шаги (завершённые пропускаются; при необходимости явно включите «Повторная транскрипция» в окне предпросмотра), затем создаётся сводка и извлекаются задачи. Задачи выполняются в «Очереди обработки» справа вверху, где можно в любой момент посмотреть ход или отменить.',
    'اضغط «معالجة بنقرة واحدة» على تسجيل أو ملاحظة: تُنفَّذ الخطوات غير المكتملة بالترتيب (وتُتخطّى المكتملة؛ وعند الحاجة فعِّل «إعادة النسخ» صراحةً في المعاينة)، ثم يُنشأ ملخص وتُستخرج المهام. تُنفَّذ المهام في «قائمة المعالجة» أعلى اليمين، حيث يمكنك متابعة التقدم أو الإلغاء في أي وقت.',
    'किसी रिकॉर्डिंग या नोट पर «वन-क्लिक प्रोसेस» दबाएँ: बाकी बचे चरण क्रम से पूरे होते हैं (पूर्ण हुए छोड़े जाते हैं; ज़रूरत पड़ने पर पूर्वावलोकन में «पुनः प्रतिलेखन» स्पष्ट रूप से चालू करें), फिर सारांश बनता है और कार्य निकाले जाते हैं। कार्य ऊपर दाईं ओर «प्रोसेसिंग कतार» में चलते हैं, जहाँ कभी भी प्रगति देख या रद्द कर सकते हैं।',
    'แตะ «ประมวลผลในคลิกเดียว» บนไฟล์บันทึกหรือโน้ต จะทำขั้นตอนที่ยังไม่ได้ทำตามลำดับ (ขั้นตอนที่เสร็จแล้วจะถูกข้าม หากจำเป็นให้เปิด «ถอดเสียงใหม่» อย่างชัดเจนในหน้าตัวอย่าง) จากนั้นสร้างสรุปและแยกงาน งานจะรันใน «คิวประมวลผล» มุมขวาบน ดูความคืบหน้าหรือยกเลิกได้ทุกเมื่อ',
    'Nhấn «Xử lý một chạm» trên bản ghi âm hoặc ghi chú: các bước chưa xử lý sẽ lần lượt hoàn tất (bước đã xong được bỏ qua; khi cần, hãy bật rõ ràng «Phiên âm lại» trong bản xem trước), sau đó tạo tóm tắt và trích xuất việc cần làm. Tác vụ chạy trong «Hàng đợi xử lý» ở góc trên bên phải, có thể xem tiến độ hoặc hủy bất cứ lúc nào.',
    'Ketuk «Proses Sekali Klik» pada rekaman atau catatan: langkah yang belum diproses dijalankan berurutan (yang sudah selesai dilewati; bila perlu, aktifkan «Transkripsi ulang» secara eksplisit di pratinjau), lalu ringkasan dibuat dan tugas diekstraksi. Tugas berjalan di «Antrean Pemrosesan» di kanan atas, Anda bisa melihat kemajuan atau membatalkan kapan saja.',
    'Bir kayıt veya notta «Tek Tıkla İşle»\'ye dokunun: henüz yapılmamış adımlar sırayla tamamlanır (tamamlananlar atlanır; gerekirse önizlemede «Yeniden yazıya dök» seçeneğini açıkça etkinleştirin), ardından özet oluşturulur ve görevler çıkarılır. Görevler sağ üstteki «İşleme Kuyruğu»\'nda çalışır; ilerlemeyi istediğiniz zaman görebilir veya iptal edebilirsiniz.',
    'Tik op ‘Verwerking met één klik’ bij een opname of notitie: nog niet verwerkte stappen worden op volgorde uitgevoerd (voltooide worden overgeslagen; schakel indien nodig in de voorvertoning expliciet ‘Opnieuw transcriberen’ in), daarna wordt een samenvatting gemaakt en worden taken geëxtraheerd. Taken lopen in de ‘Verwerkingswachtrij’ rechtsboven, waar je altijd de voortgang kunt bekijken of kunt annuleren.',
    'Dotknij «Przetwarzanie jednym kliknięciem» na nagraniu lub notatce: nieukończone kroki są wykonywane po kolei (ukończone są pomijane; w razie potrzeby włącz jawnie «Transkrybuj ponownie» w podglądzie), następnie tworzone jest podsumowanie i wyodrębniane zadania. Zadania działają w «Kolejce przetwarzania» w prawym górnym rogu, gdzie w każdej chwili można sprawdzić postęp lub anulować.',
    'Натисніть «Обробка одним кліком» для запису чи нотатки: невиконані кроки виконуються по черзі (завершені пропускаються; за потреби явно увімкніть «Повторна транскрипція» у вікні попереднього перегляду), далі створюється підсумок і вилучаються завдання. Завдання виконуються в «Черзі обробки» праворуч угорі, де можна будь-коли переглянути поступ чи скасувати.',
    'Tryck på ”Bearbeta med ett klick” på en inspelning eller anteckning: återstående steg utförs i tur och ordning (slutförda hoppas över; aktivera vid behov uttryckligen ”Transkribera igen” i förhandsvisningen), därefter skapas en sammanfattning och uppgifter extraheras. Uppgifterna körs i ”Bearbetningskö” uppe till höger, där du när som helst kan se förloppet eller avbryta.',
])

# MARK: - 隐私：用户权利（把不存在的「应用内备份/恢复」改为 Finder 手动备份）

add('您可以随时：\n• 删除任意录音及其转写、总结与待办\n• 在系统设置中撤销麦克风、屏幕录制与语音识别访问权限\n• 在 Finder 中复制数据文件夹完成手动备份（路径见「设置 → 数据管理」）\n• 手动删除数据文件夹以彻底清除本机数据', [
    '您可以隨時：\n• 刪除任意錄音及其轉寫、總結與待辦\n• 在系統設定中撤銷麥克風、螢幕錄製與語音辨識存取權限\n• 在 Finder 中複製資料資料夾完成手動備份（路徑見「設定 → 資料管理」）\n• 手動刪除資料資料夾以徹底清除本機資料',
    'You can at any time:\n• Delete any recording and its transcript, summary and todos\n• Revoke Microphone, Screen Recording and Speech Recognition permissions in System Settings\n• Copy the data folder in Finder to make a manual backup (path: “Settings → Data Management”)\n• Delete the data folder manually to completely erase local data',
    'いつでも次のことができます：\n• 任意の録音とその文字起こし・要約・ToDo を削除\n• システム設定でマイク・画面収録・音声認識のアクセス権を取り消す\n• Finder でデータフォルダをコピーして手動バックアップ（パスは「設定 → データ管理」）\n• データフォルダを手動で削除して本機のデータを完全に消去',
    '언제든지 다음을 할 수 있습니다:\n• 모든 녹음과 그 전사·요약·할 일 삭제\n• 시스템 설정에서 마이크, 화면 기록, 음성 인식 접근 권한 철회\n• Finder에서 데이터 폴더를 복사해 수동 백업(경로: ‘설정 → 데이터 관리’)\n• 데이터 폴더를 직접 삭제해 로컬 데이터 완전 제거',
    "Vous pouvez à tout moment :\n• Supprimer un enregistrement et sa transcription, son résumé et ses tâches\n• Révoquer les autorisations Microphone, Enregistrement de l'écran et Reconnaissance vocale dans Réglages Système\n• Copier le dossier de données dans le Finder pour une sauvegarde manuelle (chemin : « Réglages → Gestion des données »)\n• Supprimer manuellement le dossier de données pour effacer complètement les données locales",
    'Sie können jederzeit:\n• eine beliebige Aufnahme samt Transkript, Zusammenfassung und To-dos löschen\n• Mikrofon-, Bildschirmaufnahme- und Spracherkennungsrechte in den Systemeinstellungen entziehen\n• den Datenordner im Finder kopieren, um manuell zu sichern (Pfad: „Einstellungen → Datenverwaltung“)\n• den Datenordner manuell löschen, um lokale Daten vollständig zu entfernen',
    'Puedes en cualquier momento:\n• Eliminar cualquier grabación y su transcripción, resumen y tareas\n• Revocar los permisos de Micrófono, Grabación de pantalla y Reconocimiento de voz en Ajustes del Sistema\n• Copiar la carpeta de datos en el Finder para hacer una copia de seguridad manual (ruta: «Ajustes → Gestión de datos»)\n• Eliminar manualmente la carpeta de datos para borrar por completo los datos locales',
    'Puoi in qualsiasi momento:\n• Eliminare qualsiasi registrazione e la relativa trascrizione, riassunto e attività\n• Revocare i permessi di Microfono, Registrazione schermo e Riconoscimento vocale nelle Impostazioni di Sistema\n• Copiare la cartella dati nel Finder per un backup manuale (percorso: «Impostazioni → Gestione dati»)\n• Eliminare manualmente la cartella dati per cancellare completamente i dati locali',
    'Pode, a qualquer momento:\n• Eliminar qualquer gravação e a respetiva transcrição, resumo e tarefas\n• Revogar as permissões de Microfone, Gravação de Ecrã e Reconhecimento de Fala nas Definições do Sistema\n• Copiar a pasta de dados no Finder para um backup manual (caminho: «Definições → Gestão de dados»)\n• Eliminar manualmente a pasta de dados para apagar completamente os dados locais',
    'Вы можете в любой момент:\n• удалить любую запись вместе с её транскрипцией, сводкой и задачами\n• отозвать права доступа к микрофону, записи экрана и распознаванию речи в «Системных настройках»\n• скопировать папку данных в Finder для ручного резервного копирования (путь: «Настройки → Управление данными»)\n• вручную удалить папку данных, чтобы полностью стереть локальные данные',
    'يمكنك في أي وقت:\n• حذف أي تسجيل وما يرتبط به من نسخة نصية وملخص ومهام\n• إلغاء أذونات الميكروفون وتسجيل الشاشة والتعرّف على الكلام من إعدادات النظام\n• نسخ مجلد البيانات في Finder لأخذ نسخة احتياطية يدوية (المسار: «الإعدادات → إدارة البيانات»)\n• حذف مجلد البيانات يدويًا لمحو البيانات المحلية بالكامل',
    'आप कभी भी:\n• किसी भी रिकॉर्डिंग और उसके प्रतिलेखन, सारांश व कार्यों को हटा सकते हैं\n• सिस्टम सेटिंग्स में माइक्रोफ़ोन, स्क्रीन रिकॉर्डिंग और वाक् पहचान की अनुमति वापस ले सकते हैं\n• मैनुअल बैकअप के लिए Finder में डेटा फ़ोल्डर की प्रतिलिपि बना सकते हैं (पथ: «सेटिंग्स → डेटा प्रबंधन»)\n• स्थानीय डेटा पूरी तरह मिटाने के लिए डेटा फ़ोल्डर मैनुअल रूप से हटा सकते हैं',
    'คุณสามารถทำได้ตลอดเวลา:\n• ลบการบันทึกใด ๆ พร้อมข้อความถอดเสียง สรุป และงาน\n• เพิกถอนสิทธิ์ไมโครโฟน การบันทึกหน้าจอ และการรู้จำเสียงในตั้งค่าระบบ\n• คัดลอกโฟลเดอร์ข้อมูลใน Finder เพื่อสำรองข้อมูลด้วยตนเอง (เส้นทาง: «ตั้งค่า → การจัดการข้อมูล»)\n• ลบโฟลเดอร์ข้อมูลด้วยตนเองเพื่อล้างข้อมูลในเครื่องทั้งหมด',
    'Bạn có thể bất cứ lúc nào:\n• Xóa mọi bản ghi và bản phiên âm, tóm tắt, việc cần làm của nó\n• Thu hồi quyền Micrô, Ghi màn hình và Nhận dạng giọng nói trong Cài đặt Hệ thống\n• Sao chép thư mục dữ liệu trong Finder để sao lưu thủ công (đường dẫn: «Cài đặt → Quản lý dữ liệu»)\n• Tự xóa thư mục dữ liệu để xóa hoàn toàn dữ liệu cục bộ',
    'Anda dapat kapan saja:\n• Menghapus rekaman apa pun beserta transkripsi, ringkasan, dan tugasnya\n• Mencabut izin Mikrofon, Perekaman Layar, dan Pengenalan Ucapan di Pengaturan Sistem\n• Menyalin folder data di Finder untuk cadangan manual (jalur: «Pengaturan → Manajemen Data»)\n• Menghapus folder data secara manual untuk menghapus data lokal sepenuhnya',
    'Dilediğiniz zaman:\n• Herhangi bir kaydı ve onun yazı dökümünü, özetini ve görevlerini silebilirsiniz\n• Sistem Ayarları\'ndan Mikrofon, Ekran Kaydı ve Konuşma Tanıma izinlerini kaldırabilirsiniz\n• Elle yedeklemek için Veri klasörünü Finder\'da kopyalayabilirsiniz (yol: «Ayarlar → Veri Yönetimi»)\n• Yerel verileri tamamen silmek için Veri klasörünü elle silebilirsiniz',
    'U kunt op elk moment:\n• een willekeurige opname en de bijbehorende transcriptie, samenvatting en taken verwijderen\n• de rechten voor Microfoon, Schermopname en Spraakherkenning intrekken in Systeeminstellingen\n• de gegevensmap in Finder kopiëren voor een handmatige back-up (pad: ‘Instellingen → Gegevensbeheer’)\n• de gegevensmap handmatig verwijderen om lokale gegevens volledig te wissen',
    'Możesz w każdej chwili:\n• usunąć dowolne nagranie wraz z jego transkrypcją, podsumowaniem i zadaniami\n• odebrać uprawnienia Mikrofonu, Nagrywania ekranu i Rozpoznawania mowy w Ustawieniach systemowych\n• skopiować folder danych w Finderze, aby wykonać ręczną kopię zapasową (ścieżka: «Ustawienia → Zarządzanie danymi»)\n• ręcznie usunąć folder danych, aby całkowicie wyczyścić dane lokalne',
    'Ви можете будь-коли:\n• видалити будь-який запис разом із його транскрипцією, підсумком і завданнями\n• відкликати дозволи на мікрофон, запис екрана та розпізнавання мовлення в «Системних налаштуваннях»\n• скопіювати теку даних у Finder для ручного резервного копіювання (шлях: «Налаштування → Керування даними»)\n• вручну видалити теку даних, щоб повністю стерти локальні дані',
    'Du kan när som helst:\n• radera en inspelning och dess transkribering, sammanfattning och uppgifter\n• återkalla behörigheterna för Mikrofon, Skärminspelning och Taligenkänning i Systeminställningar\n• kopiera datamappen i Finder för en manuell säkerhetskopia (sökväg: ”Inställningar → Datahantering”)\n• manuellt radera datamappen för att helt rensa lokala data',
])

# MARK: - 隐私：把不实的「开源声明」改为「本地处理说明」

add('本地处理说明', [
    '本機處理說明',
    'Local Processing',
    '本機処理について',
    '로컬 처리 안내',
    'Traitement local',
    'Lokale Verarbeitung',
    'Procesamiento local',
    'Elaborazione locale',
    'Processamento local',
    'Локальная обработка',
    'المعالجة المحلية',
    'स्थानीय प्रसंस्करण',
    'การประมวลผลในเครื่อง',
    'Xử lý cục bộ',
    'Pemrosesan Lokal',
    'Yerel İşleme',
    'Lokale verwerking',
    'Przetwarzanie lokalne',
    'Локальна обробка',
    'Lokal bearbetning',
])

add('Memozia 的录音、转写与总结默认全部在本机完成，音频与文本不会上传；只有当您主动配置并使用云端转写或云端大模型时，相关内容才会发送到您自行指定的第三方服务。', [
    'Memozia 的錄音、轉寫與總結預設全部在本機完成，音訊與文字不會上傳；只有當您主動設定並使用雲端轉寫或雲端大模型時，相關內容才會傳送至您自行指定的第三方服務。',
    'By default, all recording, transcription and summarization in Memozia happen on your Mac, and audio and text are never uploaded. Only when you actively configure and use cloud transcription or a cloud LLM is the relevant content sent to a third-party service you specified.',
    'Memozia の録音・文字起こし・要約は既定ですべて本機で行われ、音声やテキストがアップロードされることはありません。クラウド文字起こしやクラウド LLM をご自身で設定・使用した場合にのみ、該当する内容が指定した第三者サービスへ送信されます。',
    'Memozia의 녹음, 전사, 요약은 기본적으로 모두 이 Mac에서 처리되며 오디오와 텍스트는 업로드되지 않습니다. 클라우드 전사나 클라우드 LLM을 직접 설정해 사용할 때만 해당 내용이 지정한 제3자 서비스로 전송됩니다.',
    "Par défaut, l'enregistrement, la transcription et le résumé dans Memozia se font entièrement sur votre Mac ; l'audio et le texte ne sont jamais téléversés. Ce n'est que si vous configurez et utilisez activement une transcription cloud ou un LLM cloud que le contenu concerné est envoyé à un service tiers que vous avez choisi.",
    'Standardmäßig erfolgen Aufnahme, Transkription und Zusammenfassung in Memozia vollständig auf Ihrem Mac; Audio und Text werden nie hochgeladen. Nur wenn Sie aktiv eine Cloud-Transkription oder ein Cloud-LLM einrichten und nutzen, werden die betreffenden Inhalte an einen von Ihnen gewählten Drittanbieterdienst gesendet.',
    'De forma predeterminada, la grabación, la transcripción y el resumen en Memozia se realizan por completo en tu Mac; el audio y el texto nunca se suben. Solo cuando configuras y usas activamente una transcripción en la nube o un LLM en la nube se envía el contenido correspondiente a un servicio de terceros que tú elijas.',
    'Per impostazione predefinita, registrazione, trascrizione e riassunto in Memozia avvengono interamente sul tuo Mac; audio e testo non vengono mai caricati. Solo se configuri e usi attivamente una trascrizione cloud o un LLM cloud il contenuto pertinente viene inviato a un servizio di terze parti da te scelto.',
    'Por predefinição, a gravação, a transcrição e o resumo no Memozia são feitos inteiramente no seu Mac; o áudio e o texto nunca são carregados. Só quando configura e usa ativamente uma transcrição na nuvem ou um LLM na nuvem é que o conteúdo relevante é enviado para um serviço de terceiros por si escolhido.',
    'По умолчанию запись, транскрипция и создание сводки в Memozia выполняются полностью на вашем Mac; аудио и текст никогда не загружаются. Только если вы сами настроите и будете использовать облачную транскрипцию или облачную LLM, соответствующие данные отправятся в выбранный вами сторонний сервис.',
    'افتراضيًا، يتم التسجيل والنسخ وإنشاء الملخص في Memozia بالكامل على جهاز Mac لديك، ولا يُرفع الصوت أو النص أبدًا. فقط عند إعدادك واستخدامك للنسخ السحابي أو نموذج LLM سحابي يُرسَل المحتوى ذو الصلة إلى خدمة طرف ثالث تحددها بنفسك.',
    'Memozia में रिकॉर्डिंग, प्रतिलेखन और सारांश डिफ़ॉल्ट रूप से पूरी तरह आपके Mac पर होते हैं; ऑडियो और टेक्स्ट कभी अपलोड नहीं होते। केवल जब आप स्वयं क्लाउड प्रतिलेखन या क्लाउड LLM कॉन्फ़िगर करके उपयोग करते हैं, तभी संबंधित सामग्री आपके चुने हुए तृतीय-पक्ष सेवा को भेजी जाती है।',
    'โดยค่าเริ่มต้น การบันทึก การถอดเสียง และการสรุปใน Memozia ทำบน Mac ของคุณทั้งหมด และไม่มีการอัปโหลดเสียงหรือข้อความ จะส่งเนื้อหาที่เกี่ยวข้องไปยังบริการของบุคคลที่สามที่คุณระบุก็ต่อเมื่อคุณตั้งค่าและใช้การถอดเสียงบนคลาวด์หรือ LLM บนคลาวด์ด้วยตนเองเท่านั้น',
    'Mặc định, việc ghi âm, phiên âm và tóm tắt trong Memozia đều diễn ra hoàn toàn trên máy Mac của bạn; âm thanh và văn bản không bao giờ được tải lên. Chỉ khi bạn chủ động cấu hình và dùng phiên âm đám mây hoặc LLM đám mây thì nội dung liên quan mới được gửi đến dịch vụ bên thứ ba do bạn chỉ định.',
    'Secara default, perekaman, transkripsi, dan peringkasan di Memozia sepenuhnya dilakukan di Mac Anda; audio dan teks tidak pernah diunggah. Hanya saat Anda sendiri mengonfigurasi dan menggunakan transkripsi awan atau LLM awan, konten terkait dikirim ke layanan pihak ketiga yang Anda tentukan.',
    'Varsayılan olarak Memozia\'da kayıt, yazıya dökme ve özetleme tamamen Mac\'inizde yapılır; ses ve metin hiçbir zaman yüklenmez. Yalnızca kendi belirlediğiniz bulut yazıya dökme veya bulut LLM\'ini etkin biçimde yapılandırıp kullandığınızda ilgili içerik seçtiğiniz üçüncü taraf hizmetine gönderilir.',
    'Standaard gebeuren opname, transcriptie en samenvatting in Memozia volledig op uw Mac; audio en tekst worden nooit geüpload. Alleen wanneer u zelf cloudtranscriptie of een cloud-LLM configureert en gebruikt, wordt de betreffende inhoud naar een door u gekozen externe dienst verzonden.',
    'Domyślnie nagrywanie, transkrypcja i podsumowywanie w Memozia odbywają się w całości na Twoim Macu; dźwięk i tekst nigdy nie są przesyłane. Dopiero gdy samodzielnie skonfigurujesz i użyjesz transkrypcji w chmurze lub modelu LLM w chmurze, odpowiednie treści zostaną wysłane do wskazanej przez Ciebie usługi zewnętrznej.',
    'Типово запис, транскрипція та підсумовування в Memozia виконуються повністю на вашому Mac; аудіо й текст ніколи не завантажуються. Лише коли ви самі налаштуєте й використовуєте хмарну транскрипцію чи хмарну LLM, відповідний вміст надсилається до вказаної вами сторонньої служби.',
    'Som standard sker inspelning, transkribering och sammanfattning i Memozia helt på din Mac; ljud och text laddas aldrig upp. Endast när du själv konfigurerar och använder molntranskribering eller en moln-LLM skickas det relevanta innehållet till en tredjepartstjänst som du anger.',
])

# MARK: - 关于页卖点（去掉不存在的「文件夹备份同步」）

add('数据加密存储 + 数据文件夹位于文稿目录', [
    '資料加密儲存 + 資料資料夾位於「文稿」目錄',
    'Encrypted local storage + data folder in Documents',
    'データの暗号化保存 + データフォルダは「書類」内',
    '데이터 암호화 저장 + 데이터 폴더는 ‘서류’에 위치',
    'Stockage chiffré + dossier de données dans Documents',
    'Verschlüsselte Speicherung + Datenordner in „Dokumente“',
    'Almacenamiento cifrado + carpeta de datos en Documentos',
    'Archiviazione cifrata + cartella dati in Documenti',
    'Armazenamento cifrado + pasta de dados em Documentos',
    'Шифрованное хранение + папка данных в «Документах»',
    'تخزين مشفّر + مجلد البيانات في «المستندات»',
    'एन्क्रिप्टेड संग्रहण + डेटा फ़ोल्डर «Documents» में',
    'จัดเก็บแบบเข้ารหัส + โฟลเดอร์ข้อมูลอยู่ใน «เอกสาร»',
    'Lưu trữ mã hóa + thư mục dữ liệu trong «Tài liệu»',
    'Penyimpanan terenkripsi + folder data di «Dokumen»',
    'Şifreli depolama + Veri klasörü «Belgeler» içinde',
    'Versleutelde opslag + gegevensmap in ‘Documenten’',
    'Szyfrowane przechowywanie + folder danych w «Dokumenty»',
    'Шифроване зберігання + тека даних у «Документах»',
    'Krypterad lagring + datamapp i ”Dokument”',
])


def dump_catalog(catalog):
    """按 String Catalog 的既有排版写出：json.dumps 默认输出 `"key": value`，
    而 Xcode 写的是 `"key" : value`（冒号前留空格）。不做这一步会把整个文件
    重排成另一种风格，产生十万行级别的无意义 diff（内容完全一致）。
    末尾不补换行，与原文件保持一致。"""
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False)
    key_colon = re.compile(r'^( *)(("(?:[^"\\]|\\.)*")): ')
    return '\n'.join(key_colon.sub(r'\1\2 : ', line) for line in text.split('\n'))


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    removed = added = filled = 0
    for key in REMOVE:
        if key in existing:
            del existing[key]
            removed += 1

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
        f.write(dump_catalog(catalog))
    print(f'完成：删除旧键 {removed} 条，新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
