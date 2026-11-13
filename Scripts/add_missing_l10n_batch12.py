#!/usr/bin/env python3
# 补齐批次 12：多占位符格式串（源码里是插值字符串，只有 zh-Hans 有条目）
# 全部使用位置说明符（%1$…/%2$…），因为各语言语序不同、参数顺序会变
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}

# 这几条的源文里是插值字符串（非位置说明符），zh-Hans 也统一写成位置说明符形式，
# 与 20 种目标语言保持一致，避免同一格式串在源语言与译文间风格分裂
ZH_HANS_OVERRIDE = {
    '%@（%@）': '%1$@（%2$@）',
    '质量：%@（%@）': '质量：%1$@（%2$@）',
    '只删除原始视频文件（约 %@），释放空间。关键帧 %d 张、画面要点、转写与总结全部保留。清理后无法重新抽取关键帧。':
        '只删除原始视频文件（约 %1$@），释放空间。关键帧 %2$d 张、画面要点、转写与总结全部保留。清理后无法重新抽取关键帧。',
    '导入完成：新增 %lld、跳过重复 %lld、无效 %lld': '导入完成：新增 %1$lld、跳过重复 %2$lld、无效 %3$lld',
    '批量总结完成：成功 %lld 个，失败 %lld 个': '批量总结完成：成功 %1$lld 个，失败 %2$lld 个',
    '批量转写完成：成功 %lld 个，失败 %lld 个。失败的录音可在列表中查看错误详情。':
        '批量转写完成：成功 %1$lld 个，失败 %2$lld 个。失败的录音可在列表中查看错误详情。',
}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('%@（%@）', [
    '%1$@（%2$@）',
    '%1$@ (%2$@)',
    '%1$@（%2$@）',
    '%1$@(%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
    '%1$@ (%2$@)',
])

add('质量：%@（%@）', [
    '品質：%1$@（%2$@）',
    'Quality: %1$@ (%2$@)',
    '品質：%1$@（%2$@）',
    '품질: %1$@ (%2$@)',
    'Qualité : %1$@ (%2$@)',
    'Qualität: %1$@ (%2$@)',
    'Calidad: %1$@ (%2$@)',
    'Qualità: %1$@ (%2$@)',
    'Qualidade: %1$@ (%2$@)',
    'Качество: %1$@ (%2$@)',
    'الجودة: %1$@ (%2$@)',
    'गुणवत्ता: %1$@ (%2$@)',
    'คุณภาพ: %1$@ (%2$@)',
    'Chất lượng: %1$@ (%2$@)',
    'Kualitas: %1$@ (%2$@)',
    'Kalite: %1$@ (%2$@)',
    'Kwaliteit: %1$@ (%2$@)',
    'Jakość: %1$@ (%2$@)',
    'Якість: %1$@ (%2$@)',
    'Kvalitet: %1$@ (%2$@)',
])

add('只删除原始视频文件（约 %@），释放空间。关键帧 %d 张、画面要点、转写与总结全部保留。清理后无法重新抽取关键帧。', [
    '只刪除原始影片檔案（約 %1$@），釋放空間。關鍵影格 %2$d 張、畫面要點、轉寫與總結全部保留。清理後無法重新擷取關鍵影格。',
    'Deletes only the original video file (about %1$@) to free up space. Keyframes (%2$d), visual notes, transcript and summary are all kept. After cleanup, keyframes can no longer be extracted.',
    '元の動画ファイル（約 %1$@）だけを削除して容量を空けます。キーフレーム %2$d 枚、画面メモ、文字起こしと要約はすべて保持されます。整理後はキーフレームを再抽出できません。',
    '원본 동영상 파일(약 %1$@)만 삭제해 공간을 확보합니다. 키프레임 %2$d개, 화면 요약, 전사와 요약은 모두 유지됩니다. 정리 후에는 키프레임을 다시 추출할 수 없습니다.',
    "Supprime uniquement le fichier vidéo d'origine (environ %1$@) pour libérer de l'espace. Les images clés (%2$d), le résumé visuel, la transcription et le résumé sont tous conservés. Après nettoyage, les images clés ne peuvent plus être extraites.",
    'Löscht nur die Originalvideodatei (ca. %1$@), um Speicher freizugeben. Keyframes (%2$d), visuelle Notizen, Transkript und Zusammenfassung bleiben erhalten. Nach dem Aufräumen können keine Keyframes mehr extrahiert werden.',
    'Elimina solo el archivo de vídeo original (unos %1$@) para liberar espacio. Los fotogramas clave (%2$d), las notas visuales, la transcripción y el resumen se conservan. Tras la limpieza no se pueden volver a extraer fotogramas clave.',
    'Elimina solo il file video originale (circa %1$@) per liberare spazio. Fotogrammi chiave (%2$d), note visive, trascrizione e riepilogo vengono tutti conservati. Dopo la pulizia non è più possibile estrarre i fotogrammi chiave.',
    'Elimina apenas o ficheiro de vídeo original (cerca de %1$@) para libertar espaço. Os fotogramas-chave (%2$d), as notas visuais, a transcrição e o resumo são todos mantidos. Após a limpeza, já não é possível extrair fotogramas-chave.',
    'Удаляется только исходный видеофайл (около %1$@), чтобы освободить место. Ключевые кадры (%2$d), визуальные заметки, расшифровка и резюме сохраняются. После очистки извлечь ключевые кадры заново нельзя.',
    'يحذف ملف الفيديو الأصلي فقط (نحو %1$@) لتحرير المساحة. تُحتفظ بالإطارات الرئيسية (%2$d) والملاحظات المرئية والنص والملخص. وبعد التنظيف لا يمكن استخراج الإطارات الرئيسية مجددًا.',
    'केवल मूल वीडियो फ़ाइल (लगभग %1$@) हटाकर जगह खाली करता है। कीफ़्रेम %2$d, दृश्य नोट्स, ट्रांसक्रिप्ट और सारांश सब सुरक्षित रहते हैं। सफ़ाई के बाद कीफ़्रेम दोबारा नहीं निकाले जा सकते।',
    'ลบเฉพาะไฟล์วิดีโอต้นฉบับ (ประมาณ %1$@) เพื่อคืนพื้นที่ โดยยังคงคีย์เฟรม %2$d รายการ บันทึกภาพ ข้อความถอดความ และสรุปไว้ทั้งหมด หลังล้างแล้วจะแยกคีย์เฟรมซ้ำไม่ได้',
    'Chỉ xóa tệp video gốc (khoảng %1$@) để giải phóng dung lượng. Khung hình chính %2$d, ghi chú hình ảnh, bản chuyển ngữ và tóm tắt đều được giữ lại. Sau khi dọn, không thể trích xuất lại khung hình chính.',
    'Hanya menghapus file video asli (sekitar %1$@) untuk mengosongkan ruang. Keyframe %2$d, catatan visual, transkripsi, dan ringkasan semuanya tetap disimpan. Setelah dibersihkan, keyframe tidak dapat diekstrak lagi.',
    'Yalnızca orijinal video dosyasını (yaklaşık %1$@) silerek yer açar. %2$d kare, görsel notlar, çeviri yazı ve özet korunur. Temizlemeden sonra kareler yeniden çıkarılamaz.',
    'Verwijdert alleen het originele videobestand (ongeveer %1$@) om ruimte vrij te maken. Keyframes (%2$d), visuele notities, transcriptie en samenvatting blijven allemaal bewaard. Na het opruimen kunnen keyframes niet opnieuw worden geëxtraheerd.',
    'Usuwa tylko oryginalny plik wideo (około %1$@), aby zwolnić miejsce. Klatki kluczowe (%2$d), notatki wizualne, transkrypcja i podsumowanie pozostają. Po wyczyszczeniu nie można ponownie wyodrębnić klatek kluczowych.',
    'Видаляється лише оригінальний відеофайл (близько %1$@), щоб звільнити місце. Ключові кадри (%2$d), візуальні нотатки, транскрипція й підсумок залишаються. Після очищення повторно видобути ключові кадри не можна.',
    'Tar bara bort originalvideofilen (cirka %1$@) för att frigöra utrymme. %2$d nyckelbildrutor, visuella anteckningar, transkribering och sammanfattning behålls. Efter rensning kan nyckelbildrutor inte extraheras igen.',
])

add('导入完成：新增 %lld、跳过重复 %lld、无效 %lld', [
    '匯入完成：新增 %1$lld、跳過重複 %2$lld、無效 %3$lld',
    'Import finished: %1$lld added, %2$lld duplicates skipped, %3$lld invalid',
    '取り込み完了：追加 %1$lld 件、重複をスキップ %2$lld 件、無効 %3$lld 件',
    '가져오기 완료: %1$lld개 추가, %2$lld개 중복 건너뜀, %3$lld개 유효하지 않음',
    'Importation terminée : %1$lld ajoutés, %2$lld doublons ignorés, %3$lld non valides',
    'Import abgeschlossen: %1$lld hinzugefügt, %2$lld Duplikate übersprungen, %3$lld ungültig',
    'Importación completada: %1$lld añadidos, %2$lld duplicados omitidos, %3$lld no válidos',
    'Importazione completata: %1$lld aggiunti, %2$lld duplicati ignorati, %3$lld non validi',
    'Importação concluída: %1$lld adicionados, %2$lld duplicados ignorados, %3$lld inválidos',
    'Импорт завершён: добавлено %1$lld, пропущено дубликатов %2$lld, недействительных %3$lld',
    'اكتمل الاستيراد: أُضيف %1$lld، وتم تخطي %2$lld مكررًا، و%3$lld غير صالح',
    'आयात पूर्ण: %1$lld जोड़े गए, %2$lld डुप्लिकेट छोड़े गए, %3$lld अमान्य',
    'นำเข้าเสร็จสิ้น: เพิ่ม %1$lld รายการ ข้ามรายการซ้ำ %2$lld รายการ ไม่ถูกต้อง %3$lld รายการ',
    'Nhập hoàn tất: thêm %1$lld, bỏ qua trùng lặp %2$lld, không hợp lệ %3$lld',
    'Impor selesai: %1$lld ditambahkan, %2$lld duplikat dilewati, %3$lld tidak valid',
    'İçe aktarma tamamlandı: %1$lld eklendi, %2$lld yinelenen atlandı, %3$lld geçersiz',
    'Importeren voltooid: %1$lld toegevoegd, %2$lld duplicaten overgeslagen, %3$lld ongeldig',
    'Import zakończony: dodano %1$lld, pominięto duplikaty %2$lld, nieprawidłowe %3$lld',
    'Імпорт завершено: додано %1$lld, пропущено дублікатів %2$lld, недійсних %3$lld',
    'Importen klar: %1$lld tillagda, %2$lld dubbletter överhoppade, %3$lld ogiltiga',
])

add('批量总结完成：成功 %lld 个，失败 %lld 个', [
    '批次總結完成：成功 %1$lld 個，失敗 %2$lld 個',
    'Batch summary finished: %1$lld succeeded, %2$lld failed',
    '一括要約が完了しました：成功 %1$lld 件、失敗 %2$lld 件',
    '일괄 요약 완료: 성공 %1$lld개, 실패 %2$lld개',
    'Résumé par lots terminé : %1$lld réussis, %2$lld échoués',
    'Stapelzusammenfassung abgeschlossen: %1$lld erfolgreich, %2$lld fehlgeschlagen',
    'Resumen por lotes completado: %1$lld correctos, %2$lld fallidos',
    'Riepilogo in blocco completato: %1$lld riusciti, %2$lld non riusciti',
    'Resumo em lote concluído: %1$lld com sucesso, %2$lld com falha',
    'Пакетное резюме завершено: успешно %1$lld, с ошибкой %2$lld',
    'اكتمل الملخص الجماعي: نجح %1$lld وفشل %2$lld',
    'बैच सारांश पूर्ण: %1$lld सफल, %2$lld विफल',
    'สรุปแบบชุดเสร็จสิ้น: สำเร็จ %1$lld ล้มเหลว %2$lld',
    'Tóm tắt hàng loạt hoàn tất: thành công %1$lld, thất bại %2$lld',
    'Ringkasan massal selesai: %1$lld berhasil, %2$lld gagal',
    'Toplu özet tamamlandı: %1$lld başarılı, %2$lld başarısız',
    'Batchsamenvatting voltooid: %1$lld geslaagd, %2$lld mislukt',
    'Podsumowanie zbiorcze zakończone: %1$lld udanych, %2$lld nieudanych',
    'Пакетний підсумок завершено: успішно %1$lld, невдало %2$lld',
    'Batchsammanfattning klar: %1$lld lyckade, %2$lld misslyckade',
])

add('批量转写完成：成功 %lld 个，失败 %lld 个。失败的录音可在列表中查看错误详情。', [
    '批次轉寫完成：成功 %1$lld 個，失敗 %2$lld 個。失敗的錄音可在清單中檢視錯誤詳情。',
    'Batch transcription finished: %1$lld succeeded, %2$lld failed. See error details for failed recordings in the list.',
    '一括文字起こしが完了しました：成功 %1$lld 件、失敗 %2$lld 件。失敗した録音のエラー詳細はリストで確認できます。',
    '일괄 전사 완료: 성공 %1$lld개, 실패 %2$lld개. 실패한 녹음의 오류 상세는 목록에서 확인할 수 있습니다.',
    'Transcription par lots terminée : %1$lld réussies, %2$lld échouées. Consultez les détails des erreurs dans la liste.',
    'Stapeltranskription abgeschlossen: %1$lld erfolgreich, %2$lld fehlgeschlagen. Fehlerdetails für fehlgeschlagene Aufnahmen finden Sie in der Liste.',
    'Transcripción por lotes completada: %1$lld correctas, %2$lld fallidas. Consulta los detalles de error de las grabaciones fallidas en la lista.',
    "Trascrizione in blocco completata: %1$lld riuscite, %2$lld non riuscite. Consulta i dettagli degli errori delle registrazioni non riuscite nell'elenco.",
    'Transcrição em lote concluída: %1$lld com sucesso, %2$lld com falha. Veja os detalhes dos erros das gravações com falha na lista.',
    'Пакетная расшифровка завершена: успешно %1$lld, с ошибками %2$lld. Подробности ошибок неудачных записей смотрите в списке.',
    'اكتمل التفريغ الجماعي: نجح %1$lld وفشل %2$lld. راجع تفاصيل أخطاء التسجيلات الفاشلة في القائمة.',
    'बैच ट्रांसक्रिप्शन पूर्ण: %1$lld सफल, %2$lld विफल। विफल रिकॉर्डिंग के त्रुटि विवरण सूची में देखें।',
    'การถอดความแบบชุดเสร็จสิ้น: สำเร็จ %1$lld ล้มเหลว %2$lld ดูรายละเอียดข้อผิดพลาดของการบันทึกที่ล้มเหลวในรายการ',
    'Chuyển ngữ hàng loạt hoàn tất: thành công %1$lld, thất bại %2$lld. Xem chi tiết lỗi của các bản ghi thất bại trong danh sách.',
    'Transkripsi massal selesai: %1$lld berhasil, %2$lld gagal. Lihat detail kesalahan rekaman yang gagal di daftar.',
    'Toplu çeviri yazı tamamlandı: %1$lld başarılı, %2$lld başarısız. Başarısız kayıtların hata ayrıntılarını listede görün.',
    'Batchtranscriptie voltooid: %1$lld geslaagd, %2$lld mislukt. Bekijk foutdetails van mislukte opnamen in de lijst.',
    'Transkrypcja zbiorcza zakończona: %1$lld udanych, %2$lld nieudanych. Szczegóły błędów nieudanych nagrań znajdziesz na liście.',
    'Пакетне транскрибування завершено: успішно %1$lld, невдало %2$lld. Деталі помилок невдалих записів перегляньте у списку.',
    'Batchtranskribering klar: %1$lld lyckade, %2$lld misslyckade. Se felinformation för misslyckade inspelningar i listan.',
])


def main():
    with open(CATALOG, 'r', encoding='utf-8') as f:
        catalog = json.load(f)

    existing = catalog['strings']
    for key, vals in T.items():
        entry = existing.setdefault(key, {})
        entry['localizations'] = {
            'zh-Hans': {'stringUnit': {'state': 'translated', 'value': ZH_HANS_OVERRIDE.get(key, key)}},
        }
        for lang, val in zip(LANGS, vals):
            entry['localizations'][lang] = {'stringUnit': {'state': 'translated', 'value': val}}
        entry.pop('extractionState', None)

    with open(CATALOG, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')
    print(f'批次12 完成：补齐 {len(T)} 条多占位符格式串')


if __name__ == '__main__':
    main()
