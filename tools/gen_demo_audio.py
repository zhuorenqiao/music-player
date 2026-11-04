#!/usr/bin/env python3
"""生成播放器内置示例音频（纯标准库，无第三方依赖）。

本脚本使用加性合成的方式生成 3 首风格不同的短曲：
  * track-01.wav  晨光序曲  C 大调，92 BPM，三角波主旋律 + 柔和铺底
  * track-02.wav  霓虹夜行  A 小调，124 BPM，软方波主旋律 + 锯齿贝斯
  * track-03.wav  海边书店  F 大调，78 BPM，正弦波主旋律 + 慢速揉弦

每首曲子由「主旋律 + 贝斯 + 和弦铺底」三个声部叠加，音符带 ADSR 包络，
输出 44100Hz / 16bit / 单声道 WAV，单文件约 2MB。

脚本幂等：重复执行会用相同参数覆盖输出文件。
用法：
    python tools/gen_demo_audio.py
"""

from __future__ import annotations

import math
import os
import wave
from array import array

SAMPLE_RATE = 44100
TWO_PI = 2.0 * math.pi

# 输出目录：<项目根>/public/assets/audio（Vite 把 public/ 原样作为静态资源服务）
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "public", "assets", "audio")


# ---------------------------------------------------------------------------
# 基础乐理 / 波形工具
# ---------------------------------------------------------------------------
def midi_to_freq(note: int) -> float:
    """MIDI 音高转频率（A4 = 69 = 440Hz）。"""
    return 440.0 * (2.0 ** ((note - 69) / 12.0))


def envelope(t: float, dur: float, attack: float, decay: float,
             sustain: float, release: float) -> float:
    """标准 ADSR 包络，返回 0.0 ~ 1.0 之间的增益。"""
    if t < 0.0 or t > dur:
        return 0.0
    if attack > 0.0 and t < attack:
        return t / attack
    decay_end = attack + decay
    if decay > 0.0 and t < decay_end:
        return 1.0 - (1.0 - sustain) * ((t - attack) / decay)
    release_start = max(decay_end, dur - release)
    if t < release_start:
        return sustain
    if release <= 0.0:
        return 0.0
    return sustain * max(0.0, (dur - t) / release)


def wave_sample(kind: str, phase: float) -> float:
    """按波形种类返回 -1.0 ~ 1.0 的单点采样值。"""
    if kind == "sine":
        return math.sin(phase)
    if kind == "triangle":
        # asin(sin(x)) 得到三角波，幅度归一化到 ±1
        return (2.0 / math.pi) * math.asin(math.sin(phase))
    if kind == "soft-square":
        # 只叠加 1/3/5 次谐波，得到柔和的方波（避免刺耳的高频）
        total = 0.0
        for harmonic in (1, 3, 5):
            total += math.sin(harmonic * phase) / harmonic
        return total * (4.0 / math.pi) * 0.45
    if kind == "saw":
        # 三角恒等式构造锯齿波，省掉取模运算
        return (2.0 / math.pi) * math.atan(math.tan(phase * 0.5)) * 1.2
    return math.sin(phase)


def add_voice(buffer: list[float], start_sec: float, dur: float, freq: float,
              amp: float, wave_type: str, attack: float = 0.01,
              decay: float = 0.08, sustain: float = 0.62,
              release: float = 0.14, vibrato: float = 0.0,
              vibrato_rate: float = 5.2, detune: float = 0.0) -> None:
    """把一个音符叠加进缓冲区（单调、无返回值，直接累加）。"""
    start = int(start_sec * SAMPLE_RATE)
    length = int(dur * SAMPLE_RATE)
    if length <= 0 or start >= len(buffer):
        return
    inv_rate = 1.0 / SAMPLE_RATE
    phase_a = 0.0
    phase_b = 0.0
    for i in range(length):
        index = start + i
        if index >= len(buffer):
            break
        if index < 0:
            continue
        t = i * inv_rate
        gain = envelope(t, dur, attack, decay, sustain, release)
        if gain <= 0.0:
            continue
        pitch = 1.0 + vibrato * math.sin(TWO_PI * vibrato_rate * t) if vibrato else 1.0
        base_freq = freq * pitch
        phase_a += TWO_PI * base_freq * inv_rate
        value = wave_sample(wave_type, phase_a)
        if detune:
            phase_b += TWO_PI * base_freq * (1.0 + detune) * inv_rate
            value = 0.62 * value + 0.38 * wave_sample(wave_type, phase_b)
        buffer[index] += value * gain * amp


def play_sequence(buffer: list[float], notes: list[tuple[int, float]],
                  beat_sec: float, amp: float, wave_type: str,
                  velocity: float = 1.0, **kwargs) -> float:
    """按顺序播放一段旋律，返回结束时刻（秒）。"""
    cursor = 0.0
    for note, beats in notes:
        dur = beats * beat_sec
        if note > 0:  # 0 表示休止符
            add_voice(buffer, cursor, dur, midi_to_freq(note),
                      amp * velocity, wave_type, **kwargs)
        cursor += dur
    return cursor


def seq(notes: list[int], step: float = 0.5) -> list[tuple[int, float]]:
    """把音高列表等时值展开成 (音高, 拍数) 序列。"""
    return [(note, step) for note in notes]


# ---------------------------------------------------------------------------
# 三首示例曲的乐谱数据
# ---------------------------------------------------------------------------
# 曲目 1：晨光序曲 —— C 大调琶音，明亮温暖
TRACK_1 = {
    "file": "track-01.wav",
    "bpm": 92.0,
    "lead_wave": "triangle",
    "lead_amp": 0.30,
    "bass_wave": "sine",
    "bass_amp": 0.34,
    "pad_wave": "triangle",
    "pad_amp": 0.075,
    "lead": (
        seq([72, 76, 79, 76, 74, 72, 74, 76])
        + seq([71, 74, 79, 74, 72, 71, 72, 74])
        + seq([69, 72, 76, 72, 67, 69, 71, 72])
        + seq([72, 71, 69, 67, 65, 64, 62, 60])
        + seq([72, 76, 79, 81, 79, 76, 74, 72])
        + seq([71, 74, 79, 81, 79, 74, 72, 71])
        + seq([69, 72, 77, 76, 72, 69, 72, 76])
        + seq([74, 72, 71, 69, 67, 65, 64, 60])
    ),
    "bass": [(48, 4), (43, 4), (45, 4), (41, 4),
             (48, 4), (43, 4), (50, 4), (48, 4)],
    "pad": [
        [(60, 64, 67), 0.0, 4.0],
        [(59, 62, 67), 4.0, 4.0],
        [(57, 60, 64), 8.0, 4.0],
        [(57, 60, 65), 12.0, 4.0],
        [(60, 64, 67), 16.0, 4.0],
        [(59, 62, 67), 20.0, 4.0],
        [(57, 62, 65), 24.0, 4.0],
        [(60, 64, 67), 28.0, 4.0],
    ],
}

# 曲目 2：霓虹夜行 —— A 小调，节奏推进感更强
TRACK_2 = {
    "file": "track-02.wav",
    "bpm": 124.0,
    "lead_wave": "soft-square",
    "lead_amp": 0.26,
    "bass_wave": "saw",
    "bass_amp": 0.26,
    "pad_wave": "sine",
    "pad_amp": 0.07,
    "lead": (
        seq([69, 72, 76, 72, 69, 72, 76, 79])
        + seq([67, 71, 74, 71, 67, 71, 74, 76])
        + seq([65, 69, 72, 69, 65, 69, 72, 74])
        + seq([64, 67, 71, 67, 64, 67, 69, 71])
        + seq([69, 72, 76, 79, 76, 72, 69, 67])
        + seq([67, 71, 76, 74, 71, 67, 64, 62])
        + seq([69, 72, 76, 81, 79, 76, 72, 69])
        + seq([67, 71, 74, 71, 67, 64, 62, 57])
        + seq([64, 67, 72, 76, 72, 67, 64, 60])
        + seq([62, 67, 71, 74, 71, 67, 62, 59])
        + seq([57, 60, 64, 69, 72, 69, 64, 60])
        + seq([57, 60, 62, 64, 67, 69, 71, 69])
    ),
    "bass": [(45, 2), (45, 2), (43, 2), (43, 2),
             (41, 2), (41, 2), (40, 2), (40, 2),
             (45, 2), (45, 2), (43, 2), (43, 2),
             (45, 2), (45, 2), (40, 2), (40, 2),
             (45, 2), (45, 2), (43, 2), (43, 2),
             (41, 2), (41, 2), (45, 2), (45, 2)],
    "pad": [
        [(57, 60, 64), 0.0, 4.0],
        [(55, 59, 62), 4.0, 4.0],
        [(53, 57, 60), 8.0, 4.0],
        [(52, 55, 59), 12.0, 4.0],
        [(57, 60, 64), 16.0, 4.0],
        [(55, 59, 62), 20.0, 4.0],
        [(57, 60, 64), 24.0, 4.0],
        [(52, 55, 59), 28.0, 4.0],
        [(57, 60, 64), 32.0, 4.0],
        [(55, 59, 62), 36.0, 4.0],
        [(53, 57, 60), 40.0, 4.0],
        [(57, 60, 64), 44.0, 4.0],
    ],
}

# 曲目 3：海边书店 —— F 大调慢板，正弦波 + 揉弦
TRACK_3 = {
    "file": "track-03.wav",
    "bpm": 78.0,
    "lead_wave": "sine",
    "lead_amp": 0.32,
    "bass_wave": "triangle",
    "bass_amp": 0.28,
    "pad_wave": "sine",
    "pad_amp": 0.09,
    "lead": (
        [(77, 1.0), (76, 0.5), (74, 0.5), (72, 1.0), (69, 1.0)]
        + [(74, 1.0), (72, 0.5), (70, 0.5), (69, 2.0)]
        + [(72, 1.0), (74, 0.5), (76, 0.5), (77, 1.0), (81, 1.0)]
        + [(79, 1.5), (77, 0.5), (76, 2.0)]
        + [(77, 1.0), (81, 1.0), (84, 1.0), (81, 1.0)]
        + [(79, 1.0), (77, 0.5), (76, 0.5), (74, 2.0)]
        + [(72, 1.0), (74, 1.0), (76, 1.0), (77, 1.0)]
        + [(76, 2.0), (72, 2.0)]
    ),
    "bass": [(41, 4), (45, 4), (43, 4), (41, 4),
             (36, 4), (40, 4), (41, 4), (36, 4)],
    "pad": [
        [(53, 57, 60), 0.0, 4.0],
        [(52, 57, 60), 4.0, 4.0],
        [(50, 53, 58), 8.0, 4.0],
        [(48, 53, 57), 12.0, 4.0],
        [(53, 57, 60), 16.0, 4.0],
        [(48, 52, 55), 20.0, 4.0],
        [(50, 53, 57), 24.0, 4.0],
        [(48, 53, 60), 28.0, 4.0],
    ],
}


# ---------------------------------------------------------------------------
# 渲染与写文件
# ---------------------------------------------------------------------------
def render(spec: dict) -> tuple[list[float], float]:
    """按乐谱渲染出浮点采样缓冲区，返回 (buffer, 时长秒)。"""
    beat = 60.0 / spec["bpm"]
    lead_beats = sum(beats for _, beats in spec["lead"])
    bass_beats = sum(beats for _, beats in spec["bass"])
    pad_beats = max((start + dur for _, start, dur in spec["pad"]), default=0.0)
    total_beats = max(lead_beats, bass_beats, pad_beats)
    duration = total_beats * beat + 0.45  # 留一段衰减尾巴

    buffer = [0.0] * int(duration * SAMPLE_RATE)

    # 主旋律
    play_sequence(buffer, spec["lead"], beat, spec["lead_amp"],
                  spec["lead_wave"], attack=0.012, decay=0.1,
                  sustain=0.6, release=0.16,
                  vibrato=0.004 if spec["lead_wave"] == "sine" else 0.0,
                  vibrato_rate=4.8,
                  detune=0.003 if spec["lead_wave"] == "soft-square" else 0.0)

    # 贝斯
    play_sequence(buffer, spec["bass"], beat, spec["bass_amp"],
                  spec["bass_wave"], attack=0.02, decay=0.12,
                  sustain=0.72, release=0.2)

    # 和弦铺底：每个音同时进入，音量很低，只做氛围
    for chord, start_beat, dur_beats in spec["pad"]:
        start_sec = start_beat * beat
        dur = dur_beats * beat
        for note in chord:
            add_voice(buffer, start_sec, dur, midi_to_freq(note),
                      spec["pad_amp"], spec["pad_wave"],
                      attack=0.35, decay=0.5, sustain=0.85, release=0.9,
                      vibrato=0.0015, vibrato_rate=0.6)

    return buffer, duration


def write_wav(path: str, buffer: list[float]) -> None:
    """归一化后写成 16bit 单声道 WAV（幂等覆盖）。"""
    peak = 0.0
    for value in buffer:
        magnitude = abs(value)
        if magnitude > peak:
            peak = magnitude
    gain = (0.89 / peak) if peak > 0.0 else 1.0

    samples = array("h")
    for value in buffer:
        scaled = value * gain
        if scaled > 1.0:
            scaled = 1.0
        elif scaled < -1.0:
            scaled = -1.0
        samples.append(int(scaled * 32767.0))

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(samples.tobytes())


def main() -> None:
    """生成全部示例音频，并打印时长与体积。"""
    for spec in (TRACK_1, TRACK_2, TRACK_3):
        buffer, duration = render(spec)
        path = os.path.join(OUTPUT_DIR, spec["file"])
        write_wav(path, buffer)
        size_kb = os.path.getsize(path) / 1024.0
        print(f"{spec['file']}: {duration:.2f}s, {size_kb:.1f} KB")


if __name__ == "__main__":
    main()
