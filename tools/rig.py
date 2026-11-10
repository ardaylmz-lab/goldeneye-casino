# Otomatik iskelet: dört görünümlü GLB'den en soldaki figürü ayırır, yatay kesitlerle bacak/gövde/kol dallarını bulur, eklemleri hesaplar,
# köşe ağırlıklarını üretir ve iskeletli GLB yazar. Model: y yukarı, yüz +z, karakterin solu +x, ayaklar y=0.
# Kullanım: python3 -I rig.py <kaynak.glb> <çıktı.glb> [doku_boyutu]
import sys, json, struct, io, numpy as np
from PIL import Image
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
src,dst=sys.argv[1],sys.argv[2]; TEXSZ=int(sys.argv[3]) if len(sys.argv)>3 else 1024
d=open(src,'rb').read(); L=struct.unpack('<I',d[12:16])[0]; J=json.loads(d[20:20+L]); BIN=d[20+L+8:]
acc,bv=J['accessors'],J['bufferViews']; prim=J['meshes'][0]['primitives'][0]
def arr(ai,dt,n):
    a=acc[ai]; v=bv[a['bufferView']]; off=v.get('byteOffset',0)+a.get('byteOffset',0)
    return np.frombuffer(BIN,dtype=dt,count=a['count']*n,offset=off).reshape(-1,n)
ct={5121:np.uint8,5123:np.uint16,5125:np.uint32}
P=arr(prim['attributes']['POSITION'],np.float32,3).astype(np.float64); UV=arr(prim['attributes']['TEXCOORD_0'],np.float32,2)
I=arr(prim['indices'],ct[acc[prim['indices']]['componentType']],1).reshape(-1,3).astype(np.int64)
# ---- en soldaki figür ----
key=np.round(P*20000).astype(np.int64); _,inv=np.unique(key,axis=0,return_inverse=True); inv=inv.reshape(-1); W=inv[I]; nv=inv.max()+1
e=np.concatenate([W[:,[0,1]],W[:,[1,2]],W[:,[2,0]]]); nc,lab=connected_components(coo_matrix((np.ones(len(e)),(e[:,0],e[:,1])),shape=(nv,nv)),directed=False)
tl=lab[W[:,0]]; tcnt=np.bincount(tl,minlength=nc); big=[c for c in range(nc) if tcnt[c]>0.05*len(I)]
cx=[P[I[tl==c]].reshape(-1,3)[:,0].mean() for c in big]; comp=big[int(np.argmin(cx))]
T=I[tl==comp]; used=np.unique(T); remap=-np.ones(len(P),np.int64); remap[used]=np.arange(len(used)); T=remap[T]; P=P[used]; UV=UV[used]
mn,mx=P.min(0),P.max(0); P[:,0]-=(mn[0]+mx[0])/2; P[:,2]-=(mn[2]+mx[2])/2; P[:,1]-=mn[1]; H=float(P[:,1].max())
# kaynaştırılmış (konuma göre) topoloji
key=np.round(P*20000).astype(np.int64); _,first,wid=np.unique(key,axis=0,return_index=True,return_inverse=True); wid=wid.reshape(-1); V=P[first]; Tw=wid[T]
ok=(Tw[:,0]!=Tw[:,1])&(Tw[:,1]!=Tw[:,2])&(Tw[:,0]!=Tw[:,2]); Tw=Tw[ok]; T=T[ok]; nw=len(V)
print(f'figür: köşe {len(P)} (kaynaşık {nw}), üçgen {len(T)}, boy H={H:.3f}, en {P[:,0].max()-P[:,0].min():.3f}, derinlik {P[:,2].max()-P[:,2].min():.3f}')
# ---- yatay kesitler: her kesitte kapalı halkalar ----
NS=280; ys=(np.arange(NS)+.5)*H/NS; ty=V[Tw][:,:,1]; slices=[]
for c in ys:
    ab=ty>c; cnt=ab.sum(1); ids=np.where((cnt==1)|(cnt==2))[0]
    if len(ids)==0: slices.append([]); continue
    a=ab[ids]; lone=np.where(cnt[ids,None]==1,a,~a).argmax(1); tri=Tw[ids]; r=np.arange(len(ids)); vl=tri[r,lone]; v1=tri[r,(lone+1)%3]; v2=tri[r,(lone+2)%3]
    e1=np.sort(np.stack([vl,v1],1),1); e2=np.sort(np.stack([vl,v2],1),1); ek=np.concatenate([e1,e2]); uq,ei=np.unique(ek,axis=0,return_inverse=True); ei=ei.reshape(-1); n=len(ids)
    A=V[uq[:,0]]; B=V[uq[:,1]]; t=((c-A[:,1])/(B[:,1]-A[:,1]))[:,None]; pts=A+t*(B-A)
    nl,ll=connected_components(coo_matrix((np.ones(n),(ei[:n],ei[n:])),shape=(len(uq),len(uq))),directed=False); tlab=ll[ei[:n]]; loops=[]
    for k in range(nl):
        p=pts[ll==k]; loops.append(dict(cx=float(p[:,0].mean()),cz=float(p[:,2].mean()),x0=float(p[:,0].min()),x1=float(p[:,0].max()),z0=float(p[:,2].min()),z1=float(p[:,2].max()),tris=set(ids[tlab==k].tolist()),n=len(p)))
        loops[-1]['ext']=(loops[-1]['x1']-loops[-1]['x0'])+(loops[-1]['z1']-loops[-1]['z0'])
    slices.append(loops)
idx=lambda f:int(np.clip(round(f*NS-.5),0,NS-1))
def best(prev,loops):
    if not loops: return None
    sh=[len(prev['tris']&l['tris']) for l in loops]; k=int(np.argmax(sh))
    if sh[k]>0: return loops[k]
    dd=[abs(l['cx']-prev['cx'])+abs(l['cz']-prev['cz']) for l in loops]; k=int(np.argmin(dd)); return loops[k] if dd[k]<0.06*H else None
# bacaklar: iki büyük halka, zıt taraflarda
i0=None
for i in range(idx(.08),idx(.35)):
    m=sorted([l for l in slices[i] if l['ext']>0.05*H],key=lambda l:-l['ext'])
    if len(m)>=2 and m[0]['cx']*m[1]['cx']<0 and m[1]['ext']>0.5*m[0]['ext']: i0=i; break
assert i0 is not None,'bacak halkaları bulunamadı'
legL=[None]*NS; legR=[None]*NS; body=[None]*NS; m=sorted(slices[i0],key=lambda l:-l['ext'])[:2]; legL[i0]=max(m,key=lambda l:l['cx']); legR[i0]=min(m,key=lambda l:l['cx'])
for i in range(i0-1,-1,-1):
    for arrL in (legL,legR):
        nx=best(arrL[i+1],slices[i]) if arrL[i+1] else None; arrL[i]=nx
ic=None
for i in range(i0+1,NS):
    a=best(legL[i-1],slices[i]); b=best(legR[i-1],slices[i])
    if a is None or b is None or a is b: ic=i; body[i]=a if a is not None else b; break
    legL[i]=a; legR[i]=b
assert ic is not None,'kasık bulunamadı'
# kasığın üstünde 'ana halka': merkeze yakın en büyük halka (kapüşon, yaka, saç gibi ek kabuklar ayrı halkalar olabilir)
for i in range(ic+1,NS):
    c=[l for l in slices[i] if abs(l['cx'])<0.2*H]
    if c: body[i]=max(c,key=lambda l:l['ext'])
itop=max(i for i in range(NS) if body[i] is not None)
# kollar: merkez halkanın dışında kalan yan dallar; her tarafta dikeyde en uzun dal koldur (pantolon kıvrımı gibi kısa dallar elenir)
arms={}
for s_,name in ((1,'L'),(-1,'R')):
    tracks=[]; active=None
    for i in range(idx(.18),idx(.85)):
        cen_=body[i] or (legL[i] if s_>0 else legR[i])
        if cen_ is None: continue
        cand=[l for l in slices[i] if l is not body[i] and l is not legL[i] and l is not legR[i] and l['ext']>0.015*H and ((l['cx']>cen_['x1']-0.02*H) if s_>0 else (l['cx']<cen_['x0']+0.02*H))]
        if active is not None:
            nx=best(active['tr'][i-1],slices[i]) if active['tr'][i-1] is not None else None
            if nx is None or nx is body[i] or nx is legL[i] or nx is legR[i]: active['i_a']=i; active['merged']=nx is body[i]; tracks.append(active); active=None
            else: active['tr'][i]=nx; continue
        if active is None and cand:
            active=dict(tr=[None]*NS,i_f=i,i_a=i,merged=False); active['tr'][i]=max(cand,key=lambda l:l['ext'])
    if active is not None: tracks.append(active)
    assert tracks,'kol bulunamadı '+name
    arms[name]=max(tracks,key=lambda t:t['i_a']-t['i_f']); print(' kol',name,'dal sayısı',len(tracks),'seçilen: parmak ucu',round(ys[arms[name]['i_f']]/H,3),'birleşme',round(ys[arms[name]['i_a']]/H,3),'gövdeyle birleşti:',arms[name]['merged'])
yc=ys[ic]; print(f'kasık y={yc/H:.3f}H | gövde tepesi {ys[itop]/H:.3f}H')
# ---- bölge etiketleri (0 gövde, 1 sol bacak, 2 sağ bacak, 3 sol kol, 4 sağ kol) ----
i_nk_guess=idx(.78); votes=np.zeros((len(Tw),5),np.int32)
for i in range(NS):
    known=[(lab_,lp) for lab_,lp in ((0,body[i]),(1,legL[i]),(2,legR[i]),(3,arms['L']['tr'][i]),(4,arms['R']['tr'][i])) if lp is not None]; lim={id(lp):lab_ for lab_,lp in known}
    # kol dalı bu yükseklikte izlenmiyorsa (dokunma noktasının üstü) ama gövdenin dışında yan halka varsa o da koldur
    for lp in slices[i]:
        lab_=lim.get(id(lp))
        if lab_ is None:
            if body[i] is not None and ys[i]>ys[ic] and lp['cx']>body[i]['x1']-0.02*H and ys[i]<ys[i_nk_guess]: lab_=3
            elif body[i] is not None and ys[i]>ys[ic] and lp['cx']<body[i]['x0']+0.02*H and ys[i]<ys[i_nk_guess]: lab_=4
            elif known: lab_=min(known,key=lambda t:abs(t[1]['cx']-lp['cx'])+abs(t[1]['cz']-lp['cz']))[0]
            else: lab_=0
        votes[list(lp['tris']),lab_]+=1
tlab=np.where(votes.sum(1)>0,votes.argmax(1),-1); vv=np.zeros((nw,5),np.int32)
for k in range(3): np.add.at(vv,Tw[tlab>=0][:,k],np.eye(5,dtype=np.int32)[tlab[tlab>=0]])
vlab=np.where(vv.sum(1)>0,vv.argmax(1),-1); ee=np.concatenate([Tw[:,[0,1]],Tw[:,[1,2]],Tw[:,[2,0]]]); ee=np.concatenate([ee,ee[:,::-1]])
for _ in range(60):
    un=vlab<0
    if not un.any(): break
    m=un[ee[:,0]]&(vlab[ee[:,1]]>=0); nv2=vlab.copy(); nv2[ee[m,0]]=vlab[ee[m,1]]; vlab=nv2
vlab[vlab<0]=0; print('bölge köşe sayıları [gövde, sol bacak, sağ bacak, sol kol, sağ kol]:',np.bincount(vlab,minlength=5).tolist())
# ---- eklemler ----
def cen(tr,y):
    i=idx(y/H); 
    for dlt in range(0,12):
        for j in (i-dlt,i+dlt):
            if 0<=j<NS and tr[j] is not None: l=tr[j]; return np.array([l['cx'],y,l['cz']]),l
    raise SystemExit('halka yok')
yhip=yc+0.035*H; yank=0.065*H; yknee=(yhip+yank)/2; jt={}
for nm,tr in (('Left',legL),('Right',legR)):
    c1,_=cen(tr,yc-0.05*H); jt[nm+'UpLeg']=np.array([c1[0],yhip,c1[2]]); jt[nm+'Leg'],_=cen(tr,yknee); jt[nm+'Foot'],lf=cen(tr,yank); jt[nm+'Toe']=np.array([lf['cx'],0.012*H,lf['z1']])
# boyun: eksen çevresindeki en küçük halkanın en dar olduğu yükseklik (kapüşon ve yaka dış kabuk olarak kalır)
ym=max(ys[arms['L']['i_a']],ys[arms['R']['i_a']]); ax=cen(body,yc+0.12*H)[0]; nk=[]
for i in range(idx((ym+0.06*H)/H),idx(.94)):
    inn=[l for l in slices[i] if l['x0']<ax[0]<l['x1'] and l['z0']-0.02*H<ax[2]<l['z1']+0.02*H and l['ext']>0.04*H]
    if inn: l=min(inn,key=lambda l:l['ext']); nk.append((l['ext'],i,l))
ext_n,i_n,ln_=min(nk); yn=ys[i_n]; inner=lambda y:(lambda c:np.array([c[2]['cx'],y,c[2]['cz']]))(min(nk,key=lambda t:abs(ys[t[1]]-y)))
# omuz: ana halkanın yarı genişliği boyuna doğru düşmeden önceki son 'geniş' yükseklik
arad={}; shtop={}
for nm,k,sg in (('Left','L',1),('Right','R',-1)):
    A=arms[k]; tr=A['tr']; ya=ys[A['i_a']]; yf=ys[A['i_f']]; top=[tr[i] for i in range(max(A['i_f'],A['i_a']-14),A['i_a']) if tr[i]]; rad=float(np.median([min(l['x1']-l['x0'],l['z1']-l['z0'])/2 for l in top])); arad[nm]=rad
    # omuz noktası: boyundan aşağı inerken yarı genişlik önce hızla artar (omuz eğimi), sonra neredeyse sabit kalır (kolun dış yüzü);
    # eğimin 45 derecenin altına indiği ilk yükseklik omuz tepesidir
    hw=np.array([(ys[i],(body[i]['x1'] if sg>0 else -body[i]['x0'])) for i in range(A['i_a'],i_n) if body[i] is not None]); k5=np.ones(5)/5; hs=np.convolve(np.pad(hw[:,1],2,mode='edge'),k5,'valid')
    g=-(hs[4:]-hs[:-4])/(hw[4:,0]-hw[:-4,0]); gy=hw[2:-2,0]; st=None                 # g>0: yukarı çıkarken daralma hızı
    for j in range(len(g)-1,-1,-1):
        if g[j]<0.8 and hs[j+2]>hs.max()*0.6: st=j; break
    yst=float(gy[st]) if st is not None else float(hw[np.argmax(hs>=0.86*hs.max()),0]); shtop[nm]=yst
    print('  yarı genişlik profili',nm,[(round(float(a)/H,2),round(float(b)/H,3)) for a,b in zip(hw[::6,0],hs[::6])])
    ysh=yst-1.5*rad; hwy=(body[idx(ysh/H)]['x1'] if sg>0 else -body[idx(ysh/H)]['x0']); xs=sg*(hwy-1.5*rad); mc,_=cen(tr,ya-0.01*H); zs=0.5*(mc[2]+inner(yn)[2])
    jt[nm+'Arm']=np.array([xs,ysh,zs])
    # kol yolu: omuz -> birleşme noktasındaki kol merkezi -> ... -> parmak ucu; dirsek ve bilek yol uzunluğuna göre
    path=[jt[nm+'Arm']]+[np.array([tr[i]['cx'],ys[i],tr[i]['cz']]) for i in range(A['i_a']-1,A['i_f']-1,-1) if tr[i] is not None]; path=np.array(path); seg=np.linalg.norm(np.diff(path,axis=0),axis=1); cum=np.concatenate([[0],np.cumsum(seg)])
    at=lambda f:np.array([np.interp(f*cum[-1],cum,path[:,c]) for c in range(3)])
    jt[nm+'ForeArm']=at(.44); jt[nm+'Hand']=at(.78); jt[nm+'HandTip']=path[-1]; A['ya']=ya; A['xin']=float(np.mean([(l['x0'] if sg>0 else l['x1']) for l in top[-4:]]))
    print(f' {nm}: omuz tepesi {yst/H:.3f}H, omuz eklemi [{xs/H:+.3f} {ysh/H:.3f}]H, kol yarıçapı {rad/H:.3f}H, kol yolu {cum[-1]/H:.3f}H, birleşme {ya/H:.3f}H')
ysh=(jt['LeftArm'][1]+jt['RightArm'][1])/2; bc=lambda y:cen(body,y)[0]
jt['Hips']=bc(yc+0.05*H); jt['Spine']=bc(jt['Hips'][1]+0.34*(ysh-jt['Hips'][1])); jt['Chest']=bc(jt['Hips'][1]+0.68*(ysh-jt['Hips'][1]))
jt['Neck']=inner(max(ysh+0.02*H,yn-0.04*H)); jt['Head']=inner(yn+0.01*H); jt['HeadTop']=np.array([jt['Head'][0],H,jt['Head'][2]])
for k in ('Hips','Spine','Chest','Neck','Head','HeadTop'): jt[k][0]=0.5*jt[k][0]   # merkez çizgisi: asimetriyi yumuşat
print(f'boyun en dar y={yn/H:.3f}H genişlik {(ln_["x1"]-ln_["x0"])/H:.3f}H | omuz y={ysh/H:.3f}H')
BONES=[('Hips',None,'Spine'),('Spine','Hips','Chest'),('Chest','Spine','Neck'),('Neck','Chest','Head'),('Head','Neck','HeadTop'),
 ('LeftArm','Chest','LeftForeArm'),('LeftForeArm','LeftArm','LeftHand'),('LeftHand','LeftForeArm','LeftHandTip'),('RightArm','Chest','RightForeArm'),('RightForeArm','RightArm','RightHand'),('RightHand','RightForeArm','RightHandTip'),
 ('LeftUpLeg','Hips','LeftLeg'),('LeftLeg','LeftUpLeg','LeftFoot'),('LeftFoot','LeftLeg','LeftToe'),('RightUpLeg','Hips','RightLeg'),('RightLeg','RightUpLeg','RightFoot'),('RightFoot','RightLeg','RightToe')]
bi={b[0]:i for i,b in enumerate(BONES)}
for b in BONES: print(f"  {b[0]:13s} [{jt[b[0]][0]/H:+.3f} {jt[b[0]][1]/H:.3f} {jt[b[0]][2]/H:+.3f}]H  uzunluk {np.linalg.norm(jt[b[2]]-jt[b[0]])/H:.3f}H")
# ---- ağırlıklar ----
def dseg(Pp,a,b):
    ab=b-a; t=np.clip(((Pp-a)@ab)/max(ab@ab,1e-12),0,1); return np.linalg.norm(Pp-(a+t[:,None]*ab),axis=1)
bw=lambda y:(lambda l:(l['x1']-l['x0'])/2)(cen(body,y)[1])
rad={'Hips':bw(jt['Hips'][1]),'Spine':bw(jt['Spine'][1])*0.85,'Chest':bw(jt['Chest'][1])*0.6,'Neck':(ln_['x1']-ln_['x0'])/2*1.2,'Head':bw((jt['Head'][1]+H)/2)}
for nm in ('Left','Right'):
    lr=(lambda l:min(l['x1']-l['x0'],l['z1']-l['z0'])/2)(cen(legL if nm=='Left' else legR,yknee)[1]); rad[nm+'UpLeg']=lr*1.1; rad[nm+'Leg']=lr; rad[nm+'Foot']=lr; rad[nm+'Arm']=arad[nm]*1.4; rad[nm+'ForeArm']=arad[nm]; rad[nm+'Hand']=arad[nm]
D=np.stack([dseg(V,jt[b[0]],jt[b[2]])/rad[b[0]] for b in BONES],1); allow=np.zeros((nw,len(BONES)),bool); y=V[:,1]; x=V[:,0]
def al(mask,names):
    for n in names: allow[mask,bi[n]]=True
al(vlab==1,['Hips','LeftUpLeg','LeftLeg','LeftFoot']); al(vlab==2,['Hips','RightUpLeg','RightLeg','RightFoot'])
al(vlab==3,['Chest','LeftArm','LeftForeArm','LeftHand']); al(vlab==4,['Chest','RightArm','RightForeArm','RightHand'])
Bm=vlab==0; al(Bm,['Hips','Spine','Chest','Neck','Head'])
for nm,k,sg in (('Left','L',1),('Right','R',-1)):
    A=arms[k]; S_=jt[nm+'Arm']; E_=jt[nm+'ForeArm']; r_=rad[nm+'Arm']
    axx=np.interp(y,[E_[1],S_[1]],[E_[0],S_[0]])                       # kol ekseninin o yükseklikteki x'i (omuzun üstünde omuz x'i)
    side=(sg*(x-axx)>-0.9*r_)&(y>A['ya']-0.02*H)&(y<shtop[nm]+0.03*H)
    al(Bm&side,[nm+'Arm',nm+'ForeArm']); allow[np.ix_(Bm&side&(sg*(x-axx)>0.2*r_),[bi['Hips'],bi['Head']])]=False
al(Bm&(y<yc+0.07*H)&(x>0),['LeftUpLeg']); al(Bm&(y<yc+0.07*H)&(x<0),['RightUpLeg'])
Wt=np.where(allow,1.0/np.maximum(D,0.25)**4,0.0)
Wt[(y>jt['Head'][1]+0.035*H)[:,None]&(np.arange(len(BONES))!=bi['Head'])[None,:]]=0; Wt[y>jt['Head'][1]+0.035*H,bi['Head']]=1     # kafa ve saç tek kemik
Wt/=Wt.sum(1,keepdims=True)
dom=Wt.argmax(1); LOW={bi[n] for n in ('LeftForeArm','LeftHand','RightForeArm','RightHand')}; CORE={bi[n] for n in ('Hips','Spine','LeftUpLeg','LeftLeg','LeftFoot','RightUpLeg','RightLeg','RightFoot')}
lowv=np.isin(dom,list(LOW))|((vlab>=3)&(y<min(jt['LeftForeArm'][1],jt['RightForeArm'][1])+0.02*H)); corev=np.isin(dom,list(CORE))&(vlab<3)
bridge=lowv[Tw].any(1)&corev[Tw].any(1); print('köprü üçgeni (kesildi):',int(bridge.sum())); keepT=~bridge; Tw_all=Tw; Tw=Tw[keepT]
ee=np.concatenate([Tw[:,[0,1]],Tw[:,[1,2]],Tw[:,[2,0]]]); ee=np.concatenate([ee,ee[:,::-1]])
An=coo_matrix((np.ones(len(ee)),(ee[:,0],ee[:,1])),shape=(nw,nw)).tocsr(); An.data[:]=1; deg=np.maximum(np.asarray(An.sum(1)).reshape(-1),1)
for _ in range(5): Wt=0.5*Wt+0.5*(An@Wt)/deg[:,None]
top4=np.argsort(-Wt,1)[:,:4]; w4=np.take_along_axis(Wt,top4,1); w4[w4<0.02]=0; w4/=w4.sum(1,keepdims=True)
print('ağırlık: köşe başına ortalama etkili kemik',round(float((w4>0).sum(1).mean()),2),'| baskın kemik dağılımı:',{BONES[i][0]:int(n) for i,n in enumerate(np.bincount(top4[:,0],minlength=len(BONES)))})
# ---- yumuşak normaller ----
T=T[keepT]
fn=np.cross(V[Tw[:,1]]-V[Tw[:,0]],V[Tw[:,2]]-V[Tw[:,0]]); an=np.zeros((nw,3))
for k in range(3): np.add.at(an,Tw[:,k],fn)
Nn=an[wid]; ln=np.linalg.norm(Nn,axis=1,keepdims=True); Nn=(Nn/np.where(ln>1e-12,ln,1)).astype(np.float32)
# ---- doku ----
img=J['images'][0]; iv=bv[img['bufferView']]; im=Image.open(io.BytesIO(BIN[iv.get('byteOffset',0):iv.get('byteOffset',0)+iv['byteLength']])).convert('RGB')
if im.size[0]!=TEXSZ: im=im.resize((TEXSZ,TEXSZ),Image.LANCZOS)
tb=io.BytesIO(); im.save(tb,'JPEG',quality=86,optimize=True); tex=tb.getvalue()
# ---- GLB ----
def pad(b,c=b'\x00'): return b+c*((4-len(b)%4)%4)
ibm=np.tile(np.eye(4,dtype=np.float32),(len(BONES),1,1))
for i,b in enumerate(BONES): ibm[i,3,:3]=-jt[b[0]]          # sütun-öncelikli: öteleme son sütunda (düz dizide 12..14)
blobs=[T.astype(np.uint32).tobytes(),P.astype(np.float32).tobytes(),Nn.tobytes(),UV.astype(np.float32).tobytes(),top4[wid].astype(np.uint8).tobytes(),w4[wid].astype(np.float32).tobytes(),ibm.tobytes(),tex]
blobs=[pad(b) for b in blobs]; offs=np.cumsum([0]+[len(b) for b in blobs]); nodes=[{'name':'Figure','mesh':0,'skin':0}]; ni={}
for b in BONES: ni[b[0]]=len(nodes); nodes.append({'name':b[0],'translation':[float(v) for v in (jt[b[0]]-(jt[b[1]] if b[1] else 0))]})
for b in BONES:
    if b[1]: nodes[ni[b[1]]].setdefault('children',[]).append(ni[b[0]])
for tipn,par in (('HeadTop','Head'),('LeftHandTip','LeftHand'),('RightHandTip','RightHand'),('LeftToe','LeftFoot'),('RightToe','RightFoot')):
    nodes[ni[par]].setdefault('children',[]).append(len(nodes)); nodes.append({'name':tipn,'translation':[float(v) for v in jt[tipn]-jt[par]]})
tgt=[34963,34962,34962,34962,34962,34962,None,None]; raw=[len(T)*12,len(P)*12,len(P)*12,len(P)*8,len(P)*4,len(P)*16,len(BONES)*64,len(tex)]
out={'asset':{'version':'2.0','generator':'goldeneye rig.py'},'scene':0,'scenes':[{'nodes':[0,ni['Hips']],'extras':{'height':H,'crotch':float(yc),'shoulder':float(ysh)}}],'nodes':nodes,
 'meshes':[{'primitives':[{'attributes':{'POSITION':1,'NORMAL':2,'TEXCOORD_0':3,'JOINTS_0':4,'WEIGHTS_0':5},'indices':0,'material':0}]}],'skins':[{'joints':[ni[b[0]] for b in BONES],'inverseBindMatrices':6,'skeleton':ni['Hips']}],
 'materials':[{'pbrMetallicRoughness':{'baseColorTexture':{'index':0},'metallicFactor':0.0,'roughnessFactor':0.8},'doubleSided':True}],'textures':[{'source':0,'sampler':0}],'samplers':[{'magFilter':9729,'minFilter':9987}],'images':[{'bufferView':7,'mimeType':'image/jpeg'}],
 'buffers':[{'byteLength':int(offs[-1])}],'bufferViews':[dict({'buffer':0,'byteOffset':int(offs[i]),'byteLength':raw[i]},**({'target':tgt[i]} if tgt[i] else {})) for i in range(8)],
 'accessors':[{'bufferView':0,'componentType':5125,'count':int(T.size),'type':'SCALAR'},{'bufferView':1,'componentType':5126,'count':len(P),'type':'VEC3','min':[float(v) for v in P.min(0)],'max':[float(v) for v in P.max(0)]},
  {'bufferView':2,'componentType':5126,'count':len(P),'type':'VEC3'},{'bufferView':3,'componentType':5126,'count':len(P),'type':'VEC2'},{'bufferView':4,'componentType':5121,'count':len(P),'type':'VEC4'},{'bufferView':5,'componentType':5126,'count':len(P),'type':'VEC4'},{'bufferView':6,'componentType':5126,'count':len(BONES),'type':'MAT4'}]}
jb=pad(json.dumps(out,separators=(',',':')).encode(),b' '); binb=b''.join(blobs)
open(dst,'wb').write(struct.pack('<4sII',b'glTF',2,28+len(jb)+len(binb))+struct.pack('<I4s',len(jb),b'JSON')+jb+struct.pack('<I4s',len(binb),b'BIN\x00')+binb)
print(f'yazıldı: {(28+len(jb)+len(binb))//1024} KB (doku {len(tex)//1024} KB {TEXSZ}px, geometri+iskelet {(len(binb)-len(tex))//1024} KB)')
