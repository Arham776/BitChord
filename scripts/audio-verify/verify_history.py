#!/usr/bin/env python3
"""Compare actual production playback around 8e8e44a using the same stereo bytes."""
import array,hashlib,json,math,pathlib,struct,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[2];history=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/private/tmp/bitchord-audio-history')
rate=48000;frames=rate*3;values=[]
for i in range(frames):
 s=.2*math.sin(2*math.pi*997*i/rate);values.extend([s,s])
# One over-range transient affects an entire 512-frame guard block in the old mixer.
values[2*12000]=1.6;values[2*12000+1]=1.6
pcm=array.array('f',values).tobytes();source=history/'hot.wav'
source.write_bytes(b'RIFF'+struct.pack('<I',36+len(pcm))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,2,rate,rate*8,8,32)+b'data'+struct.pack('<I',len(pcm))+pcm)
outputs={};logs={}
for name,exe in [('before',history/'before-render'),('after',history/'after-render'),('repaired',root/'native-core/target/release/examples/playback_render')]:
 dest=history/(name+'.wav');r=subprocess.run([str(exe),str(source),str(dest)],check=True,capture_output=True,text=True,timeout=60);logs[name]=r.stderr.strip();x=array.array('f');x.frombytes(dest.read_bytes()[44:]);outputs[name]=x
assert all(len(v)==frames*2 for v in outputs.values()),{k:len(v)//2 for k,v in outputs.items()}
reference=outputs['before'];after=outputs['after'];fixed=outputs['repaired']
assert fixed==reference,'Transparent should match pre-guard unity playback of this fixture'
changes=[i for i,(a,b) in enumerate(zip(reference,after)) if abs(a-b)>1e-7]
assert changes,'historical guard did not activate'
# Gain movement on normal samples, excluding the clipped transient itself.
steps=[]
for i in range(1,frames):
 if abs(values[2*i])<.01 or abs(values[2*(i-1)])<.01 or i in [12000,12001]:continue
 g=after[2*i]/values[2*i];prev=after[2*(i-1)]/values[2*(i-1)]
 if abs(g-prev)>.01:steps.append({'frame':i,'gain_step':g-prev,'sample_difference_from_before':after[2*i]-reference[2*i]})
assert len(steps)>=2,steps
report={'before_revision':'1859a643f7bf1f625367254cf582921fc88629ea','after_revision':'8e8e44a8dc07ea625ac08abbb0ab5c1ca547bba0','fixture_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'output_rate':rate,'frames':frames,'settings':'unity gain, flat EQ, spatial/normalization/crossfade off; same stereo float input','changed_samples':len(changes),'max_difference':max(abs(a-b) for a,b in zip(reference,after)),'guard_gain_discontinuities':steps,'repaired_transparent_matches_before':True,'engine_logs':logs,'scope':'synthetic overload establishes block-guard regression; does not identify the cause in Nerve'}
(root/'native-core/audio-validation/historical-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
print('Old guard changed %d samples; %d gain discontinuities; repaired Transparent matches pre-guard'% (len(changes),len(steps)))
