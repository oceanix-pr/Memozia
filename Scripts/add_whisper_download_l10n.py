#!/usr/bin/env python3
# Whisper 模型下载：设置页新增「下载模型」区块文案 20 种语言
# 与 add_micprivacy_l10n.py 同一合并策略（补全已被自动抽取的空条目）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('下载模型', [
    '下載模型',
    'Download Model',
    'モデルをダウンロード',
    '모델 다운로드',
    'Télécharger le modèle',
    'Modell herunterladen',
    'Descargar modelo',
    'Scarica modello',
    'Transferir modelo',
    'Скачать модель',
    'تنزيل النموذج',
    'मॉडल डाउनलोड करें',
    'ดาวน์โหลดโมเดล',
    'Tải mô hình',
    'Unduh Model',
    'Modeli İndir',
    'Model downloaden',
    'Pobierz model',
    'Завантажити модель',
    'Ladda ner modell',
])

add('下载源', [
    '下載來源',
    'Download Source',
    'ダウンロード元',
    '다운로드 소스',
    'Source de téléchargement',
    'Download-Quelle',
    'Origen de descarga',
    'Origine di download',
    'Origem de transferência',
    'Источник загрузки',
    'مصدر التنزيل',
    'डाउनलोड स्रोत',
    'แหล่งดาวน์โหลด',
    'Nguồn tải',
    'Sumber Unduhan',
    'İndirme kaynağı',
    'Downloadbron',
    'Źródło pobierania',
    'Джерело завантаження',
    'Nedladdningskälla',
])

add('HF-Mirror 镜像', [
    'HF-Mirror 鏡像',
    'HF-Mirror Mirror',
    'HF-Mirror ミラー',
    'HF-Mirror 미러',
    'Miroir HF-Mirror',
    'HF-Mirror-Spiegel',
    'Espejo HF-Mirror',
    'Mirror HF-Mirror',
    'Espelho HF-Mirror',
    'Зеркало HF-Mirror',
    'مرآة HF-Mirror',
    'HF-Mirror मिरर',
    'HF-Mirror มิเรอร์',
    'Gương HF-Mirror',
    'Mirror HF-Mirror',
    'HF-Mirror yansısı',
    'HF-Mirror-spiegel',
    'Lustro HF-Mirror',
    'Дзеркало HF-Mirror',
    'HF-Mirror-spegel',
])

add('HuggingFace 官方', [
    'HuggingFace 官方',
    'HuggingFace Official',
    'HuggingFace 公式',
    'HuggingFace 공식',
    'HuggingFace officiel',
    'HuggingFace (offiziell)',
    'HuggingFace oficial',
    'HuggingFace ufficiale',
    'HuggingFace oficial',
    'HuggingFace (официальный)',
    'HuggingFace الرسمي',
    'HuggingFace आधिकारिक',
    'HuggingFace อย่างเป็นทางการ',
    'HuggingFace chính thức',
    'HuggingFace resmi',
    'HuggingFace resmî',
    'HuggingFace officieel',
    'HuggingFace (oficjalne)',
    'HuggingFace (офіційний)',
    'HuggingFace (officiell)',
])

add('模型档位', [
    '模型檔位',
    'Model Size',
    'モデルサイズ',
    '모델 등급',
    'Taille du modèle',
    'Modellgröße',
    'Tamaño del modelo',
    'Dimensione modello',
    'Tamanho do modelo',
    'Размер модели',
    'فئة النموذج',
    'मॉडल आकार',
    'ขนาดโมเดล',
    'Kích thước mô hình',
    'Ukuran Model',
    'Model boyutu',
    'Modelgrootte',
    'Rozmiar modelu',
    'Розмір моделі',
    'Modellstorlek',
])

add('已下载', [
    '已下載',
    'Downloaded',
    'ダウンロード済み',
    '다운로드됨',
    'Téléchargé',
    'Heruntergeladen',
    'Descargado',
    'Scaricato',
    'Transferido',
    'Загружено',
    'تم التنزيل',
    'डाउनलोड हो गया',
    'ดาวน์โหลดแล้ว',
    'Đã tải xuống',
    'Terunduh',
    'İndirildi',
    'Gedownload',
    'Pobrano',
    'Завантажено',
    'Nedladdad',
])

add('下载并加载', [
    '下載並載入',
    'Download and Load',
    'ダウンロードして読み込む',
    '다운로드 후 불러오기',
    'Télécharger et charger',
    'Herunterladen und laden',
    'Descargar y cargar',
    'Scarica e carica',
    'Transferir e carregar',
    'Скачать и загрузить',
    'تنزيل وتحميل',
    'डाउनलोड और लोड करें',
    'ดาวน์โหลดและโหลด',
    'Tải và nạp',
    'Unduh dan muat',
    'İndir ve yükle',
    'Downloaden en laden',
    'Pobierz i wczytaj',
    'Завантажити й активувати',
    'Ladda ner och läs in',
])

add('取消下载', [
    '取消下載',
    'Cancel Download',
    'ダウンロードを中止',
    '다운로드 취소',
    'Annuler le téléchargement',
    'Download abbrechen',
    'Cancelar descarga',
    'Annulla download',
    'Cancelar transferência',
    'Отменить загрузку',
    'إلغاء التنزيل',
    'डाउनलोड रद्द करें',
    'ยกเลิกการดาวน์โหลด',
    'Hủy tải xuống',
    'Batalkan unduhan',
    'İndirmeyi iptal et',
    'Download annuleren',
    'Anuluj pobieranie',
    'Скасувати завантаження',
    'Avbryt nedladdning',
])

add('下载的模型会保存到模型文件夹下的同名子文件夹；也可以自行准备好模型后用「选择…」指定文件夹。', [
    '下載的模型會儲存到模型資料夾下的同名子資料夾；也可以自行準備好模型後用「選擇…」指定資料夾。',
    'Downloaded models are saved in a subfolder of the same name inside the model folder. You can also prepare the model yourself and pick the folder with “Choose…”.',
    'ダウンロードしたモデルはモデルフォルダ内の同名サブフォルダに保存されます。自分でモデルを用意して「選択…」でフォルダを指定することもできます。',
    '다운로드한 모델은 모델 폴더 안의 같은 이름 하위 폴더에 저장됩니다. 직접 준비한 모델을 ‘선택…’으로 지정할 수도 있습니다.',
    "Les modèles téléchargés sont enregistrés dans un sous-dossier du même nom dans le dossier de modèles. Vous pouvez aussi préparer le modèle vous-même et choisir le dossier avec « Choisir… ».",
    'Heruntergeladene Modelle werden in einem gleichnamigen Unterordner des Modellordners gespeichert. Sie können das Modell auch selbst bereitstellen und den Ordner über „Auswählen…“ wählen.',
    'Los modelos descargados se guardan en una subcarpeta con el mismo nombre dentro de la carpeta de modelos. También puedes preparar el modelo tú mismo y elegir la carpeta con «Elegir…».',
    'I modelli scaricati vengono salvati in una sottocartella con lo stesso nome nella cartella dei modelli. Puoi anche preparare il modello da solo e scegliere la cartella con «Scegli…».',
    'Os modelos transferidos são guardados numa subpasta com o mesmo nome dentro da pasta de modelos. Também pode preparar o modelo manualmente e escolher a pasta com «Escolher…».',
    'Скачанные модели сохраняются в подпапке с тем же именем внутри папки моделей. Можно также подготовить модель вручную и указать папку кнопкой «Выбрать…».',
    'تُحفظ النماذج التي تم تنزيلها في مجلد فرعي بالاسم نفسه داخل مجلد النماذج. يمكنك أيضًا تجهيز النموذج بنفسك واختيار المجلد عبر «اختيار…».',
    'डाउनलोड किए गए मॉडल मॉडल फ़ोल्डर के अंदर उसी नाम के उप-फ़ोल्डर में सहेजे जाते हैं। आप स्वयं मॉडल तैयार करके «चुनें…» से फ़ोल्डर भी चुन सकते हैं।',
    'โมเดลที่ดาวน์โหลดจะถูกบันทึกไว้ในโฟลเดอร์ย่อยชื่อเดียวกันภายในโฟลเดอร์โมเดล และคุณยังสามารถเตรียมโมเดลเองแล้วเลือกโฟลเดอร์ด้วย «เลือก…» ได้',
    'Mô hình đã tải sẽ được lưu vào thư mục con cùng tên trong thư mục mô hình. Bạn cũng có thể tự chuẩn bị mô hình rồi chọn thư mục bằng «Chọn…».',
    'Model yang diunduh disimpan dalam subfolder bernama sama di dalam folder model. Anda juga dapat menyiapkan model sendiri lalu memilih foldernya dengan «Pilih…».',
    'İndirilen modeller, model klasörü içinde aynı adlı bir alt klasöre kaydedilir. Modeli kendiniz hazırlayıp «Seç…» ile klasörü de seçebilirsiniz.',
    'Gedownloade modellen worden opgeslagen in een submap met dezelfde naam in de modellenmap. Je kunt het model ook zelf klaarzetten en de map kiezen met «Kies…».',
    'Pobrane modele są zapisywane w podfolderze o tej samej nazwie w folderze modeli. Możesz też przygotować model samodzielnie i wybrać folder przyciskiem „Wybierz…”.',
    'Завантажені моделі зберігаються в підпапці з тією ж назвою всередині папки моделей. Також можна підготувати модель самостійно й вибрати папку кнопкою «Вибрати…».',
    'Nedladdade modeller sparas i en undermapp med samma namn i modellmappen. Du kan också förbereda modellen själv och välja mappen med «Välj…».',
])

add('无法创建或访问模型文件夹：%@', [
    '無法建立或存取模型資料夾：%@',
    'Unable to create or access the model folder: %@',
    'モデルフォルダを作成またはアクセスできません：%@',
    '모델 폴더를 만들거나 접근할 수 없습니다: %@',
    "Impossible de créer ou d'accéder au dossier de modèles : %@",
    'Modellordner kann nicht erstellt oder aufgerufen werden: %@',
    'No se puede crear o acceder a la carpeta de modelos: %@',
    'Impossibile creare o accedere alla cartella dei modelli: %@',
    'Não foi possível criar ou aceder à pasta de modelos: %@',
    'Не удалось создать или открыть папку моделей: %@',
    'تعذّر إنشاء مجلد النماذج أو الوصول إليه: %@',
    'मॉडल फ़ोल्डर बनाया या खोला नहीं जा सका: %@',
    'ไม่สามารถสร้างหรือเข้าถึงโฟลเดอร์โมเดลได้: %@',
    'Không thể tạo hoặc truy cập thư mục mô hình: %@',
    'Tidak dapat membuat atau mengakses folder model: %@',
    'Model klasörü oluşturulamadı veya açılamadı: %@',
    'Kan de modellenmap niet aanmaken of openen: %@',
    'Nie można utworzyć ani otworzyć folderu modeli: %@',
    'Не вдалося створити або відкрити папку моделей: %@',
    'Det gick inte att skapa eller komma åt modellmappen: %@',
])

add('该文件夹下已存在同名模型：%@。请先删除它，或换一个模型文件夹。', [
    '該資料夾下已存在同名模型：%@。請先刪除它，或換一個模型資料夾。',
    'A model with the same name already exists in this folder: %@. Delete it first, or choose another model folder.',
    'このフォルダには同名のモデルが既に存在します：%@。先に削除するか、別のモデルフォルダを選んでください。',
    '이 폴더에 같은 이름의 모델이 이미 있습니다: %@. 먼저 삭제하거나 다른 모델 폴더를 선택하세요.',
    "Un modèle du même nom existe déjà dans ce dossier : %@. Supprimez-le d'abord ou choisissez un autre dossier de modèles.",
    'In diesem Ordner existiert bereits ein gleichnamiges Modell: %@. Löschen Sie es zuerst oder wählen Sie einen anderen Modellordner.',
    'Ya existe un modelo con el mismo nombre en esta carpeta: %@. Elimínalo primero o elige otra carpeta de modelos.',
    'Esiste già un modello con lo stesso nome in questa cartella: %@. Eliminalo prima o scegli un’altra cartella dei modelli.',
    'Já existe um modelo com o mesmo nome nesta pasta: %@. Elimine-o primeiro ou escolha outra pasta de modelos.',
    'В этой папке уже есть модель с таким именем: %@. Удалите её или выберите другую папку моделей.',
    'يوجد نموذج بالاسم نفسه في هذا المجلد: %@. احذفه أولاً أو اختر مجلد نماذج آخر.',
    'इस फ़ोल्डर में उसी नाम का मॉडल पहले से मौजूद है: %@. पहले उसे हटाएँ या दूसरा मॉडल फ़ोल्डर चुनें।',
    'มีโมเดลชื่อเดียวกันอยู่ในโฟลเดอร์นี้แล้ว: %@ โปรดลบก่อนหรือเลือกโฟลเดอร์โมเดลอื่น',
    'Đã có mô hình cùng tên trong thư mục này: %@. Hãy xóa nó trước hoặc chọn thư mục mô hình khác.',
    'Sudah ada model dengan nama sama di folder ini: %@. Hapus dulu atau pilih folder model lain.',
    'Bu klasörde aynı ada sahip bir model zaten var: %@. Önce onu silin veya başka bir model klasörü seçin.',
    'Er bestaat al een model met dezelfde naam in deze map: %@. Verwijder het eerst of kies een andere modellenmap.',
    'W tym folderze istnieje już model o tej samej nazwie: %@. Najpierw go usuń lub wybierz inny folder modeli.',
    'У цій папці вже є модель з такою назвою: %@. Спочатку видаліть її або виберіть іншу папку моделей.',
    'Det finns redan en modell med samma namn i den här mappen: %@. Ta bort den först eller välj en annan modellmapp.',
])

add('模型下载失败：%@', [
    '模型下載失敗：%@',
    'Model download failed: %@',
    'モデルのダウンロードに失敗しました：%@',
    '모델 다운로드 실패: %@',
    'Échec du téléchargement du modèle : %@',
    'Modell-Download fehlgeschlagen: %@',
    'Error al descargar el modelo: %@',
    'Download del modello non riuscito: %@',
    'Falha ao transferir o modelo: %@',
    'Не удалось скачать модель: %@',
    'فشل تنزيل النموذج: %@',
    'मॉडल डाउनलोड विफल: %@',
    'ดาวน์โหลดโมเดลไม่สำเร็จ: %@',
    'Tải mô hình thất bại: %@',
    'Gagal mengunduh model: %@',
    'Model indirilemedi: %@',
    'Downloaden van model mislukt: %@',
    'Pobieranie modelu nie powiodło się: %@',
    'Не вдалося завантажити модель: %@',
    'Nedladdning av modell misslyckades: %@',
])

add('下载已完成但模型文件不完整：%@', [
    '下載已完成但模型檔案不完整：%@',
    'The download finished but the model files are incomplete: %@',
    'ダウンロードは完了しましたが、モデルファイルが不完全です：%@',
    '다운로드는 끝났지만 모델 파일이 불완전합니다: %@',
    'Le téléchargement est terminé mais les fichiers du modèle sont incomplets : %@',
    'Der Download ist abgeschlossen, aber die Modelldateien sind unvollständig: %@',
    'La descarga terminó pero los archivos del modelo están incompletos: %@',
    'Il download è terminato ma i file del modello sono incompleti: %@',
    'A transferência terminou mas os ficheiros do modelo estão incompletos: %@',
    'Загрузка завершена, но файлы модели неполные: %@',
    'اكتمل التنزيل لكن ملفات النموذج غير مكتملة: %@',
    'डाउनलोड पूरा हुआ लेकिन मॉडल फ़ाइलें अधूरी हैं: %@',
    'ดาวน์โหลดเสร็จแล้วแต่ไฟล์โมเดลไม่ครบถ้วน: %@',
    'Đã tải xong nhưng tệp mô hình chưa đầy đủ: %@',
    'Unduhan selesai tetapi file model tidak lengkap: %@',
    'İndirme tamamlandı ancak model dosyaları eksik: %@',
    'Download voltooid, maar de modelbestanden zijn onvolledig: %@',
    'Pobieranie zakończone, ale pliki modelu są niekompletne: %@',
    'Завантаження завершено, але файли моделі неповні: %@',
    'Nedladdningen är klar men modellfilerna är ofullständiga: %@',
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
