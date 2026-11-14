# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#   "kokoro==0.9.4",
#   "soundfile",
#   "numpy",
#   "playwright==1.59.0",
#   "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl",
# ]
# ///
"""Builds the video on unreeled.app/security: how Unreeled keeps an account private.

    uv run website/video/build.py            everything, into Unreeled/Video/ and website/public/video/
    uv run website/video/build.py voice      only the narration and the timeline
    uv run website/video/build.py frames     only the pictures
    uv run website/video/build.py sound      only the sound
    uv run website/video/build.py encode     only the final files, from the pictures and the sound
    uv run website/video/build.py still 42.5 one picture, at 42.5 seconds, to look at (--tall for
                                             the tall shape)
    uv run website/video/build.py levels     how loud each sound effect is beside the voice

Everything is made here, from this folder, with free software:

  - the words are narration.json, spoken by Kokoro (Apache 2.0), an open text-to-speech model.
    Any of its voices can read them: `--voice am_fenrir`, `--voice bm_george`;
  - the pictures are scenes.html, a page that draws the frame for any moment, photographed 30
    times a second by a headless Chromium (Playwright). It draws two shapes: wide, for the website,
    and tall, for a phone held upright, which the app shows. Both get the same sound;
  - the sound effects are computed below, sample by sample. There are no recordings;
  - ffmpeg puts them together.

The timeline follows the voice: each scene lasts as long as its sentences take to say, and the
page starts its animations at the words they belong to. So after changing narration.json, run
everything again.

It needs uv (https://docs.astral.sh/uv/) and ffmpeg. The first run downloads Kokoro's model
(about 310 MB) from Hugging Face, and Chromium if Playwright has none:

    uv run --with playwright==1.59.0 playwright install chromium

What it writes is committed. Both shapes of the video, its captions and where its parts begin go
to Unreeled/Video/: the app carries them and plays its own copies, and the website's build takes
the wide one and the captions from there, as it takes the query list. Two pictures from the video, which only the website shows,
go to website/public/video/.
"""

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import wave
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
PUBLIC = HERE.parent / "public" / "video"
APP = HERE.parent.parent / "Unreeled" / "Video"
NAME = "security"
FPS = 30
# The video's two shapes: wide for the website, and tall for a phone held upright, which the app
# plays. Each has its pictures' folder and, for the tall one, its own file name.
SHAPES = {"wide": (1920, 1080, "frames", NAME), "tall": (1080, 1800, "frames-tall", f"{NAME}-tall")}
RATE = 48000  # of the sound; Kokoro speaks at 24000
VOICE_RATE = 24000


# MARK: Voice


def spoken(text: str, replacements: dict) -> str:
    """The words as they're said: "unreeled.app" is written that way and said "unreeled dot app"."""
    for written, said in replacements.items():
        text = text.replace(written, said)
    return text


def trim(audio: np.ndarray, before=0.05, after=0.12):
    """Without the silence Kokoro leaves around what it says. Returns the audio and how much went
    from its start, in seconds."""
    window = VOICE_RATE // 100
    count = len(audio) // window
    loud = np.sqrt((audio[: count * window].reshape(count, window) ** 2).mean(axis=1))
    speech = np.nonzero(loud > 0.02 * loud.max())[0]
    first = max(0, speech[0] * window - int(before * VOICE_RATE))
    last = min(len(audio), (speech[-1] + 1) * window + int(after * VOICE_RATE))
    out = audio[first:last].copy()
    ramp = VOICE_RATE // 200
    out[:ramp] *= np.linspace(0, 1, ramp)
    out[-ramp:] *= np.linspace(1, 0, ramp)
    return out, first / VOICE_RATE


def phrases(text: str) -> list[str]:
    """A scene's text in the pieces a reader takes at once: up to each comma, colon or full stop."""
    return [piece.strip() for piece in re.findall(r".+?(?:[.,:;!?](?=\s|$)|$)", text) if piece.strip()]


def captions(text: str, words: list[dict]) -> list[dict]:
    """Subtitles for one scene: its phrases, timed by the words Kokoro said, a sentence at a time
    unless the sentence is too long for two lines."""
    groups, group = [], []
    for word in words:
        group.append(word)
        if word["w"] in {".", ",", ":", ";", "!", "?"}:
            groups.append(group)
            group = []
    if group:
        groups.append(group)
    pieces = phrases(text)
    if len(pieces) != len(groups):
        raise SystemExit(f"Can't time the subtitles of {text!r}: {len(pieces)} phrases, {len(groups)} spoken")
    cues = []
    for piece, group in zip(pieces, groups):
        said = [word for word in group if "s" in word]
        cue = {"s": said[0]["s"], "e": said[-1]["e"], "text": piece}
        previous = cues[-1] if cues else None
        if previous and not previous["text"].endswith((".", "!", "?")) and len(previous["text"]) + len(piece) < 76:
            previous["e"] = cue["e"]
            previous["text"] += " " + piece
        else:
            cues.append(cue)
    return cues


def voice(arguments, work: Path):
    """Says each scene, and writes how long everything takes: timeline.json."""
    import warnings

    warnings.filterwarnings("ignore")
    import soundfile
    import torch
    from kokoro import KPipeline

    script = json.loads((HERE / "narration.json").read_text())
    name = arguments.voice or script["voice"]
    speed = arguments.speed or script["speed"]
    # A voice's first letter is its accent: a for American, b for British.
    pipeline = KPipeline(lang_code=name[0], repo_id="hexgrad/Kokoro-82M")
    clips = work / "voice"
    shutil.rmtree(clips, ignore_errors=True)
    clips.mkdir(parents=True)

    scenes, clock = [], 0.0
    for scene in script["scenes"]:
        torch.manual_seed(0)  # the same take every time
        audio, words, offset = [], [], 0.0
        for part in pipeline(spoken(scene["text"], script["spoken"]), voice=name, speed=speed, split_pattern=None):
            samples = part.audio.numpy()
            for token in part.tokens or []:
                word = {"w": token.text}
                if token.start_ts is not None and token.end_ts is not None:
                    word |= {"s": offset + token.start_ts, "e": offset + token.end_ts}
                words.append(word)
            audio.append(samples)
            offset += len(samples) / VOICE_RATE
            print(f"  {scene['id']}: {part.phonemes}")
        audio, cut = trim(np.concatenate(audio))
        soundfile.write(clips / f"{scene['id']}.wav", audio, VOICE_RATE, subtype="FLOAT")

        start = clock
        speech = start + scene.get("lead", 0.45)
        length = len(audio) / VOICE_RATE
        end = speech + length + scene.get("tail", 0.5)
        for word in words:
            if "s" in word:
                word["s"] = round(speech + max(0.0, word["s"] - cut), 3)
                word["e"] = round(speech + min(length, word["e"] - cut), 3)
        scenes.append(
            {
                "id": scene["id"],
                **({"chapter": scene["chapter"]} if "chapter" in scene else {}),
                "start": round(start, 3),
                "end": round(end, 3),
                "speech": [round(speech, 3), round(speech + length, 3)],
                "words": words,
                "cues": captions(scene["text"], words),
            }
        )
        clock = end

    frames = math.ceil(clock * FPS)
    timeline = {"fps": FPS, "frames": frames, "duration": round(frames / FPS, 3), "voice": name, "scenes": scenes}
    (work / "timeline.json").write_text(json.dumps(timeline, indent=1))
    # For looking at scenes.html in a browser.
    (work / "timeline.js").write_text(f"window.TIMELINE = window.TIMELINE || {json.dumps(timeline)};\n")
    said = sum(scene["speech"][1] - scene["speech"][0] for scene in scenes)
    print(f"Voice {name}: {said:.1f} s of speech, {timeline['duration']:.1f} s in all, {frames} frames.")


def timeline_of(work: Path) -> dict:
    path = work / "timeline.json"
    if not path.exists():
        raise SystemExit("No timeline yet: run the voice step first.")
    return json.loads(path.read_text())


# MARK: Pictures


def open_page(playwright, timeline: dict, shape="wide"):
    """scenes.html in a headless Chromium, told the timeline and which shape to draw, ready to
    draw any moment."""
    try:
        browser = playwright.chromium.launch()
    except Exception as error:
        if "Executable doesn't exist" in str(error):
            raise SystemExit("Chromium is missing: uv run --with playwright==1.59.0 playwright install chromium")
        raise
    width, height, _, _ = SHAPES[shape]
    page = browser.new_page(viewport={"width": width, "height": height}, device_scale_factor=1)
    page.on("pageerror", lambda error: print(f"scenes.html: {error}", file=sys.stderr))
    page.add_init_script(f"window.RENDERING = true; window.FORMAT = {json.dumps(shape)}; window.TIMELINE = {json.dumps(timeline)};")
    page.goto((HERE / "scenes.html").as_uri())
    page.wait_for_function("window.ready === true", timeout=20000)
    return browser, page


def render(job):
    """One worker's share of the frames, of one shape."""
    work, numbers, shape = job
    from playwright.sync_api import sync_playwright

    timeline = timeline_of(Path(work))
    folder = SHAPES[shape][2]
    with sync_playwright() as playwright:
        browser, page = open_page(playwright, timeline, shape)
        for number in numbers:
            page.evaluate(f"seek({number / FPS})")
            page.screenshot(path=f"{work}/{folder}/{number:05d}.png", type="png")
        browser.close()
    return len(numbers)


def frames(arguments, work: Path):
    timeline = timeline_of(work)
    workers = max(1, min(arguments.workers, os.cpu_count() or 1))
    numbers = list(range(timeline["frames"]))
    for shape, (_, _, name, _) in SHAPES.items():
        folder = work / name
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
        jobs = [(str(work), numbers[worker::workers], shape) for worker in range(workers)]
        with ProcessPoolExecutor(workers) as pool:
            done = sum(pool.map(render, jobs))
        print(f"Pictures, {shape}: {done} frames with {workers} browsers.")


def still(arguments, work: Path):
    """Pictures of single moments, to look at while changing scenes.html."""
    from playwright.sync_api import sync_playwright

    timeline = timeline_of(work)
    shape = "tall" if arguments.tall else "wide"
    folder = work / ("stills-tall" if arguments.tall else "stills")
    folder.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        browser, page = open_page(playwright, timeline, shape)
        for moment in arguments.at:
            page.evaluate(f"seek({moment})")
            path = folder / f"{moment:07.2f}.png"
            page.screenshot(path=str(path), type="png")
            print(path)
        browser.close()


# MARK: Sound
#
# Every effect is computed here: sines for the tones, filtered noise for the air. They're quiet
# and short on purpose, under a voice.
#
# How loud each one plays was set by measuring, since a number says little about how loud a sound
# seems: the voice is brought to -28 LUFS before the mix (see sound), and each effect's loudest
# moment (ITU-R BS.1770, as ffmpeg's ebur128 measures it) sits about 10 LU under that, the small
# ticks further down, and the two that are heard on their own, the chime and the opening chord,
# about 6 LU under.


def seconds(length: float) -> np.ndarray:
    return np.arange(int(length * RATE)) / RATE


def edges(samples: np.ndarray, attack=0.004, release=0.012) -> np.ndarray:
    """No sound starts or stops at once: that clicks."""
    out = samples.copy()
    rise, fall = int(attack * RATE), int(release * RATE)
    out[:rise] *= np.linspace(0, 1, rise)
    out[-fall:] *= np.linspace(1, 0, fall)
    return out


def tone(frequency: float, length: float, decay: float, glide=0.0, warmth=0.2) -> np.ndarray:
    """A sine that fades, gliding `glide` semitones over its length, with a little of its octave."""
    t = seconds(length)
    pitch = frequency * 2 ** (glide * t / length / 12)
    phase = 2 * np.pi * np.cumsum(pitch) / RATE
    return edges((np.sin(phase) + warmth * np.sin(2 * phase)) * np.exp(-t / decay))


def air(length: float, low: float, high: float, sharpness=2.0, seed=1) -> np.ndarray:
    """Noise through a band that sweeps from `low` to `high` hertz: a breath of air."""
    count = int(length * RATE)
    noise = np.random.default_rng(seed).standard_normal(count)
    out = np.zeros(count)
    lowpass = band = 0.0
    for index in range(count):
        cutoff = low * (high / low) ** (index / count)
        coefficient = 2 * math.sin(math.pi * cutoff / RATE)
        lowpass += coefficient * band
        band += coefficient * (noise[index] - lowpass - band / sharpness)
        out[index] = band
    return out / np.abs(out).max()


def bell(frequency: float, length=0.9, decay=0.28) -> np.ndarray:
    t = seconds(length)
    partials = np.sin(2 * np.pi * frequency * t) * np.exp(-t / decay)
    partials += 0.32 * np.sin(2 * np.pi * 2 * frequency * t) * np.exp(-t / (decay * 0.55))
    partials += 0.10 * np.sin(2 * np.pi * 3.01 * frequency * t) * np.exp(-t / (decay * 0.3))
    return edges(partials, attack=0.003, release=0.05)


def sequence(*notes) -> np.ndarray:
    """Sounds one after another: (seconds from the start, samples) pairs, added up."""
    length = max(int(at * RATE) + len(samples) for at, samples in notes)
    out = np.zeros(length)
    for at, samples in notes:
        first = int(at * RATE)
        out[first : first + len(samples)] += samples
    return out


def effect(name: str) -> tuple[np.ndarray, float]:
    """An effect's samples and how loud it plays, out of 1."""
    match name:
        case "pop":  # something appears
            return tone(540, 0.12, 0.035, glide=-6), 0.068
        case "tick":  # a key, a small step
            return sequence((0, tone(1500, 0.03, 0.008, warmth=0)), (0, 0.3 * edges(air(0.012, 2500, 5000, seed=3), 0.001, 0.004))), 0.09
        case "whoosh":  # something moves across
            body = air(0.5, 350, 2600, seed=5)
            return edges(body * np.sin(np.pi * np.arange(len(body)) / len(body)) ** 2, 0.02, 0.05), 0.07
        case "hop":  # the notification, from one stop to the next
            return tone(440, 0.14, 0.045, glide=5), 0.06
        case "lock":  # a lock closes
            click = edges(air(0.006, 2600, 3800, seed=7), 0.0005, 0.003)
            clack = edges(air(0.012, 1700, 2300, seed=8), 0.0005, 0.006)
            return sequence((0, 0.7 * click), (0.06, clack), (0.06, 0.9 * tone(150, 0.09, 0.03, glide=-8, warmth=0))), 0.086
        case "unlock":  # and opens
            click = edges(air(0.008, 2200, 3200, seed=9), 0.0005, 0.004)
            return sequence((0, click), (0.05, 0.6 * tone(660, 0.1, 0.035, glide=4))), 0.113
        case "thud":  # something is turned away
            return sequence((0, tone(125, 0.16, 0.05, glide=-6, warmth=0.35)), (0, 0.15 * edges(air(0.02, 300, 900, seed=11), 0.001, 0.01))), 0.066
        case "erase":  # something is deleted
            body = air(0.34, 2400, 450, seed=13)
            return edges(body * np.exp(-seconds(0.34) / 0.12), 0.004, 0.05), 0.075
        case "sparkle":  # keys are made
            notes = [1046.5, 1318.5, 1568.0, 2093.0]
            return sequence(*[(0.05 * index, tone(note, 0.16, 0.05, warmth=0.1)) for index, note in enumerate(notes)]), 0.0226
        case "stamp":  # a seal on paper
            return sequence((0, tone(170, 0.11, 0.035, glide=-10, warmth=0.1)), (0, 0.35 * edges(air(0.018, 900, 2400, seed=15), 0.001, 0.01))), 0.081
        case "check":  # it's right
            return sequence((0, tone(880, 0.1, 0.035, warmth=0.1)), (0.085, tone(1318.5, 0.18, 0.06, warmth=0.1))), 0.036
        case "on":  # a switch
            return sequence((0, tone(700, 0.05, 0.014)), (0.07, tone(1050, 0.07, 0.02))), 0.08
        case "off":
            return sequence((0, tone(1050, 0.05, 0.014)), (0.07, tone(700, 0.07, 0.02))), 0.08
        case "chime":  # a notification arrives
            return sequence((0, bell(1174.7)), (0.13, bell(1568.0, 1.1, 0.36))), 0.0207
        case "swell":  # the opening and the ending: a soft chord
            t = seconds(4.6)
            chord = sum(
                np.sin(2 * np.pi * note * (1 + detune) * t)
                for note in (196.0, 293.66, 392.0, 493.88, 587.33)
                for detune in (-0.0025, 0, 0.0025)
            )
            shape = np.minimum(1, t / 0.9) * np.minimum(1, (t[-1] - t) / 2.8)
            return chord / 15 * shape**2, 0.08
    raise SystemExit(f"scenes.html asks for a sound that doesn't exist: {name}")


def place(track: np.ndarray, samples: np.ndarray, at: float, gain: float, pan: float):
    """Adds a sound to the stereo track at a moment, towards the left (-1) or the right (1)."""
    first = int(at * RATE)
    samples = samples[: max(0, len(track) - first)]
    angle = (pan + 1) * math.pi / 4
    track[first : first + len(samples), 0] += samples * gain * math.cos(angle) * math.sqrt(2)
    track[first : first + len(samples), 1] += samples * gain * math.sin(angle) * math.sqrt(2)


def write_wave(path: Path, track: np.ndarray, rate: int):
    with wave.open(str(path), "wb") as file:
        file.setnchannels(track.shape[1] if track.ndim > 1 else 1)
        file.setsampwidth(2)
        file.setframerate(rate)
        file.writeframes((np.clip(track, -1, 1) * 32767).astype("<i2").tobytes())


def ffmpeg(*arguments, capture=False):
    command = ["ffmpeg", "-hide_banner", "-loglevel", "info" if capture else "error", "-y", *map(str, arguments)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"ffmpeg failed:\n{result.stderr[-3000:]}")
    return result.stderr


def sound(arguments, work: Path):
    """The voice and the effects, mixed and brought to an even loudness: mix.wav."""
    import soundfile
    from playwright.sync_api import sync_playwright

    timeline = timeline_of(work)
    with sync_playwright() as playwright:
        browser, page = open_page(playwright, timeline)
        sounds = page.evaluate("window.SOUNDS")
        browser.close()
    (work / "sounds.json").write_text(json.dumps(sounds, indent=1))

    length = int(timeline["duration"] * VOICE_RATE)
    speech = np.zeros(length)
    for scene in timeline["scenes"]:
        clip, _ = soundfile.read(work / "voice" / f"{scene['id']}.wav", dtype="float64")
        first = int(scene["speech"][0] * VOICE_RATE)
        speech[first : first + len(clip)] += clip[: length - first]
    write_wave(work / "speech.wav", speech / max(1.0, np.abs(speech).max()) * 0.9, VOICE_RATE)

    effects = np.zeros((int(timeline["duration"] * RATE), 2))
    made = {}
    for item in sounds:
        if item["name"] not in made:
            made[item["name"]] = effect(item["name"])
        samples, loudness = made[item["name"]]
        place(effects, samples, item["t"], loudness * item.get("gain", 1), item.get("pan", 0))
    write_wave(work / "effects.wav", effects, RATE)

    # The voice in the middle, a little evened out and brought to a known loudness, whichever voice
    # it is, so the effects sit under it as they were set. Then the whole is brought to -16 LUFS,
    # the loudness web video is usually set to, by one plain gain, with a limiter for the few
    # peaks that would go over.
    def loudness(*arguments) -> float:
        report = ffmpeg(*arguments, "-f", "null", "-", capture=True)
        return float(re.findall(r"I:\s+(-?[\d.]+) LUFS", report)[-1])

    inputs = ["-i", work / "speech.wav", "-i", work / "effects.wav"]
    even = "aresample=48000,highpass=f=70,acompressor=threshold=0.1:ratio=3:attack=8:release=120:knee=4"
    spoken_at = loudness("-i", work / "speech.wav", "-af", f"{even},ebur128")
    mixed = (
        f"[0:a]{even},volume={-28 - spoken_at:.2f}dB,pan=stereo|c0=c0|c1=c0[speech];"
        f"[1:a]volume={arguments.effects}[effects];[speech][effects]amix=inputs=2:normalize=0"
    )
    mixed_at = loudness(*inputs, "-filter_complex", f"{mixed},ebur128[out]", "-map", "[out]")
    levelled = f"volume={-16 - mixed_at:.2f}dB,alimiter=limit=0.84:attack=5:release=60:level=false"
    ffmpeg(*inputs, "-filter_complex", f"{mixed},{levelled}[out]", "-map", "[out]", "-ar", RATE, "-c:a", "pcm_s16le", work / "mix.wav")
    report = ffmpeg("-i", work / "mix.wav", "-af", "ebur128=peak=true", "-f", "null", "-", capture=True)
    peak = re.findall(r"Peak:\s+(-?[\d.]+) dBFS", report)[-1]
    final = re.findall(r"I:\s+(-?[\d.]+) LUFS", report)[-1]
    print(f"Sound: {len(sounds)} effects of {len(made)} kinds. The mix is {final} LUFS, peaking at {peak} dBFS.")


def levels(arguments, work: Path):
    """How loud each effect in use is beside the voice, for setting a new one: see the note above
    effect()."""
    path = work / "sounds.json"
    if not path.exists():
        raise SystemExit("No sounds yet: run the sound step first.")
    for name in sorted({item["name"] for item in json.loads(path.read_text())}):
        samples, loudness = effect(name)
        track = np.zeros((RATE * 6, 2))
        place(track, samples, 1.0, loudness, 0)
        write_wave(work / "effect.wav", track, RATE)
        report = ffmpeg("-i", work / "effect.wav", "-af", "ebur128", "-f", "null", "-", capture=True)
        loudest = max(float(value) for value in re.findall(r"M:\s*(-?[\d.]+)", report))
        print(f"  {name:8s} {len(samples) / RATE:4.2f} s  {loudest - -28:+5.1f} LU beside the voice")
    (work / "effect.wav").unlink()


# MARK: The files


def stamp(moment: float) -> str:
    return f"{int(moment // 3600):02d}:{int(moment % 3600 // 60):02d}:{moment % 60:06.3f}"


def two_lines(text: str) -> str:
    """A subtitle too long for one line, broken nearest its middle."""
    if len(text) <= 42:
        return text
    spaces = [index for index, character in enumerate(text) if character == " "]
    middle = min(spaces, key=lambda index: abs(index - len(text) / 2))
    return text[:middle] + "\n" + text[middle + 1 :]


def subtitles(timeline: dict) -> str:
    cues = [cue for scene in timeline["scenes"] for cue in scene["cues"]]
    lines = ["WEBVTT", ""]
    for index, cue in enumerate(cues):
        # Each stays a moment after its last word, but never into the next one.
        end = min(cue["e"] + 0.35, cues[index + 1]["s"] - 0.04) if index + 1 < len(cues) else cue["e"] + 0.6
        lines += [f"{stamp(cue['s'])} --> {stamp(end)}", two_lines(cue["text"]), ""]
    return "\n".join(lines)


def encode(arguments, work: Path):
    timeline = timeline_of(work)
    PUBLIC.mkdir(parents=True, exist_ok=True)
    APP.mkdir(parents=True, exist_ok=True)
    # The same sound under both shapes, so they can stand in for each other at any moment.
    for shape, (_, _, pictures, name) in SHAPES.items():
        video = APP / f"{name}.mp4"
        ffmpeg(
            "-framerate", FPS, "-i", work / pictures / "%05d.png", "-i", work / "mix.wav",
            "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
            "-c:v", "libx264", "-preset", "veryslow", "-crf", arguments.quality, "-tune", "animation",
            "-profile:v", "high", "-level", "4.1", "-g", FPS * 4,
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
            "-c:a", "aac", "-b:a", "128k", "-ar", RATE,
            "-t", timeline["duration"], "-movflags", "+faststart",
            "-map_metadata", "-1", "-metadata", "title=How Unreeled keeps your account private",
            "-metadata:s:a:0", "language=eng",
            video,
        )  # fmt: skip
        print(f"{video.relative_to(HERE.parent.parent)}: {timeline['duration']:.1f} s, {video.stat().st_size / 1e6:.1f} MB.")
    (APP / f"{NAME}.vtt").write_text(subtitles(timeline))
    # Where each part begins, for the app to start at one: the scenes narration.json gives a chapter.
    chapters = [{"title": scene["chapter"], "start": scene["start"]} for scene in timeline["scenes"] if "chapter" in scene]
    (APP / f"{NAME}-chapters.json").write_text(json.dumps(chapters, indent=2) + "\n")
    # Two pictures from it. What the page shows before the video plays: the title, once it has
    # settled. And for the page's text: the way a notification takes, once it has arrived.
    scenes = {scene["id"]: scene for scene in timeline["scenes"]}
    for name, moment in {NAME: scenes["title"]["end"] - 0.9, f"{NAME}-path": scenes["path"]["end"] - 0.45}.items():
        frame = work / "frames" / f"{round(moment * FPS):05d}.png"
        ffmpeg("-i", frame, "-vf", "scale=1280:-2:flags=lanczos", "-frames:v", 1, "-update", 1, PUBLIC / f"{name}.png")
    if not arguments.keep_frames:
        for _, _, pictures, _ in SHAPES.values():
            shutil.rmtree(work / pictures, ignore_errors=True)


# MARK: Run


def main():
    parser = argparse.ArgumentParser(description="Builds the video on unreeled.app/security.")
    parser.add_argument("step", nargs="?", default="all", choices=["all", "voice", "frames", "sound", "encode", "still", "levels"])
    parser.add_argument("at", nargs="*", type=float, help="for still: the moments, in seconds")
    parser.add_argument("--voice", help="one of Kokoro's voices, instead of narration.json's")
    parser.add_argument("--speed", type=float, help="how fast it speaks, instead of narration.json's")
    parser.add_argument("--effects", type=float, default=1.0, help="how loud the effects are: 1 as designed, 0 for none")
    parser.add_argument("--quality", type=int, default=20, help="x264's CRF: lower is better and larger")
    parser.add_argument("--workers", type=int, default=6, help="how many browsers take the pictures")
    parser.add_argument("--work", type=Path, default=HERE / ".build", help="where the pieces are kept")
    parser.add_argument("--keep-frames", action="store_true", help="keep the pictures after encoding")
    parser.add_argument("--tall", action="store_true", help="for still: the tall shape, not the wide one")
    arguments = parser.parse_args()
    arguments.work.mkdir(parents=True, exist_ok=True)
    steps = ["voice", "frames", "sound", "encode"] if arguments.step == "all" else [arguments.step]
    for step in steps:
        globals()[step](arguments, arguments.work.resolve())


if __name__ == "__main__":
    main()
