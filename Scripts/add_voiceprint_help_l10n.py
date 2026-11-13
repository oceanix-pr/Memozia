#!/usr/bin/env python3
# 声纹识别缺陷修复：帮助视图「转写 / 声纹识别」两节新增文案 20 种语言
# 与 add_echo_reduction_l10n.py 同一策略（键不存在则新增，存在则补全 21 种语言条目）
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('长会议（超过约 30 分钟）的说话人区分分段处理，进度会显示当前段号', [
    '長會議（超過約 30 分鐘）的說話人區分分段處理，進度會顯示當前段號',
    'For long meetings (over about 30 minutes) speaker separation is processed in segments, and the progress shows the current segment',
    '長時間の会議（約30分超）では話者分離を分割して処理し、進行状況に現在のセグメント番号を表示します',
    '긴 회의(약 30분 초과)는 화자 구분을 구간별로 처리하며, 진행 상황에 현재 구간 번호가 표시됩니다',
    "Pour les réunions longues (plus d'environ 30 minutes), la séparation des locuteurs est traitée par segments et la progression indique le segment en cours",
    'Bei langen Besprechungen (über etwa 30 Minuten) wird die Sprechertrennung abschnittsweise verarbeitet; der Fortschritt zeigt den aktuellen Abschnitt',
    'En reuniones largas (más de unos 30 minutos) la separación de hablantes se procesa por segmentos y el progreso muestra el segmento actual',
    "Nelle riunioni lunghe (oltre circa 30 minuti) la separazione degli interlocutori viene elaborata a segmenti e l'avanzamento mostra il segmento corrente",
    'Em reuniões longas (mais de cerca de 30 minutos) a separação de falantes é processada por segmentos e o progresso mostra o segmento atual',
    'В длинных встречах (более примерно 30 минут) разделение говорящих обрабатывается по сегментам, а в ходе выполнения отображается номер текущего сегмента',
    'في الاجتماعات الطويلة (أكثر من نحو 30 دقيقة) تُعالَج عملية تمييز المتحدثين على شكل مقاطع، ويُعرض رقم المقطع الحالي في شريط التقدّم',
    'लंबी मीटिंग (लगभग 30 मिनट से अधिक) में वक्ता पृथक्करण खंडों में संसाधित होता है और प्रगति में वर्तमान खंड संख्या दिखती है',
    'การประชุมยาว (เกินประมาณ 30 นาที) จะแยกผู้พูดเป็นช่วง ๆ และแถบความคืบหน้าจะแสดงหมายเลขช่วงปัจจุบัน',
    'Với cuộc họp dài (hơn khoảng 30 phút), việc phân tách người nói được xử lý theo từng đoạn và tiến trình hiển thị số đoạn hiện tại',
    'Untuk rapat panjang (lebih dari sekitar 30 menit), pemisahan pembicara diproses per segmen dan progres menampilkan nomor segmen saat ini',
    'Uzun toplantılarda (yaklaşık 30 dakikadan fazla) konuşmacı ayrımı bölümler hâlinde işlenir ve ilerleme çubuğu geçerli bölüm numarasını gösterir',
    'Bij lange vergaderingen (meer dan ongeveer 30 minuten) wordt de sprekersscheiding per segment verwerkt en toont de voortgang het huidige segmentnummer',
    'W długich spotkaniach (ponad około 30 minut) rozdzielanie mówców jest przetwarzane segmentami, a postęp pokazuje numer bieżącego segmentu',
    'У довгих зустрічах (понад приблизно 30 хвилин) розділення мовців обробляється сегментами, а в перебігу показується номер поточного сегмента',
    'I långa möten (över cirka 30 minuter) bearbetas talaruppdelningen i segment och förloppet visar aktuellt segmentnummer',
])

add('同一人的多条声纹（不同场次分别注册）在识别时会自动合并；也可在「设置 → 声纹库」用「合并同名」整理', [
    '同一人的多條聲紋（不同場次分別註冊）在辨識時會自動合併；也可在「設定 → 聲紋庫」用「合併同名」整理',
    'Multiple voiceprints of the same person (registered in different sessions) are merged automatically during recognition; you can also tidy them up with “Merge Same Names” in Settings → Voiceprint Library',
    '同一人物の複数の声紋（別々の場面で登録）は認識時に自動的に統合されます。「設定 → 声紋ライブラリ」の「同名を統合」で整理することもできます',
    '같은 사람의 여러 성문(서로 다른 세션에서 등록)은 인식 시 자동으로 병합됩니다. ‘설정 → 성문 보관함’에서 ‘같은 이름 병합’으로 정리할 수도 있습니다',
    "Plusieurs empreintes vocales de la même personne (enregistrées lors de sessions différentes) sont fusionnées automatiquement lors de la reconnaissance ; vous pouvez aussi les regrouper avec « Fusionner les noms identiques » dans Réglages → Bibliothèque d'empreintes",
    'Mehrere Stimmabdrücke derselben Person (in verschiedenen Sitzungen registriert) werden bei der Erkennung automatisch zusammengeführt; alternativ lassen sie sich unter „Einstellungen → Stimmabdruck-Bibliothek“ mit „Gleiche Namen zusammenführen“ aufräumen',
    'Varias huellas de voz de la misma persona (registradas en sesiones distintas) se fusionan automáticamente al reconocer; también puedes ordenarlas con «Combinar nombres iguales» en Ajustes → Biblioteca de huellas',
    'Più impronte vocali della stessa persona (registrate in sessioni diverse) vengono unite automaticamente al riconoscimento; puoi anche sistemarle con «Unisci nomi uguali» in Impostazioni → Libreria impronte',
    'Várias impressões de voz da mesma pessoa (registadas em sessões diferentes) são combinadas automaticamente no reconhecimento; também pode organizá-las com «Combinar nomes iguais» em Ajustes → Biblioteca de impressões de voz',
    'Несколько голосовых отпечатков одного человека (зарегистрированных в разных сессиях) при распознавании объединяются автоматически; также их можно упорядочить кнопкой «Объединить одноимённые» в «Настройки → Библиотека голосов»',
    'تُدمَج بصمات الصوت المتعددة للشخص نفسه (المسجَّلة في جلسات مختلفة) تلقائيًا عند التعرّف؛ ويمكنك أيضًا ترتيبها عبر «دمج الأسماء المتطابقة» في الإعدادات ← مكتبة بصمات الصوت',
    'एक ही व्यक्ति की कई वॉइसप्रिंट (अलग-अलग सत्रों में पंजीकृत) पहचान के समय स्वतः मिला दी जाती हैं; आप «सेटिंग्स → वॉइसप्रिंट लाइब्रेरी» में «समान नाम मिलाएँ» से इन्हें व्यवस्थित भी कर सकते हैं',
    'ลายเสียงหลายรายการของคนเดียวกัน (ที่ลงทะเบียนไว้คนละครั้ง) จะถูกรวมให้อัตโนมัติตอนตรวจจับ และยังจัดระเบียบได้ด้วย «รวมชื่อเดียวกัน» ใน «การตั้งค่า → คลังลายเสียง»',
    'Nhiều mẫu giọng của cùng một người (đăng ký ở các buổi khác nhau) sẽ được gộp tự động khi nhận diện; bạn cũng có thể sắp xếp chúng bằng «Gộp cùng tên» trong «Cài đặt → Thư viện mẫu giọng»',
    'Beberapa cetak suara orang yang sama (didaftarkan pada sesi berbeda) digabungkan otomatis saat pengenalan; Anda juga dapat merapikannya dengan «Gabungkan Nama Sama» di Pengaturan → Pustaka Cetak Suara',
    "Aynı kişinin birden çok ses izi (farklı oturumlarda kaydedilen) tanıma sırasında otomatik olarak birleştirilir; bunları Ayarlar → Ses İzi Kitaplığı'ndaki «Aynı Adları Birleştir» ile de düzenleyebilirsiniz",
    'Meerdere stemafdrukken van dezelfde persoon (geregistreerd in verschillende sessies) worden bij herkenning automatisch samengevoegd; je kunt ze ook opruimen met ‘Zelfde namen samenvoegen’ in Instellingen → Stemafdrukkenbibliotheek',
    'Wiele odcisków głosu tej samej osoby (zarejestrowanych w różnych sesjach) jest automatycznie scalanych podczas rozpoznawania; możesz je też uporządkować opcją „Scal te same nazwy” w Ustawienia → Biblioteka odcisków głosu',
    'Кілька голосових відбитків однієї людини (зареєстрованих у різних сеансах) під час розпізнавання об’єднуються автоматично; також їх можна впорядкувати кнопкою «Об’єднати однойменні» в «Налаштування → Бібліотека голосових відбитків»',
    'Flera röstavtryck från samma person (registrerade i olika sessioner) slås samman automatiskt vid igenkänning; du kan också städa dem med ”Slå samman samma namn” i Inställningar → Röstavtrycksbibliotek',
])

add('识别偏保守：相似度不足或与他人嗓音接近时保留「说话人 N」，宁可不标注也不错标', [
    '辨識偏保守：相似度不足或與他人嗓音接近時保留「說話人 N」，寧可不標註也不錯標',
    'Recognition errs on the safe side: if the similarity is too low or the voice is close to someone else’s, the label stays as “Speaker N” — better unlabelled than mislabelled',
    '認識は保守的です。類似度が足りない場合や他人の声に近い場合は「話者 N」のままにします（誤って名付けるより、名付けないほうがましという方針）',
    '인식은 보수적으로 동작합니다. 유사도가 부족하거나 다른 사람의 목소리와 비슷하면 ‘화자 N’으로 남겨 둡니다. 잘못 붙이는 것보다 붙이지 않는 편을 택합니다',
    "La reconnaissance reste prudente : si la similarité est insuffisante ou si la voix est proche de celle d'une autre personne, l'étiquette reste « Locuteur N » — mieux vaut ne rien nommer que mal nommer",
    'Die Erkennung bleibt vorsichtig: Reicht die Ähnlichkeit nicht aus oder ist die Stimme einer anderen Person ähnlich, bleibt die Bezeichnung „Sprecher N“ – lieber unbenannt als falsch benannt',
    'El reconocimiento es prudente: si la similitud es insuficiente o la voz se parece a la de otra persona, se mantiene «Hablante N»; mejor sin etiquetar que etiquetar mal',
    "Il riconoscimento è prudente: se la somiglianza è insufficiente o la voce è simile a quella di un'altra persona, resta «Interlocutore N»; meglio non etichettare che etichettare male",
    'O reconhecimento é prudente: se a semelhança for insuficiente ou a voz for próxima da de outra pessoa, mantém-se «Falante N»; mais vale não etiquetar do que etiquetar mal',
    'Распознавание действует осторожно: если схожести недостаточно или голос близок к чужому, остаётся «Говорящий N» — лучше не подписать, чем подписать неверно',
    'التعرّف متحفّظ: إذا كانت درجة التشابه غير كافية أو كان الصوت قريبًا من صوت شخص آخر، يبقى الوسم «متحدث N»؛ فعدم وضع اسم أفضل من وضع اسم خاطئ',
    'पहचान सतर्क रहती है: समानता कम होने या किसी और की आवाज़ से मेल खाने पर «वक्ता N» ही रहता है — ग़लत नाम देने से बेहतर है नाम न देना',
    'การตรวจจับเน้นความระมัดระวัง หากความคล้ายไม่พอหรือเสียงใกล้เคียงกับคนอื่น จะคงเป็น «ผู้พูด N» ไว้ — ไม่ติดชื่อยังดีกว่าติดชื่อผิด',
    'Nhận diện thiên về thận trọng: nếu độ tương đồng không đủ hoặc giọng gần với người khác, nhãn vẫn là «Người nói N» — không gán tên còn hơn gán sai',
    'Pengenalan bersikap hati-hati: jika kemiripan kurang atau suara mirip orang lain, label tetap «Pembicara N» — lebih baik tanpa nama daripada salah nama',
    'Tanıma temkinlidir: benzerlik yetersizse veya ses başka birine yakınsa etiket «Konuşmacı N» olarak kalır — yanlış adlandırmaktansa adlandırmamak yeğdir',
    'Herkenning is terughoudend: is de gelijkenis onvoldoende of lijkt de stem op die van iemand anders, dan blijft het label ‘Spreker N’ — liever geen naam dan een verkeerde naam',
    'Rozpoznawanie działa ostrożnie: jeśli podobieństwo jest zbyt małe lub głos jest zbliżony do głosu innej osoby, etykieta pozostaje „Mówca N” — lepiej nie podpisywać niż podpisać błędnie',
    'Розпізнавання діє обережно: якщо схожості недостатньо або голос близький до чужого, залишається «Мовець N» — краще не підписувати, ніж підписати неправильно',
    'Igenkänningen är försiktig: om likheten är otillräcklig eller rösten liknar någon annans förblir etiketten ”Talare N” — hellre utan namn än fel namn',
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
