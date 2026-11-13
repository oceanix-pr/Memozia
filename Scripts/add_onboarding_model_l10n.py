#!/usr/bin/env python3
# 新手引导「准备模型」页：文案 20 种语言
# 与 add_whisper_download_l10n.py 同一合并策略（补全已被自动抽取的空条目）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('准备模型', [
    '準備模型',
    'Prepare Models',
    'モデルを準備',
    '모델 준비',
    'Préparer les modèles',
    'Modelle vorbereiten',
    'Preparar modelos',
    'Prepara i modelli',
    'Preparar modelos',
    'Подготовка моделей',
    'تحضير النماذج',
    'मॉडल तैयार करें',
    'เตรียมโมเดล',
    'Chuẩn bị mô hình',
    'Siapkan Model',
    'Modelleri Hazırla',
    'Modellen voorbereiden',
    'Przygotuj modele',
    'Підготувати моделі',
    'Förbered modeller',
])

add('首次使用需要先下载本地模型', [
    '首次使用需要先下載本機模型',
    'Download the local models to get started',
    '初回はローカルモデルのダウンロードが必要です',
    '처음 사용하려면 로컬 모델을 먼저 내려받아야 합니다',
    'Téléchargez les modèles locaux pour commencer',
    'Laden Sie zuerst die lokalen Modelle herunter',
    'Descarga los modelos locales para empezar',
    'Scarica i modelli locali per iniziare',
    'Transfira os modelos locais para começar',
    'Для начала скачайте локальные модели',
    'نزّل النماذج المحلية للبدء',
    'शुरू करने के लिए स्थानीय मॉडल डाउनलोड करें',
    'ดาวน์โหลดโมเดลในเครื่องก่อนเริ่มใช้งาน',
    'Tải mô hình cục bộ để bắt đầu',
    'Unduh model lokal untuk memulai',
    'Başlamak için yerel modelleri indirin',
    'Download eerst de lokale modellen',
    'Pobierz modele lokalne, aby rozpocząć',
    'Спершу завантажте локальні моделі',
    'Ladda ner de lokala modellerna först',
])

add('语音转写依赖 Whisper CoreML 模型，说话人分离依赖 pyannote 分段模型；两者都下载到本机、完全离线运行，不上传任何数据。也可以稍后在「设置 → 语音转写」手动指定模型文件夹。', [
    '語音轉寫依賴 Whisper CoreML 模型，說話人分離依賴 pyannote 分段模型；兩者都下載到本機、完全離線執行，不上傳任何資料。也可以稍後在「設定 → 語音轉寫」手動指定模型資料夾。',
    'Speech-to-text needs a Whisper CoreML model, and speaker separation needs the pyannote segmentation model. Both are downloaded to this Mac and run fully offline — nothing is uploaded. You can also point at a model folder manually later in Settings → Transcription.',
    '音声文字起こしには Whisper CoreML モデル、話者分離には pyannote セグメンテーションモデルが必要です。どちらも本機にダウンロードされ、完全にオフラインで動作し、データは送信されません。後から「設定 → 音声文字起こし」でモデルフォルダを手動指定することもできます。',
    '음성 텍스트 변환에는 Whisper CoreML 모델, 화자 분리에는 pyannote 분할 모델이 필요합니다. 둘 다 이 Mac에 내려받아 완전히 오프라인으로 실행되며 어떤 데이터도 업로드되지 않습니다. 나중에 ‘설정 → 음성 변환’에서 모델 폴더를 직접 지정할 수도 있습니다.',
    "La transcription nécessite un modèle Whisper CoreML et la séparation des locuteurs le modèle de segmentation pyannote. Les deux sont téléchargés sur ce Mac et fonctionnent entièrement hors ligne ; aucune donnée n'est envoyée. Vous pouvez aussi désigner un dossier de modèles plus tard dans Réglages → Transcription.",
    'Die Transkription benötigt ein Whisper-CoreML-Modell, die Sprechertrennung das pyannote-Segmentierungsmodell. Beide werden auf diesen Mac geladen und laufen vollständig offline – es werden keine Daten hochgeladen. Alternativ können Sie später unter Einstellungen → Transkription einen Modellordner angeben.',
    'La transcripción necesita un modelo Whisper CoreML y la separación de hablantes el modelo de segmentación pyannote. Ambos se descargan en este Mac y funcionan totalmente sin conexión; no se sube ningún dato. También puedes indicar una carpeta de modelos más tarde en Ajustes → Transcripción.',
    'La trascrizione richiede un modello Whisper CoreML e la separazione degli speaker il modello di segmentazione pyannote. Entrambi vengono scaricati su questo Mac e funzionano completamente offline; nessun dato viene inviato. Puoi anche indicare una cartella dei modelli più tardi in Impostazioni → Trascrizione.',
    'A transcrição precisa de um modelo Whisper CoreML e a separação de falantes do modelo de segmentação pyannote. Ambos são transferidos para este Mac e funcionam totalmente offline; nada é enviado. Também pode indicar uma pasta de modelos mais tarde em Definições → Transcrição.',
    'Для расшифровки нужна модель Whisper CoreML, для разделения говорящих — модель сегментации pyannote. Обе скачиваются на этот Mac и работают полностью офлайн, ничего не отправляется. Папку моделей можно указать вручную позже в «Настройки → Расшифровка».',
    'يحتاج تحويل الكلام إلى نص إلى نموذج Whisper CoreML، ويحتاج فصل المتحدثين إلى نموذج تقطيع pyannote. يُنزَّل كلاهما على هذا الجهاز ويعملان دون اتصال بالكامل، ولا تُرفع أي بيانات. يمكنك أيضًا تحديد مجلد النماذج يدويًا لاحقًا من «الإعدادات → تحويل الكلام».',
    'वाक्-से-पाठ के लिए Whisper CoreML मॉडल और वक्ता पृथक्करण के लिए pyannote सेगमेंटेशन मॉडल चाहिए। दोनों इस Mac पर डाउनलोड होते हैं और पूरी तरह ऑफ़लाइन चलते हैं; कोई डेटा अपलोड नहीं होता। आप बाद में «सेटिंग्स → ट्रांसक्रिप्शन» में मॉडल फ़ोल्डर मैन्युअल रूप से भी चुन सकते हैं।',
    'การแปลงเสียงเป็นข้อความต้องใช้โมเดล Whisper CoreML และการแยกผู้พูดต้องใช้โมเดลแบ่งส่วน pyannote ทั้งคู่ดาวน์โหลดมาที่เครื่องนี้และทำงานแบบออฟไลน์ทั้งหมด ไม่มีการอัปโหลดข้อมูลใด ๆ และคุณยังเลือกโฟลเดอร์โมเดลเองได้ภายหลังที่ «การตั้งค่า → การถอดเสียง»',
    'Chuyển giọng nói thành văn bản cần mô hình Whisper CoreML, tách người nói cần mô hình phân đoạn pyannote. Cả hai được tải về máy này và chạy hoàn toàn ngoại tuyến, không tải dữ liệu lên đâu cả. Bạn cũng có thể chỉ định thư mục mô hình sau trong «Cài đặt → Chuyển văn bản».',
    'Transkripsi memerlukan model Whisper CoreML dan pemisahan pembicara memerlukan model segmentasi pyannote. Keduanya diunduh ke Mac ini dan berjalan sepenuhnya offline; tidak ada data yang diunggah. Anda juga dapat memilih folder model secara manual nanti di «Pengaturan → Transkripsi».',
    'Konuşma metne dönüştürme Whisper CoreML modelini, konuşmacı ayrımı pyannote bölütleme modelini gerektirir. İkisi de bu Mac’e indirilir ve tamamen çevrimdışı çalışır; hiçbir veri yüklenmez. Model klasörünü sonradan «Ayarlar → Metne dönüştürme» bölümünde de seçebilirsiniz.',
    'Transcriptie vereist een Whisper CoreML-model en sprekeropdeling het pyannote-segmentatiemodel. Beide worden op deze Mac gedownload en werken volledig offline; er wordt niets geüpload. Je kunt later ook een modellenmap kiezen in «Instellingen → Transcriptie».',
    'Transkrypcja wymaga modelu Whisper CoreML, a rozdzielanie mówców modelu segmentacji pyannote. Oba są pobierane na tego Maca i działają w pełni offline; nic nie jest wysyłane. Folder modeli możesz też wskazać później w «Ustawienia → Transkrypcja».',
    'Для розшифрування потрібна модель Whisper CoreML, для розділення мовців — модель сегментації pyannote. Обидві завантажуються на цей Mac і працюють повністю офлайн, нічого не надсилається. Папку моделей можна вказати вручну пізніше в «Налаштування → Розшифрування».',
    'Transkribering kräver en Whisper CoreML-modell och talaruppdelning kräver pyannote-segmenteringsmodellen. Båda laddas ner till den här Macen och körs helt offline; inget skickas upp. Du kan också ange en modellmapp senare i «Inställningar → Transkribering».',
])

add('下载', [
    '下載',
    'Download',
    'ダウンロード',
    '다운로드',
    'Télécharger',
    'Herunterladen',
    'Descargar',
    'Scarica',
    'Transferir',
    'Скачать',
    'تنزيل',
    'डाउनलोड',
    'ดาวน์โหลด',
    'Tải xuống',
    'Unduh',
    'İndir',
    'Downloaden',
    'Pobierz',
    'Завантажити',
    'Ladda ner',
])

add('下载源：%@（可在「设置 → 语音转写」更改）', [
    '下載來源：%@（可在「設定 → 語音轉寫」更改）',
    'Download source: %@ (change in Settings → Transcription)',
    'ダウンロード元：%@（「設定 → 音声文字起こし」で変更できます）',
    '다운로드 소스: %@ (‘설정 → 음성 변환’에서 변경 가능)',
    'Source de téléchargement : %@ (modifiable dans Réglages → Transcription)',
    'Download-Quelle: %@ (änderbar unter Einstellungen → Transkription)',
    'Origen de descarga: %@ (se cambia en Ajustes → Transcripción)',
    'Origine di download: %@ (modificabile in Impostazioni → Trascrizione)',
    'Origem de transferência: %@ (alterável em Definições → Transcrição)',
    'Источник загрузки: %@ (меняется в «Настройки → Расшифровка»)',
    'مصدر التنزيل: %@ (يمكن تغييره من «الإعدادات → تحويل الكلام»)',
    'डाउनलोड स्रोत: %@ («सेटिंग्स → ट्रांसक्रिप्शन» में बदलें)',
    'แหล่งดาวน์โหลด: %@ (เปลี่ยนได้ที่ «การตั้งค่า → การถอดเสียง»)',
    'Nguồn tải: %@ (thay đổi trong «Cài đặt → Chuyển văn bản»)',
    'Sumber unduhan: %@ (ubah di «Pengaturan → Transkripsi»)',
    'İndirme kaynağı: %@ («Ayarlar → Metne dönüştürme» bölümünde değiştirilir)',
    'Downloadbron: %@ (wijzig in «Instellingen → Transcriptie»)',
    'Źródło pobierania: %@ (zmienisz w «Ustawienia → Transkrypcja»)',
    'Джерело завантаження: %@ (змінюється в «Налаштування → Розшифрування»)',
    'Nedladdningskälla: %@ (ändras i «Inställningar → Transkribering»)',
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
    print(f'完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
