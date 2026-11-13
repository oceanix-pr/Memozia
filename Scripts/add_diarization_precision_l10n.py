#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 专业模式「精细度」五档：设置页与帮助视图新增文案 20 种语言
# 与 add_echo_reduction_l10n.py 同一策略（键不存在则新增，存在则补全 21 种语言条目）
#
# 注：「标准」档显示名沿用目录中既有条目（21 语言、en=Standard，语义一致），不在此重复写入。
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('精细度', [
    '精細度',
    'Precision',
    '精度',
    '정밀도',
    'Précision',
    'Genauigkeit',
    'Precisión',
    'Precisione',
    'Precisão',
    'Точность',
    'الدقة',
    'परिशुद्धता',
    'ความละเอียด',
    'Độ chi tiết',
    'Presisi',
    'Hassasiyet',
    'Precisie',
    'Dokładność',
    'Точність',
    'Precision',
])

add('最快', [
    '最快',
    'Fastest',
    '最速',
    '가장 빠름',
    'Le plus rapide',
    'Am schnellsten',
    'La más rápida',
    'La più veloce',
    'A mais rápida',
    'Самая быстрая',
    'الأسرع',
    'सबसे तेज़',
    'เร็วที่สุด',
    'Nhanh nhất',
    'Tercepat',
    'En hızlı',
    'Snelst',
    'Najszybsza',
    'Найшвидша',
    'Snabbast',
])

add('较快', [
    '較快',
    'Faster',
    '速め',
    '빠름',
    'Rapide',
    'Schneller',
    'Rápida',
    'Veloce',
    'Rápida',
    'Быстрая',
    'أسرع',
    'तेज़',
    'เร็ว',
    'Nhanh',
    'Cepat',
    'Hızlı',
    'Snel',
    'Szybka',
    'Швидша',
    'Snabb',
])

add('精细', [
    '精細',
    'Fine',
    '高精度',
    '정밀',
    'Fine',
    'Fein',
    'Fina',
    'Fine',
    'Fina',
    'Точная',
    'دقيق',
    'सूक्ष्म',
    'ละเอียด',
    'Mịn',
    'Halus',
    'İnce',
    'Fijn',
    'Dokładna',
    'Точна',
    'Fin',
])

add('最精细', [
    '最精細',
    'Finest',
    '最高精度',
    '최정밀',
    'La plus fine',
    'Am feinsten',
    'La más fina',
    'La più fine',
    'A mais fina',
    'Самая точная',
    'الأدق',
    'सर्वाधिक सूक्ष्म',
    'ละเอียดที่สุด',
    'Mịn nhất',
    'Paling halus',
    'En ince',
    'Fijnst',
    'Najdokładniejsza',
    'Найточніша',
    'Finast',
])

add('越高越细：分段窗口重叠更多、每段更长，说话人边界更精确，同时更吃 CPU 与内存。档位只调整分段相关参数（何时分段、每段多长、窗口重叠多少），说话人聚类与声纹识别的判定标准不变。「标准」与历史默认行为一致；修改后需重新转写才生效。', [
    '越高越細：分段視窗重疊更多、每段更長，說話人邊界更精確，同時更吃 CPU 與記憶體。檔位只調整分段相關參數（何時分段、每段多長、視窗重疊多少），說話人聚類與聲紋辨識的判定標準不變。「標準」與歷史預設行為一致；修改後需重新轉寫才生效。',
    'Higher is finer: more overlap between segmentation windows and longer segments make speaker boundaries more precise, at the cost of more CPU and memory. The level only changes segmentation parameters (when to split, how long each segment is, how much windows overlap); the decision thresholds for speaker clustering and voiceprint recognition stay the same. “Standard” matches the previous default behaviour; changes take effect only after re-transcribing.',
    '高いほど細かくなります。分割ウィンドウの重なりが増え、1 セグメントが長くなるため話者の境界がより正確になりますが、CPU とメモリの使用量も増えます。この段階で変わるのは分割に関するパラメータ（いつ分割するか、1 セグメントの長さ、ウィンドウの重なり量）のみで、話者クラスタリングと声紋認識の判定基準は変わりません。「標準」は従来の既定動作と同じです。変更は再文字起こし後に反映されます。',
    '높을수록 더 세밀합니다. 분할 창의 겹침이 많아지고 각 구간이 길어져 화자 경계가 더 정확해지지만 CPU와 메모리를 더 사용합니다. 이 단계에서 바뀌는 것은 분할 관련 파라미터(언제 분할할지, 구간 길이, 창 겹침 정도)뿐이며, 화자 클러스터링과 성문 인식의 판정 기준은 그대로입니다. ‘표준’은 기존 기본 동작과 동일합니다. 변경 사항은 다시 전사한 뒤에 적용됩니다.',
    "Plus le niveau est élevé, plus le traitement est fin : davantage de chevauchement entre les fenêtres de segmentation et des segments plus longs rendent les frontières des locuteurs plus précises, au prix d'une consommation accrue de CPU et de mémoire. Le niveau ne modifie que les paramètres de segmentation (quand découper, durée de chaque segment, chevauchement des fenêtres) ; les seuils de décision du regroupement des locuteurs et de la reconnaissance d'empreintes vocales restent identiques. « Standard » correspond au comportement par défaut précédent ; les modifications ne prennent effet qu'après une nouvelle transcription.",
    'Höher bedeutet feiner: Mehr Überlappung der Segmentierungsfenster und längere Segmente machen Sprechergrenzen präziser, kosten aber mehr CPU und Speicher. Die Stufe ändert nur Segmentierungsparameter (wann getrennt wird, wie lang ein Segment ist, wie stark Fenster überlappen); die Entscheidungsschwellen für Sprecher-Clustering und Stimmabdruck-Erkennung bleiben gleich. „Standard“ entspricht dem bisherigen Standardverhalten; Änderungen wirken erst nach erneutem Transkribieren.',
    'Cuanto más alto, más fino: más solapamiento entre ventanas de segmentación y segmentos más largos hacen que los límites de los hablantes sean más precisos, a costa de más CPU y memoria. El nivel solo cambia los parámetros de segmentación (cuándo dividir, cuánto dura cada segmento y cuánto se solapan las ventanas); los umbrales de decisión del agrupamiento de hablantes y del reconocimiento de huellas de voz no cambian. «Estándar» coincide con el comportamiento predeterminado anterior; los cambios solo se aplican tras volver a transcribir.',
    'Più alto è più fine: maggiore sovrapposizione tra le finestre di segmentazione e segmenti più lunghi rendono i confini degli interlocutori più precisi, al costo di più CPU e memoria. Il livello cambia solo i parametri di segmentazione (quando dividere, quanto dura ogni segmento, quanto si sovrappongono le finestre); le soglie decisionali del raggruppamento degli interlocutori e del riconoscimento delle impronte vocali restano invariate. «Standard» corrisponde al comportamento predefinito precedente; le modifiche hanno effetto solo dopo una nuova trascrizione.',
    'Quanto mais alto, mais fino: mais sobreposição entre janelas de segmentação e segmentos mais longos tornam os limites dos falantes mais precisos, ao custo de mais CPU e memória. O nível altera apenas parâmetros de segmentação (quando dividir, duração de cada segmento e sobreposição das janelas); os limites de decisão da aglomeração de falantes e do reconhecimento de impressões de voz mantêm-se iguais. «Padrão» corresponde ao comportamento predefinido anterior; as alterações só se aplicam após uma nova transcrição.',
    'Чем выше уровень, тем точнее обработка: больше перекрытие окон сегментации и более длинные сегменты делают границы говорящих точнее, но требуют больше процессора и памяти. Уровень меняет только параметры сегментации (когда разделять, длину сегмента и перекрытие окон); пороги кластеризации говорящих и распознавания голосовых отпечатков остаются прежними. «Стандартный» соответствует прежнему поведению по умолчанию; изменения вступают в силу только после повторной транскрибации.',
    'كلما ارتفع المستوى زادت الدقة: زيادة تداخل نوافذ التقسيم وطول المقاطع تجعل حدود المتحدثين أدق، مقابل استهلاك أكبر للمعالج والذاكرة. لا يغيّر المستوى سوى معاملات التقسيم (متى يتم التقسيم، وطول كل مقطع، ومقدار تداخل النوافذ)؛ أما عتبات قرار تجميع المتحدثين والتعرّف على بصمات الصوت فتبقى كما هي. «قياسي» يطابق السلوك الافتراضي السابق؛ ولا تُطبَّق التغييرات إلا بعد إعادة النسخ النصي.',
    'स्तर जितना ऊँचा, प्रोसेसिंग उतनी महीन: विभाजन विंडो का अधिक ओवरलैप और लंबे खंड वक्ताओं की सीमाएँ अधिक सटीक बनाते हैं, पर CPU और मेमोरी भी अधिक लगती है। स्तर केवल विभाजन से जुड़े पैरामीटर बदलता है (कब विभाजित करें, प्रत्येक खंड कितना लंबा हो, विंडो कितनी ओवरलैप करें); वक्ता क्लस्टरिंग और वॉइसप्रिंट पहचान के निर्णय-मानदंड अपरिवर्तित रहते हैं। «मानक» पिछले डिफ़ॉल्ट व्यवहार के समान है; बदलाव दोबारा ट्रांसक्राइब करने पर ही लागू होते हैं।',
    'ยิ่งสูงยิ่งละเอียด: การเหลื่อมกันของหน้าต่างแบ่งช่วงมากขึ้นและช่วงที่ยาวขึ้นทำให้ขอบเขตผู้พูดแม่นยำขึ้น แต่ใช้ CPU และหน่วยความจำมากขึ้น ระดับนี้ปรับเฉพาะพารามิเตอร์การแบ่งช่วง (จะแบ่งเมื่อใด แต่ละช่วงยาวเท่าใด หน้าต่างเหลื่อมกันแค่ไหน) ส่วนเกณฑ์ตัดสินของการจัดกลุ่มผู้พูดและการตรวจจับลายเสียงไม่เปลี่ยน «มาตรฐาน» ตรงกับพฤติกรรมเริ่มต้นเดิม และการเปลี่ยนแปลงจะมีผลหลังถอดเสียงใหม่เท่านั้น',
    'Càng cao càng mịn: cửa sổ phân đoạn chồng lấn nhiều hơn và mỗi đoạn dài hơn giúp ranh giới người nói chính xác hơn, nhưng tốn thêm CPU và bộ nhớ. Mức này chỉ thay đổi các tham số phân đoạn (khi nào tách, mỗi đoạn dài bao lâu, cửa sổ chồng lấn bao nhiêu); ngưỡng quyết định của việc gom cụm người nói và nhận diện mẫu giọng không đổi. «Tiêu chuẩn» giống với hành vi mặc định trước đây; thay đổi chỉ có hiệu lực sau khi chép lời lại.',
    'Semakin tinggi semakin halus: tumpang tindih jendela segmentasi lebih banyak dan segmen lebih panjang membuat batas pembicara lebih presisi, dengan konsekuensi CPU dan memori lebih besar. Tingkat ini hanya mengubah parameter segmentasi (kapan memisah, berapa lama tiap segmen, seberapa besar jendela bertumpang tindih); ambang keputusan pengelompokan pembicara dan pengenalan cetak suara tidak berubah. «Standar» sama dengan perilaku bawaan sebelumnya; perubahan baru berlaku setelah transkripsi ulang.',
    'Seviye yükseldikçe işleme incelir: bölütleme pencereleri arasındaki örtüşmenin artması ve bölütlerin uzaması konuşmacı sınırlarını daha kesin yapar, karşılığında daha fazla CPU ve bellek kullanılır. Bu seviye yalnızca bölütleme parametrelerini değiştirir (ne zaman bölünecek, her bölüt ne kadar uzun, pencereler ne kadar örtüşecek); konuşmacı kümeleme ve ses izi tanıma karar eşikleri değişmez. «Standart» önceki varsayılan davranışla aynıdır; değişiklikler ancak yeniden yazıya dökme sonrasında geçerli olur.',
    'Hoger is fijner: meer overlap tussen segmentatievensters en langere segmenten maken sprekersgrenzen nauwkeuriger, ten koste van meer CPU en geheugen. Het niveau wijzigt alleen segmentatieparameters (wanneer er wordt gesplitst, hoe lang elk segment is, hoeveel vensters overlappen); de beslissingsdrempels voor sprekersclustering en stemafdrukherkenning blijven gelijk. ‘Standaard’ komt overeen met het vroegere standaardgedrag; wijzigingen gelden pas na opnieuw transcriberen.',
    'Im wyższy poziom, tym dokładniejsze przetwarzanie: większe nakładanie się okien segmentacji i dłuższe segmenty zwiększają precyzję granic mówców, kosztem większego użycia CPU i pamięci. Poziom zmienia tylko parametry segmentacji (kiedy dzielić, jak długi jest segment, jak mocno nakładają się okna); progi decyzyjne grupowania mówców i rozpoznawania odcisków głosu pozostają bez zmian. „Standardowy” odpowiada poprzedniemu domyślnemu działaniu; zmiany działają dopiero po ponownym przepisaniu na tekst.',
    'Що вищий рівень, то точніша обробка: більше перекриття вікон сегментації та довші сегменти роблять межі мовців точнішими, але потребують більше процесора й пам’яті. Рівень змінює лише параметри сегментації (коли розділяти, яка довжина сегмента й наскільки перекриваються вікна); пороги кластеризації мовців і розпізнавання голосових відбитків залишаються незмінними. «Стандартний» відповідає попередній типовій поведінці; зміни набувають чинності лише після повторного розпізнавання.',
    'Högre är finare: mer överlapp mellan segmenteringsfönster och längre segment gör talargränserna mer exakta, men kostar mer CPU och minne. Nivån ändrar bara segmenteringsparametrar (när det delas, hur långt varje segment är, hur mycket fönstren överlappar); beslutsgränserna för talarklustring och röstavtrycksigenkänning är oförändrade. ”Standard” motsvarar det tidigare standardbeteendet; ändringar gäller först efter ny transkribering.',
])

add('专业模式下可在「设置 → 转写」调整说话人区分的「精细度」五档：越高边界越准、越吃 CPU 与内存，中间档为默认', [
    '專業模式下可在「設定 → 轉寫」調整說話人區分的「精細度」五檔：越高邊界越準、越吃 CPU 與記憶體，中間檔為預設',
    'In Pro mode you can set the speaker-separation “Precision” in Settings → Transcription (five levels): higher levels give more accurate speaker boundaries but use more CPU and memory; the middle level is the default',
    'プロモードでは「設定 → 文字起こし」で話者分離の「精度」を 5 段階から選べます。高いほど境界が正確になりますが CPU とメモリを多く使います。既定は中央の段階です',
    '프로 모드에서는 ‘설정 → 전사’에서 화자 구분 ‘정밀도’를 5단계로 조절할 수 있습니다. 높을수록 경계가 정확하지만 CPU와 메모리를 더 사용하며, 기본값은 중간 단계입니다',
    "En mode Pro, vous pouvez régler la « Précision » de la séparation des locuteurs dans Réglages → Transcription (cinq niveaux) : plus le niveau est élevé, plus les frontières sont précises, mais plus la consommation de CPU et de mémoire augmente ; le niveau intermédiaire est celui par défaut",
    'Im Pro-Modus lässt sich die „Genauigkeit“ der Sprechertrennung unter Einstellungen → Transkription in fünf Stufen einstellen: Höhere Stufen liefern genauere Sprechergrenzen, brauchen aber mehr CPU und Speicher; Standard ist die mittlere Stufe',
    'En modo Pro puedes ajustar la «Precisión» de la separación de hablantes en Ajustes → Transcripción (cinco niveles): a mayor nivel, límites más precisos pero más consumo de CPU y memoria; el nivel intermedio es el predeterminado',
    'In modalità Pro puoi impostare la «Precisione» della separazione degli interlocutori in Impostazioni → Trascrizione (cinque livelli): più alto è il livello, più i confini sono precisi ma maggiore è il consumo di CPU e memoria; il livello intermedio è quello predefinito',
    'No modo Pro pode ajustar a «Precisão» da separação de falantes em Ajustes → Transcrição (cinco níveis): quanto mais alto, mais precisos os limites, mas maior o consumo de CPU e memória; o nível intermédio é o predefinido',
    'В профессиональном режиме «Точность» разделения говорящих настраивается в «Настройки → Транскрибация» (пять уровней): чем выше уровень, тем точнее границы, но тем больше нагрузка на процессор и память; по умолчанию выбран средний уровень',
    'في الوضع الاحترافي يمكنك ضبط «الدقة» لتمييز المتحدثين من الإعدادات ← النسخ النصي (خمسة مستويات): كلما ارتفع المستوى زادت دقة الحدود وزاد استهلاك المعالج والذاكرة، والمستوى الأوسط هو الافتراضي',
    'प्रो मोड में «सेटिंग्स → ट्रांसक्रिप्शन» में वक्ता पृथक्करण की «परिशुद्धता» पाँच स्तरों में समायोजित कर सकते हैं: स्तर जितना ऊँचा, सीमाएँ उतनी सटीक पर CPU और मेमोरी की खपत अधिक; बीच का स्तर डिफ़ॉल्ट है',
    'ในโหมดโปร ปรับ «ความละเอียด» ของการแยกผู้พูดได้ที่ «การตั้งค่า → ถอดเสียง» มีห้าระดับ: ยิ่งสูงขอบเขตยิ่งแม่นแต่ใช้ CPU และหน่วยความจำมากขึ้น โดยค่าเริ่มต้นอยู่ที่ระดับกลาง',
    'Ở chế độ Pro, bạn có thể chỉnh «Độ chi tiết» của việc phân tách người nói trong «Cài đặt → Chép lời» (năm mức): mức càng cao ranh giới càng chính xác nhưng tốn nhiều CPU và bộ nhớ hơn; mức giữa là mặc định',
    'Di mode Pro Anda dapat mengatur «Presisi» pemisahan pembicara di Pengaturan → Transkripsi (lima tingkat): semakin tinggi semakin presisi batasnya tetapi semakin banyak CPU dan memori; tingkat tengah adalah bawaan',
    "Pro modda konuşmacı ayrımının «Hassasiyet»ini Ayarlar → Yazıya Dökme'de beş seviye olarak ayarlayabilirsiniz: seviye yükseldikçe sınırlar keskinleşir ancak CPU ve bellek kullanımı artar; varsayılan orta seviyedir",
    'In Pro-modus kun je de ‘Precisie’ van de sprekersscheiding instellen via Instellingen → Transcriptie (vijf niveaus): hoger geeft nauwkeuriger sprekersgrenzen maar gebruikt meer CPU en geheugen; het middelste niveau is de standaard',
    'W trybie Pro możesz ustawić „Dokładność” rozdzielania mówców w Ustawienia → Transkrypcja (pięć poziomów): wyższy poziom to dokładniejsze granice, ale większe zużycie CPU i pamięci; domyślny jest poziom środkowy',
    'У професійному режимі «Точність» розділення мовців налаштовується в «Налаштування → Транскрипція» (п’ять рівнів): що вищий рівень, то точніші межі, але більше навантаження на процесор і пам’ять; типовий — середній рівень',
    'I Pro-läge kan du ställa in «Precision» för talaruppdelningen under Inställningar → Transkribering (fem nivåer): högre nivå ger exaktare talargränser men använder mer CPU och minne; mellannivån är standard',
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
        f.write(dump_catalog(catalog))
    print(f'完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
