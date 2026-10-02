import copy, glob, hashlib, json, uuid, zipfile
from pathlib import Path

BASE = Path(__file__).parent
old = zipfile.ZipFile(BASE / 'BitChord-Cover.sketch')
files = {n: old.read(n) for n in old.namelist()}
doc = json.loads(files['document.json'])
page_name = doc['pages'][0]['_ref'] + '.json'
page = json.loads(files[page_name])
root = page['layers'][0]
source = root['layers'][0]['layers']
templates = {c: next(x for x in source if x['_class'] == c) for c in ['rectangle', 'oval', 'text', 'bitmap']}
glass = json.loads(Path('/private/tmp/bitchord-glass.json').read_text())

def uid(): return str(uuid.uuid4()).upper()
def frame(x, y, w, h): return {'_class':'rect','constrainProportions':False,'x':x,'y':y,'width':w,'height':h}
def color(hex, a=1):
    h=hex.lstrip('#'); r,g,b=[int(h[i:i+2],16)/255 for i in (0,2,4)]
    return {'_class':'color','red':r,'green':g,'blue':b,'alpha':a}
def clone(l, name, x,y,w,h):
    l=copy.deepcopy(l);l['do_objectID']=uid();l['name']=name;l['nameIsFixed']=True;l['frame']=frame(x,y,w,h)
    l['style']['do_objectID']=uid();l.pop('sharedStyleID',None);l['isLocked']=False
    return l
def fill(hex,a=1):
    f=copy.deepcopy(templates['rectangle']['style']['fills'][0]);f['fillType']=0;f['color']=color(hex,a);return f
def shape(name,x,y,w,h,hex,a=1,oval=False,r=0):
    l=clone(templates['oval' if oval else 'rectangle'],name,x,y,w,h)
    l['style']['fills']=[fill(hex,a)];l['style']['shadows']=[];l['style']['blurs']=[]
    l['style']['corners']={'_class':'MSImmutableStyleCorners','radii':[r] if r else [],'style':1,'prefersConcentric':False,'smoothing':0.6}
    if 'points' in l:
        for pt in l['points']:pt['cornerRadius']=r
    return l
def gradient(l, stops, start='{0, 0}', end='{1, 1}', radial=False):
    f=l['style']['fills'][0];f['fillType']=1
    f['gradient'].update({'from':start,'to':end,'gradientType':1 if radial else 0,'elipseLength':1,'stops':[{'_class':'gradientStop','position':p,'color':color(c,a)} for p,c,a in stops]})
    return l
def text(s,x,y,w,h,size,font='SFProDisplay-Regular',hex='FFFFFF',a=1):
    l=clone(templates['text'],s,x,y,w,h);l['style']['fills']=[fill(hex,a)]
    attrs={'MSAttributedStringFontAttribute':{'_class':'fontDescriptor','attributes':{'name':font,'size':size}},'ligature':1,'MSAttributedStringColorAttribute':color(hex,a),'paragraphStyle':{'_class':'paragraphStyle','alignment':0,'maximumLineHeight':size*1.1,'minimumLineHeight':size*1.1,'paragraphSpacing':0},'kerning':-size*(.025 if size>=44 else .008)}
    l['style']['textStyle']['encodedAttributes']=attrs
    l['attributedString']={'_class':'attributedString','string':s,'attributes':[{'_class':'stringAttribute','location':0,'length':len(s),'attributes':attrs}]}
    l['textBehaviour']=1;l.pop('glyphBounds',None);return l
def bitmap(path,name,x,y,w,h):
    b=Path(path).read_bytes();ref='images/'+hashlib.sha1(b).hexdigest()+'.png';files[ref]=b
    l=clone(templates['bitmap'],name,x,y,w,h);l['image']['_ref']=ref;return l
def group(name,x,y,w,h,layers,r=0):
    g=clone(root,name,x,y,w,h);g['groupBehavior']=1;g['clippingBehavior']=1 if r else 2;g['layers']=layers;g['exportOptions']['exportFormats']=[]
    g['style']['fills']=[];g['style']['shadows']=[];g['style']['corners']={'_class':'MSImmutableStyleCorners','radii':[r] if r else [],'style':1,'smoothing':.6,'prefersConcentric':False}
    return g
def shadow(l,blur=44,y=20,a=.45):
    l['style']['shadows'].append({'_class':'shadow','isEnabled':True,'isInnerShadow':False,'blurRadius':blur,'offsetX':0,'offsetY':y,'spread':0,'color':color('000000',a),'contextSettings':{'_class':'graphicsContextSettings','blendMode':0,'opacity':1}});return l

layers=[]
layers.append(gradient(shape('Cobalt → midnight',0,0,1920,1080,'0E1FA9'),[(0,'1023AD',1),(.38,'10217F',1),(.73,'0B1034',1),(1,'080C21',1)],'{0, 0.25}','{1, 0.55}'))
layers.append(gradient(shape('Blue atmospheric light',-550,-430,1500,1600,'2556FF'),[(0,'1849FF',.7),(.48,'1B37FC',.24),(1,'1B37FC',0)],'{0.5, 0.5}','{1, 0.5}',True))
layers.append(gradient(shape('Cyan lower glow',740,340,1480,1380,'17D5F0'),[(0,'17D5F0',.68),(.45,'099DC2',.3),(1,'099DC2',0)],'{0.5, 0.5}','{1, 0.5}',True))
layers.append(gradient(shape('Coral reflected light',1280,-410,1000,1050,'FD4974'),[(0,'FE507E',.48),(.4,'942591',.2),(1,'942591',0)],'{0.5, 0.5}','{1, 0.5}',True))

# Reference-style feature copy, directly on the background.
layers.append(text('Hi-Res audio and\nAutomix',90,879,500,80,34,hex='CBD6F5',a=.96))
layers.append(text('Your library. Across Apple devices.',90,977,510,36,24,hex='DDE6FF',a=.76))
icon=group('BitChord · rounded app icon',88,77,96,96,[bitmap('/Users/baguma/Downloads/AppIcon.png','Original app icon',0,0,96,96)],25)
shadow(icon,24,10,.2);layers.append(icon)
layers.append(text('BitChord',206,93,390,62,46,'SFProDisplay-Bold'))
layers.append(text('Your music.',84,293,535,100,86,'SFProDisplay-Bold'))
layers.append(text('Native',84,396,535,100,86,'SFProDisplay-Bold'))
layers.append(text('everywhere.',84,499,535,100,86,'SFProDisplay-Bold'))
layers.append(text('Made for Mac, iPad and iPhone.',90,633,510,70,29,hex='DDE6FF',a=.88))

def add_devices():
    config=json.loads((BASE/'Apple-Resources/device-layout.json').read_text())
    # Preserve the original Mac screenshot, cropping only its black margin.
    native=json.loads(Path('/private/tmp/bitchord-window.json').read_text())
    mac=group('Mac · Apple UI Kit window',648,128,1160,731.56,[],16)
    mac['style']=copy.deepcopy(native['style']);mac['style']['do_objectID']=uid()
    mac['style']['corners']['radii']=[16]
    ms=1160/3420
    mac['layers']=[bitmap('/Users/baguma/Downloads/Screenshot 2026-10-01 at 17.14.42.png','Original Mac screenshot · margin cropped',-112*ms,-76*ms,3644*ms,2372*ms)]
    layers.append(mac)
    for dev in config:
        x,y,w=dev['placement'];bw,bh=dev['size'];sc=w/bw;h=bh*sc
        sx,sy,sw,sh=dev['screen']
        # Native clip from the real product's screen aperture.
        iw,ih=dev['imageSize'];fit=min(sw/iw,sh/ih)*sc
        screen=group(dev['name']+' · screenshot',sx*sc,sy*sc,sw*sc,sh*sc,[bitmap(dev['screenshot'],'Original screenshot · proportions preserved',(sw*sc-iw*fit)/2,(sh*sc-ih*fit)/2,iw*fit,ih*fit)],dev.get('radius',0)*sc)
        screen['style']['fills']=[fill('000000')]
        bez=bitmap(BASE/'Apple-Resources'/dev['bezel'], 'Hoverify '+dev['name']+' bezel',0,0,w,h)
        g=group(dev['name']+' · downloaded device frame',x,y,w,h,[screen,bez]);shadow(g,40,24,.45)
        layers.append(g)

if (BASE/'Apple-Resources/device-layout.json').exists():add_devices()
root['layers']=layers;root['name']='BitChord · Apple cover';root['frame']=frame(0,0,1920,1080);root['clippingBehavior']=1
root['exportOptions']['exportFormats']=[{'_class':'exportFormat','absoluteSize':0,'fileFormat':'png','name':'','namingScheme':0,'scale':1,'visibleScaleType':0}]
page['name']='Cover';page['layers']=[root]
files[page_name]=json.dumps(page).encode();files['document.json']=json.dumps(doc).encode()
files['user.json']=json.dumps({}).encode()
out=BASE/'BitChord-Apple-Cover.sketch'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
    for n,b in files.items():
        if not n.startswith('previews/'):z.writestr(n,b)
print(out)
print('ROOT_ID',root['do_objectID'])
