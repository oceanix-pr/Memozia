#!/usr/bin/env python3
"""生成 16kHz 单声道 WAV 长音频（含少量静音/噪声段），用于内存与取消延迟基准。

用法: gen_long_audio.py <minutes> <out.wav>

仅用于规模测试，不要求是真实语音：内容为静音段 + 低幅周期性脉冲段，
但文件长度、采样格式与真实转写输入一致（16kHz / 单声道 / 16-bit PCM）。
"""
import os
import sys
import array
import wave

RATE = 16000


def silence_frames():
    return b"\x00\x00" * RATE


def noise_frames():
    # 确定性低幅脉冲（无随机，保证可复现）
    samples = array.array("h", (0 for _ in range(RATE)))
    for i in range(0, RATE, 97):
        samples[i] = 600 if (i // 97) % 2 == 0 else -600
    return samples.tobytes()


def main():
    if len(sys.argv) < 3:
        print("用法: gen_long_audio.py <minutes> <out.wav>", file=sys.stderr)
        return 2
    minutes = float(sys.argv[1])
    out_path = sys.argv[2]
    total_seconds = max(1, int(round(minutes * 60)))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    silence = silence_frames()
    noise = noise_frames()
    with wave.open(out_path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        for second in range(total_seconds):
            # 每 10 秒插入 1 秒噪声，其余静音
            handle.writeframes(noise if second % 10 == 9 else silence)
    print(out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
