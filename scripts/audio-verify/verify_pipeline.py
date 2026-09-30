#!/usr/bin/env python3
"""Production pitch preservation and bounded diagnostic capture checks."""
import array,hashlib,json,math,pathlib,struct,subprocess,tempfile,wave
root=pathlib.Path(__file__).resolve().parents[2]
exe=root/'native-core/target/release/examples/playback_render'
def read_float(path):
 data=path.read_bytes();assert data[:4]==b'RIFF' and data[8:12]==b'WAVE'
 rate=struct.unpack_from('<I',data,24)[0];x=array.array('f');x.frombytes(data[44:]);return rate,x
with tempfile.TemporaryDirectory(prefix='bitchord-pipeline-') as tmp:
 d=pathlib.Path(tmp);source=d/'tone.wav';rate=48000;hz=997
 pcm=b''.join(struct.pack('<hh', *([int(.2*32768*math.sin(2*math.pi*hz*i/rate))]*2)) for i in range(rate))
 with wave.open(str(source),'wb') as w:
  w.setnchannels(2);w.setsampwidth(2);w.setframerate(rate);w.writeframes(pcm*35)
 speed_out=d/'speed.wav'
 log=subprocess.run([str(exe),str(source),str(speed_out),'--speed','1.25'],check=True,capture_output=True,text=True).stderr
 sr,samples=read_float(speed_out);duration=len(samples)/2/sr
 # Discard startup/tail and measure rising zero crossings of the steady signal.
 x=samples[2*sr:2*26*sr:2];crossings=[i for i in range(1,len(x)) if x[i-1]<=0<x[i]]
 measured=(len(crossings)-1)*sr/(crossings[-1]-crossings[0])
 cents=1200*math.log2(measured/hz)
 assert abs(cents)<3,(measured,hz,cents)
 assert abs(duration-35/1.25)<.02,duration
 capture=d/'capture';enhanced=d/'enhanced.wav'
 run=subprocess.run([str(exe),str(source),str(enhanced),'--mode','enhanced','--capture',str(capture)],capture_output=True,text=True)
 assert run.returncode==0, run.stderr
 metadata=json.loads((capture/'capture.json').read_text());frames={}
 for stage in ['decoder','voice','protected']:
  r,s=read_float(capture/(stage+'.wav'));frames[stage]=len(s)//2
  assert frames[stage]==30*r,(stage,frames[stage],r)
 assert metadata['source_sha256']==hashlib.sha256(source.read_bytes()).hexdigest()
 assert metadata['source_complete_at_capture_finish'] and metadata['settings_history']
 assert metadata['settings_at_finish']['sound_mode']=='Enhanced'
 report={'pitch_preserving_speed':{'source_hz':hz,'measured_hz':measured,'pitch_error_cents':cents,'pitch_gate_cents':3,'speed':1.25,'source_seconds':35,'output_seconds':duration,'expected_seconds':28,'engine':log.strip()},'bounded_capture':{'stage_frames':frames,'capture_limit_seconds':30,'metadata':metadata}}
 (root/'native-core/audio-validation/pipeline-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
 print('Pitch: %.5f Hz; duration %.6f s; bounded captures valid'%(measured,duration))
