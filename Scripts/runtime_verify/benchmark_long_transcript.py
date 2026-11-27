"""用一小时的合成录音检查首次恢复与重复对账。参数为 Memozia 可执行文件。"""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


def make_fixture(root):
    name = "20260708080000"
    entry = root / "2026-07" / name
    entry.mkdir(parents=True)
    generator = Path(__file__).with_name("gen_long_audio.py")
    subprocess.run([sys.executable, str(generator), "60", str(entry / (name + ".wav"))],
                   stdout=subprocess.DEVNULL, check=True)
    (entry / "meta.json").write_text(json.dumps({
        "itemType": "recording", "title": "Synthetic fixture", "storedFileName": name + ".wav",
        "duration": 3600, "fileExtension": "wav", "entry_id": "4e4f8e6a-1813-45b9-827a-9efb2cb965e6",
    }))
    # 空正文隔离 SwiftData 恢复成本，命令行基准也无需访问用户的加密密钥。
    segments = [{"startTime": i * 1.2, "endTime": (i + 1) * 1.2, "speaker": "Test", "text": ""}
                for i in range(3000)]
    (entry / "transcript.json").write_text(json.dumps(segments))


def verify(app, root, database, expected_inserts, threshold):
    run = subprocess.run([app, "--verify-filesync", str(root), "--db", str(database)],
                         stdout=subprocess.PIPE, text=True, check=True)
    result = json.loads(run.stdout.strip().splitlines()[-1])
    print(json.dumps(result), flush=True)
    with sqlite3.connect((database / "verify.store").as_uri() + "?mode=ro", uri=True) as conn:
        rows = conn.execute("""
            SELECT (SELECT COUNT(*) FROM ZAUDIORECORDING),
                   (SELECT COUNT(*) FROM ZTRANSCRIPTSEGMENT),
                   (SELECT COUNT(*) FROM ZTRANSCRIPTSEGMENT s
                    JOIN ZAUDIORECORDING r ON s.ZRECORDING = r.Z_PK)
        """).fetchone()
    if (rows != (1, 3000, 3000) or result["insertedEntries"] != expected_inserts
            or result["saveFailed"] or not result["mirrorFlushComplete"]
            or result["mainThreadSamples"] < 1 or result["mainThreadMaxBlockMs"] >= threshold):
        raise SystemExit(f"FAIL: rows={rows}, expected inserts={expected_inserts}, limit={threshold}ms")


if __name__ == "__main__":
    app = sys.argv[1]
    threshold = float(os.environ.get("Memozia_MAINBLOCK_THRESHOLD_MS", 50))
    with tempfile.TemporaryDirectory(prefix="MemoziaLongTranscript-") as work:
        root, database = Path(work) / "entries", Path(work) / "db"
        make_fixture(root)
        for inserts in (1, 0):
            verify(app, root, database, inserts, threshold)
    print("PASS: 两轮各有 1 条录音、3,000 个关联片段，主线程延迟均在阈值内。")
