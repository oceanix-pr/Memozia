#!/usr/bin/env python3
# 补齐批次 11：导出/合并/存储错误、录屏质量与菜单栏短标签等 20 种语言
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('保存笔记元数据失败', [
    '儲存筆記中繼資料失敗',
    'Failed to save note metadata',
    'ノートのメタデータ保存に失敗',
    '노트 메타데이터 저장 실패',
    "Échec de l'enregistrement des métadonnées de la note",
    'Metadaten der Notiz konnten nicht gespeichert werden',
    'Error al guardar los metadatos de la nota',
    'Salvataggio dei metadati della nota non riuscito',
    'Falha ao guardar os metadados da nota',
    'Не удалось сохранить метаданные заметки',
    'فشل حفظ البيانات الوصفية للملاحظة',
    'नोट मेटाडेटा सहेजना विफल',
    'บันทึกข้อมูลเมตาของโน้ตไม่สำเร็จ',
    'Lưu siêu dữ liệu ghi chú thất bại',
    'Gagal menyimpan metadata catatan',
    'Not üst verileri kaydedilemedi',
    'Metagegevens van notitie opslaan mislukt',
    'Nie udało się zapisać metadanych notatki',
    'Не вдалося зберегти метадані нотатки',
    'Kunde inte spara anteckningens metadata',
])

add('创建导入文件夹失败，请检查存储目录是否可写、磁盘空间是否充足后重试。', [
    '建立匯入資料夾失敗，請檢查儲存目錄是否可寫入、磁碟空間是否充足後重試。',
    'Failed to create the import folder. Check that the storage folder is writable and that there is enough disk space, then try again.',
    '取り込みフォルダを作成できません。保存先フォルダに書き込めるか、ディスク容量が足りているかを確認して再試行してください。',
    '가져오기 폴더를 만들지 못했습니다. 저장 폴더에 쓸 수 있는지와 디스크 공간이 충분한지 확인한 뒤 다시 시도하세요.',
    "Échec de la création du dossier d'importation. Vérifiez que le dossier de stockage est accessible en écriture et que l'espace disque est suffisant, puis réessayez.",
    'Importordner konnte nicht erstellt werden. Prüfen Sie, ob der Speicherordner beschreibbar ist und genügend Speicherplatz frei ist, und versuchen Sie es erneut.',
    'No se pudo crear la carpeta de importación. Comprueba que la carpeta de almacenamiento se pueda escribir y que haya espacio en disco suficiente, y vuelve a intentarlo.',
    'Impossibile creare la cartella di importazione. Controlla che la cartella di archiviazione sia scrivibile e che ci sia spazio su disco sufficiente, poi riprova.',
    'Falha ao criar a pasta de importação. Verifique se a pasta de armazenamento é gravável e se há espaço em disco suficiente e tente novamente.',
    'Не удалось создать папку импорта. Проверьте, доступна ли папка хранения для записи и достаточно ли места на диске, затем повторите попытку.',
    'فشل إنشاء مجلد الاستيراد. تحقق من إمكانية الكتابة في مجلد التخزين ومن توفر مساحة قرص كافية ثم أعد المحاولة.',
    'आयात फ़ोल्डर बनाना विफल। जाँचें कि संग्रहण फ़ोल्डर लिखने योग्य है और डिस्क स्थान पर्याप्त है, फिर पुनः प्रयास करें।',
    'สร้างโฟลเดอร์นำเข้าไม่สำเร็จ โปรดตรวจสอบว่าโฟลเดอร์จัดเก็บเขียนได้และพื้นที่ดิสก์เพียงพอ แล้วลองใหม่',
    'Tạo thư mục nhập thất bại. Kiểm tra xem thư mục lưu trữ có ghi được không và dung lượng đĩa có đủ không, rồi thử lại.',
    'Gagal membuat folder impor. Periksa apakah folder penyimpanan dapat ditulis dan ruang disk cukup, lalu coba lagi.',
    'İçe aktarma klasörü oluşturulamadı. Depolama klasörünün yazılabilir ve disk alanının yeterli olduğunu kontrol edip tekrar deneyin.',
    'Map voor importeren maken mislukt. Controleer of de opslagmap beschrijfbaar is en of er genoeg schijfruimte is, en probeer opnieuw.',
    'Nie udało się utworzyć folderu importu. Sprawdź, czy folder przechowywania jest zapisywalny i czy jest wystarczająco miejsca na dysku, a następnie spróbuj ponownie.',
    'Не вдалося створити папку імпорту. Перевірте, чи папка зберігання доступна для запису та чи достатньо місця на диску, потім повторіть спробу.',
    'Kunde inte skapa importmappen. Kontrollera att lagringsmappen är skrivbar och att det finns tillräckligt med diskutrymme, och försök igen.',
])

add('创建录音文件夹失败，请检查存储目录是否可写、磁盘空间是否充足后重试。', [
    '建立錄音資料夾失敗，請檢查儲存目錄是否可寫入、磁碟空間是否充足後重試。',
    'Failed to create the recording folder. Check that the storage folder is writable and that there is enough disk space, then try again.',
    '録音フォルダを作成できません。保存先フォルダに書き込めるか、ディスク容量が足りているかを確認して再試行してください。',
    '녹음 폴더를 만들지 못했습니다. 저장 폴더에 쓸 수 있는지와 디스크 공간이 충분한지 확인한 뒤 다시 시도하세요.',
    "Échec de la création du dossier d'enregistrement. Vérifiez que le dossier de stockage est accessible en écriture et que l'espace disque est suffisant, puis réessayez.",
    'Aufnahmeordner konnte nicht erstellt werden. Prüfen Sie, ob der Speicherordner beschreibbar ist und genügend Speicherplatz frei ist, und versuchen Sie es erneut.',
    'No se pudo crear la carpeta de grabación. Comprueba que la carpeta de almacenamiento se pueda escribir y que haya espacio en disco suficiente, y vuelve a intentarlo.',
    'Impossibile creare la cartella di registrazione. Controlla che la cartella di archiviazione sia scrivibile e che ci sia spazio su disco sufficiente, poi riprova.',
    'Falha ao criar a pasta de gravação. Verifique se a pasta de armazenamento é gravável e se há espaço em disco suficiente e tente novamente.',
    'Не удалось создать папку записи. Проверьте, доступна ли папка хранения для записи и достаточно ли места на диске, затем повторите попытку.',
    'فشل إنشاء مجلد التسجيل. تحقق من إمكانية الكتابة في مجلد التخزين ومن توفر مساحة قرص كافية ثم أعد المحاولة.',
    'रिकॉर्डिंग फ़ोल्डर बनाना विफल। जाँचें कि संग्रहण फ़ोल्डर लिखने योग्य है और डिस्क स्थान पर्याप्त है, फिर पुनः प्रयास करें।',
    'สร้างโฟลเดอร์บันทึกไม่สำเร็จ โปรดตรวจสอบว่าโฟลเดอร์จัดเก็บเขียนได้และพื้นที่ดิสก์เพียงพอ แล้วลองใหม่',
    'Tạo thư mục ghi âm thất bại. Kiểm tra xem thư mục lưu trữ có ghi được không và dung lượng đĩa có đủ không, rồi thử lại.',
    'Gagal membuat folder rekaman. Periksa apakah folder penyimpanan dapat ditulis dan ruang disk cukup, lalu coba lagi.',
    'Kayıt klasörü oluşturulamadı. Depolama klasörünün yazılabilir ve disk alanının yeterli olduğunu kontrol edip tekrar deneyin.',
    'Map voor opnemen maken mislukt. Controleer of de opslagmap beschrijfbaar is en of er genoeg schijfruimte is, en probeer opnieuw.',
    'Nie udało się utworzyć folderu nagrania. Sprawdź, czy folder przechowywania jest zapisywalny i czy jest wystarczająco miejsca na dysku, a następnie spróbuj ponownie.',
    'Не вдалося створити папку запису. Перевірте, чи папка зберігання доступна для запису та чи достатньо місця на диску, потім повторіть спробу.',
    'Kunde inte skapa inspelningsmappen. Kontrollera att lagringsmappen är skrivbar och att det finns tillräckligt med diskutrymme, och försök igen.',
])

add('创建笔记文件夹失败，请检查存储目录是否可写、磁盘空间是否充足后重试。', [
    '建立筆記資料夾失敗，請檢查儲存目錄是否可寫入、磁碟空間是否充足後重試。',
    'Failed to create the note folder. Check that the storage folder is writable and that there is enough disk space, then try again.',
    'ノートフォルダを作成できません。保存先フォルダに書き込めるか、ディスク容量が足りているかを確認して再試行してください。',
    '노트 폴더를 만들지 못했습니다. 저장 폴더에 쓸 수 있는지와 디스크 공간이 충분한지 확인한 뒤 다시 시도하세요.',
    "Échec de la création du dossier de note. Vérifiez que le dossier de stockage est accessible en écriture et que l'espace disque est suffisant, puis réessayez.",
    'Notizordner konnte nicht erstellt werden. Prüfen Sie, ob der Speicherordner beschreibbar ist und genügend Speicherplatz frei ist, und versuchen Sie es erneut.',
    'No se pudo crear la carpeta de nota. Comprueba que la carpeta de almacenamiento se pueda escribir y que haya espacio en disco suficiente, y vuelve a intentarlo.',
    'Impossibile creare la cartella della nota. Controlla che la cartella di archiviazione sia scrivibile e che ci sia spazio su disco sufficiente, poi riprova.',
    'Falha ao criar a pasta de nota. Verifique se a pasta de armazenamento é gravável e se há espaço em disco suficiente e tente novamente.',
    'Не удалось создать папку заметки. Проверьте, доступна ли папка хранения для записи и достаточно ли места на диске, затем повторите попытку.',
    'فشل إنشاء مجلد الملاحظة. تحقق من إمكانية الكتابة في مجلد التخزين ومن توفر مساحة قرص كافية ثم أعد المحاولة.',
    'नोट फ़ोल्डर बनाना विफल। जाँचें कि संग्रहण फ़ोल्डर लिखने योग्य है और डिस्क स्थान पर्याप्त है, फिर पुनः प्रयास करें।',
    'สร้างโฟลเดอร์โน้ตไม่สำเร็จ โปรดตรวจสอบว่าโฟลเดอร์จัดเก็บเขียนได้และพื้นที่ดิสก์เพียงพอ แล้วลองใหม่',
    'Tạo thư mục ghi chú thất bại. Kiểm tra xem thư mục lưu trữ có ghi được không và dung lượng đĩa có đủ không, rồi thử lại.',
    'Gagal membuat folder catatan. Periksa apakah folder penyimpanan dapat ditulis dan ruang disk cukup, lalu coba lagi.',
    'Not klasörü oluşturulamadı. Depolama klasörünün yazılabilir ve disk alanının yeterli olduğunu kontrol edip tekrar deneyin.',
    'Map voor notitie maken mislukt. Controleer of de opslagmap beschrijfbaar is en of er genoeg schijfruimte is, en probeer opnieuw.',
    'Nie udało się utworzyć folderu notatki. Sprawdź, czy folder przechowywania jest zapisywalny i czy jest wystarczająco miejsca na dysku, a następnie spróbuj ponownie.',
    'Не вдалося створити папку нотатки. Перевірте, чи папка зберігання доступна для запису та чи достатньо місця на диску, потім повторіть спробу.',
    'Kunde inte skapa anteckningsmappen. Kontrollera att lagringsmappen är skrivbar och att det finns tillräckligt med diskutrymme, och försök igen.',
])

add('右键「导出」可导出原始录音，或将转写、总结导出为 Markdown 或 PDF，也可一键复制内容', [
    '右鍵「匯出」可匯出原始錄音，或將轉寫、總結匯出為 Markdown 或 PDF，也可一鍵複製內容',
    'Right-click “Export” to export the original audio, or export the transcript and summary as Markdown or PDF; you can also copy everything with one click',
    '右クリックの「書き出す」で元の録音を書き出したり、文字起こしと要約を Markdown や PDF として書き出せます。ワンクリックで内容をコピーすることもできます。',
    '마우스 오른쪽 버튼의 ‘내보내기’로 원본 녹음을 내보내거나 전사와 요약을 Markdown 또는 PDF로 내보낼 수 있고, 한 번에 내용을 복사할 수도 있습니다.',
    "Un clic droit sur « Exporter » permet d'exporter l'enregistrement d'origine, ou d'exporter la transcription et le résumé en Markdown ou PDF ; vous pouvez aussi tout copier en un clic.",
    'Rechtsklick auf „Exportieren“ exportiert die Originalaufnahme oder exportiert Transkript und Zusammenfassung als Markdown oder PDF; der Inhalt lässt sich auch mit einem Klick kopieren.',
    'Con el clic derecho en «Exportar» puedes exportar la grabación original, o exportar la transcripción y el resumen como Markdown o PDF; también puedes copiar el contenido con un clic.',
    'Con il clic destro su «Esporta» puoi esportare la registrazione originale oppure esportare trascrizione e riepilogo in Markdown o PDF; puoi anche copiare il contenuto con un clic.',
    'Com o clique direito em «Exportar» pode exportar a gravação original ou exportar a transcrição e o resumo como Markdown ou PDF; também pode copiar o conteúdo com um clique.',
    'Правый клик по «Экспорт» позволяет экспортировать оригинальную запись или сохранить расшифровку и резюме в Markdown или PDF; содержимое можно скопировать одним щелчком.',
    'بالنقر بزر الفأرة الأيمن على «تصدير» يمكنك تصدير التسجيل الأصلي، أو تصدير النص والملخص بصيغة Markdown أو PDF، ويمكنك أيضًا نسخ المحتوى بنقرة واحدة.',
    'राइट-क्लिक «निर्यात» से मूल रिकॉर्डिंग निर्यात करें, या ट्रांसक्रिप्ट और सारांश को Markdown या PDF के रूप में निर्यात करें; एक क्लिक में सामग्री कॉपी भी कर सकते हैं',
    'คลิกขวา «ส่งออก» เพื่อส่งออกเสียงต้นฉบับ หรือส่งออกข้อความถอดความและสรุปเป็น Markdown หรือ PDF และยังคัดลอกเนื้อหาได้ในคลิกเดียว',
    'Nhấp chuột phải «Xuất» để xuất bản ghi gốc, hoặc xuất bản chuyển ngữ và tóm tắt dưới dạng Markdown hoặc PDF; cũng có thể sao chép nội dung bằng một cú nhấp.',
    'Klik kanan «Ekspor» untuk mengekspor rekaman asli, atau mengekspor transkripsi dan ringkasan sebagai Markdown atau PDF; Anda juga dapat menyalin isinya dengan sekali klik.',
    'Sağ tıklayıp «Dışa Aktar» ile orijinal kaydı dışa aktarabilir ya da çeviri yazı ve özeti Markdown veya PDF olarak dışa aktarabilirsiniz; içeriği tek tıkla da kopyalayabilirsiniz.',
    'Rechtsklik «Exporteren» om de originele opname te exporteren, of om transcriptie en samenvatting als Markdown of PDF te exporteren; je kunt de inhoud ook met één klik kopiëren.',
    'Kliknij prawym przyciskiem „Eksportuj”, aby wyeksportować oryginalne nagranie albo transkrypcję i podsumowanie jako Markdown lub PDF; możesz też skopiować treść jednym kliknięciem.',
    'Клацніть правою кнопкою «Експорт», щоб експортувати оригінальний запис або зберегти транскрипцію й підсумок у Markdown чи PDF; вміст можна скопіювати одним клацанням.',
    'Högerklicka på «Exportera» för att exportera originalinspelningen, eller exportera transkribering och sammanfattning som Markdown eller PDF; du kan också kopiera innehållet med ett klick.',
])

add('合并', [
    '合併', 'Merge', '統合', '병합', 'Fusionner', 'Zusammenführen', 'Combinar', 'Unisci',
    'Juntar', 'Объединить', 'دمج', 'मर्ज', 'รวม', 'Hợp nhất', 'Gabung', 'Birleştir',
    'Samenvoegen', 'Scal', 'Об’єднати', 'Slå samman',
])

add('合并同名', [
    '合併同名', 'Merge same-name', '同名を統合', '같은 이름 병합', 'Fusionner les homonymes',
    'Gleichnamige zusammenführen', 'Combinar homónimos', 'Unisci omonimi', 'Juntar homónimos',
    'Объединить одноимённые', 'دمج المتطابقة بالاسم', 'समान नाम मर्ज करें', 'รวมชื่อเดียวกัน',
    'Hợp nhất cùng tên', 'Gabung nama sama', 'Aynı adlıları birleştir', 'Gelijkluidende samenvoegen',
    'Scal o tej samej nazwie', 'Об’єднати однойменні', 'Slå samman med samma namn',
])

add('合并同名声纹', [
    '合併同名聲紋', 'Merge same-name voiceprints', '同名の声紋を統合', '같은 이름 음성 지문 병합',
    'Fusionner les empreintes vocales homonymes', 'Gleichnamige Stimmprofile zusammenführen',
    'Combinar huellas de voz homónimas', 'Unisci impronte vocali omonime', 'Juntar impressões vocais homónimas',
    'Объединить одноимённые голосовые отпечатки', 'دمج البصمات الصوتية المتطابقة بالاسم',
    'समान नाम के वॉयसप्रिंट मर्ज करें', 'รวมลายเสียงชื่อเดียวกัน', 'Hợp nhất dấu vân giọng nói cùng tên',
    'Gabung sidik suara bernama sama', 'Aynı adlı ses izlerini birleştir',
    'Gelijknamige spraakafdrukken samenvoegen', 'Scal odciski głosu o tej samej nazwie',
    'Об’єднати однойменні голосові відбитки', 'Slå samman röstavtryck med samma namn',
])

add('合并失败：%@', [
    '合併失敗：%@', 'Merge failed: %@', '統合に失敗：%@', '병합 실패: %@', 'Échec de la fusion : %@',
    'Zusammenführen fehlgeschlagen: %@', 'Error al combinar: %@', 'Unione non riuscita: %@',
    'Falha ao juntar: %@', 'Не удалось объединить: %@', 'فشل الدمج: %@', 'मर्ज विफल: %@',
    'รวมไม่สำเร็จ: %@', 'Hợp nhất thất bại: %@', 'Gabung gagal: %@', 'Birleştirme başarısız: %@',
    'Samenvoegen mislukt: %@', 'Scalanie nie powiodło się: %@', 'Не вдалося об’єднати: %@',
    'Sammanslagning misslyckades: %@',
])

add('后台任务进程仍占用数据库，为避免两个进程同时写入损坏数据，本次运行以临时模式启动、不会保存任何改动。\n请退出应用后重新打开；若反复出现，可在「活动监视器」中结束 Memozia 的后台进程。', [
    '背景工作程序仍占用資料庫，為避免兩個程序同時寫入造成資料損毀，本次執行以臨時模式啟動、不會儲存任何變更。\n請結束應用程式後重新開啟；若反覆出現，可在「活動監視器」中結束 Memozia 的背景程序。',
    'A background task process still holds the database. To avoid data corruption from two processes writing at once, this run started in temporary mode and will not save any changes.\nQuit the app and open it again; if this keeps happening, end Memozia’s background process in Activity Monitor.',
    'バックグラウンドタスクのプロセスがまだデータベースを使用中です。2 つのプロセスが同時に書き込むとデータが壊れるため、今回は一時モードで起動し、変更は保存されません。\nアプリを終了して開き直してください。繰り返す場合は「アクティビティモニタ」で Memozia のバックグラウンドプロセスを終了してください。',
    '백그라운드 작업 프로세스가 아직 데이터베이스를 사용 중입니다. 두 프로세스가 동시에 쓰면 데이터가 손상될 수 있어 이번 실행은 임시 모드로 시작되었고 어떤 변경도 저장되지 않습니다.\n앱을 종료한 뒤 다시 열어 주세요. 반복되면 ‘활성 상태 보기’에서 Memozia 백그라운드 프로세스를 종료하세요.',
    "Un processus de tâche d'arrière-plan utilise encore la base de données. Pour éviter une corruption par double écriture, cette session a démarré en mode temporaire et n'enregistrera aucun changement.\nQuittez l'app et rouvrez-la ; si cela se reproduit, terminez le processus d'arrière-plan de Memozia dans le Moniteur d'activité.",
    'Ein Hintergrundprozess belegt noch die Datenbank. Um Datenverlust durch gleichzeitiges Schreiben zu vermeiden, läuft diese Sitzung im temporären Modus und speichert keine Änderungen.\nBeenden Sie die App und öffnen Sie sie erneut; falls das wiederholt auftritt, beenden Sie den Hintergrundprozess von Memozia in der Aktivitätsanzeige.',
    'Un proceso de tarea en segundo plano aún ocupa la base de datos. Para evitar corrupción por escritura simultánea, esta ejecución se inició en modo temporal y no guardará ningún cambio.\nSal de la app y vuelve a abrirla; si se repite, finaliza el proceso en segundo plano de Memozia en el Monitor de Actividad.',
    "Un processo di attività in background occupa ancora il database. Per evitare corruzione da doppia scrittura, questa esecuzione è partita in modalità temporanea e non salverà alcuna modifica.\nEsci dall'app e riaprila; se si ripete, termina il processo in background di Memozia in Monitoraggio Attività.",
    'Um processo de tarefa em segundo plano ainda ocupa a base de dados. Para evitar corrupção por escrita simultânea, esta execução iniciou em modo temporário e não guardará alterações.\nSaia da aplicação e abra-a novamente; se persistir, termine o processo em segundo plano do Memozia no Monitor de Atividade.',
    'Процесс фоновой задачи всё ещё занимает базу данных. Чтобы избежать повреждения при одновременной записи, этот запуск выполнен во временном режиме и не сохранит изменения.\nВыйдите из приложения и откройте его снова; если это повторяется, завершите фоновый процесс Memozia в «Мониторе системы».',
    'لا تزال إحدى عمليات المهام في الخلفية تستخدم قاعدة البيانات. لتجنّب تلف البيانات بسبب الكتابة المتزامنة، بدأ هذا التشغيل في الوضع المؤقت ولن يحفظ أي تغييرات.\nاخرج من التطبيق ثم افتحه مجددًا؛ وإذا تكرر الأمر، أنهِ عملية Memozia الخلفية من «مراقبة النشاط».',
    'कोई पृष्ठभूमि कार्य प्रक्रिया अभी भी डेटाबेस का उपयोग कर रही है। एक साथ दो प्रक्रियाओं के लिखने से डेटा खराब होने से बचाने के लिए यह बार अस्थायी मोड में शुरू हुआ है और कोई बदलाव सहेजा नहीं जाएगा।\nऐप से बाहर निकलकर फिर से खोलें; बार-बार होने पर «गतिविधि मॉनिटर» में Memozia की पृष्ठभूमि प्रक्रिया समाप्त करें।',
    'มีโปรเซสงานเบื้องหลังยังใช้ฐานข้อมูลอยู่ เพื่อป้องกันข้อมูลเสียหายจากการเขียนพร้อมกัน ครั้งนี้จึงเริ่มในโหมดชั่วคราวและจะไม่บันทึกการเปลี่ยนแปลงใด ๆ\nโปรดออกจากแอปแล้วเปิดใหม่ หากเกิดซ้ำ ให้สิ้นสุดโปรเซสเบื้องหลังของ Memozia ใน «มอนิเตอร์กิจกรรม»',
    'Có tiến trình tác vụ nền vẫn đang chiếm cơ sở dữ liệu. Để tránh hỏng dữ liệu do hai tiến trình ghi cùng lúc, lần chạy này khởi động ở chế độ tạm thời và sẽ không lưu thay đổi nào.\nHãy thoát ứng dụng rồi mở lại; nếu vẫn tái diễn, hãy kết thúc tiến trình nền của Memozia trong «Theo dõi hoạt động».',
    'Proses tugas latar belakang masih memakai basis data. Agar data tidak rusak karena dua proses menulis bersamaan, sesi ini dimulai dalam mode sementara dan tidak akan menyimpan perubahan apa pun.\nKeluar dari aplikasi lalu buka lagi; jika terus terjadi, akhiri proses latar belakang Memozia di «Monitor Aktivitas».',
    'Bir arka plan görev süreci hâlâ veritabanını kullanıyor. İki sürecin aynı anda yazması veriyi bozmasın diye bu oturum geçici modda başlatıldı ve hiçbir değişiklik kaydedilmeyecek.\nUygulamadan çıkıp yeniden açın; tekrarlanırsa Memozia’nun arka plan sürecini «Etkinlik Monitörü»nde sonlandırın.',
    'Een achtergrondtaakproces gebruikt de database nog. Om gegevensbeschadiging door gelijktijdig schrijven te voorkomen, is deze sessie in tijdelijke modus gestart en worden geen wijzigingen opgeslagen.\nSluit de app af en open deze opnieuw; als dit blijft gebeuren, beëindig dan het achtergrondproces van Memozia in «Activiteitenweergave».',
    'Proces zadania w tle nadal zajmuje bazę danych. Aby uniknąć uszkodzenia danych przez jednoczesny zapis, ten przebieg uruchomiono w trybie tymczasowym i nie zapisze on żadnych zmian.\nZamknij aplikację i otwórz ją ponownie; jeśli to się powtarza, zakończ proces w tle Memozia w „Monitorze aktywności”.',
    'Фоновий процес завдання все ще займає базу даних. Щоб уникнути пошкодження даних через одночасний запис, цей запуск виконано в тимчасовому режимі й жодні зміни не збережуться.\nВийдіть із застосунку та відкрийте його знову; якщо це повторюється, завершіть фоновий процес Memozia у «Моніторі активності».',
    'En bakgrundsprocess använder fortfarande databasen. För att undvika dataförstöring när två processer skriver samtidigt startade denna körning i tillfälligt läge och sparar inga ändringar.\nAvsluta appen och öppna den igen; om det upprepas, avsluta Memozias bakgrundsprocess i «Aktivitetsövervakning».',
])

add('声源', [
    '聲源', 'Audio Source', '音声ソース', '오디오 소스', 'Source audio', 'Audioquelle',
    'Fuente de audio', 'Sorgente audio', 'Fonte de áudio', 'Источник звука', 'مصدر الصوت',
    'ऑडियो स्रोत', 'แหล่งเสียง', 'Nguồn âm thanh', 'Sumber audio', 'Ses kaynağı',
    'Audiobron', 'Źródło dźwięku', 'Джерело звуку', 'Ljudkälla',
])

add('声源：%@', [
    '聲源：%@', 'Audio source: %@', '音声ソース：%@', '오디오 소스: %@', 'Source audio : %@',
    'Audioquelle: %@', 'Fuente de audio: %@', 'Sorgente audio: %@', 'Fonte de áudio: %@',
    'Источник звука: %@', 'مصدر الصوت: %@', 'ऑडियो स्रोत: %@', 'แหล่งเสียง: %@',
    'Nguồn âm thanh: %@', 'Sumber audio: %@', 'Ses kaynağı: %@', 'Audiobron: %@',
    'Źródło dźwięku: %@', 'Джерело звуку: %@', 'Ljudkälla: %@',
])

add('导入', [
    '匯入', 'Import', '取り込む', '가져오기', 'Importer', 'Importieren', 'Importar', 'Importa',
    'Importar', 'Импорт', 'استيراد', 'आयात', 'นำเข้า', 'Nhập', 'Impor', 'İçe Aktar',
    'Importeren', 'Importuj', 'Імпорт', 'Importera',
])

add('导入条目的元数据写入失败', [
    '匯入項目的中繼資料寫入失敗',
    'Failed to write metadata for the imported item',
    '取り込んだ項目のメタデータ書き込みに失敗',
    '가져온 항목의 메타데이터 쓰기 실패',
    "Échec de l'écriture des métadonnées de l'élément importé",
    'Metadaten des importierten Eintrags konnten nicht geschrieben werden',
    'Error al escribir los metadatos del elemento importado',
    "Scrittura dei metadati dell'elemento importato non riuscita",
    'Falha ao escrever os metadados do item importado',
    'Не удалось записать метаданные импортированного элемента',
    'فشل كتابة البيانات الوصفية للعنصر المستورد',
    'आयातित आइटम का मेटाडेटा लिखना विफल',
    'เขียนข้อมูลเมตาของรายการที่นำเข้าไม่สำเร็จ',
    'Ghi siêu dữ liệu của mục đã nhập thất bại',
    'Gagal menulis metadata item yang diimpor',
    'İçe aktarılan öğenin üst verileri yazılamadı',
    'Metagegevens van geïmporteerd item schrijven mislukt',
    'Nie udało się zapisać metadanych zaimportowanego elementu',
    'Не вдалося записати метадані імпортованого елемента',
    'Kunde inte skriva metadata för det importerade objektet',
])

add('导出总结为 .pdf', [
    '匯出總結為 .pdf', 'Export summary as .pdf', '要約を .pdf として書き出す', '요약을 .pdf로 내보내기',
    'Exporter le résumé en .pdf', 'Zusammenfassung als .pdf exportieren', 'Exportar resumen como .pdf',
    'Esporta riepilogo come .pdf', 'Exportar resumo como .pdf', 'Экспорт резюме в .pdf',
    'تصدير الملخص بصيغة .pdf', 'सारांश को .pdf के रूप में निर्यात करें', 'ส่งออกสรุปเป็น .pdf',
    'Xuất tóm tắt dưới dạng .pdf', 'Ekspor ringkasan sebagai .pdf', 'Özeti .pdf olarak dışa aktar',
    'Samenvatting exporteren als .pdf', 'Eksportuj podsumowanie jako .pdf',
    'Експортувати підсумок як .pdf', 'Exportera sammanfattning som .pdf',
])

add('导出转写为 .pdf', [
    '匯出轉寫為 .pdf', 'Export transcript as .pdf', '文字起こしを .pdf として書き出す', '전사를 .pdf로 내보내기',
    'Exporter la transcription en .pdf', 'Transkript als .pdf exportieren', 'Exportar transcripción como .pdf',
    'Esporta trascrizione come .pdf', 'Exportar transcrição como .pdf', 'Экспорт расшифровки в .pdf',
    'تصدير النص بصيغة .pdf', 'ट्रांसक्रिप्ट को .pdf के रूप में निर्यात करें', 'ส่งออกข้อความถอดความเป็น .pdf',
    'Xuất bản chuyển ngữ dưới dạng .pdf', 'Ekspor transkripsi sebagai .pdf', 'Çeviri yazıyı .pdf olarak dışa aktar',
    'Transcriptie exporteren als .pdf', 'Eksportuj transkrypcję jako .pdf',
    'Експортувати транскрипцію як .pdf', 'Exportera transkribering som .pdf',
])

add('将同名且同模型的多条声纹按样本数加权合并为一条（向量取质心，来源录音合并）；无跨模型合并，原条目归入最早一条。', [
    '將同名且同模型的多條聲紋按樣本數加權合併為一條（向量取質心，來源錄音合併）；不跨模型合併，原條目歸入最早一條。',
    'Merges multiple voiceprints with the same name and model into one, weighted by sample count (the vector becomes the centroid and the source recordings are merged); no cross-model merging, and the original entries fold into the earliest one.',
    '同じ名前かつ同じモデルの複数の声紋を、サンプル数で重み付けして 1 件に統合します（ベクトルは重心、元の録音は統合）。モデルをまたぐ統合は行わず、元の項目は最も古い 1 件にまとめられます。',
    '같은 이름과 같은 모델의 여러 음성 지문을 샘플 수로 가중해 하나로 병합합니다(벡터는 중심, 원본 녹음은 병합). 모델 간 병합은 하지 않으며 원래 항목은 가장 이른 항목에 합쳐집니다.',
    "Fusionne plusieurs empreintes vocales de même nom et même modèle en une seule, pondérée par le nombre d'échantillons (le vecteur devient le centroïde, les enregistrements sources sont fusionnés) ; pas de fusion entre modèles, les entrées d'origine sont regroupées dans la plus ancienne.",
    'Mehrere Stimmprofile mit gleichem Namen und Modell werden nach Stichprobenzahl gewichtet zu einem zusammengeführt (Vektor als Schwerpunkt, Quellaufnahmen zusammengelegt); keine modellübergreifende Zusammenführung, die ursprünglichen Einträge gehen in den ältesten über.',
    'Combina varias huellas de voz con el mismo nombre y modelo en una sola, ponderada por el número de muestras (el vector pasa a ser el centroide y se combinan las grabaciones de origen); sin combinación entre modelos, y las entradas originales se integran en la más antigua.',
    'Unisce più impronte vocali con lo stesso nome e modello in una sola, ponderata per il numero di campioni (il vettore diventa il centroide e le registrazioni di origine vengono unite); nessuna unione tra modelli e le voci originali confluiscono nella più antica.',
    'Junta várias impressões vocais com o mesmo nome e modelo numa só, ponderada pelo número de amostras (o vetor passa a ser o centroide e as gravações de origem são combinadas); sem junção entre modelos, e os itens originais são integrados no mais antigo.',
    'Объединяет несколько голосовых отпечатков с одинаковым именем и моделью в один с весами по числу образцов (вектор становится центроидом, исходные записи объединяются); слияния между моделями нет, исходные элементы попадают в самый ранний.',
    'تدمج عدة بصمات صوتية بالاسم والنموذج نفسهما في بصمة واحدة بترجيح عدد العينات (يصبح المتجه مركز الثقل وتُدمج التسجيلات المصدر)؛ ولا يوجد دمج بين النماذج، وتُضم العناصر الأصلية إلى الأقدم.',
    'समान नाम और समान मॉडल के कई वॉयसप्रिंट को नमूनों की संख्या से भारित करके एक में मर्ज करता है (वेक्टर केंद्रक बनता है, स्रोत रिकॉर्डिंग मर्ज होती हैं); मॉडल के बीच मर्ज नहीं होता, मूल प्रविष्टियाँ सबसे पुरानी में समाहित होती हैं।',
    'รวมลายเสียงหลายรายการที่ชื่อและโมเดลเดียวกันเป็นหนึ่งรายการโดยถ่วงน้ำหนักตามจำนวนตัวอย่าง (เวกเตอร์เป็นค่ากลาง และบันทึกต้นทางถูกรวม) ไม่รวมข้ามโมเดล และรายการเดิมจะถูกรวมเข้าที่เก่าที่สุด',
    'Hợp nhất nhiều dấu vân giọng nói cùng tên và cùng mô hình thành một, có trọng số theo số mẫu (vector lấy trung tâm, các bản ghi nguồn được hợp nhất); không hợp nhất khác mô hình, các mục gốc được gộp vào mục sớm nhất.',
    'Gabungkan beberapa sidik suara dengan nama dan model sama menjadi satu, ditimbang berdasarkan jumlah sampel (vektor menjadi centroid dan rekaman sumber digabung); tidak ada penggabungan antar model, dan item asli masuk ke yang paling awal.',
    'Aynı ad ve aynı modele sahip birden çok ses izini örnek sayısına göre ağırlıklı olarak tek bir izde birleştirir (vektör ağırlık merkezi olur, kaynak kayıtlar birleştirilir); modeller arası birleştirme yoktur ve asıl öğeler en erken olana katılır.',
    'Voegt meerdere spraakafdrukken met dezelfde naam en hetzelfde model samen tot één, gewogen naar aantal monsters (de vector wordt het zwaartepunt en de bronopnamen worden samengevoegd); geen samenvoeging tussen modellen, en de oorspronkelijke items gaan op in de oudste.',
    'Scala wiele odcisków głosu o tej samej nazwie i modelu w jeden, ważony liczbą próbek (wektor staje się centroidem, nagrania źródłowe są scalane); brak scalania między modelami, a oryginalne elementy trafiają do najstarszego.',
    'Об’єднує кілька голосових відбитків з однаковою назвою та моделлю в один із зважуванням за кількістю зразків (вектор стає центроїдом, вихідні записи об’єднуються); міжмодельного об’єднання немає, вихідні елементи долучаються до найранішого.',
    'Slår samman flera röstavtryck med samma namn och modell till ett, viktat efter antal prover (vektorn blir centroiden och källinspelningarna slås samman); ingen sammanslagning mellan modeller och de ursprungliga objekten förs till det tidigaste.',
])

add('已合并 %lld 组同名声纹', [
    '已合併 %lld 組同名聲紋',
    'Merged %lld same-name voiceprint groups',
    '同名の声紋を %lld 組統合しました',
    '같은 이름 음성 지문 %lld개 그룹을 병합했습니다',
    "Fusion de %lld groupes d'empreintes vocales homonymes",
    '%lld Gruppen gleichnamiger Stimmprofile zusammengeführt',
    'Se combinaron %lld grupos de huellas de voz homónimas',
    'Uniti %lld gruppi di impronte vocali omonime',
    '%lld grupos de impressões vocais homónimas foram juntos',
    'Объединено групп одноимённых голосовых отпечатков: %lld',
    'تم دمج %lld من مجموعات البصمات الصوتية المتطابقة بالاسم',
    '%lld समान नाम वाले वॉयसप्रिंट समूह मर्ज किए गए',
    'รวมลายเสียงชื่อเดียวกัน %lld กลุ่มแล้ว',
    'Đã hợp nhất %lld nhóm dấu vân giọng nói cùng tên',
    'Menggabungkan %lld grup sidik suara bernama sama',
    '%lld aynı adlı ses izi grubu birleştirildi',
    '%lld groepen gelijknamige spraakafdrukken samengevoegd',
    'Scalono %lld grup odcisków głosu o tej samej nazwie',
    'Об’єднано груп однойменних голосових відбитків: %lld',
    'Slagit samman %lld grupper med röstavtryck med samma namn',
])

add('库内存在同名多条目：加权合并为一条', [
    '庫內存在同名多條目：加權合併為一條',
    'Multiple entries share the same name in the library: merge them into one by weighted average',
    'ライブラリに同名の複数項目があります：加重平均で 1 件に統合します',
    '라이브러리에 같은 이름의 항목이 여러 개 있습니다: 가중 평균으로 하나로 병합합니다',
    'Plusieurs entrées portent le même nom dans la bibliothèque : fusionnez-les en une par moyenne pondérée',
    'In der Bibliothek gibt es mehrere gleichnamige Einträge: nach Gewichtung zu einem zusammenführen',
    'Hay varias entradas con el mismo nombre en la biblioteca: combínalas en una con media ponderada',
    'Nella libreria esistono più voci con lo stesso nome: uniscile in una con media ponderata',
    'Existem várias entradas com o mesmo nome na biblioteca: junte-as numa só por média ponderada',
    'В библиотеке есть несколько элементов с одинаковым именем: объедините их в один с весами',
    'توجد عدة عناصر بالاسم نفسه في المكتبة: ادمجها في عنصر واحد بمتوسط مرجّح',
    'लाइब्रेरी में एक ही नाम की कई प्रविष्टियाँ हैं: भारित औसत से एक में मर्ज करें',
    'มีหลายรายการชื่อเดียวกันในคลัง: รวมเป็นหนึ่งด้วยค่าเฉลี่ยถ่วงน้ำหนัก',
    'Thư viện có nhiều mục cùng tên: hợp nhất thành một bằng trung bình có trọng số',
    'Ada beberapa item bernama sama di pustaka: gabungkan menjadi satu dengan rata-rata tertimbang',
    'Kitaplıkta aynı adlı birden çok öğe var: ağırlıklı ortalamayla tek öğede birleştirin',
    'Er staan meerdere items met dezelfde naam in de bibliotheek: voeg ze samen tot één met gewogen gemiddelde',
    'W bibliotece istnieje kilka elementów o tej samej nazwie: scal je w jeden metodą średniej ważonej',
    'У бібліотеці є кілька елементів з однаковою назвою: об’єднайте їх в один зі зважуванням',
    'Det finns flera objekt med samma namn i biblioteket: slå samman dem till ett med viktat medelvärde',
])

add('待办文件写入失败：%@', [
    '待辦檔案寫入失敗：%@',
    'Failed to write the to-do file: %@',
    'ToDo ファイルの書き込みに失敗：%@',
    '할 일 파일 쓰기 실패: %@',
    "Échec de l'écriture du fichier de tâches : %@",
    'Aufgabendatei konnte nicht geschrieben werden: %@',
    'Error al escribir el archivo de tareas: %@',
    'Scrittura del file delle attività non riuscita: %@',
    'Falha ao escrever o ficheiro de tarefas: %@',
    'Не удалось записать файл задач: %@',
    'فشل كتابة ملف المهام: %@',
    'कार्य फ़ाइल लिखना विफल: %@',
    'เขียนไฟล์งานไม่สำเร็จ: %@',
    'Ghi tệp việc cần làm thất bại: %@',
    'Gagal menulis file tugas: %@',
    'Görev dosyası yazılamadı: %@',
    'Takenbestand schrijven mislukt: %@',
    'Nie udało się zapisać pliku zadań: %@',
    'Не вдалося записати файл завдань: %@',
    'Kunde inte skriva uppgiftsfilen: %@',
])

add('总结内容支持编辑和导出为 Markdown 或 PDF', [
    '總結內容支援編輯和匯出為 Markdown 或 PDF',
    'The summary can be edited and exported as Markdown or PDF',
    '要約は編集でき、Markdown や PDF として書き出せます',
    '요약은 편집할 수 있고 Markdown 또는 PDF로 내보낼 수 있습니다',
    'Le résumé peut être modifié et exporté en Markdown ou PDF',
    'Die Zusammenfassung lässt sich bearbeiten und als Markdown oder PDF exportieren',
    'El resumen se puede editar y exportar como Markdown o PDF',
    'Il riepilogo può essere modificato ed esportato in Markdown o PDF',
    'O resumo pode ser editado e exportado como Markdown ou PDF',
    'Резюме можно редактировать и экспортировать в Markdown или PDF',
    'يمكن تعديل الملخص وتصديره بصيغة Markdown أو PDF',
    'सारांश संपादित करके Markdown या PDF के रूप में निर्यात किया जा सकता है',
    'สรุปแก้ไขได้และส่งออกเป็น Markdown หรือ PDF',
    'Có thể chỉnh sửa tóm tắt và xuất dưới dạng Markdown hoặc PDF',
    'Ringkasan dapat diedit dan diekspor sebagai Markdown atau PDF',
    'Özet düzenlenebilir ve Markdown veya PDF olarak dışa aktarılabilir',
    'De samenvatting kan worden bewerkt en geëxporteerd als Markdown of PDF',
    'Podsumowanie można edytować i eksportować jako Markdown lub PDF',
    'Підсумок можна редагувати й експортувати як Markdown або PDF',
    'Sammanfattningen kan redigeras och exporteras som Markdown eller PDF',
])

add('批量总结全部失败（%lld 个）', [
    '批次總結全部失敗（%lld 個）',
    'Batch summary failed for all (%lld)',
    '一括要約はすべて失敗しました（%lld 件）',
    '일괄 요약 모두 실패(%lld개)',
    'Le résumé par lots a échoué pour tous (%lld)',
    'Stapelzusammenfassung vollständig fehlgeschlagen (%lld)',
    'El resumen por lotes falló para todos (%lld)',
    'Riepilogo in blocco non riuscito per tutti (%lld)',
    'O resumo em lote falhou para todos (%lld)',
    'Пакетное резюме не удалось для всех (%lld)',
    'فشل الملخص الجماعي للجميع (%lld)',
    'बैच सारांश सभी के लिए विफल (%lld)',
    'สรุปแบบชุดล้มเหลวทั้งหมด (%lld)',
    'Tóm tắt hàng loạt thất bại tất cả (%lld)',
    'Ringkasan massal gagal semua (%lld)',
    'Toplu özet tümü için başarısız (%lld)',
    'Batchsamenvatting mislukt voor alle (%lld)',
    'Podsumowanie zbiorcze nie powiodło się dla wszystkich (%lld)',
    'Пакетний підсумок не вдався для всіх (%lld)',
    'Batchsammanfattning misslyckades för alla (%lld)',
])

add('批量转写全部失败（%lld 个）。请检查模型是否已加载或网络是否正常。', [
    '批次轉寫全部失敗（%lld 個）。請檢查模型是否已載入或網路是否正常。',
    'Batch transcription failed for all (%lld). Please check whether the model is loaded or the network is working.',
    '一括文字起こしはすべて失敗しました（%lld 件）。モデルが読み込まれているか、ネットワークが正常か確認してください。',
    '일괄 전사 모두 실패(%lld개). 모델이 로드되었는지 또는 네트워크가 정상인지 확인하세요.',
    'La transcription par lots a échoué pour tous (%lld). Vérifiez que le modèle est chargé ou que le réseau fonctionne.',
    'Stapeltranskription vollständig fehlgeschlagen (%lld). Bitte prüfen Sie, ob das Modell geladen ist oder das Netzwerk funktioniert.',
    'La transcripción por lotes falló para todas (%lld). Comprueba si el modelo está cargado o si la red funciona.',
    'La trascrizione in blocco non è riuscita per tutti (%lld). Controlla che il modello sia caricato o che la rete funzioni.',
    'A transcrição em lote falhou para todas (%lld). Verifique se o modelo está carregado ou se a rede está a funcionar.',
    'Пакетная расшифровка не удалась для всех (%lld). Проверьте, загружена ли модель и работает ли сеть.',
    'فشل التفريغ الجماعي للجميع (%lld). تحقق من تحميل النموذج أو من عمل الشبكة.',
    'बैच ट्रांसक्रिप्शन सभी के लिए विफल (%lld)। जाँचें कि मॉडल लोड है या नेटवर्क काम कर रहा है।',
    'การถอดความแบบชุดล้มเหลวทั้งหมด (%lld) โปรดตรวจสอบว่าโหลดโมเดลแล้วหรือเครือข่ายทำงานอยู่',
    'Chuyển ngữ hàng loạt thất bại tất cả (%lld). Vui lòng kiểm tra mô hình đã được tải chưa hoặc mạng có hoạt động không.',
    'Transkripsi massal gagal semua (%lld). Silakan periksa apakah model sudah dimuat atau jaringan berfungsi.',
    'Toplu çeviri yazı tümü için başarısız (%lld). Lütfen modelin yüklü olup olmadığını veya ağın çalışıp çalışmadığını kontrol edin.',
    'Batchtranscriptie mislukt voor alle (%lld). Controleer of het model is geladen of het netwerk werkt.',
    'Transkrypcja zbiorcza nie powiodła się dla wszystkich (%lld). Sprawdź, czy model jest wczytany lub czy sieć działa.',
    'Пакетне транскрибування не вдалося для всіх (%lld). Перевірте, чи завантажено модель або чи працює мережа.',
    'Batchtranskribering misslyckades för alla (%lld). Kontrollera om modellen är inläst eller om nätverket fungerar.',
])

add('数据库被后台任务占用', [
    '資料庫被背景工作程序占用',
    'The database is in use by a background task',
    'データベースはバックグラウンドタスクが使用中です',
    '데이터베이스가 백그라운드 작업에서 사용 중입니다',
    "La base de données est utilisée par une tâche d'arrière-plan",
    'Die Datenbank wird von einer Hintergrundaufgabe verwendet',
    'La base de datos está siendo usada por una tarea en segundo plano',
    "Il database è in uso da un'attività in background",
    'A base de dados está a ser usada por uma tarefa em segundo plano',
    'База данных занята фоновой задачей',
    'قاعدة البيانات قيد الاستخدام من مهمة في الخلفية',
    'डेटाबेस पृष्ठभूमि कार्य द्वारा उपयोग में है',
    'ฐานข้อมูลถูกใช้งานโดยงานเบื้องหลัง',
    'Cơ sở dữ liệu đang được tác vụ nền sử dụng',
    'Basis data sedang dipakai oleh tugas latar belakang',
    'Veritabanı bir arka plan görevi tarafından kullanılıyor',
    'De database wordt gebruikt door een achtergrondtaak',
    'Baza danych jest zajęta przez zadanie w tle',
    'База даних зайнята фоновим завданням',
    'Databasen används av en bakgrundsuppgift',
])

add('无法创建 PDF 导出通道，请重试或检查磁盘空间。', [
    '無法建立 PDF 匯出通道，請重試或檢查磁碟空間。',
    "Couldn't create the PDF export channel; try again or check disk space.",
    'PDF 書き出し用のチャネルを作成できません。再試行するか、ディスク容量を確認してください。',
    'PDF 내보내기 채널을 만들 수 없습니다. 다시 시도하거나 디스크 공간을 확인하세요.',
    "Impossible de créer le canal d'export PDF ; réessayez ou vérifiez l'espace disque.",
    'PDF-Exportkanal konnte nicht erstellt werden; versuchen Sie es erneut oder prüfen Sie den Speicherplatz.',
    'No se pudo crear el canal de exportación a PDF; vuelve a intentarlo o comprueba el espacio en disco.',
    'Impossibile creare il canale di esportazione PDF; riprova o controlla lo spazio su disco.',
    'Não foi possível criar o canal de exportação em PDF; tente novamente ou verifique o espaço em disco.',
    'Не удалось создать канал экспорта PDF; повторите попытку или проверьте место на диске.',
    'تعذّر إنشاء قناة تصدير PDF؛ أعد المحاولة أو تحقق من مساحة القرص.',
    'PDF निर्यात चैनल नहीं बनाया जा सका; पुनः प्रयास करें या डिस्क स्थान जाँचें।',
    'สร้างช่องทางส่งออก PDF ไม่ได้ โปรดลองใหม่หรือตรวจสอบพื้นที่ดิสก์',
    'Không tạo được kênh xuất PDF; hãy thử lại hoặc kiểm tra dung lượng đĩa.',
    'Tidak dapat membuat saluran ekspor PDF; coba lagi atau periksa ruang disk.',
    'PDF dışa aktarma kanalı oluşturulamadı; tekrar deneyin veya disk alanını kontrol edin.',
    'Kan PDF-export niet aanmaken; probeer opnieuw of controleer de schijfruimte.',
    'Nie można utworzyć kanału eksportu PDF; spróbuj ponownie lub sprawdź miejsce na dysku.',
    'Не вдалося створити канал експорту PDF; повторіть спробу або перевірте місце на диску.',
    'Kunde inte skapa PDF-exportkanalen; försök igen eller kontrollera diskutrymmet.',
])

add('无法创建 PDF 画布，请重试。', [
    '無法建立 PDF 畫布，請重試。',
    "Couldn't create the PDF canvas; try again.",
    'PDF キャンバスを作成できません。再試行してください。',
    'PDF 캔버스를 만들 수 없습니다. 다시 시도하세요.',
    'Impossible de créer le canevas PDF ; réessayez.',
    'PDF-Leinwand konnte nicht erstellt werden; versuchen Sie es erneut.',
    'No se pudo crear el lienzo PDF; vuelve a intentarlo.',
    'Impossibile creare la tela PDF; riprova.',
    'Não foi possível criar a tela PDF; tente novamente.',
    'Не удалось создать холст PDF; повторите попытку.',
    'تعذّر إنشاء لوحة PDF؛ أعد المحاولة.',
    'PDF कैनवास नहीं बनाया जा सका; पुनः प्रयास करें।',
    'สร้างแคนวาส PDF ไม่ได้ โปรดลองใหม่',
    'Không tạo được khung vẽ PDF; hãy thử lại.',
    'Tidak dapat membuat kanvas PDF; coba lagi.',
    'PDF tuvali oluşturulamadı; tekrar deneyin.',
    'Kan PDF-canvas niet aanmaken; probeer opnieuw.',
    'Nie można utworzyć kanwy PDF; spróbuj ponownie.',
    'Не вдалося створити полотно PDF; повторіть спробу.',
    'Kunde inte skapa PDF-ytan; försök igen.',
])

add('无法读取所选文件', [
    '無法讀取所選檔案',
    "Couldn't read the selected file",
    '選択したファイルを読み取れません',
    '선택한 파일을 읽을 수 없습니다',
    'Impossible de lire le fichier sélectionné',
    'Die ausgewählte Datei konnte nicht gelesen werden',
    'No se pudo leer el archivo seleccionado',
    'Impossibile leggere il file selezionato',
    'Não foi possível ler o ficheiro selecionado',
    'Не удалось прочитать выбранный файл',
    'تعذّر قراءة الملف المحدد',
    'चुनी गई फ़ाइल पढ़ी नहीं जा सकी',
    'อ่านไฟล์ที่เลือกไม่ได้',
    'Không đọc được tệp đã chọn',
    'Tidak dapat membaca file yang dipilih',
    'Seçilen dosya okunamadı',
    'Kan het geselecteerde bestand niet lezen',
    'Nie można odczytać wybranego pliku',
    'Не вдалося прочитати вибраний файл',
    'Kunde inte läsa den valda filen',
])

add('标准', [
    '標準', 'Standard', '標準', '표준', 'Standard', 'Standard', 'Estándar', 'Standard',
    'Padrão', 'Стандарт', 'قياسي', 'मानक', 'มาตรฐาน', 'Tiêu chuẩn', 'Standar', 'Standart',
    'Standaard', 'Standard', 'Стандарт', 'Standard',
])

add('没有可合并的同名声纹', [
    '沒有可合併的同名聲紋',
    'No same-name voiceprints to merge',
    '統合できる同名の声紋がありません',
    '병합할 같은 이름의 음성 지문이 없습니다',
    'Aucune empreinte vocale homonyme à fusionner',
    'Keine gleichnamigen Stimmprofile zum Zusammenführen',
    'No hay huellas de voz homónimas para combinar',
    'Nessuna impronta vocale omonima da unire',
    'Não há impressões vocais homónimas para juntar',
    'Нет одноимённых голосовых отпечатков для объединения',
    'لا توجد بصمات صوتية متطابقة بالاسم لدمجها',
    'मर्ज करने के लिए समान नाम वाले वॉयसप्रिंट नहीं हैं',
    'ไม่มีลายเสียงชื่อเดียวกันให้รวม',
    'Không có dấu vân giọng nói cùng tên để hợp nhất',
    'Tidak ada sidik suara bernama sama untuk digabungkan',
    'Birleştirilecek aynı adlı ses izi yok',
    'Geen gelijknamige spraakafdrukken om samen te voegen',
    'Brak odcisków głosu o tej samej nazwie do scalenia',
    'Немає однойменних голосових відбитків для об’єднання',
    'Inga röstavtryck med samma namn att slå samman',
])

add('没有可导出的内容。', [
    '沒有可匯出的內容。',
    'There is nothing to export.',
    '書き出せる内容がありません。',
    '내보낼 내용이 없습니다.',
    "Il n'y a rien à exporter.",
    'Es gibt nichts zu exportieren.',
    'No hay nada que exportar.',
    "Non c'è nulla da esportare.",
    'Não há nada para exportar.',
    'Экспортировать нечего.',
    'لا يوجد محتوى للتصدير.',
    'निर्यात करने के लिए कुछ नहीं है।',
    'ไม่มีเนื้อหาให้ส่งออก',
    'Không có nội dung để xuất.',
    'Tidak ada yang bisa diekspor.',
    'Dışa aktarılacak içerik yok.',
    'Er is niets om te exporteren.',
    'Nie ma nic do wyeksportowania.',
    'Немає чого експортувати.',
    'Det finns inget att exportera.',
])

add('约 %.1f GB/小时', [
    '約 %.1f GB/小時',
    'About %.1f GB/hour',
    '約 %.1f GB/時間',
    '약 %.1f GB/시간',
    'Environ %.1f Go/heure',
    'Etwa %.1f GB/Stunde',
    'Unos %.1f GB/hora',
    'Circa %.1f GB/ora',
    'Cerca de %.1f GB/hora',
    'Около %.1f ГБ/час',
    'نحو %.1f GB/ساعة',
    'लगभग %.1f GB/घंटा',
    'ประมาณ %.1f GB/ชั่วโมง',
    'Khoảng %.1f GB/giờ',
    'Sekitar %.1f GB/jam',
    'Yaklaşık %.1f GB/saat',
    'Ongeveer %.1f GB/uur',
    'Około %.1f GB/godzinę',
    'Близько %.1f ГБ/год',
    'Cirka %.1f GB/timme',
])

add('质量', [
    '品質', 'Quality', '品質', '품질', 'Qualité', 'Qualität', 'Calidad', 'Qualità',
    'Qualidade', 'Качество', 'الجودة', 'गुणवत्ता', 'คุณภาพ', 'Chất lượng', 'Kualitas',
    'Kalite', 'Kwaliteit', 'Jakość', 'Якість', 'Kvalitet',
])

add('配置导出', [
    '設定匯出', 'Config Export', '設定の書き出し', '설정 내보내기', 'Export de configuration',
    'Konfigurationsexport', 'Exportación de configuración', 'Esportazione configurazione',
    'Exportação de configuração', 'Экспорт настроек', 'تصدير الإعدادات', 'कॉन्फ़िगरेशन निर्यात',
    'การส่งออกการตั้งค่า', 'Xuất cấu hình', 'Ekspor Konfigurasi', 'Yapılandırma dışa aktarma',
    'Configuratie-export', 'Eksport konfiguracji', 'Експорт налаштувань', 'Konfigurationsexport',
])

add('高清', [
    '高畫質', 'HD', '高画質', '고화질', 'HD', 'HD', 'HD', 'HD', 'HD', 'HD',
    'دقة عالية', 'HD', 'HD', 'HD', 'HD', 'HD', 'HD', 'HD', 'HD', 'HD',
])

add('省空间', [
    '省空間', 'Save space', '容量節約', '공간 절약', "Économiser l'espace", 'Speicher sparen',
    'Ahorrar espacio', 'Risparmia spazio', 'Poupar espaço', 'Экономия места', 'توفير المساحة',
    'स्थान बचाएँ', 'ประหยัดพื้นที่', 'Tiết kiệm dung lượng', 'Hemat ruang', 'Yerden tasarruf',
    'Ruimte besparen', 'Oszczędzaj miejsce', 'Економія місця', 'Spara utrymme',
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
    print(f'批次11 完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
