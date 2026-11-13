#!/usr/bin/env python3
# 离线参考回声消除：录音设置页「回声消除」小节文案 20 种语言
# 与 add_micdocs_l10n.py 同一策略（键不存在则新增，存在则补全 21 种语言条目）
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('回声消除', [
    '回音消除',
    'Echo Cancellation',
    'エコー除去',
    '에코 제거',
    "Suppression d'écho",
    'Echounterdrückung',
    'Cancelación de eco',
    "Cancellazione dell'eco",
    'Cancelamento de eco',
    'Подавление эха',
    'إلغاء الصدى',
    'प्रतिध्वनि निवारण',
    'การตัดเสียงสะท้อน',
    'Khử tiếng vọng',
    'Pembatalan Gema',
    'Yankı Giderme',
    'Echo-onderdrukking',
    'Eliminacja echa',
    'Придушення відлуння',
    'Ekoutsläckning',
])

add('离线参考回声消除', [
    '離線參考回音消除',
    'Offline Reference Echo Cancellation',
    'オフライン参照エコー除去',
    '오프라인 참조 에코 제거',
    "Suppression d'écho à référence hors ligne",
    'Offline-Referenz-Echounterdrückung',
    'Cancelación de eco con referencia sin conexión',
    "Cancellazione dell'eco con riferimento offline",
    'Cancelamento de eco com referência offline',
    'Подавление эха по опорному сигналу офлайн',
    'إلغاء الصدى بمرجع دون اتصال',
    'ऑफ़लाइन संदर्भ प्रतिध्वनि निवारण',
    'การตัดเสียงสะท้อนโดยอ้างอิงแบบออฟไลน์',
    'Khử tiếng vọng tham chiếu ngoại tuyến',
    'Pembatalan Gema Referensi Luring',
    'Çevrimdışı Referans Yankı Giderme',
    'Echo-onderdrukking met offline referentie',
    'Eliminacja echa z odniesieniem offline',
    'Придушення відлуння за офлайн-опорним сигналом',
    'Ekoutsläckning med offline-referens',
])

add('以系统音频为参考，消除麦克风轨里由扬声器外放泄漏回来的远端声音，避免同一句话在合并后出现两份。\n\n仅在「来源」同时包含麦克风与系统音频（混合模式）时生效；处理失败会自动沿用原始音轨，不会丢失录音。', [
    '以系統音訊為參考，消除麥克風軌裡由揚聲器外放洩漏回來的遠端聲音，避免同一句話在合併後出現兩份。\n\n僅在「來源」同時包含麥克風與系統音訊（混合模式）時生效；處理失敗會自動沿用原始音軌，不會遺失錄音。',
    'Uses the system audio as a reference to remove far-end sound that leaked into the microphone track through the speakers, so the same sentence does not appear twice after mixing.\n\nOnly applies when “Source” includes both Microphone and System Audio (mixed mode); if processing fails, the original track is kept, so no audio is lost.',
    'システム音声を参照として、スピーカーから漏れ込んだマイクトラック内の遠端の音声を除去し、ミックス後に同じ発話が二重に現れるのを防ぎます。\n\n「ソース」にマイクとシステム音声の両方（ミックスモード）が含まれる場合のみ有効です。処理に失敗した場合は元のトラックをそのまま使うため、録音が失われることはありません。',
    '시스템 오디오를 참조로 사용해 스피커를 통해 마이크 트랙에 유입된 원격 음성을 제거하여, 믹싱 후 같은 문장이 두 번 나타나지 않도록 합니다.\n\n‘소스’에 마이크와 시스템 오디오가 모두 포함된 경우(혼합 모드)에만 적용됩니다. 처리에 실패하면 원본 트랙을 그대로 사용하므로 녹음이 유실되지 않습니다.',
    "Utilise l'audio système comme référence pour supprimer le son distant qui a fuité dans la piste du microphone via les haut-parleurs, afin que la même phrase n'apparaisse pas deux fois après le mixage.\n\nS'applique uniquement lorsque « Source » inclut à la fois le microphone et l'audio système (mode mixte) ; en cas d'échec, la piste d'origine est conservée, aucun enregistrement n'est perdu.",
    'Nutzt den Systemton als Referenz, um den über die Lautsprecher in die Mikrofon-Spur gelangten fernen Ton zu entfernen, damit derselbe Satz nach dem Mischen nicht doppelt vorkommt.\n\nGilt nur, wenn „Quelle“ Mikrofon und Systemton enthält (Mischmodus); schlägt die Verarbeitung fehl, bleibt die Original-Spur erhalten, es geht keine Aufnahme verloren.',
    'Usa el audio del sistema como referencia para eliminar el sonido remoto que se filtró a la pista del micrófono a través de los altavoces, para que la misma frase no aparezca dos veces tras la mezcla.\n\nSolo se aplica cuando «Fuente» incluye micrófono y audio del sistema (modo mixto); si falla el procesado, se conserva la pista original, sin perder grabación.',
    "Usa l'audio di sistema come riferimento per rimuovere il suono remoto filtrato nella traccia del microfono dagli altoparlanti, così la stessa frase non compare due volte dopo il missaggio.\n\nSi applica solo quando «Sorgente» include microfono e audio di sistema (modalità mista); se l'elaborazione fallisce, la traccia originale viene mantenuta: nessuna registrazione va persa.",
    'Usa o áudio do sistema como referência para remover o som remoto que vazou para a faixa do microfone pelos altifalantes, para que a mesma frase não apareça duas vezes após a mistura.\n\nSó se aplica quando «Fonte» inclui microfone e áudio do sistema (modo misto); se o processamento falhar, a faixa original é mantida e nenhuma gravação é perdida.',
    'Использует системный звук как опорный сигнал, чтобы убрать дальний звук, попавший в дорожку микрофона через динамики, — одна и та же фраза не будет дублироваться после сведения.\n\nДействует только когда «Источник» включает и микрофон, и системный звук (смешанный режим); при сбое обработки остаётся исходная дорожка, запись не теряется.',
    'يستخدم صوت النظام كمرجع لإزالة صوت الطرف البعيد الذي تسرّب إلى مسار الميكروفون عبر مكبرات الصوت، حتى لا تظهر الجملة نفسها مرتين بعد الدمج.\n\nيُطبَّق فقط عندما يتضمن «المصدر» الميكروفون وصوت النظام معًا (الوضع المختلط)؛ وإذا فشلت المعالجة يُحتفظ بالمسار الأصلي دون فقدان التسجيل.',
    'सिस्टम ऑडियो को संदर्भ बनाकर स्पीकर से माइक्रोफ़ोन ट्रैक में आए दूर के साथी की आवाज़ हटाता है, ताकि मिक्स करने पर एक ही वाक्य दो बार न दिखे।\n\nयह केवल तब लागू होता है जब «स्रोत» में माइक्रोफ़ोन और सिस्टम ऑडियो दोनों शामिल हों (मिश्रित मोड); प्रोसेसिंग विफल होने पर मूल ट्रैक ही रहता है, रिकॉर्डिंग नहीं जाती।',
    'ใช้เสียงระบบเป็นข้อมูลอ้างอิงเพื่อลบเสียงปลายทางที่รั่วเข้ามาในแทร็กไมโครโฟนผ่านลำโพง เพื่อไม่ให้ประโยคเดียวกันปรากฏซ้ำสองครั้งหลังมิกซ์\n\nใช้ได้เฉพาะเมื่อ «แหล่ง» มีทั้งไมโครโฟนและเสียงระบบ (โหมดผสม) เท่านั้น หากประมวลผลล้มเหลวจะใช้แทร็กต้นฉบับต่อไป การบันทึกจะไม่สูญหาย',
    'Dùng âm thanh hệ thống làm tham chiếu để loại bỏ âm thanh đầu xa lọt vào track micrô qua loa, tránh cùng một câu xuất hiện hai lần sau khi trộn.\n\nChỉ áp dụng khi «Nguồn» gồm cả micrô và âm thanh hệ thống (chế độ hỗn hợp); nếu xử lý thất bại, track gốc được giữ nguyên, bản ghi không bị mất.',
    'Memakai audio sistem sebagai referensi untuk menghapus suara ujung jauh yang bocor ke trek mikrofon lewat pengeras suara, agar kalimat yang sama tidak muncul dua kali setelah pencampuran.\n\nHanya berlaku bila «Sumber» mencakup mikrofon dan audio sistem (mode campuran); jika pemrosesan gagal, trek asli tetap dipakai dan rekaman tidak hilang.',
    'Hoparlör üzerinden mikrofon kanalına sızan uzak taraf sesini, sistem sesini referans alarak kaldırır; böylece aynı cümle mikslemeden sonra iki kez görünmez.\n\nYalnızca «Kaynak» hem mikrofonu hem sistem sesini içerdiğinde (karışık mod) geçerlidir; işleme başarısız olursa özgün kanal korunur, kayıt kaybolmaz.',
    'Gebruikt de systeemaudio als referentie om geluid van de andere kant te verwijderen dat via de luidsprekers in het microfoonspoor is gelekt, zodat dezelfde zin na het mixen niet twee keer voorkomt.\n\nAlleen van toepassing als «Bron» zowel microfoon als systeemaudio bevat (gemengde modus); mislukt de verwerking, dan blijft het oorspronkelijke spoor behouden en gaat er geen opname verloren.',
    'Używa dźwięku systemowego jako odniesienia, aby usunąć dźwięk drugiej strony, który przez głośniki przedostał się do ścieżki mikrofonu — dzięki temu to samo zdanie nie pojawi się dwukrotnie po zmiksowaniu.\n\nDziała tylko wtedy, gdy «Źródło» obejmuje mikrofon i dźwięk systemowy (tryb mieszany); jeśli przetwarzanie się nie powiedzie, zachowywana jest oryginalna ścieżka i nagranie nie ginie.',
    'Використовує системний звук як опорний сигнал, щоб прибрати далекий звук, який через динаміки потрапив у дорожку мікрофона, — одна й та сама фраза не дублюватиметься після зведення.\n\nДіє лише коли «Джерело» містить і мікрофон, і системний звук (змішаний режим); у разі збою обробки залишається вихідна дорожка, запис не втрачається.',
    'Använder systemljudet som referens för att ta bort fjärrljud som läckt in i mikrospåret via högtalarna, så att samma mening inte förekommer två gånger efter mixning.\n\nGäller bara när «Källa» innehåller både mikrofon och systemljud (blandat läge); om bearbetningen misslyckas behålls originalspåret och ingen inspelning går förlorad.',
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