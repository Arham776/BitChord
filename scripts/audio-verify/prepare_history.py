#!/usr/bin/env python3
"""Export untouched historical mixer/decoder implementations with a float-WAV adapter.
Only the adapter is added; no historical DSP is edited. Build each exported example
with Cargo, then copy its executable before building the next revision.
"""
from pathlib import Path
import subprocess,tarfile,io,sys
repo=Path(__file__).resolve().parents[2]
root=Path(sys.argv[1] if len(sys.argv)>1 else '/private/tmp/bitchord-audio-history');root.mkdir(exist_ok=True)
src=(repo/'native-core/examples/playback_render.rs').read_text()
src=src.replace('    ClarityPreset, ClarityTuning, PlaybackState, SoundMode, TrackEndReason,','    PlaybackState, TrackEndReason,')
src=src.replace('fn track_ended(&self, _: TrackEndReason, _: String)', 'fn track_ended(&self, _: TrackEndReason)')
a=src.index('    let mode =');b=src.index('    let (buffered, position, duration)',a)
src=src[:a]+'    let seconds = 600.0;\n'+src[b:]
a=src.index('    tx.send(Command::SetPreferAppleAac(');b=src.index('    let (reply, response)',a)
src=src[:a]+'    tx.send(Command::SetLoudnessEnabled(false)).unwrap();\n    tx.send(Command::SetSpatial(false)).unwrap();\n'+src[b:]
src=src.replace('"{}: {} Hz, {} channels → {} Hz; {:?}",','"{}: {} Hz, {} channels → {} Hz",').replace('info.codec, info.sample_rate, info.channels, rate, mode','info.codec, info.sample_rate, info.channels, rate')
# The old worker publishes its count after pushing PCM. Consume only published
# complete frames so this adapter cannot introduce the original counter race.
src=src.replace('        while consumer.slots() >= 2 {','        while buffered.load(Ordering::Acquire) > 0 && consumer.slots() >= 2 {').replace('            n += 2;','            n += 2;\n            buffered.fetch_sub(1, Ordering::AcqRel);')
a=src.index('        if n > 0 {');b=src.index('        if ended.load(',a);src=src[:a]+src[b:]
a=src.index('    let (done, finished)');b=src.index('    tx.send(Command::Shutdown)',a);src=src[:a]+src[b:]
a=src.index('    if let Some(start) = option("--start")');b=src.index('    let mut pcm = Vec::new();',a);src=src[:a]+src[b:]
src=src.replace('native_core::diagnostics::write_float_wav(std::path::Path::new(&args[1]), rate, &pcm).unwrap();','write_float_wav(&args[1], rate, &pcm);')
src+='''\nfn write_float_wav(path: &str, rate: u32, pcm: &[f32]) {\nlet mut bytes=Vec::new();let n=(pcm.len()*4) as u32;\nbytes.extend(b"RIFF");bytes.extend((36+n).to_le_bytes());bytes.extend(b"WAVEfmt ");bytes.extend(16u32.to_le_bytes());bytes.extend(3u16.to_le_bytes());bytes.extend(2u16.to_le_bytes());bytes.extend(rate.to_le_bytes());bytes.extend((rate*8).to_le_bytes());bytes.extend(8u16.to_le_bytes());bytes.extend(32u16.to_le_bytes());bytes.extend(b"data");bytes.extend(n.to_le_bytes());for s in pcm {bytes.extend(s.to_le_bytes());}std::fs::write(path,bytes).unwrap();\n}\n'''
for name,ref in [('before','8e8e44a^'),('after','8e8e44a')]:
 p=root/name;p.mkdir(exist_ok=True)
 archive=subprocess.check_output(['git','-C',str(repo),'archive',ref,'native-core'])
 with tarfile.open(fileobj=io.BytesIO(archive)) as t:
  # Trusted local Git export, nevertheless reject absolute/traversal members.
  assert all(not Path(m.name).is_absolute() and '..' not in Path(m.name).parts for m in t.getmembers())
  t.extractall(p)
 (p/'native-core/examples/playback_render.rs').write_text(src)
 print(name,subprocess.check_output(['git','-C',str(repo),'rev-parse',ref],text=True).strip())
