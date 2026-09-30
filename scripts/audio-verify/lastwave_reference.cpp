// Compiles Lastwave's actual pinned processor; no filter implementation is mirrored here.
#include "DspProcessor.h"
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cmath>
int main(int argc,char**argv){
 if(argc!=6)return 2;int rate=atoi(argv[1]);double hz=atof(argv[2]);int side=atoi(argv[3]);
 std::vector<float> samples(rate*2);
 for(int i=0;i<rate;i++){float x=0.001f*std::sin(2*3.14159265358979323846*hz*i/rate);samples[i*2]=x;samples[i*2+1]=side?-x:x;}
 lastwave::audio::DspProcessor dsp;dsp.configure(rate);dsp.setStudioMasterClarity(true);dsp.setClarityPreset(atoi(argv[5]));dsp.setPeakProtectionEnabled(false);dsp.process(samples.data(),rate,2);
 FILE*f=fopen(argv[4],"wb");if(!f)return 3;fwrite(samples.data(),sizeof(float),samples.size(),f);fclose(f);
}
