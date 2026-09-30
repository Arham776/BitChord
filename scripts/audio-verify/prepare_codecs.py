#!/usr/bin/env python3
"""Generate Apple codec fixtures and fetch the documented FFmpeg Opus/MP3 vectors.
The files are validation inputs, not app resources. Keep them in ignored target/.
"""
import argparse,array,math,pathlib,struct,subprocess,wave
p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);a=p.parse_args();a.directory.mkdir(parents=True,exist_ok=True)
def tone(path,channels,seconds):
 rate=48000;pcm=array.array('h')
 for i in range(int(rate*seconds)):
  for ch in range(channels):pcm.append(int(5000*math.sin(2*math.pi*(13000 if channels==2 else (ch+1)*1000)*i/rate)))
 with wave.open(str(path),'wb') as w:
  w.setnchannels(channels);w.setsampwidth(2);w.setframerate(rate);w.writeframes(pcm.tobytes())
source=a.directory/'pcm.wav';tone(source,2,1)
for name,fmt,encoding,bitrate in [('aac-lc.m4a','m4af','aac',192000),('he-aac.m4a','m4af','aach',64000),('he-aac-v2.m4a','m4af','aacp',32000),('alac.m4a','m4af','alac',None),('lossless.flac','flac','flac',None),('pcm.aiff','AIFF','BEI16',None)]:
 cmd=['afconvert',str(source),str(a.directory/name),'-f',fmt,'-d',encoding]
 if bitrate:cmd+=['-b',str(bitrate)]
 subprocess.run(cmd,check=True)
# Positioned WAVEFORMATEXTENSIBLE 5.1: FL, FR, FC, LFE, BL, BR.
raw=a.directory/'surround-raw.wav';tone(raw,6,.1)
with wave.open(str(raw)) as w:pcm=w.readframes(w.getnframes())
fmt=struct.pack('<HHIIHHHHI',65534,6,48000,48000*12,12,16,22,16,0x3f)+bytes.fromhex('0100000000001000800000aa00389b71')
surround=a.directory/'surround.wav';surround.write_bytes(b'RIFF'+struct.pack('<I',4+8+len(fmt)+8+len(pcm))+b'WAVEfmt '+struct.pack('<I',len(fmt))+fmt+b'data'+struct.pack('<I',len(pcm))+pcm);raw.unlink()
for name,url in [('surround8.m4a','https://samples.ffmpeg.org/A-codecs/AAC/8_Channel_ID.m4a'),('mp3.mp3','https://samples.ffmpeg.org/A-codecs/MP3/ascii.mp3'),('opus.ogg','https://samples.ffmpeg.org/A-codecs/opus/testvector12.ogg'),('opus.mka','https://fate-suite.ffmpeg.org/opus/testvector12.mka')]:
 subprocess.run(['curl','--fail','--location','--silent','--show-error',url,'--output',str(a.directory/name)],check=True)
# The FATE Matroska vector has only Opus packets. Change the EBML DocType
# declaration/version to WebM while leaving the complete Segment bytes intact.
data=(a.directory/'opus.mka').read_bytes();assert data[:4]==bytes.fromhex('1a45dfa3')
width=9-data[4].bit_length()
length=int.from_bytes(data[4:4+width],'big') & ((1<<(7*width))-1)
end=4+width+length
header=data[4+width:end].replace(b'\x42\x82\x88matroska',b'\x42\x82\x84webm').replace(b'\x42\x87\x81\x02',b'\x42\x87\x81\x04')
assert len(header)<127
(a.directory/'opus.webm').write_bytes(data[:4]+bytes([0x80+len(header)])+header+data[end:])
print('Prepared 13 codec fixtures in',a.directory)
