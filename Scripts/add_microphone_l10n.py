#!/usr/bin/env python3
# 麦克风设备选择：界面文案 20 种语言
#
# 与其它 add_*_l10n.py 的差别：这些 key 已被 Xcode 自动抽取进 Catalog（空条目），
# 因此这里不是「跳过已存在」，而是「补全缺失的 localizations」，并清掉 extractionState。
import json
import re

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('麦克风', [
    '麥克風',
    'Microphone',
    'マイク',
    '마이크',
    'Microphone',
    'Mikrofon',
    'Micrófono',
    'Microfono',
    'Microfone',
    'Микрофон',
    'الميكروفون',
    'माइक्रोफ़ोन',
    'ไมโครโฟน',
    'Micrô',
    'Mikrofon',
    'Mikrofon',
    'Microfoon',
    'Mikrofon',
    'Мікрофон',
    'Mikrofon',
])

add('跟随系统默认', [
    '跟隨系統預設',
    'Follow System Default',
    'システムのデフォルトに従う',
    '시스템 기본값 따르기',
    'Suivre la valeur par défaut du système',
    'Systemstandard folgen',
    'Seguir el valor predeterminado del sistema',
    'Segui il valore predefinito di sistema',
    'Seguir o padrão do sistema',
    'Как в системе по умолчанию',
    'اتباع الإعداد الافتراضي للنظام',
    'सिस्टम डिफ़ॉल्ट का पालन करें',
    'ใช้ค่าเริ่มต้นของระบบ',
    'Theo mặc định hệ thống',
    'Ikuti Default Sistem',
    'Sistem Varsayılanını Kullan',
    'Systeemstandaard volgen',
    'Zgodnie z domyślnym systemowym',
    'Як у системі (типово)',
    'Följ systemstandard',
])

add('输入设备', [
    '輸入裝置',
    'Input Device',
    '入力デバイス',
    '입력 장치',
    "Périphérique d'entrée",
    'Eingabegerät',
    'Dispositivo de entrada',
    'Dispositivo di input',
    'Dispositivo de entrada',
    'Устройство ввода',
    'جهاز الإدخال',
    'इनपुट डिवाइस',
    'อุปกรณ์อินพุต',
    'Thiết bị đầu vào',
    'Perangkat Input',
    'Giriş Aygıtı',
    'Invoerapparaat',
    'Urządzenie wejściowe',
    'Пристрій введення',
    'Indataenhet',
])

add('已断开，将回退系统默认', [
    '已中斷連線，將改回系統預設',
    'Disconnected, will fall back to the system default',
    '切断されました（システムのデフォルトに戻ります）',
    '연결 해제됨, 시스템 기본값으로 대체됩니다',
    'Déconnecté, retour au périphérique système par défaut',
    'Getrennt, verwendet wieder den Systemstandard',
    'Desconectado, se usará el valor predeterminado del sistema',
    'Disconnesso, verrà usato il valore predefinito di sistema',
    'Desconectado, voltará ao padrão do sistema',
    'Отключено, будет использоваться устройство по умолчанию',
    'تم قطع الاتصال، سيتم الرجوع إلى الإعداد الافتراضي للنظام',
    'डिस्कनेक्ट हो गया, सिस्टम डिफ़ॉल्ट पर वापस जाएगा',
    'ตัดการเชื่อมต่อแล้ว จะกลับไปใช้ค่าเริ่มต้นของระบบ',
    'Đã ngắt kết nối, sẽ quay về mặc định hệ thống',
    'Terputus, akan kembali ke default sistem',
    'Bağlantı kesildi, sistem varsayılanına dönülecek',
    'Verbinding verbroken, valt terug op systeemstandaard',
    'Rozłączono, powrót do domyślnego systemowego',
    'Від’єднано, буде використано пристрій за замовчуванням',
    'Frånkopplad, återgår till systemstandard',
])

add('所选麦克风不提供系统静音属性，「自动检测系统静音」对它无效。', [
    '所選麥克風不提供系統靜音屬性，「自動偵測系統靜音」對它無效。',
    'The selected microphone does not expose a system mute property, so “Auto-detect system mute” has no effect on it.',
    '選択したマイクはシステムミュート属性を提供しないため、「システムミュートを自動検出」は機能しません。',
    '선택한 마이크는 시스템 음소거 속성을 제공하지 않으므로 ‘시스템 음소거 자동 감지’가 적용되지 않습니다.',
    "Le microphone sélectionné n'expose pas de propriété de muet système ; « Détection automatique du muet » n'a donc aucun effet.",
    'Das ausgewählte Mikrofon bietet keine System-Stummschaltung, daher wirkt „Systemstummschaltung automatisch erkennen“ nicht.',
    'El micrófono seleccionado no expone una propiedad de silencio del sistema, por lo que «Detectar silencio del sistema» no tiene efecto.',
    'Il microfono selezionato non espone una proprietà di mute di sistema, quindi «Rilevamento automatico del mute» non ha effetto.',
    'O microfone selecionado não expõe a propriedade de mudo do sistema, portanto «Detetar mudo do sistema automaticamente» não tem efeito.',
    'Выбранный микрофон не поддерживает системное отключение звука, поэтому «Автоопределение системного отключения» для него не работает.',
    'الميكروفون المحدد لا يوفر خاصية كتم الصوت على مستوى النظام، لذا فإن «الكشف التلقائي عن كتم النظام» لا يؤثر عليه.',
    'चुना गया माइक्रोफ़ोन सिस्टम म्यूट प्रॉपर्टी नहीं देता, इसलिए “सिस्टम म्यूट का स्वतः पता लगाएँ” उस पर काम नहीं करेगा।',
    'ไมโครโฟนที่เลือกไม่มีคุณสมบัติปิดเสียงระดับระบบ ดังนั้น «ตรวจจับการปิดเสียงของระบบอัตโนมัติ» จึงไม่มีผล',
    'Micrô đã chọn không hỗ trợ thuộc tính tắt tiếng hệ thống, nên «Tự phát hiện tắt tiếng hệ thống» không có tác dụng.',
    'Mikrofon yang dipilih tidak menyediakan properti bisu sistem, sehingga «Deteksi otomatis bisu sistem» tidak berlaku.',
    'Seçilen mikrofon sistem sessize alma özelliği sunmuyor, bu nedenle «Sistem sesini otomatik algıla» etkisizdir.',
    'De gekozen microfoon biedt geen systeem-dempingseigenschap, dus «Systeemdempen automatisch detecteren» heeft geen effect.',
    'Wybrany mikrofon nie udostępnia właściwości wyciszenia systemowego, więc „Automatyczne wykrywanie wyciszenia systemu” nie działa.',
    'Вибраний мікрофон не підтримує системне вимкнення звуку, тому «Автовизначення системного вимкнення» для нього не діє.',
    'Den valda mikrofonen saknar systemdämpning, så «Upptäck systemdämpning automatiskt» har ingen effekt.',
])

add('麦克风：%@', [
    '麥克風：%@',
    'Microphone: %@',
    'マイク：%@',
    '마이크: %@',
    'Microphone : %@',
    'Mikrofon: %@',
    'Micrófono: %@',
    'Microfono: %@',
    'Microfone: %@',
    'Микрофон: %@',
    'الميكروفون: %@',
    'माइक्रोफ़ोन: %@',
    'ไมโครโฟน: %@',
    'Micrô: %@',
    'Mikrofon: %@',
    'Mikrofon: %@',
    'Microfoon: %@',
    'Mikrofon: %@',
    'Мікрофон: %@',
    'Mikrofon: %@',
])

# 9.1.0：录音徽章的麦克风入口由一个菜单同时承担「静音 / 解除静音」与「选择输入设备」，
# 这里补上菜单项与悬浮提示的文案（原先那几个字符串是裸 String，从未进过 Catalog）
add('静音麦克风', [
    '靜音麥克風',
    'Mute Microphone',
    'マイクをミュート',
    '마이크 음소거',
    'Couper le microphone',
    'Mikrofon stummschalten',
    'Silenciar micrófono',
    'Disattiva microfono',
    'Silenciar microfone',
    'Отключить микрофон',
    'كتم الميكروفون',
    'माइक्रोफ़ोन म्यूट करें',
    'ปิดไมโครโฟน',
    'Tắt tiếng micrô',
    'Bisukan mikrofon',
    'Mikrofonu sessize al',
    'Microfoon dempen',
    'Wycisz mikrofon',
    'Вимкнути мікрофон',
    'Stäng av mikrofonen',
])

add('解除静音', [
    '解除靜音',
    'Unmute',
    'ミュートを解除',
    '음소거 해제',
    'Réactiver le son',
    'Stummschaltung aufheben',
    'Activar sonido',
    'Riattiva audio',
    'Reativar som',
    'Включить микрофон',
    'إلغاء الكتم',
    'अनम्यूट करें',
    'เลิกปิดไมโครโฟน',
    'Bỏ tắt tiếng',
    'Batal bisukan',
    'Sesi aç',
    'Dempen opheffen',
    'Włącz dźwięk',
    'Увімкнути звук',
    'Slå på ljudet',
])

add('系统静音中，需在系统中解除', [
    '系統靜音中，需在系統中解除',
    'Muted by the system — turn it off in System Settings',
    'システムでミュート中。システム側で解除してください',
    '시스템에서 음소거 중입니다. 시스템에서 해제하세요',
    'Coupé par le système — désactivez-le dans les Réglages Système',
    'Vom System stummgeschaltet – in den Systemeinstellungen aufheben',
    'Silenciado por el sistema: desactívalo en Ajustes del Sistema',
    'Disattivato dal sistema: riattivalo nelle Impostazioni di Sistema',
    'Silenciado pelo sistema — desative nos Ajustes do Sistema',
    'Микрофон отключён системой — включите его в «Системных настройках»',
    'تم الكتم بواسطة النظام — أوقفه من إعدادات النظام',
    'सिस्टम द्वारा म्यूट — इसे सिस्टम सेटिंग्स में बंद करें',
    'ถูกปิดโดยระบบ — เปิดคืนได้ในการตั้งค่าระบบ',
    'Bị hệ thống tắt tiếng — hãy bật lại trong Cài đặt hệ thống',
    'Dibisukan oleh sistem — matikan di Pengaturan Sistem',
    "Sistem tarafından sessize alındı — Sistem Ayarları'ndan açın",
    'Gedempt door het systeem — schakel dit uit in Systeeminstellingen',
    'Wyciszone przez system — wyłącz to w Ustawieniach systemowych',
    'Вимкнено системою — увімкніть у «Системних налаштуваннях»',
    'Avstängt av systemet – stäng av det i Systeminställningar',
])

add('会议软件静音中，需在会议软件内解除', [
    '會議軟體靜音中，需在會議軟體內解除',
    'Muted by the meeting app — turn it off inside that app',
    '会議アプリでミュート中。会議アプリ側で解除してください',
    '회의 앱에서 음소거 중입니다. 해당 앱에서 해제하세요',
    "Coupé par l'application de réunion — désactivez-le dans cette application",
    'Von der Besprechungs-App stummgeschaltet – dort aufheben',
    'Silenciado por la app de reunión: desactívalo en esa app',
    "Disattivato dall'app di riunione: riattivalo in quell'app",
    'Silenciado pelo app de reunião — desative nesse app',
    'Микрофон отключён приложением встречи — включите его там',
    'تم الكتم بواسطة تطبيق الاجتماع — أوقفه من داخل التطبيق',
    'मीटिंग ऐप द्वारा म्यूट — इसे उस ऐप में बंद करें',
    'ถูกปิดโดยแอปประชุม — เปิดคืนได้ในแอปนั้น',
    'Bị ứng dụng họp tắt tiếng — hãy bật lại trong ứng dụng đó',
    'Dibisukan oleh aplikasi rapat — matikan di aplikasi tersebut',
    'Toplantı uygulaması tarafından sessize alındı — o uygulamadan açın',
    'Gedempt door de vergaderapp — schakel dit uit in die app',
    'Wyciszone przez aplikację do spotkań — wyłącz to w tej aplikacji',
    'Вимкнено застосунком зустрічі — увімкніть його там',
    'Avstängt av mötesappen – stäng av det i den appen',
])


def write_catalog(catalog):
    """按 Xcode 写回 Localizable.xcstrings 的实际格式落盘。

    `json.dump` 的默认写法与 Xcode 不一致（键值分隔符是 `": "` 而不是 `" : "`，
    空对象写成 `{}` 而不是展开为多一行），直接 dump 会让整个文件产生十万行级的
    无意义 diff——只新增几条键，看起来却像全文重写。这里逐行还原 Xcode 的格式：
    - 键值分隔符统一为 `" : "`
    - 空对象展开为 `{` / 空行 / `}` 三行（Apple 的写法）
    - 文件末尾不补换行（Xcode 也不补）
    - 每个条目的 `localizations` 子键按字母序排列：Xcode 就是这么写的，
      而我们按「zh-Hans 在前、其余按语言表顺序」插入，不排一下会把整条重写
    """
    # JSON 对象本身无序，但 git diff 与 Xcode 都按字母序看，这里对齐
    for entry in catalog.get('strings', {}).values():
        locs = entry.get('localizations')
        if isinstance(locs, dict):
            entry['localizations'] = {k: locs[k] for k in sorted(locs)}

    raw = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False)
    lines = []
    for line in raw.split('\n'):
        empty_object = re.match(r'^(\s*)"([^"]*)": \{\}(,?)$', line)
        if empty_object:
            indent, key, comma = empty_object.groups()
            lines.extend([f'{indent}"{key}" : {{', '', f'{indent}}}{comma}'])
            continue
        pair = re.match(r'^(\s*)"([^"]*)": (.*)$', line)
        if pair:
            indent, key, value = pair.groups()
            lines.append(f'{indent}"{key}" : {value}')
            continue
        lines.append(line)
    with open(CATALOG, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


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
        # 源语言 zh-Hans 与既有条目格式一致（值 = Key 本身）
        entry['localizations'] = {
            'zh-Hans': {'stringUnit': {'state': 'translated', 'value': key}},
        }
        for lang, val in zip(LANGS, vals):
            entry['localizations'][lang] = {'stringUnit': {'state': 'translated', 'value': val}}
        entry.pop('extractionState', None)

    write_catalog(catalog)
    print(f'完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
