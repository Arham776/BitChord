#!/usr/bin/env python3
"""Gate production compressed seeks against continuous PCM and Apple's file API.

Run after prepare_codecs.py on macOS with AudioToolbox codec-service access.
HE reconstruction is stateful: compare a seek to an independent seek, rather
than requiring the restart to reproduce a continuous decoder's SBR/PS state.
"""
import array
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
fixtures = pathlib.Path(sys.argv[1]).resolve()
exe = root / 'native-core/target/release/examples/playback_render'
reference = fixtures.parent / 'apple-seek-reference'
subprocess.run(['xcrun', 'clang', '-O2', str(root / 'scripts/audio-verify/apple_seek_reference.c'),
                '-framework', 'AudioToolbox', '-framework', 'CoreFoundation',
                '-o', str(reference)], check=True)

def pcm(path):
    data = path.read_bytes()
    assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
    samples = array.array('f')
    samples.frombytes(data[44:])
    return samples

def difference(a, b):
    assert len(a) == len(b), (len(a), len(b))
    return max((abs(x-y) for x, y in zip(a, b)), default=0)

report = []
cases = [(name, .5) for name in ['aac-lc.m4a', 'he-aac.m4a', 'he-aac-v2.m4a',
          'opus.ogg', 'opus.mka', 'opus.webm', 'surround8.m4a', 'mp3.mp3']]
cases += [(name, 5.0) for name in ['opus.ogg', 'opus.mka', 'opus.webm', 'surround8.m4a', 'mp3.mp3']]
for name, start in cases:
    source = fixtures / name
    rate = 44100 if name == 'mp3.mp3' else 48000
    full = fixtures / (name + '.render-seek-baseline.wav')
    subprocess.run([str(exe), str(source), str(full), '--rate', str(rate)], capture_output=True,
                   text=True, check=True, timeout=90)
    baseline = pcm(full)[int(start * rate) * 2:]
    outputs = []
    logs = []
    for chunk in [7, 4096]:
        out = fixtures / (name + f'.render-seek-{start}-{chunk}.wav')
        run = subprocess.run([str(exe), str(source), str(out), '--start', str(start),
                              '--chunk', str(chunk), '--rate', str(rate)], capture_output=True,
                             text=True, check=True, timeout=90)
        outputs.append(pcm(out))
        logs.append(run.stderr.strip())
    assert outputs[0] == outputs[1], f'seek depends on pull size: {name}'
    seek = outputs[0]
    assert len(seek) == len(baseline), f'incorrect remaining length: {name}'
    early = difference(baseline[:4096], seek[:4096])
    steady = difference(baseline[9600:], seek[9600:])
    item = {'fixture': name, 'seek_seconds': start, 'frames': len(seek)//2,
            'baseline_remaining_frames': len(baseline)//2, 'output_rate': rate,
            'pull_sizes': [7, 4096], 'samples_identical_between_pull_sizes': True,
            'first_2048_frames_max_difference': early,
            'after_100ms_max_difference': steady, 'engine': logs[0]}
    if name.startswith('he-aac'):
        ref = fixtures / (name + f'.reference-seek-{start}.wav')
        subprocess.run([str(reference), str(source), str(ref), str(start)],
                       check=True, capture_output=True, text=True)
        delta = difference(seek, pcm(ref))
        assert delta <= 1e-6, (name, 'independent Apple seek disagrees', delta)
        item.update(independent_apple_seek_max_difference=delta,
                    reference_gate=1e-6,
                    comparison='ExtAudioFile seek; continuous SBR/PS state differs after reset')
    else:
        assert max(early, steady) <= 1e-6, (name, 'cold seek artifact', early, steady)
        item.update(reference_gate=1e-6, comparison='continuous production decode')
    report.append(item)
    print(name, start, 'seek length, partition and reference gates pass', flush=True)

(root / 'native-core/audio-validation/seek-comparison.json').write_text(
    json.dumps(report, indent=2) + '\n')
