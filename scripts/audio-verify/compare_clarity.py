#!/usr/bin/env python3
"""Compare low-level RMS against the pinned, independently compiled C++ chain.
Usage: compare_clarity.py /path/to/LastWave-Native [output.json]
"""
import array,hashlib,json,math,pathlib,subprocess,sys,tempfile
root=pathlib.Path(__file__).resolve().parents[2]
ref=pathlib.Path(sys.argv[1]);revision=subprocess.check_output(['git','-C',str(ref),'rev-parse','HEAD'],text=True).strip()
assert revision=='ec11a430fcf6e7f06bbae450e768d48f1d97d161',revision
subprocess.run(['cargo','build','--release','--example','clarity_response','--manifest-path',str(root/'native-core/Cargo.toml')],check=True)
results=[]
with tempfile.TemporaryDirectory(prefix='bitchord-clarity-') as d:
 exe=pathlib.Path(d)/'lastwave'
 subprocess.run(['clang++','-O2','-std=c++17','-I'+str(ref/'app/src/main/cpp'),str(root/'scripts/audio-verify/lastwave_reference.cpp'),str(ref/'app/src/main/cpp/DspProcessor.cpp'),'-o',str(exe)],check=True)
 for preset in range(4):
  for rate in [44100,48000]:
   for side in [0,1]:
    for hz in [40,72,130,280,750,1000,3400,6000,10500,16000,19000]:
     paths=[pathlib.Path(d)/'cpp.f32',pathlib.Path(d)/'rust.f32']
     for cmd,path in zip([exe,root/'native-core/target/release/examples/clarity_response'],paths):subprocess.run([str(cmd),str(rate),str(hz),str(side),str(path),str(preset)],check=True)
     rms=[]
     for path in paths:
      x=array.array('f');x.frombytes(path.read_bytes());steady=x[rate:] # final half-second, both channels
      rms.append(math.sqrt(sum(v*v for v in steady)/len(steady)))
     delta=20*math.log10(rms[1]/rms[0]);results.append(dict(preset=["reference","speaker","headphone","dac"][preset],rate=rate,signal='side' if side else 'mid',hz=hz,delta_db=delta))
worst=max(abs(r['delta_db']) for r in results)
report=dict(reference_revision=revision,rust_sound_sha256=hashlib.sha256((root/"native-core/src/sound.rs").read_bytes()).hexdigest(),max_deviation_db=worst,results=results)
path=pathlib.Path(sys.argv[2]) if len(sys.argv)>2 else root/'native-core/audio-validation/clarity-comparison.json';path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n')
print('Maximum low-level deviation from actual Lastwave: %.4f dB'%worst)
assert worst<=0.15,report
