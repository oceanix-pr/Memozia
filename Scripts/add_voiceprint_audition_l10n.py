#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 声纹标记弹窗「试听最早一段」：按钮提示 + 帮助条目 20 种语言
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


add('试听该说话人最早的一段，便于判断是谁', [
    '試聽該說話人最早的一段，便於判斷是誰',
    'Preview this speaker’s earliest segment to help tell who it is',
    'この話者の最初の発話を試聴して、誰かを判断しやすくします',
    '이 화자의 가장 이른 구간을 미리 들어 누구인지 판단하기 쉽게 합니다',
    "Écouter le premier passage de cet interlocuteur pour aider à l'identifier",
    'Den frühesten Abschnitt dieses Sprechers anhören, um ihn leichter zuzuordnen',
    'Escuchar el primer fragmento de este hablante para ayudarte a identificarlo',
    'Ascolta il primo frammento di questo interlocutore per aiutarti a identificarlo',
    'Ouvir o primeiro segmento deste falante para ajudar a identificá-lo',
    'Прослушать самый ранний фрагмент этого говорящего, чтобы понять, кто это',
    'استمع إلى أول مقطع لهذا المتحدث لتسهيل تحديد هويته',
    'यह कौन है यह पहचानने में मदद के लिए इस वक्ता का सबसे पहला खंड सुनें',
    'ฟังช่วงแรกสุดของผู้พูดรายนี้เพื่อช่วยระบุว่าเป็นใคร',
    'Nghe đoạn sớm nhất của người nói này để dễ nhận biết là ai',
    'Dengarkan segmen paling awal pembicara ini untuk membantu mengenali siapa dia',
    'Kim olduğunu anlamaya yardımcı olmak için bu konuşmacının en erken bölümünü dinleyin',
    'Beluister het vroegste fragment van deze spreker om te helpen bepalen wie het is',
    'Odsłuchaj najwcześniejszego fragmentu tego mówcy, aby ułatwić rozpoznanie, kto to',
    'Прослухати найраніший фрагмент цього мовця, щоб легше визначити, хто це',
    'Lyssna på talarens tidigaste segment för att lättare avgöra vem det är',
])

add('标记前可点每行左侧的播放按钮，试听该说话人最早的一段，便于判断是谁', [
    '標記前可點每行左側的播放按鈕，試聽該說話人最早的一段，便於判斷是誰',
    'Before marking, click the play button on the left of each row to preview that speaker’s earliest segment, so you can tell who it is',
    '登録前に各行の左にある再生ボタンを押すと、その話者の最初の発話を試聴でき、誰かを判断しやすくなります',
    '등록 전에 각 행 왼쪽의 재생 버튼을 눌러 해당 화자의 가장 이른 구간을 미리 들어 보면 누구인지 판단하기 쉽습니다',
    "Avant d'enregistrer, cliquez sur le bouton de lecture à gauche de chaque ligne pour écouter le premier passage de cet interlocuteur et l'identifier",
    'Vor dem Markieren die Wiedergabetaste links in der Zeile anklicken, um den frühesten Abschnitt dieses Sprechers anzuhören und ihn so leichter zuzuordnen',
    'Antes de marcar, pulsa el botón de reproducción a la izquierda de cada fila para escuchar el primer fragmento de ese hablante e identificarlo',
    "Prima di contrassegnare, premi il pulsante di riproduzione a sinistra di ogni riga per ascoltare il primo frammento di quell'interlocutore e identificarlo",
    'Antes de marcar, clique no botão de reprodução à esquerda de cada linha para ouvir o primeiro segmento desse falante e identificá-lo',
    'Перед разметкой нажмите кнопку воспроизведения слева от каждой строки, чтобы прослушать самый ранний фрагмент говорящего и понять, кто это',
    'قبل وضع العلامة، انقر زر التشغيل على يسار كل سطر للاستماع إلى أول مقطع لهذا المتحدث لتسهيل تحديد هويته',
    'मार्क करने से पहले प्रत्येक पंक्ति के बाईं ओर दिए प्ले बटन को दबाकर उस वक्ता का सबसे पहला खंड सुनें, जिससे पहचानने में सुविधा हो',
    'ก่อนติดชื่อ กดปุ่มเล่นทางซ้ายของแต่ละแถวเพื่อฟังช่วงแรกสุดของผู้พูดรายนั้น จะช่วยให้ระบุได้ว่าเป็นใคร',
    'Trước khi đánh dấu, nhấn nút phát bên trái mỗi dòng để nghe đoạn sớm nhất của người nói đó, giúp nhận biết là ai',
    'Sebelum menandai, klik tombol putar di kiri setiap baris untuk mendengarkan segmen paling awal pembicara tersebut agar lebih mudah dikenali',
    'İşaretlemeden önce her satırın solundaki oynat düğmesine basarak o konuşmacının en erken bölümünü dinleyin; kim olduğunu anlamanıza yardımcı olur',
    'Klik vóór het markeren op de afspeelknop links in elke rij om het vroegste fragment van die spreker te beluisteren, zodat je kunt bepalen wie het is',
    'Przed oznaczeniem kliknij przycisk odtwarzania po lewej stronie wiersza, aby odsłuchać najwcześniejszego fragmentu tego mówcy i rozpoznać, kto to',
    'Перед позначенням натисніть кнопку відтворення ліворуч у кожному рядку, щоб прослухати найраніший фрагмент цього мовця й визначити, хто це',
    'Tryck på uppspelningsknappen till vänster i varje rad före markeringen för att lyssna på talarens tidigaste segment och lättare avgöra vem det är',
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
