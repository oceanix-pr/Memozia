#!/usr/bin/env python3
# 大模型配置导入导出（改为设备密钥自动加解密）：新增文案 20 种语言 + 清理口令方案遗留的死 key
#
# 新增策略同前几个脚本：已完整翻译（>=21 条）的 key 保持原样不清洗。
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

# 口令方案（PassphraseCrypto）已移除，这些 key 不再被任何代码引用
DEAD_KEYS = [
    '导出为口令加密文件（含 API Key），请牢记口令；导入时用同一口令解开。',
    '设定导出密码',
    '输入导入密码',
    '导出文件包含 API Key，将用此密码加密（至少 8 位）。密码只保存在你脑中，忘记后无法恢复。',
    '该文件已加密，请输入导出时设定的密码。',
    '口令错误或文件已损坏',
    '不支持的加密文件格式',
    '密钥派生失败',
    '「设置 → 大模型 → 配置迁移」可导出/导入模型配置（含 API Key），导出文件用你设定的口令加密，便于换机迁移；口令请牢记，忘记后无法恢复',
    '「设置 → 大模型 → 配置迁移」导出的文件包含你的 API Key，会用你设定的口令做 PBKDF2 + AES-GCM 加密，再保存到你选择的位置。口令不写入文件、不上传，仅用于本机加解密；请妥善保管口令，忘记后将无法再打开该文件。',
]

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('导出文件会自动加密（与本地数据同一把密钥），只有本机 Memozia 能解开。', [
    '匯出檔會自動加密（與本機資料同一把金鑰），只有本機 Memozia 能解開。',
    'Exported files are encrypted automatically with the same key as your local data, so only Memozia on this Mac can open them.',
    '書き出したファイルはローカルデータと同じ鍵で自動的に暗号化されます。開けるのは本機の Memozia だけです。',
    '내보낸 파일은 로컬 데이터와 같은 키로 자동 암호화되며, 이 Mac의 Memozia에서만 열 수 있습니다.',
    'Les fichiers exportés sont chiffrés automatiquement avec la même clé que vos données locales : seul Memozia sur ce Mac peut les ouvrir.',
    'Exportierte Dateien werden automatisch mit demselben Schlüssel wie Ihre lokalen Daten verschlüsselt; nur Memozia auf diesem Mac kann sie öffnen.',
    'Los archivos exportados se cifran automáticamente con la misma clave que tus datos locales, así que solo Memozia en este Mac puede abrirlos.',
    'I file esportati vengono cifrati automaticamente con la stessa chiave dei tuoi dati locali: solo Memozia su questo Mac può aprirli.',
    'Os ficheiros exportados são cifrados automaticamente com a mesma chave dos seus dados locais; só o Memozia neste Mac os pode abrir.',
    'Экспортированные файлы шифруются автоматически тем же ключом, что и локальные данные, поэтому открыть их может только Memozia на этом Mac.',
    'تُشفَّر الملفات المُصدَّرة تلقائيًا بالمفتاح نفسه المستخدم لبياناتك المحلية، لذلك لا يمكن فتحها إلا في Memozia على هذا الجهاز.',
    'निर्यातित फ़ाइलें आपके स्थानीय डेटा की उसी कुंजी से स्वतः एन्क्रिप्ट होती हैं, इसलिए इन्हें केवल इस Mac के Memozia में ही खोला जा सकता है।',
    'ไฟล์ที่ส่งออกจะถูกเข้ารหัสอัตโนมัติด้วยคีย์เดียวกับข้อมูลในเครื่อง จึงเปิดได้เฉพาะใน Memozia บนเครื่องนี้เท่านั้น',
    'Tệp xuất được mã hóa tự động bằng cùng khóa với dữ liệu trên máy, nên chỉ Memozia trên máy này mở được.',
    'File ekspor otomatis dienkripsi dengan kunci yang sama seperti data lokal, jadi hanya Memozia di Mac ini yang dapat membukanya.',
    'Dışa aktarılan dosyalar yerel verilerinizle aynı anahtarla otomatik şifrelenir; bu nedenle yalnızca bu Mac’teki Memozia açabilir.',
    'Geëxporteerde bestanden worden automatisch versleuteld met dezelfde sleutel als je lokale gegevens; alleen Memozia op deze Mac kan ze openen.',
    'Eksportowane pliki są automatycznie szyfrowane tym samym kluczem co dane lokalne, więc otworzy je tylko Memozia na tym Macu.',
    'Експортовані файли шифруються автоматично тим самим ключем, що й локальні дані, тож відкрити їх може лише Memozia на цьому Mac.',
    'Exporterade filer krypteras automatiskt med samma nyckel som dina lokala data, så bara Memozia på den här Macen kan öppna dem.',
])

add('该文件无法在本机解密：可能由其他 Mac 导出，或文件已损坏。', [
    '該檔案無法在本機解密：可能由其他 Mac 匯出，或檔案已損壞。',
    'This file cannot be decrypted on this Mac: it may have been exported from another Mac, or the file is damaged.',
    'このファイルは本機では復号できません。別の Mac で書き出されたか、ファイルが壊れている可能性があります。',
    '이 파일은 이 Mac에서 복호화할 수 없습니다. 다른 Mac에서 내보냈거나 파일이 손상되었을 수 있습니다.',
    "Ce fichier ne peut pas être déchiffré sur ce Mac : il provient peut-être d'un autre Mac, ou il est endommagé.",
    'Diese Datei kann auf diesem Mac nicht entschlüsselt werden — sie stammt möglicherweise von einem anderen Mac oder ist beschädigt.',
    'Este archivo no se puede descifrar en este Mac: puede proceder de otro Mac o estar dañado.',
    'Questo file non può essere decifrato su questo Mac: potrebbe provenire da un altro Mac o essere danneggiato.',
    'Este ficheiro não pode ser decifrado neste Mac: pode ter sido exportado de outro Mac ou estar danificado.',
    'Этот файл нельзя расшифровать на этом Mac: возможно, он экспортирован с другого Mac или повреждён.',
    'تعذّر فك تشفير هذا الملف على هذا الجهاز: ربما صُدِّر من Mac آخر أو أن الملف تالف.',
    'यह फ़ाइल इस Mac पर डिक्रिप्ट नहीं हो सकती: यह किसी अन्य Mac से निर्यात की गई हो सकती है या फ़ाइल ख़राब है।',
    'ไฟล์นี้ถอดรหัสบนเครื่องนี้ไม่ได้ อาจส่งออกจาก Mac เครื่องอื่นหรือไฟล์เสียหาย',
    'Không thể giải mã tệp này trên máy này: có thể tệp được xuất từ Mac khác hoặc đã hỏng.',
    'File ini tidak dapat didekripsi di Mac ini: mungkin diekspor dari Mac lain atau file rusak.',
    'Bu dosya bu Mac’te çözülemiyor: başka bir Mac’ten aktarılmış veya bozulmuş olabilir.',
    'Dit bestand kan niet op deze Mac worden ontsleuteld: het is mogelijk op een andere Mac geëxporteerd of beschadigd.',
    'Nie można odszyfrować tego pliku na tym Macu: pochodzi z innego Maca albo jest uszkodzony.',
    'Цей файл неможливо розшифрувати на цьому Mac: можливо, його експортовано з іншого Mac або файл пошкоджено.',
    'Filen kan inte dekrypteras på den här Macen: den kan komma från en annan Mac eller vara skadad.',
])

add('「设置 → 大模型 → 配置迁移」可导出/导入模型配置（含 API Key），导出文件自动加密、无需设密码，但只能在本机 Memozia 导入', [
    '「設定 → 大模型 → 設定遷移」可匯出/匯入模型設定（含 API Key），匯出檔自動加密、無需設密碼，但只能在本機 Memozia 匯入',
    'Use “Settings → LLM → Config Transfer” to export/import model configs (including API keys). The file is encrypted automatically with no passphrase, but can only be imported by Memozia on this Mac.',
    '「設定 → 大規模モデル → 設定の移行」でモデル設定（API キーを含む）を書き出し/読み込みできます。書き出したファイルは自動で暗号化され（合言葉不要）、本機の Memozia でしか読み込めません。',
    '‘설정 → 대형 모델 → 설정 이전’에서 모델 설정(API 키 포함)을 내보내기/가져오기할 수 있습니다. 내보낸 파일은 자동으로 암호화되며(암호 불필요) 이 Mac의 Memozia에서만 가져올 수 있습니다.',
    "« Réglages → Grand modèle → Transfert de configuration » permet d'exporter/importer les configurations (clés API incluses). Le fichier est chiffré automatiquement, sans mot de passe, mais seul Memozia sur ce Mac peut l'importer.",
    'Unter „Einstellungen → LLM → Konfigurationsübertragung“ lassen sich Modellkonfigurationen (inkl. API-Schlüssel) ex- und importieren. Die Datei wird automatisch verschlüsselt (ohne Passphrase), kann aber nur von Memozia auf diesem Mac importiert werden.',
    'En «Ajustes → Modelo → Transferencia de configuración» puedes exportar/importar configuraciones (claves de API incluidas). El archivo se cifra automáticamente, sin contraseña, pero solo Memozia en este Mac puede importarlo.',
    'In «Impostazioni → Modello → Trasferimento configurazione» puoi esportare/importare le configurazioni (chiavi API incluse). Il file è cifrato automaticamente, senza passphrase, ma può essere importato solo da Memozia su questo Mac.',
    'Em «Definições → Modelo → Transferência de configuração» pode exportar/importar configurações (chaves de API incluídas). O ficheiro é cifrado automaticamente, sem palavra-passe, mas só o Memozia neste Mac o pode importar.',
    'В «Настройки → Модель → Перенос настроек» можно экспортировать/импортировать конфигурации (включая API-ключи). Файл шифруется автоматически, без пароля, но импортировать его может только Memozia на этом Mac.',
    'من «الإعدادات → النموذج → نقل الإعدادات» يمكنك تصدير/استيراد إعدادات النموذج (مع مفاتيح API). يُشفَّر الملف تلقائيًا دون عبارة مرور، لكن لا يمكن استيراده إلا في Memozia على هذا الجهاز.',
    '«सेटिंग्स → मॉडल → कॉन्फ़िगरेशन स्थानांतरण» से मॉडल कॉन्फ़िगरेशन (API कुंजियों सहित) निर्यात/आयात करें। फ़ाइल स्वतः एन्क्रिप्ट होती है (पासफ़्रेज़ की ज़रूरत नहीं), पर इसे केवल इस Mac के Memozia में ही आयात किया जा सकता है।',
    'ที่ «การตั้งค่า → โมเดล → การย้ายการตั้งค่า» ส่งออก/นำเข้าการตั้งค่าโมเดล (รวม API Key) ไฟล์จะถูกเข้ารหัสอัตโนมัติ (ไม่ต้องใช้รหัสผ่าน) แต่นำเข้าได้เฉพาะใน Memozia บนเครื่องนี้เท่านั้น',
    'Tại «Cài đặt → Mô hình → Chuyển cấu hình» bạn có thể xuất/nhập cấu hình mô hình (gồm khóa API). Tệp được mã hóa tự động, không cần mật khẩu, nhưng chỉ Memozia trên máy này mới nhập được.',
    'Di «Pengaturan → Model → Transfer Konfigurasi» Anda dapat mengekspor/mengimpor konfigurasi model (termasuk kunci API). File dienkripsi otomatis tanpa frasa sandi, tetapi hanya Memozia di Mac ini yang dapat mengimpornya.',
    '«Ayarlar → Model → Yapılandırma Aktarımı» ile model yapılandırmalarını (API anahtarları dahil) dışa/içe aktarın. Dosya otomatik şifrelenir (parola gerekmez), ancak yalnızca bu Mac’teki Memozia içe aktarabilir.',
    'Via «Instellingen → Model → Configuratie overdragen» kun je modelconfiguraties (inclusief API-sleutels) exporteren/importeren. Het bestand wordt automatisch versleuteld (geen wachtwoordzin nodig), maar alleen Memozia op deze Mac kan het importeren.',
    'W „Ustawienia → Model → Przenoszenie konfiguracji” możesz eksportować/importować konfiguracje (także klucze API). Plik jest szyfrowany automatycznie (bez hasła), ale zaimportuje go tylko Memozia na tym Macu.',
    'У «Налаштування → Модель → Перенесення налаштувань» можна експортувати/імпортувати конфігурації (разом із ключами API). Файл шифрується автоматично, без пароля, але імпортувати його може лише Memozia на цьому Mac.',
    'Under «Inställningar → Modell → Överför konfiguration» kan du exportera/importera modellkonfigurationer (inklusive API-nycklar). Filen krypteras automatiskt utan lösenordsfras, men kan bara importeras av Memozia på den här Macen.',
])

add('「设置 → 大模型 → 配置迁移」导出的文件包含你的 API Key，会用本机密钥自动加密（与本地数据同一套，密钥保存在系统钥匙串），再保存到你选择的位置；因为没有额外口令，该文件只能在本机 Memozia 导入。密钥不会上传，文件请妥善保管。', [
    '「設定 → 大模型 → 設定遷移」匯出的檔案包含你的 API Key，會用本機金鑰自動加密（與本機資料同一套，金鑰保存在系統鑰匙圈），再儲存到你選擇的位置；因為沒有額外口令，該檔案只能在本機 Memozia 匯入。金鑰不會上傳，檔案請妥善保管。',
    'Files exported from “Settings → LLM → Config Transfer” contain your API keys and are encrypted automatically with the local key (the same one used for your local data, stored in the system keychain), then saved wherever you choose. Because there is no separate passphrase, such a file can only be imported by Memozia on this Mac. The key is never uploaded; please keep the file safe.',
    '「設定 → 大規模モデル → 設定の移行」で書き出したファイルには API キーが含まれ、本機の鍵（ローカルデータと同じ鍵。システムのキーチェーンに保存）で自動的に暗号化され、選んだ場所に保存されます。追加の合言葉がないため、このファイルは本機の Memozia でしか読み込めません。鍵は送信されません。ファイルは大切に保管してください。',
    '‘설정 → 대형 모델 → 설정 이전’으로 내보낸 파일에는 API 키가 포함되며, 이 Mac의 키(로컬 데이터와 동일, 시스템 키체인에 저장)로 자동 암호화되어 원하는 위치에 저장됩니다. 별도 암호가 없으므로 이 파일은 이 Mac의 Memozia에서만 가져올 수 있습니다. 키는 업로드되지 않으며, 파일을 잘 보관하세요.',
    "Les fichiers exportés depuis « Réglages → Grand modèle → Transfert de configuration » contiennent vos clés API ; ils sont chiffrés automatiquement avec la clé locale (la même que vos données locales, conservée dans le trousseau système), puis enregistrés où vous voulez. Faute de mot de passe séparé, un tel fichier ne peut être importé que par Memozia sur ce Mac. La clé n'est jamais transmise ; conservez le fichier en lieu sûr.",
    'Aus „Einstellungen → LLM → Konfigurationsübertragung“ exportierte Dateien enthalten Ihre API-Schlüssel und werden automatisch mit dem lokalen Schlüssel verschlüsselt (derselbe wie für Ihre lokalen Daten, im Systemschlüsselbund), dann an einem Ort Ihrer Wahl gespeichert. Da es keine separate Passphrase gibt, kann eine solche Datei nur von Memozia auf diesem Mac importiert werden. Der Schlüssel wird nie hochgeladen; bewahren Sie die Datei sicher auf.',
    'Los archivos exportados desde «Ajustes → Modelo → Transferencia de configuración» contienen tus claves de API y se cifran automáticamente con la clave local (la misma que usan tus datos locales, guardada en el llavero del sistema), y se guardan donde elijas. Al no haber contraseña adicional, ese archivo solo puede importarlo Memozia en este Mac. La clave nunca se sube; guarda el archivo en un lugar seguro.',
    'I file esportati da «Impostazioni → Modello → Trasferimento configurazione» contengono le chiavi API e vengono cifrati automaticamente con la chiave locale (la stessa dei tuoi dati locali, conservata nel portachiavi di sistema), poi salvati dove preferisci. Non essendoci una passphrase separata, quel file può essere importato solo da Memozia su questo Mac. La chiave non viene mai inviata; conserva il file in un luogo sicuro.',
    'Os ficheiros exportados em «Definições → Modelo → Transferência de configuração» contêm as suas chaves de API e são cifrados automaticamente com a chave local (a mesma dos dados locais, guardada no porta-chaves do sistema) e guardados onde escolher. Como não há palavra-passe separada, esse ficheiro só pode ser importado pelo Memozia neste Mac. A chave nunca é enviada; guarde o ficheiro em local seguro.',
    'Файлы, экспортированные из «Настройки → Модель → Перенос настроек», содержат ваши API-ключи и автоматически шифруются локальным ключом (тем же, что и локальные данные, он хранится в связке ключей системы), после чего сохраняются в выбранное место. Отдельного пароля нет, поэтому такой файл может импортировать только Memozia на этом Mac. Ключ никуда не передаётся; храните файл надёжно.',
    'الملفات المُصدَّرة من «الإعدادات → النموذج → نقل الإعدادات» تتضمن مفاتيح API الخاصة بك، وتُشفَّر تلقائيًا بالمفتاح المحلي (نفس المفتاح المستخدم لبياناتك المحلية، والمحفوظ في سلسلة مفاتيح النظام)، ثم تُحفظ في المكان الذي تختاره. ولعدم وجود عبارة مرور منفصلة، لا يمكن استيراد هذا الملف إلا في Memozia على هذا الجهاز. لا يُرسل المفتاح إلى أي مكان، فاحفظ الملف بعناية.',
    '«सेटिंग्स → मॉडल → कॉन्फ़िगरेशन स्थानांतरण» से निर्यातित फ़ाइलों में आपकी API कुंजियाँ होती हैं और वे स्थानीय कुंजी (आपके स्थानीय डेटा वाली ही कुंजी, जो सिस्टम कीचेन में रहती है) से स्वतः एन्क्रिप्ट होकर आपके चुने स्थान पर सहेजी जाती हैं। अलग पासफ़्रेज़ न होने के कारण ऐसी फ़ाइल केवल इस Mac के Memozia में ही आयात की जा सकती है। कुंजी कहीं अपलोड नहीं होती; फ़ाइल संभालकर रखें।',
    'ไฟล์ที่ส่งออกจาก «การตั้งค่า → โมเดล → การย้ายการตั้งค่า» มี API Key ของคุณ และจะถูกเข้ารหัสอัตโนมัติด้วยคีย์ในเครื่อง (คีย์เดียวกับข้อมูลในเครื่อง เก็บไว้ในพวงกุญแจของระบบ) แล้วบันทึกยังตำแหน่งที่คุณเลือก เนื่องจากไม่มีรหัสผ่านแยก ไฟล์นี้จึงนำเข้าได้เฉพาะใน Memozia บนเครื่องนี้เท่านั้น คีย์จะไม่ถูกอัปโหลด โปรดเก็บไฟล์ให้ปลอดภัย',
    'Tệp xuất từ «Cài đặt → Mô hình → Chuyển cấu hình» chứa khóa API của bạn và được mã hóa tự động bằng khóa trên máy (cùng khóa với dữ liệu trên máy, lưu trong chuỗi khóa hệ thống), rồi lưu vào vị trí bạn chọn. Vì không có mật khẩu riêng, tệp này chỉ có thể được nhập bởi Memozia trên máy này. Khóa không bao giờ được tải lên; hãy cất giữ tệp cẩn thận.',
    'File yang diekspor dari «Pengaturan → Model → Transfer Konfigurasi» memuat kunci API Anda dan dienkripsi otomatis dengan kunci lokal (kunci yang sama dengan data lokal, tersimpan di keychain sistem), lalu disimpan di lokasi pilihan Anda. Karena tidak ada frasa sandi terpisah, file tersebut hanya dapat diimpor oleh Memozia di Mac ini. Kunci tidak pernah diunggah; simpan file dengan aman.',
    '«Ayarlar → Model → Yapılandırma Aktarımı» ile dışa aktarılan dosyalar API anahtarlarınızı içerir ve yerel anahtarla (yerel verilerinizle aynı anahtar, sistem anahtarlığında saklanır) otomatik şifrelenip seçtiğiniz yere kaydedilir. Ayrı bir parola olmadığından bu tür bir dosya yalnızca bu Mac’teki Memozia tarafından içe aktarılabilir. Anahtar hiçbir zaman yüklenmez; dosyayı güvenli bir yerde saklayın.',
    "Bestanden die via «Instellingen → Model → Configuratie overdragen» worden geëxporteerd bevatten je API-sleutels en worden automatisch versleuteld met de lokale sleutel (dezelfde als voor je lokale gegevens, bewaard in de systeemsleutelhanger) en daarna opgeslagen waar je wilt. Omdat er geen aparte wachtwoordzin is, kan zo'n bestand alleen door Memozia op deze Mac worden geïmporteerd. De sleutel wordt nooit geüpload; bewaar het bestand veilig.",
    'Pliki eksportowane z „Ustawienia → Model → Przenoszenie konfiguracji” zawierają Twoje klucze API i są automatycznie szyfrowane kluczem lokalnym (tym samym co dane lokalne, przechowywanym w pęku kluczy systemu), a następnie zapisywane w wybranym miejscu. Ponieważ nie ma osobnego hasła, taki plik może zaimportować wyłącznie Memozia na tym Macu. Klucz nigdy nie jest wysyłany; przechowuj plik bezpiecznie.',
    'Файли, експортовані з «Налаштування → Модель → Перенесення налаштувань», містять ваші ключі API і автоматично шифруються локальним ключем (тим самим, що й локальні дані, він зберігається у зв’язці ключів системи), після чого зберігаються у вибраному місці. Оскільки окремого пароля немає, такий файл може імпортувати лише Memozia на цьому Mac. Ключ нікуди не надсилається; зберігайте файл у безпеці.',
    'Filer som exporteras från «Inställningar → Modell → Överför konfiguration» innehåller dina API-nycklar och krypteras automatiskt med den lokala nyckeln (samma som för dina lokala data, förvarad i systemets nyckelring) och sparas där du väljer. Eftersom det inte finns någon separat lösenordsfras kan en sådan fil bara importeras av Memozia på den här Macen. Nyckeln laddas aldrig upp; förvara filen säkert.',
])


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']

    removed = 0
    for key in DEAD_KEYS:
        if existing.pop(key, None) is not None:
            removed += 1

    added = filled = skipped = 0
    for key, vals in T.items():
        entry = existing.get(key)
        if entry is not None and len(entry.get('localizations', {})) >= 21:
            print(f'跳过（已有完整译文）：{key[:24]}')
            skipped += 1
            continue
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
    print(f'完成：清理死 key {removed} 条，新增 {added} 条，补译 {filled} 条，保留 {skipped} 条')


if __name__ == '__main__':
    main()
