// Independent AudioToolbox file seek, rather than the production packet bridge.
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void check(OSStatus s,const char *what){if(s){fprintf(stderr,"%s: %d\n",what,(int)s);exit(1);}}
static void u32(FILE *f,uint32_t x){fwrite(&x,4,1,f);}static void u16(FILE *f,uint16_t x){fwrite(&x,2,1,f);}
int main(int argc,char **argv){
 if(argc!=4)return 2;
 CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)argv[1],strlen(argv[1]),false);
 ExtAudioFileRef file;check(ExtAudioFileOpenURL(url,&file),"open");CFRelease(url);
 AudioStreamBasicDescription source={0};UInt32 size=sizeof(source);check(ExtAudioFileGetProperty(file,kExtAudioFileProperty_FileDataFormat,&size,&source),"source");
 AudioStreamBasicDescription pcm={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=8,.mFramesPerPacket=1,.mBytesPerFrame=8,.mChannelsPerFrame=2,.mBitsPerChannel=32};
 check(ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,sizeof(pcm),&pcm),"client");
 double seconds=atof(argv[3]);check(ExtAudioFileSeek(file,(SInt64)(seconds*source.mSampleRate)),"seek");
 fprintf(stderr,"File rate %.0f; seek %.3f seconds\n",source.mSampleRate,seconds);
 FILE *out=fopen(argv[2],"wb");if(!out)return 3;
 fwrite("RIFF",4,1,out);u32(out,0);fwrite("WAVEfmt ",8,1,out);u32(out,16);u16(out,3);u16(out,2);u32(out,48000);u32(out,48000*8);u16(out,8);u16(out,32);fwrite("data",4,1,out);u32(out,0);
 float samples[4096*2];uint32_t total=0;
 for(;;){UInt32 frames=4096;AudioBufferList buffers={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=sizeof(samples),.mData=samples}}};check(ExtAudioFileRead(file,&frames,&buffers),"read");if(!frames)break;fwrite(samples,8,frames,out);total+=frames;}
 fseek(out,4,SEEK_SET);u32(out,36+total*8);fseek(out,40,SEEK_SET);u32(out,total*8);fclose(out);ExtAudioFileDispose(file);fprintf(stderr,"%u output frames\n",total);return 0;
}
