// Apple's software AAC decoder. All allocation and conversion run on the
// decode worker, never in the hardware output callback.
#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    AudioConverterRef converter;
    AudioStreamBasicDescription input;
    AudioStreamBasicDescription output;
    const unsigned char *packet;
    UInt32 packet_size;
    int supplied;
    UInt32 order[8];
    AudioStreamPacketDescription description;
} BCHAAC;

static OSStatus supply(AudioConverterRef converter, UInt32 *count,
                       AudioBufferList *data, AudioStreamPacketDescription **descriptions,
                       void *context) {
    (void)converter;
    BCHAAC *state = context;
    if (!state->packet) { *count=0; return noErr; }
    if (state->supplied) { *count = 0; return 1; } // temporarily out of packets, not EOS
    state->supplied = 1;
    *count = 1;
    data->mNumberBuffers = 1;
    data->mBuffers[0].mNumberChannels = state->input.mChannelsPerFrame;
    data->mBuffers[0].mDataByteSize = state->packet_size;
    data->mBuffers[0].mData = (void *)state->packet;
    state->description.mStartOffset = 0;
    state->description.mVariableFramesInPacket = state->input.mFramesPerPacket;
    state->description.mDataByteSize = state->packet_size;
    if (descriptions) *descriptions = &state->description;
    return noErr;
}

// AudioToolbox requires an ES descriptor cookie, not bare ASC bytes. Keep
// the complete ASC in DecoderSpecificInfo; never rewrite its AAC profile.
static void descriptor(UInt8 **p, UInt8 tag, UInt32 length) {
    *(*p)++=tag;
    *(*p)++=0x80 | ((length>>21)&0x7f); *(*p)++=0x80 | ((length>>14)&0x7f);
    *(*p)++=0x80 | ((length>>7)&0x7f); *(*p)++=length&0x7f;
}
void *bch_aac_create(const unsigned char *asc, UInt32 asc_size,
                     double *rate, UInt32 *channels, uint64_t *mask, int he, int ps, int *error) {
    (void)he; (void)ps;
    if (!asc_size || asc_size>65536) { *error=kAudio_ParamError; return NULL; }
    BCHAAC *state=calloc(1,sizeof(*state));
    UInt32 cookie_size=37+asc_size;UInt8 *cookie=calloc(1,cookie_size);
    if (!state || !cookie) {free(state);free(cookie);*error=-1;return NULL;}
    UInt8 *p=cookie;descriptor(&p,3,32+asc_size);p+=3;
    descriptor(&p,4,18+asc_size);*p++=0x40;*p++=0x14;p+=11;
    descriptor(&p,5,asc_size);memcpy(p,asc,asc_size);p+=asc_size;
    descriptor(&p,6,1);*p++=2;
    state->input.mFormatID=kAudioFormatMPEG4AAC;
    UInt32 size=sizeof(state->input);
    OSStatus status=AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,cookie_size,cookie,&size,&state->input);
    AudioStreamBasicDescription rich=state->input;AudioChannelLayoutTag layout_tag=0;
    AudioFormatInfo info={state->input,cookie,cookie_size};UInt32 list_size=0;
    if(status==noErr) status=AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList,sizeof(info),&info,&list_size);
    if(status==noErr && list_size>=sizeof(AudioFormatListItem)) {
        AudioFormatListItem *list=malloc(list_size);
        if(!list) status=-108 /* allocation failure */;
        else {status=AudioFormatGetProperty(kAudioFormatProperty_FormatList,sizeof(info),&info,&list_size,list);if(status==noErr) {rich=list[0].mASBD;layout_tag=list[0].mChannelLayoutTag;}free(list);}
    }
    if(status!=noErr || rich.mSampleRate<=0 || !rich.mChannelsPerFrame || rich.mChannelsPerFrame>8) {
        *error=status ? status:kAudio_ParamError;free(cookie);free(state);return NULL;
    }
    *mask=0;
    UInt32 count=rich.mChannelsPerFrame;
    if(count<=2) { *mask=count==1 ? 4 : 3;state->order[0]=0;state->order[1]=1; }
    else {
        UInt32 layout_size=0;
        status=AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,sizeof(layout_tag),&layout_tag,&layout_size);
        AudioChannelLayout *layout=status==noErr ? malloc(layout_size) : NULL;
        if(layout) status=AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,sizeof(layout_tag),&layout_tag,&layout_size,layout);
        else status=kAudio_ParamError;
        uint64_t positions[8]={0};
        if(status==noErr && layout->mNumberChannelDescriptions==count) {
            int has_rears=0;
            for(UInt32 i=0;i<count;i++) if(layout->mChannelDescriptions[i].mChannelLabel==kAudioChannelLabel_RearSurroundLeft)has_rears=1;
            for(UInt32 i=0;i<count;i++) {
                AudioChannelLabel label=layout->mChannelDescriptions[i].mChannelLabel;
                if(label>=1 && label<=18)positions[i]=1ULL<<(label-1);
                else if(label==kAudioChannelLabel_RearSurroundLeft)positions[i]=1ULL<<4;
                else if(label==kAudioChannelLabel_RearSurroundRight)positions[i]=1ULL<<5;
                else status=kAudio_ParamError;
                if(has_rears && label==kAudioChannelLabel_LeftSurround)positions[i]=1ULL<<9;
                if(has_rears && label==kAudioChannelLabel_RightSurround)positions[i]=1ULL<<10;
                if(*mask & positions[i])status=kAudio_ParamError;
                *mask |= positions[i];state->order[i]=i;
            }
            // Rust consumes canonical WAVE-position order, which differs from
            // AAC's center-first channel order for several MPEG layouts.
            for(UInt32 i=0;i<count;i++)for(UInt32 j=i+1;j<count;j++)if(positions[state->order[j]]<positions[state->order[i]]) {UInt32 t=state->order[i];state->order[i]=state->order[j];state->order[j]=t;}
        } else status=kAudio_ParamError;
        free(layout);
        if(status!=noErr){*error=status;free(cookie);free(state);return NULL;}
    }
    // Select the reconstructed profile, not the LC core described by the
    // generic FormatInfo query. HE-AAC v2 otherwise decodes without PS/SBR.
    state->input=rich;
    state->output.mSampleRate=rich.mSampleRate;
    state->output.mFormatID=kAudioFormatLinearPCM;
    state->output.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked;
    state->output.mChannelsPerFrame=rich.mChannelsPerFrame;
    state->output.mBitsPerChannel=32;state->output.mFramesPerPacket=1;
    state->output.mBytesPerFrame=rich.mChannelsPerFrame*sizeof(float);
    state->output.mBytesPerPacket=state->output.mBytesPerFrame;
    AudioClassDescription codec={kAudioDecoderComponentType,rich.mFormatID,'appl'};
    status=AudioConverterNewSpecific(&state->input,&state->output,1,&codec,&state->converter);
    if(status==noErr) status=AudioConverterSetProperty(state->converter,kAudioConverterDecompressionMagicCookie,cookie_size,cookie);
    if(status==noErr && count>2) {
        AudioChannelLayout layout={0};layout.mChannelLayoutTag=layout_tag;
        status=AudioConverterSetProperty(state->converter,kAudioConverterInputChannelLayout,sizeof(layout),&layout);
        if(status==noErr)status=AudioConverterSetProperty(state->converter,kAudioConverterOutputChannelLayout,sizeof(layout),&layout);
    }
    free(cookie);
    if(status!=noErr){if(state->converter)AudioConverterDispose(state->converter);*error=status;free(state);return NULL;}
    *rate=state->output.mSampleRate;*channels=rich.mChannelsPerFrame;*error=noErr;return state;
}

int bch_aac_decode(void *handle, const unsigned char *packet, UInt32 size, float *output, UInt32 capacity, UInt32 *frames) {
    BCHAAC *state = handle;
    state->packet = packet; state->packet_size = size; state->supplied = 0;
    AudioBufferList data = {0};
    data.mNumberBuffers = 1;
    data.mBuffers[0].mNumberChannels = state->output.mChannelsPerFrame;
    data.mBuffers[0].mDataByteSize = capacity * state->output.mBytesPerFrame;
    data.mBuffers[0].mData = output;
    *frames = capacity;
    OSStatus status = AudioConverterFillComplexBuffer(state->converter, supply, state, frames, &data, NULL);
    if(status==noErr || status==1) {
        UInt32 channels=state->output.mChannelsPerFrame;
        for(UInt32 f=0;f<*frames;f++) {float frame[8];memcpy(frame,output+f*channels,channels*sizeof(float));for(UInt32 c=0;c<channels;c++)output[f*channels+c]=frame[state->order[c]];}
    }
    return status == 1 ? noErr : status;
}
void bch_aac_reset(void *handle) { BCHAAC *state = handle; AudioConverterReset(state->converter); }
void bch_aac_destroy(void *handle) { BCHAAC *state = handle; AudioConverterDispose(state->converter); free(state); }

// Container packet-table timing is expressed at the AAC core rate. Rust scales
// it to the reconstructed SBR/PS output rate before removing priming/padding.
int bch_aac_file_timing(const unsigned char *path, UInt32 length, double *rate,
                        int64_t *valid, int32_t *priming, int32_t *padding) {
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,path,length,false);
    if(!url)return -50;AudioFileID file=NULL;OSStatus status=AudioFileOpenURL(url,kAudioFileReadPermission,0,&file);CFRelease(url);
    if(status!=noErr)return status;
    AudioStreamBasicDescription asbd={0};UInt32 size=sizeof(asbd);
    status=AudioFileGetProperty(file,kAudioFilePropertyDataFormat,&size,&asbd);
    AudioFilePacketTableInfo timing={0};size=sizeof(timing);
    if(status==noErr)status=AudioFileGetProperty(file,kAudioFilePropertyPacketTableInfo,&size,&timing);
    AudioFileClose(file);
    if(status==noErr){*rate=asbd.mSampleRate;*valid=timing.mNumberValidFrames;*priming=timing.mPrimingFrames;*padding=timing.mRemainderFrames;}
    return status;
}
