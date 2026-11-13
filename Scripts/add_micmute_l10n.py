#!/usr/bin/env python3
# 麦克风静音选项：录音开始时静音 + 各处菜单命令 文案 20 种语言
# 与 add_micdocs_l10n.py 同一合并策略（补全已被自动抽取的空条目）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('录音开始时静音麦克风', [
    '錄音開始時靜音麥克風',
    'Mute microphone when recording starts',
    '録音開始時にマイクをミュート',
    '녹음 시작 시 마이크 음소거',
    "Couper le micro au début de l'enregistrement",
    'Mikrofon zu Beginn der Aufnahme stummschalten',
    'Silenciar el micrófono al iniciar la grabación',
    'Disattiva il microfono all’avvio della registrazione',
    'Silenciar o microfone ao iniciar a gravação',
    'Отключать микрофон в начале записи',
    'كتم الميكروفون عند بدء التسجيل',
    'रिकॉर्डिंग शुरू होने पर माइक्रोफ़ोन म्यूट करें',
    'ปิดเสียงไมโครโฟนเมื่อเริ่มบันทึก',
    'Tắt tiếng micrô khi bắt đầu ghi âm',
    'Bisukan mikrofon saat perekaman dimulai',
    'Kayıt başlarken mikrofonu sessize al',
    'Microfoon dempen bij de start van de opname',
    'Wycisz mikrofon na rozpoczęciu nagrywania',
    'Вимкнути мікрофон на початку запису',
    'Stäng av mikrofonen när inspelningen börjar',
])

add('开启后，每次开始录音或录屏都会先静音麦克风采集；录音中可在录音状态徽章或菜单栏「麦克风」里随时解除。', [
    '開啟後，每次開始錄音或錄影都會先將麥克風靜音；錄音中可隨時在錄音狀態徽章或選單列「麥克風」中解除。',
    'When on, every recording or screen recording starts with the microphone muted; you can unmute at any time from the recording badge or the Microphone menu in the menu bar.',
    'オンにすると、録音・画面収録のたびにマイクをミュートした状態で開始します。録音中は録音バッジまたはメニューバーの「マイク」からいつでも解除できます。',
    '켜면 녹음이나 화면 녹화를 시작할 때마다 마이크가 음소거된 상태로 시작합니다. 녹음 중에는 녹음 배지나 메뉴 막대의 ‘마이크’에서 언제든지 해제할 수 있습니다.',
    "Si cette option est activée, chaque enregistrement (audio ou écran) démarre avec le micro coupé ; vous pouvez le réactiver à tout moment depuis le badge d'enregistrement ou le menu « Microphone » de la barre des menus.",
    'Ist die Option aktiv, startet jede Aufnahme (Audio oder Bildschirm) mit stummgeschaltetem Mikrofon; über das Aufnahme-Badge oder das Menü „Mikrofon“ in der Menüleiste lässt es sich jederzeit wieder aktivieren.',
    'Si está activado, cada grabación (audio o pantalla) empieza con el micrófono silenciado; puedes reactivarlo cuando quieras desde la insignia de grabación o el menú «Micrófono» de la barra de menús.',
    'Se attiva, ogni registrazione (audio o schermo) inizia con il microfono disattivato; puoi riattivarlo in qualsiasi momento dal badge di registrazione o dal menu «Microfono» nella barra dei menu.',
    'Se ativado, cada gravação (áudio ou ecrã) começa com o microfone silenciado; pode reativá-lo a qualquer momento no distintivo de gravação ou no menu «Microfone» da barra de menus.',
    'Если включено, каждая запись (звук или экран) начинается с отключённым микрофоном; включить его можно в любой момент из значка записи или меню «Микрофон» в строке меню.',
    'عند التفعيل، يبدأ كل تسجيل (صوت أو شاشة) والميكروفون مكتوم؛ ويمكنك إلغاء الكتم في أي وقت من شارة التسجيل أو قائمة «الميكروفون» في شريط القوائم.',
    'चालू होने पर हर रिकॉर्डिंग (ऑडियो या स्क्रीन) माइक्रोफ़ोन म्यूट के साथ शुरू होती है; रिकॉर्डिंग बैज या मेन्यू बार के «माइक्रोफ़ोन» से कभी भी अनम्यूट कर सकते हैं।',
    'เมื่อเปิด ทุกการบันทึก (เสียงหรือหน้าจอ) จะเริ่มต้นโดยปิดเสียงไมโครโฟนไว้ก่อน คุณยกเลิกการปิดเสียงได้ทุกเมื่อจากป้ายบันทึกหรือเมนู «ไมโครโฟน» บนแถบเมนู',
    'Khi bật, mỗi lần ghi âm hoặc ghi màn hình đều bắt đầu với micrô đã tắt tiếng; bạn có thể bật lại bất cứ lúc nào từ huy hiệu ghi âm hoặc menu «Micrô» trên thanh menu.',
    'Jika aktif, setiap perekaman (audio atau layar) dimulai dengan mikrofon dibisukan; Anda dapat mengaktifkannya kembali kapan saja dari lencana perekaman atau menu «Mikrofon» di bilah menu.',
    'Açıkken her kayıt (ses veya ekran) mikrofon sessiz başlar; kayıt rozetinden veya menü çubuğundaki «Mikrofon» menüsünden istediğiniz zaman sessizliği kaldırabilirsiniz.',
    'Als dit aan staat, begint elke opname (audio of scherm) met gedempte microfoon; je kunt het dempen op elk moment opheffen via de opnamebadge of het menu «Microfoon» in de menubalk.',
    'Gdy włączone, każde nagranie (dźwięk lub ekran) rozpoczyna się z wyciszonym mikrofonem; możesz go włączyć w dowolnej chwili z plakietki nagrywania lub menu „Mikrofon” w pasku menu.',
    'Якщо ввімкнено, кожен запис (звук або екран) починається з вимкненим мікрофоном; увімкнути його можна будь-коли зі значка запису або меню «Мікрофон» у рядку меню.',
    'När detta är på startar varje inspelning (ljud eller skärm) med mikrofonen avstängd; du kan slå på den igen när som helst via inspelningsmärket eller menyn «Mikrofon» i menyraden.',
])

add('录音时静音', [
    '錄音時靜音',
    'Muted while recording',
    '録音中はミュート',
    '녹음 중 음소거',
    "Micro coupé pendant l'enregistrement",
    'Während der Aufnahme stumm',
    'Silenciado durante la grabación',
    'Disattivato durante la registrazione',
    'Silenciado durante a gravação',
    'Без звука во время записи',
    'مكتوم أثناء التسجيل',
    'रिकॉर्डिंग के दौरान म्यूट',
    'ปิดเสียงขณะบันทึก',
    'Tắt tiếng khi ghi',
    'Dibisukan saat merekam',
    'Kayıt sırasında sessiz',
    'Gedempt tijdens opname',
    'Wyciszony podczas nagrywania',
    'Без звуку під час запису',
    'Avstängd under inspelning',
])

add('录音开始后可静音麦克风', [
    '錄音開始後可靜音麥克風',
    'You can mute the microphone once recording starts',
    '録音開始後にマイクをミュートできます',
    '녹음이 시작된 후 마이크를 음소거할 수 있습니다',
    "Vous pourrez couper le micro une fois l'enregistrement lancé",
    'Nach Aufnahmebeginn lässt sich das Mikrofon stummschalten',
    'Podrás silenciar el micrófono cuando empiece la grabación',
    'Potrai disattivare il microfono dopo l’avvio della registrazione',
    'Poderá silenciar o microfone depois de iniciar a gravação',
    'Микрофон можно отключить после начала записи',
    'يمكنك كتم الميكروفون بعد بدء التسجيل',
    'रिकॉर्डिंग शुरू होने के बाद माइक्रोफ़ोन म्यूट कर सकते हैं',
    'ปิดเสียงไมโครโฟนได้เมื่อเริ่มบันทึกแล้ว',
    'Có thể tắt tiếng micrô sau khi bắt đầu ghi',
    'Mikrofon dapat dibisukan setelah perekaman dimulai',
    'Kayıt başladıktan sonra mikrofonu sessize alabilirsiniz',
    'Na de start van de opname kun je de microfoon dempen',
    'Po rozpoczęciu nagrywania możesz wyciszyć mikrofon',
    'Мікрофон можна вимкнути після початку запису',
    'Du kan stänga av mikrofonen när inspelningen har börjat',
])

# 菜单栏状态项改用与录音徽章共用的「已静音」口径，这条旧文案不再被源码引用
REMOVED_KEYS = ['已手动静音']


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

    for key in REMOVED_KEYS:
        existing.pop(key, None)

    with open(CATALOG, 'w', encoding='utf-8') as f:
        # 按 Xcode 自己的序列化风格写回（`"key" : value` 的空格、无结尾换行）：
        # Python 默认风格会让整个目录在 diff 里变成「全文件重写」，掩盖真正的文案改动
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(',', ' : '))
    print(f'完成：新增 {added} 条，补译 {filled} 条，移除 {len(REMOVED_KEYS)} 条')


if __name__ == '__main__':
    main()
