#!/usr/bin/env python3
"""批量生成条目文件夹，用于列表/磁盘对账规模测试。

用法: gen_sample_entries.py <count> <dataRoot> [--months k]

每个条目包含：
- 一个可播放的占位音频（0.5s 静音 WAV，>4KB，可被 AVURLAsset 识别、不会被判为损坏）
- 最小 meta.json（itemType=recording）
- 每 3 条生成一份明文 todos.json（兼容 EncryptionService 的明文回退读取）

--months k：把条目分散到 k 个月份目录（yyyy-MM）下；默认 1（平铺在 dataRoot）。
"""
import argparse
import datetime
import json
import os
import sys
import wave

RATE = 16000


def write_placeholder_wav(path):
    frames = b"\x00\x00" * int(RATE * 0.5)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(frames)


def write_todos(path, index):
    document = {
        "source": "summary",
        "model": "runtime-verify",
        "generatedAt": "2026-01-01T00:00:00Z",
        "items": [
            {"id": "t%d-a" % index, "title": "整理会议纪要", "priority": "high", "status": "pending"},
            {"id": "t%d-b" % index, "title": "发送跟进邮件", "priority": "low", "status": "exported"},
        ],
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False)


def write_summary(path, index):
    """明文 summary.md：EncryptionService 支持明文回退读取，用于验证
    「库里有内容 → 补写缺失镜像」这个写方向。"""
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("## 验证总结 %d\n\n这是运行验证用的占位总结，用于驱动镜像补写。\n" % index)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("count", type=int)
    parser.add_argument("data_root")
    parser.add_argument("--months", type=int, default=1)
    parser.add_argument(
        "--with-summary",
        action="store_true",
        help="为每个条目额外写一份明文 summary.md（供验证「库→磁盘」补写方向）",
    )
    args = parser.parse_args()

    months = max(1, args.months)
    base = datetime.datetime.now()
    os.makedirs(args.data_root, exist_ok=True)

    for index in range(args.count):
        offset_days = 30 * (index % months)
        stamp = (base - datetime.timedelta(days=offset_days, seconds=index)).strftime("%Y%m%d%H%M%S")
        month = "%s-%s" % (stamp[0:4], stamp[4:6])
        parent = os.path.join(args.data_root, month) if months > 1 else args.data_root
        folder = os.path.join(parent, stamp)
        os.makedirs(folder, exist_ok=True)

        write_placeholder_wav(os.path.join(folder, "%s.wav" % stamp))
        with open(os.path.join(folder, "meta.json"), "w", encoding="utf-8") as handle:
            json.dump(
                {"title": "验证条目 %s" % stamp, "isHidden": False, "itemType": "recording"},
                handle,
                ensure_ascii=False,
            )
        if index % 3 == 0:
            write_todos(os.path.join(folder, "todos.json"), index)
        if args.with_summary:
            write_summary(os.path.join(folder, "summary.md"), index)

    print(json.dumps({
        "count": args.count,
        "months": months,
        "data_root": os.path.abspath(args.data_root),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
