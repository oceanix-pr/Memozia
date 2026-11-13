#!/usr/bin/env python3
# 大模型配置导入导出：界面文案 20 种语言
#
# 策略：已存在且已完整翻译（>=21 条 localizations）的 key 保持原样不清洗；
# 其余（自动抽取出的空条目）补全 localizations 并清掉 extractionState。
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('配置迁移', [
    '設定遷移',
    'Config Transfer',
    '設定の移行',
    '설정 이전',
    'Transfert de configuration',
    'Konfigurationsübertragung',
    'Transferencia de configuración',
    'Trasferimento configurazione',
    'Transferência de configuração',
    'Перенос настроек',
    'نقل الإعدادات',
    'कॉन्फ़िगरेशन स्थानांतरण',
    'การย้ายการตั้งค่า',
    'Chuyển cấu hình',
    'Transfer Konfigurasi',
    'Yapılandırma Aktarımı',
    'Configuratie overdragen',
    'Przenoszenie konfiguracji',
    'Перенесення налаштувань',
    'Överför konfiguration',
])

add('导出配置…', [
    '匯出設定…',
    'Export Config…',
    '設定を書き出す…',
    '설정 내보내기…',
    'Exporter la configuration…',
    'Konfiguration exportieren…',
    'Exportar configuración…',
    'Esporta configurazione…',
    'Exportar configuração…',
    'Экспорт настроек…',
    'تصدير الإعدادات…',
    'कॉन्फ़िगरेशन निर्यात करें…',
    'ส่งออกการตั้งค่า…',
    'Xuất cấu hình…',
    'Ekspor Konfigurasi…',
    'Yapılandırmayı Dışa Aktar…',
    'Configuratie exporteren…',
    'Eksportuj konfigurację…',
    'Експорт налаштувань…',
    'Exportera konfiguration…',
])

add('导入配置…', [
    '匯入設定…',
    'Import Config…',
    '設定を読み込む…',
    '설정 가져오기…',
    'Importer la configuration…',
    'Konfiguration importieren…',
    'Importar configuración…',
    'Importa configurazione…',
    'Importar configuração…',
    'Импорт настроек…',
    'استيراد الإعدادات…',
    'कॉन्फ़िगरेशन आयात करें…',
    'นำเข้าการตั้งค่า…',
    'Nhập cấu hình…',
    'Impor Konfigurasi…',
    'Yapılandırmayı İçe Aktar…',
    'Configuratie importeren…',
    'Importuj konfigurację…',
    'Імпорт налаштувань…',
    'Importera konfiguration…',
])

add('导出不含 API Key（存于系统钥匙串），导入后需重新填写。', [
    '匯出檔不含 API Key（存於系統鑰匙圈），匯入後需重新填寫。',
    'The exported file contains no API keys (they are stored in the system keychain); re-enter them after importing.',
    '書き出したファイルに API キーは含まれません（システムのキーチェーンに保存されます）。読み込み後に再入力してください。',
    '내보낸 파일에는 API 키가 포함되지 않습니다(시스템 키체인에 저장됨). 가져온 후 다시 입력하세요.',
    "Le fichier exporté ne contient pas les clés API (stockées dans le trousseau système) ; resaisissez-les après l'import.",
    'Die exportierte Datei enthält keine API-Schlüssel (sie liegen im Systemschlüsselbund); nach dem Import erneut eingeben.',
    'El archivo exportado no incluye las claves de API (se guardan en el llavero del sistema); vuelve a introducirlas tras importar.',
    "Il file esportato non contiene le chiavi API (sono nel portachiavi di sistema); reinseriscile dopo l'importazione.",
    'O ficheiro exportado não inclui as chaves de API (ficam no porta-chaves do sistema); volte a introduzi-las após importar.',
    'В экспортируемом файле нет API-ключей (они хранятся в связке ключей системы); после импорта введите их заново.',
    'لا يتضمن الملف المُصدَّر مفاتيح API (فهي محفوظة في سلسلة مفاتيح النظام)؛ أعد إدخالها بعد الاستيراد.',
    'निर्यातित फ़ाइल में API कुंजियाँ नहीं होतीं (वे सिस्टम कीचेन में रहती हैं); आयात के बाद उन्हें दोबारा भरें।',
    'ไฟล์ที่ส่งออกไม่มี API Key (เก็บไว้ในพวงกุญแจของระบบ) หลังนำเข้าให้กรอกใหม่',
    'Tệp xuất không chứa khóa API (khóa lưu trong chuỗi khóa hệ thống); sau khi nhập hãy nhập lại.',
    'File hasil ekspor tidak memuat kunci API (tersimpan di keychain sistem); isi ulang setelah impor.',
    'Dışa aktarılan dosyada API anahtarı bulunmaz (sistem anahtarlığında saklanır); içe aktardıktan sonra yeniden girin.',
    'Het geëxporteerde bestand bevat geen API-sleutels (die staan in de systeemsleutelhanger); vul ze na het importeren opnieuw in.',
    'Eksportowany plik nie zawiera kluczy API (są w pęku kluczy systemu); po imporcie wpisz je ponownie.',
    'Експортований файл не містить ключів API (вони у зв’язці ключів системи); після імпорту введіть їх знову.',
    'Den exporterade filen innehåller inga API-nycklar (de finns i systemets nyckelring); ange dem igen efter import.',
])

add('导入完成：新增 %lld、跳过重复 %lld、无效 %lld', [
    '匯入完成：新增 %lld、跳過重複 %lld、無效 %lld',
    'Import complete: %lld added, %lld duplicates skipped, %lld invalid',
    '読み込み完了：追加 %lld、重複スキップ %lld、無効 %lld',
    '가져오기 완료: 추가 %lld, 중복 건너뜀 %lld, 무효 %lld',
    'Import terminé : %lld ajoutés, %lld doublons ignorés, %lld non valides',
    'Import abgeschlossen: %lld hinzugefügt, %lld Duplikate übersprungen, %lld ungültig',
    'Importación completada: %lld añadidos, %lld duplicados omitidos, %lld no válidos',
    'Importazione completata: %lld aggiunti, %lld duplicati saltati, %lld non validi',
    'Importação concluída: %lld adicionados, %lld duplicados ignorados, %lld inválidos',
    'Импорт завершён: добавлено %lld, пропущено дубликатов %lld, недействительных %lld',
    'اكتمل الاستيراد: أُضيف %lld، وتُخطي %lld مكررًا، و%lld غير صالح',
    'आयात पूरा: %lld जोड़े गए, %lld डुप्लिकेट छोड़े गए, %lld अमान्य',
    'นำเข้าเสร็จ: เพิ่ม %lld ข้ามซ้ำ %lld ใช้ไม่ได้ %lld',
    'Nhập xong: thêm %lld, bỏ qua trùng %lld, không hợp lệ %lld',
    'Impor selesai: %lld ditambahkan, %lld duplikat dilewati, %lld tidak valid',
    'İçe aktarma tamamlandı: %lld eklendi, %lld yinelenen atlandı, %lld geçersiz',
    'Importeren voltooid: %lld toegevoegd, %lld duplicaten overgeslagen, %lld ongeldig',
    'Import zakończony: dodano %lld, pominięto duplikaty %lld, nieprawidłowe %lld',
    'Імпорт завершено: додано %lld, пропущено дублікатів %lld, недійсних %lld',
    'Import klar: %lld tillagda, %lld dubbletter överhoppade, %lld ogiltiga',
])

add('文件格式不正确，请选择由本应用「导出配置…」生成的文件。', [
    '檔案格式不正確，請選擇由本應用程式「匯出設定…」產生的檔案。',
    'The file format is not valid. Choose a file created by this app’s “Export Config…” command.',
    'ファイル形式が正しくありません。本アプリの「設定を書き出す…」で作成したファイルを選んでください。',
    '파일 형식이 올바르지 않습니다. 이 앱의 ‘설정 내보내기…’로 만든 파일을 선택하세요.',
    "Le format du fichier est incorrect. Choisissez un fichier créé par « Exporter la configuration… » de cette app.",
    'Das Dateiformat ist ungültig. Wählen Sie eine Datei aus „Konfiguration exportieren…“ dieser App.',
    'El formato del archivo no es válido. Elige un archivo creado con «Exportar configuración…» de esta app.',
    'Il formato del file non è valido. Scegli un file creato con «Esporta configurazione…» di questa app.',
    'O formato do ficheiro não é válido. Escolha um ficheiro criado por «Exportar configuração…» desta app.',
    'Неверный формат файла. Выберите файл, созданный командой «Экспорт настроек…» этого приложения.',
    'تنسيق الملف غير صحيح. اختر ملفًا أنشأه هذا التطبيق عبر «تصدير الإعدادات…».',
    'फ़ाइल का प्रारूप सही नहीं है। इस ऐप के «कॉन्फ़िगरेशन निर्यात करें…» से बनी फ़ाइल चुनें।',
    'รูปแบบไฟล์ไม่ถูกต้อง โปรดเลือกไฟล์ที่สร้างจาก «ส่งออกการตั้งค่า…» ของแอปนี้',
    'Định dạng tệp không đúng. Hãy chọn tệp do «Xuất cấu hình…» của ứng dụng này tạo ra.',
    'Format file tidak valid. Pilih file yang dibuat oleh «Ekspor Konfigurasi…» aplikasi ini.',
    'Dosya biçimi geçersiz. Bu uygulamanın «Yapılandırmayı Dışa Aktar…» ile oluşturduğu bir dosya seçin.',
    'De bestandsindeling is ongeldig. Kies een bestand dat is gemaakt met «Configuratie exporteren…» van deze app.',
    'Nieprawidłowy format pliku. Wybierz plik utworzony przez „Eksportuj konfigurację…” tej aplikacji.',
    'Неправильний формат файлу. Виберіть файл, створений командою «Експорт налаштувань…» цього застосунку.',
    'Filformatet är ogiltigt. Välj en fil skapad av appens «Exportera konfiguration…».',
])

add('导出失败：%@', [
    '匯出失敗：%@',
    'Export failed: %@',
    '書き出しに失敗：%@',
    '내보내기 실패: %@',
    "Échec de l'export : %@",
    'Export fehlgeschlagen: %@',
    'Error al exportar: %@',
    'Esportazione non riuscita: %@',
    'Falha ao exportar: %@',
    'Не удалось экспортировать: %@',
    'فشل التصدير: %@',
    'निर्यात विफल: %@',
    'ส่งออกไม่สำเร็จ: %@',
    'Xuất thất bại: %@',
    'Ekspor gagal: %@',
    'Dışa aktarma başarısız: %@',
    'Exporteren mislukt: %@',
    'Eksport nie powiódł się: %@',
    'Не вдалося експортувати: %@',
    'Export misslyckades: %@',
])

add('「设置 → 大模型 → 配置迁移」可导出/导入模型配置，便于换机迁移；导出文件不含 API Key（Key 存系统钥匙串），导入后需重新填写', [
    '「設定 → 大模型 → 設定遷移」可匯出/匯入模型設定，便於換機遷移；匯出檔不含 API Key（Key 存系統鑰匙圈），匯入後需重新填寫',
    'Use “Settings → LLM → Config Transfer” to export/import model configs when moving to a new Mac; the file contains no API keys (they stay in the system keychain), so re-enter them after importing',
    '「設定 → 大規模モデル → 設定の移行」でモデル設定を書き出し/読み込みでき、機種変更時に便利です。書き出したファイルに API キーは含まれない（キーチェーンに保存）ため、読み込み後に再入力してください',
    '‘설정 → 대형 모델 → 설정 이전’에서 모델 설정을 내보내기/가져오기할 수 있어 기기 변경에 편리합니다. 내보낸 파일에는 API 키가 없으므로(키체인에 저장) 가져온 후 다시 입력하세요',
    '« Réglages → Grand modèle → Transfert de configuration » permet d’exporter/importer les configurations de modèle pour changer de Mac ; le fichier ne contient pas les clés API (elles restent dans le trousseau), resaisissez-les après l’import',
    'Unter „Einstellungen → LLM → Konfigurationsübertragung“ lassen sich Modellkonfigurationen für den Mac-Wechsel ex- und importieren; die Datei enthält keine API-Schlüssel (sie bleiben im Schlüsselbund) — nach dem Import erneut eingeben',
    'En «Ajustes → Modelo → Transferencia de configuración» puedes exportar/importar configuraciones de modelo al cambiar de Mac; el archivo no incluye las claves de API (siguen en el llavero), vuelve a introducirlas tras importar',
    'In «Impostazioni → Modello → Trasferimento configurazione» puoi esportare/importare le configurazioni dei modelli quando cambi Mac; il file non contiene le chiavi API (restano nel portachiavi), reinseriscile dopo l’importazione',
    'Em «Definições → Modelo → Transferência de configuração» pode exportar/importar configurações de modelo ao mudar de Mac; o ficheiro não inclui as chaves de API (ficam no porta-chaves), volte a introduzi-las após importar',
    'В разделе «Настройки → Модель → Перенос настроек» можно экспортировать/импортировать конфигурации моделей при смене Mac; в файле нет API-ключей (они в связке ключей), после импорта введите их заново',
    'من «الإعدادات → النموذج → نقل الإعدادات» يمكنك تصدير/استيراد إعدادات النموذج عند الانتقال إلى Mac جديد؛ لا يتضمن الملف مفاتيح API (تبقى في سلسلة المفاتيح)، فأعد إدخالها بعد الاستيراد',
    '«सेटिंग्स → मॉडल → कॉन्फ़िगरेशन स्थानांतरण» से नए Mac पर जाते समय मॉडल कॉन्फ़िगरेशन निर्यात/आयात करें; फ़ाइल में API कुंजियाँ नहीं होतीं (वे कीचेन में रहती हैं), आयात के बाद दोबारा भरें',
    'ที่ «การตั้งค่า → โมเดล → การย้ายการตั้งค่า» ส่งออก/นำเข้าการตั้งค่าโมเดลได้ สะดวกเมื่อเปลี่ยน Mac ไฟล์ไม่มี API Key (เก็บในพวงกุญแจ) หลังนำเข้าให้กรอกใหม่',
    'Tại «Cài đặt → Mô hình → Chuyển cấu hình» bạn có thể xuất/nhập cấu hình mô hình khi đổi Mac; tệp không chứa khóa API (khóa nằm trong chuỗi khóa), hãy nhập lại sau khi nhập',
    'Di «Pengaturan → Model → Transfer Konfigurasi» Anda dapat mengekspor/mengimpor konfigurasi model saat pindah Mac; file tidak memuat kunci API (tersimpan di keychain), isi ulang setelah impor',
    '«Ayarlar → Model → Yapılandırma Aktarımı» ile yeni Mac’e geçerken model yapılandırmalarını dışa/içe aktarabilirsiniz; dosyada API anahtarı yoktur (anahtarlıkta kalır), içe aktardıktan sonra yeniden girin',
    'Via «Instellingen → Model → Configuratie overdragen» kun je modelconfiguraties exporteren/importeren bij een nieuwe Mac; het bestand bevat geen API-sleutels (die blijven in de sleutelhanger), vul ze na het importeren opnieuw in',
    'W „Ustawienia → Model → Przenoszenie konfiguracji” możesz wyeksportować/zaimportować konfiguracje modeli przy zmianie Maca; plik nie zawiera kluczy API (są w pęku kluczy), po imporcie wpisz je ponownie',
    'У «Налаштування → Модель → Перенесення налаштувань» можна експортувати/імпортувати конфігурації моделей під час зміни Mac; файл не містить ключів API (вони у зв’язці ключів), після імпорту введіть їх знову',
    'Under «Inställningar → Modell → Överför konfiguration» kan du exportera/importera modellkonfigurationer när du byter Mac; filen innehåller inga API-nycklar (de finns i nyckelringen), ange dem igen efter import',
])


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    added = filled = skipped = 0
    for key, vals in T.items():
        entry = existing.get(key)
        if entry is not None and len(entry.get('localizations', {})) >= 21:
            # 已有完整译文：保留原样，不覆盖
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
    print(f'完成：新增 {added} 条，补译 {filled} 条，保留 {skipped} 条')


if __name__ == '__main__':
    main()
