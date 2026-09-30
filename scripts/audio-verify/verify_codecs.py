#!/usr/bin/env python3
"""Render local fixtures through production playback; compare pull partitions.
Fixture directory contains AAC/HE-AAC/HE-AAC-v2, FLAC, ALAC, AIFF made with
Apple afconvert, plus WAV and the documented FFmpeg MP3/Opus samples.
Run on a Mac with Apple codec service access (AudioToolbox requires it).
"""
import argparse, hashlib, json, pathlib, struct, subprocess

def wav(path):
    data=pathlib.Path(path).read_bytes(); off=12; fmt=None; pcm=None
    while off+8<=len(data):
        tag=data[off:off+4];n=struct.unpack_from('<I',data,off+4)[0];body=data[off+8:off+8+n]
        if tag==b'fmt ':
            fmt=struct.unpack_from('<HHIIHH',body)
            if fmt[0]==65534:fmt=(struct.unpack_from('<H',body,24)[0],)+fmt[1:]
        if tag==b'data':pcm=body
        off+=8+n+(n&1)
    assert fmt and pcm is not None
    typ,ch,rate,_,_,depth=fmt
    if typ==3 and depth==32: samples=struct.unpack('<'+'f'*(len(pcm)//4),pcm)
    elif typ==1 and depth==16:samples=tuple(v/32768 for v in struct.unpack('<'+'h'*(len(pcm)//2),pcm))
    else:raise ValueError(fmt)
    return rate,ch,samples

p=argparse.ArgumentParser();p.add_argument('fixtures',type=pathlib.Path);p.add_argument('--report',type=pathlib.Path,required=True)
a=p.parse_args();root=pathlib.Path(__file__).resolve().parents[2];exe=root/'native-core/target/release/examples/playback_render'
report=[]
for src in sorted(a.fixtures.iterdir()):
    if src.suffix not in ['.m4a','.flac','.aiff','.wav','.ogg','.mp3','.webm','.mka']:continue
    if 'render' in src.name or 'reference' in src.name or 'apple-seek' in src.name:continue
    outputs=[];logs=[]
    for chunk in [7,4096]:
        dest=src.with_name(src.name+f'.render-{chunk}.wav')
        r=subprocess.run([str(exe),str(src),str(dest),'--rate','48000','--chunk',str(chunk)],capture_output=True,text=True,timeout=90)
        logs.append(r.stderr)
        if r.returncode!=0:raise RuntimeError(f'{src}: {r.stderr}')
        outputs.append(wav(dest))
    assert outputs[0]==outputs[1],f'partition changed decoded samples: {src}'
    rate,ch,samples=outputs[0]
    assert samples, f'empty decode: {src}'
    item={'fixture':src.name,'encoded_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'frames':len(samples)//ch,'output_rate':rate,'pull_sizes':[7,4096],'samples_identical':True,'engine':logs[0].strip()}
    if src.name=='pcm.wav':
        sr,sc,original=wav(src);assert (sr,sc,original)==outputs[0];item['transparent_pcm_exact']=True
    if src.suffix in ['.m4a','.flac','.aiff']:
        ref=src.with_name(src.name+'.reference.wav')
        cmd=['afconvert',str(src),str(ref),'-f','WAVE','-d','LEF32@48000']
        if src.name=='surround8.m4a':cmd+=['-l','MPEG_7_1_A']
        elif src.name.startswith('surround'):cmd+=['-l','MPEG_5_1_A']
        subprocess.run(cmd,check=True,capture_output=True)
        rr,rc,reference=wav(ref)
        if rc==6:
            q=2**-0.5;denom=1+2*q
            reference=tuple(v for i in range(0,len(reference),6) for v in ((reference[i]+q*(reference[i+2]+reference[i+4]))/denom,(reference[i+1]+q*(reference[i+2]+reference[i+5]))/denom))
            rc=2
        if rc==8:
            # MPEG_7_1_A is FL FR FC LFE SL SR FLC FRC. The front wide
            # positions fold exclusively into their corresponding side.
            q=2**-0.5;denom=1+3*q
            reference=tuple(v for i in range(0,len(reference),8) for v in ((reference[i]+q*(reference[i+2]+reference[i+4]+reference[i+6]))/denom,(reference[i+1]+q*(reference[i+2]+reference[i+5]+reference[i+7]))/denom))
            rc=2
        # Apple's file converter may append legal encoder padding. Compare the
        # common valid region directly; report tails rather than hide them.
        n=min(len(samples),len(reference));delta=max(abs(samples[i]-reference[i]) for i in range(n))
        item.update(reference_frames=len(reference)//rc,reference_max_sample_difference=delta)
        if 'he-aac' in src.name:assert delta<1e-5, f'HE reconstruction disagrees with Apple reference: {delta}'
        if src.suffix in ['.flac','.aiff'] or 'alac' in src.name:assert delta<1e-7
    if src.suffix=='.m4a':
        apple=src.with_name(src.name+'.render-apple.wav')
        r=subprocess.run([str(exe),str(src),str(apple),'--rate','48000','--chunk','7','--apple-aac','1'],capture_output=True,text=True,timeout=90)
        assert r.returncode==0,r.stderr
        ar,ac,actual=wav(apple);assert len(actual)==len(samples)
        n=min(len(actual),len(reference));difference=max(abs(actual[i]-reference[i]) for i in range(n))
        assert difference<1e-6,(src,difference)
        item['apple_fallback_reference_max_difference']=difference
        item['apple_fallback_engine']=r.stderr.strip()
    report.append(item);print(src.name,item['frames'],'identical chunks',item.get('reference_max_sample_difference',''),flush=True)
a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,indent=2)+'\n')
