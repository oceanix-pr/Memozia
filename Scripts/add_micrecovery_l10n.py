#!/usr/bin/env python3
# 麦克风设备断开/恢复：状态横幅、恢复失败告警与缺口摘要，20 种语言
# 与 add_micmute_l10n.py 同一合并策略（按 source 文案为 key，写入各语言 value）
import json

CATALOG = 'Memozia/Resources/Localizable.xcstrings'
LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru',
         'ar', 'hi', 'th', 'vi', 'id', 'tr', 'nl', 'pl', 'uk', 'sv']

T = {}


def add(key, vals):
    assert len(vals) == 20, key
    T[key] = vals


add('麦克风输入设备已断开，正在尝试自动恢复；恢复期间的说话内容可能无法录入。', [
    '麥克風輸入裝置已中斷，正在嘗試自動恢復；恢復期間的說話內容可能無法錄入。',
    'The microphone input device has disconnected. Attempting to recover automatically; speech during recovery may not be recorded.',
    'マイク入力デバイスが切断されました。自動復元を試みています。復元中の発話は録音されない可能性があります。',
    '마이크 입력 장치가 연결 해제되었습니다. 자동 복구를 시도하는 중이며, 복구 중 발화는 녹음되지 않을 수 있습니다.',
    "Le périphérique d’entrée microphone s’est déconnecté. Rétablissement automatique en cours ; les paroles prononcées pendant le rétablissement risquent de ne pas être enregistrées.",
    'Das Mikrofoneingabegerät wurde getrennt. Automatische Wiederherstellung läuft; währenddessen gesprochene Inhalte werden möglicherweise nicht aufgezeichnet.',
    'El dispositivo de entrada de micrófono se ha desconectado. Se intentará recuperarlo automáticamente; es posible que no se grabe lo que se diga durante la recuperación.',
    'Il dispositivo di ingresso del microfono si è disconnesso. Tentativo di ripristino automatico; durante il ripristino il parlato potrebbe non essere registrato.',
    'O dispositivo de entrada do microfone foi desligado. A tentar recuperar automaticamente; a fala durante a recuperação pode não ser gravada.',
    'Устройство ввода микрофона отключено. Выполняется попытка автоматического восстановления; сказанное во время восстановления может не записаться.',
    'تم فصل جهاز إدخال الميكروفون. تتم محاولة الاستعادة تلقائيًا؛ قد لا يُسجَّل الكلام أثناء الاستعادة.',
    'माइक्रोफ़ोन इनपुट डिवाइस डिस्कनेक्ट हो गया है। स्वतः पुनर्प्राप्ति का प्रयास किया जा रहा है; पुनर्प्राप्ति के दौरान बोली गई बातें रिकॉर्ड नहीं हो सकती हैं।',
    'อุปกรณ์อินพุตไมโครโฟนถูกตัดการเชื่อมต่อ กำลังพยายามกู้คืนอัตโนมัติ ระหว่างการกู้คืนอาจบันทึกเสียงพูดไม่ได้',
    'Thiết bị đầu vào micrô đã ngắt kết nối. Đang thử tự động khôi phục; lời nói trong thời gian khôi phục có thể không được ghi.',
    'Perangkat masukan mikrofon terputus. Mencoba memulihkan secara otomatis; ucapan selama pemulihan mungkin tidak terekam.',
    'Mikrofon giriş aygıtının bağlantısı kesildi. Otomatik kurtarma deneniyor; kurtarma sırasındaki konuşmalar kaydedilmeyebilir.',
    'Het microfooningangsapparaat is losgekoppeld. Er wordt geprobeerd automatisch te herstellen; tijdens het herstel wordt gesproken tekst mogelijk niet opgenomen.',
    'Urządzenie wejściowe mikrofonu zostało odłączone. Trwa próba automatycznego przywrócenia; wypowiedzi w tym czasie mogą nie zostać nagrane.',
    'Пристрій введення мікрофона від’єднано. Виконується спроба автоматичного відновлення; сказане під час відновлення може не записатися.',
    'Mikrofonens ingångsenhet har kopplats från. Försöker återställa automatiskt; tal under återställningen kanske inte spelas in.',
])

add('麦克风输入设备断开后未能自动恢复，后续说话内容无法录入。请检查设备后停止录音并重新开始。', [
    '麥克風輸入裝置中斷後未能自動恢復，之後的說話內容無法錄入。請檢查裝置後停止錄音並重新開始。',
    'The microphone input device did not recover automatically after disconnecting. Later speech cannot be recorded. Please check the device, then stop the recording and start again.',
    'マイク入力デバイスは切断後に自動復元できませんでした。以降の発話は録音できません。デバイスを確認し、録音を停止してから再開してください。',
    '마이크 입력 장치가 연결 해제 후 자동으로 복구되지 않았습니다. 이후 발화는 녹음할 수 없습니다. 장치를 확인한 뒤 녹음을 중지하고 다시 시작하세요.',
    "Le périphérique d’entrée microphone n’a pas pu être rétabli automatiquement après la déconnexion. Les paroles suivantes ne peuvent pas être enregistrées. Vérifiez le périphérique, puis arrêtez l’enregistrement et recommencez.",
    'Das Mikrofoneingabegerät konnte nach dem Trennen nicht automatisch wiederhergestellt werden. Spätere Sprache kann nicht aufgezeichnet werden. Bitte prüfen Sie das Gerät, beenden Sie die Aufnahme und starten Sie erneut.',
    'El dispositivo de entrada de micrófono no se recuperó automáticamente tras desconectarse. Lo que se diga a partir de ahora no podrá grabarse. Comprueba el dispositivo y, después, detén la grabación y vuelve a empezar.',
    'Il dispositivo di ingresso del microfono non è stato ripristinato automaticamente dopo la disconnessione. Il parlato successivo non può essere registrato. Controlla il dispositivo, poi interrompi la registrazione e ricomincia.',
    'O dispositivo de entrada do microfone não foi recuperado automaticamente após a desconexão. A fala seguinte não pode ser gravada. Verifique o dispositivo e, em seguida, pare a gravação e comece de novo.',
    'Устройство ввода микрофона не удалось восстановить автоматически после отключения. Дальнейшая речь не записывается. Проверьте устройство, остановите запись и начните заново.',
    'تعذّرت استعادة جهاز إدخال الميكروفون تلقائيًا بعد فصله. لا يمكن تسجيل الكلام التالي. تحقّق من الجهاز ثم أوقف التسجيل وابدأ من جديد.',
    'डिस्कनेक्ट होने के बाद माइक्रोफ़ोन इनपुट डिवाइस स्वतः पुनर्प्राप्त नहीं हो सका। आगे की बोली रिकॉर्ड नहीं की जा सकती। कृपया डिवाइस जाँचें, फिर रिकॉर्डिंग रोककर दोबारा शुरू करें।',
    'อุปกรณ์อินพุตไมโครโฟนไม่สามารถกู้คืนอัตโนมัติได้หลังตัดการเชื่อมต่อ จะบันทึกเสียงพูดหลังจากนี้ไม่ได้ โปรดตรวจสอบอุปกรณ์ แล้วหยุดบันทึกและเริ่มใหม่',
    'Thiết bị đầu vào micrô không tự khôi phục được sau khi ngắt kết nối. Lời nói tiếp theo không thể ghi. Vui lòng kiểm tra thiết bị, sau đó dừng ghi âm và bắt đầu lại.',
    'Perangkat masukan mikrofon tidak pulih secara otomatis setelah terputus. Ucapan berikutnya tidak dapat direkam. Periksa perangkat, lalu hentikan perekaman dan mulai lagi.',
    'Mikrofon giriş aygıtı bağlantı kesildikten sonra otomatik olarak kurtarılamadı. Bundan sonraki konuşmalar kaydedilemez. Lütfen aygıtı kontrol edin, kaydı durdurup yeniden başlatın.',
    'Het microfooningangsapparaat is na het loskoppelen niet automatisch hersteld. Latere spraak kan niet worden opgenomen. Controleer het apparaat, stop vervolgens de opname en begin opnieuw.',
    'Nie udało się automatycznie przywrócić urządzenia wejściowego mikrofonu po odłączeniu. Dalsze wypowiedzi nie mogą zostać nagrane. Sprawdź urządzenie, a następnie zatrzymaj nagrywanie i zacznij od nowa.',
    'Пристрій введення мікрофона не вдалося відновити автоматично після від’єднання. Подальша мова не записується. Перевірте пристрій, потім зупиніть запис і почніть заново.',
    'Mikrofonens ingångsenhet kunde inte återställas automatiskt efter frånkopplingen. Efterföljande tal kan inte spelas in. Kontrollera enheten, stoppa inspelningen och börja om.',
])

add('麦克风输入设备曾断开，随后已恢复；断开期间的说话内容可能有缺失。', [
    '麥克風輸入裝置曾中斷，隨後已恢復；中斷期間的說話內容可能有缺失。',
    'The microphone input device disconnected and then recovered. Speech during the disconnection may be missing.',
    'マイク入力デバイスが一度切断され、その後復元しました。切断中の発話は欠けている可能性があります。',
    '마이크 입력 장치가 연결 해제되었다가 복구되었습니다. 연결 해제 중의 발화는 누락되었을 수 있습니다.',
    "Le périphérique d’entrée microphone s’est déconnecté puis a été rétabli. Les paroles pendant la déconnexion peuvent manquer.",
    'Das Mikrofoneingabegerät wurde getrennt und anschließend wiederhergestellt. Während der Trennung gesprochene Inhalte können fehlen.',
    'El dispositivo de entrada de micrófono se desconectó y luego se recuperó. Es posible que falte lo que se dijo durante la desconexión.',
    'Il dispositivo di ingresso del microfono si è disconnesso e poi è stato ripristinato. Il parlato durante la disconnessione potrebbe mancare.',
    'O dispositivo de entrada do microfone foi desligado e depois recuperado. A fala durante a desconexão pode estar ausente.',
    'Устройство ввода микрофона отключалось, затем восстановилось. Речь во время отключения может отсутствовать.',
    'انفصل جهاز إدخال الميكروفون ثم استُعيد. قد يكون الكلام أثناء الانفصال مفقودًا.',
    'माइक्रोफ़ोन इनपुट डिवाइस डिस्कनेक्ट हुआ और फिर पुनर्प्राप्त हो गया। डिस्कनेक्ट के दौरान की बोली गायब हो सकती है।',
    'อุปกรณ์อินพุตไมโครโฟนถูกตัดการเชื่อมต่อแล้วกลับมาใช้งานได้ เสียงพูดระหว่างที่ตัดการเชื่อมต่ออาจหายไป',
    'Thiết bị đầu vào micrô đã ngắt kết nối rồi khôi phục. Lời nói trong lúc ngắt kết nối có thể bị thiếu.',
    'Perangkat masukan mikrofon terputus lalu pulih. Ucapan selama terputus mungkin hilang.',
    'Mikrofon giriş aygıtının bağlantısı kesildi ve sonra kurtarıldı. Bağlantı kesildiği sıradaki konuşmalar eksik olabilir.',
    'Het microfooningangsapparaat is losgekoppeld en daarna hersteld. Spraak tijdens de onderbreking kan ontbreken.',
    'Urządzenie wejściowe mikrofonu zostało odłączone, a następnie przywrócone. Wypowiedzi z czasu odłączenia mogą być nieobecne.',
    'Пристрій введення мікрофона від’єднувався, а потім відновився. Мова під час від’єднання може бути відсутня.',
    'Mikrofonens ingångsenhet kopplades från och återställdes sedan. Tal under frånkopplingen kan saknas.',
])

add('麦克风输入设备断开后未确认恢复，录音可能缺少断开后的说话内容。', [
    '麥克風輸入裝置中斷後未確認恢復，錄音可能缺少中斷後的說話內容。',
    'Recovery after the microphone input device disconnected was not confirmed. The recording may be missing speech from that point on.',
    'マイク入力デバイスの切断後の復元を確認できませんでした。録音は切断以降の発話が欠けている可能性があります。',
    '마이크 입력 장치 연결 해제 후 복구가 확인되지 않았습니다. 녹음에 그 이후 발화가 빠져 있을 수 있습니다.',
    "Le rétablissement après la déconnexion du périphérique d’entrée microphone n’a pas été confirmé. L’enregistrement peut ne pas contenir les paroles qui ont suivi.",
    'Die Wiederherstellung nach dem Trennen des Mikrofoneingabegeräts wurde nicht bestätigt. In der Aufnahme können ab diesem Zeitpunkt gesprochene Inhalte fehlen.',
    'No se ha confirmado la recuperación tras la desconexión del dispositivo de entrada de micrófono. Puede que falte lo dicho a partir de ese momento.',
    'Il ripristino dopo la disconnessione del dispositivo di ingresso del microfono non è stato confermato. La registrazione potrebbe non contenere il parlato successivo.',
    'A recuperação após a desconexão do dispositivo de entrada do microfone não foi confirmada. A gravação pode não conter a fala a partir desse momento.',
    'Восстановление после отключения устройства ввода микрофона не подтверждено. В записи может отсутствовать речь с этого момента.',
    'لم يتم تأكيد الاستعادة بعد فصل جهاز إدخال الميكروفون. قد يفتقد التسجيل الكلام بعد ذلك.',
    'माइक्रोफ़ोन इनपुट डिवाइस डिस्कनेक्ट होने के बाद पुनर्प्राप्ति की पुष्टि नहीं हुई। रिकॉर्डिंग में उसके बाद की बोली अनुपस्थित हो सकती है।',
    'ไม่ยืนยันการกู้คืนหลังอุปกรณ์อินพุตไมโครโฟนถูกตัดการเชื่อมต่อ การบันทึกอาจขาดเสียงพูดหลังจากนั้น',
    'Chưa xác nhận khôi phục sau khi thiết bị đầu vào micrô ngắt kết nối. Bản ghi có thể thiếu lời nói từ đó về sau.',
    'Pemulihan setelah perangkat masukan mikrofon terputus tidak terkonfirmasi. Rekaman mungkin kehilangan ucapan setelahnya.',
    'Mikrofon giriş aygıtının bağlantısı kesildikten sonraki kurtarma doğrulanamadı. Kayıtta bu andan sonraki konuşmalar eksik olabilir.',
    'Het herstel na het loskoppelen van het microfooningangsapparaat is niet bevestigd. In de opname kan spraak vanaf dat moment ontbreken.',
    'Nie potwierdzono przywrócenia po odłączeniu urządzenia wejściowego mikrofonu. W nagraniu może brakować wypowiedzi od tego momentu.',
    'Відновлення після від’єднання пристрою введення мікрофона не підтверджено. У записі може бракувати мови з цього моменту.',
    'Återställningen efter att mikrofonens ingångsenhet kopplades från har inte bekräftats. Inspelningen kan sakna tal från och med då.',
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
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(',', ' : '))
    print(f'完成：新增 {added} 条，补译 {filled} 条')


if __name__ == '__main__':
    main()
