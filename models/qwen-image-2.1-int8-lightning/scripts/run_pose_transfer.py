#!/usr/bin/env python3
"""Qwen Image 2.1 VNCCS pose transfer through the model's local ComfyUI API."""
import argparse
import json
import mimetypes
import sys
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
WORKFLOW = HERE / "workflows/Qwen-Image-2.1-VNCCS-PoseTransfer-API.json"

def upload(url, image):
    image = Path(image)
    if not image.is_file():
        raise FileNotFoundError(image)
    boundary = "----vnccs-" + uuid.uuid4().hex
    name = image.name.replace('"', '_').replace('\r', '_').replace('\n', '_')
    mime = mimetypes.guess_type(name)[0] or 'application/octet-stream'
    header = (f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="{name}"\r\nContent-Type: {mime}\r\n\r\n').encode()
    data = header + image.read_bytes() + f'\r\n--{boundary}--\r\n'.encode()
    req = urllib.request.Request(url + '/upload/image',data=data,headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})
    with urllib.request.urlopen(req,timeout=180) as res:
        value = json.load(res)
    if not value.get('name'):
        raise RuntimeError(f'Upload failed: {value}')
    return value['name'], value.get('subfolder','')

def request_json(url,path,data=None):
    content = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url+path,data=content,headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=60) as res:
        return json.load(res)

def main():
    ap=argparse.ArgumentParser(description='3D mannequin image -> reference pose, character image -> identity')
    ap.add_argument('--char',required=True)
    ap.add_argument('--pose-ref',required=True)
    ap.add_argument('--out',required=True)
    ap.add_argument('--url',default='http://127.0.0.1:8188',help='ComfyUI gateway address')
    ap.add_argument('--seed',type=int,default=424242)
    ap.add_argument('--steps',type=int,default=25)
    ap.add_argument('--cfg',type=float,default=1.0)
    ap.add_argument('--lora-strength',type=float,default=1.0)
    ap.add_argument('--timeout',type=int,default=900)
    args=ap.parse_args()
    url=args.url.rstrip('/')
    wf=json.loads(WORKFLOW.read_text())
    pose=upload(url,args.pose_ref)
    char=upload(url,args.char)
    # Image 1 is the mannequin; image 2 is the original character.
    for node_id,ref in [('4',pose),('5',char)]:
        wf[node_id]['inputs']['image']=ref[0]
        if ref[1]:
            # ComfyUI accepts subfolder-prefixed names.
            wf[node_id]['inputs']['image']=ref[1]+'/'+ref[0]
    wf['8']['inputs'].update(seed=args.seed,steps=args.steps,cfg=args.cfg)
    wf['7']['inputs']['strength_model']=args.lora_strength
    result=request_json(url,'/prompt',{'prompt':wf,'client_id':'vnccs-'+uuid.uuid4().hex})
    if result.get('error') or not result.get('prompt_id'):
        raise RuntimeError(f'Prompt rejected: {result}')
    pid=result['prompt_id']
    stop=time.monotonic()+args.timeout
    while time.monotonic()<stop:
        time.sleep(2)
        history=request_json(url,'/history/'+pid).get(pid,{})
        if history.get('status',{}).get('status_str')=='error':
            raise RuntimeError('ComfyUI execution failed: '+json.dumps(history.get('status'),ensure_ascii=False)[:1200])
        images=history.get('outputs',{}).get('10',{}).get('images',[])
        if images:
            item=images[0]
            query=urllib.parse.urlencode({'filename':item['filename'],'subfolder':item.get('subfolder',''),'type':item.get('type','output')})
            output=Path(args.out)
            output.parent.mkdir(parents=True,exist_ok=True)
            with urllib.request.urlopen(url+'/view?'+query,timeout=120) as res:
                output.write_bytes(res.read())
            print(str(output))
            return 0
    raise TimeoutError(f'Generation did not finish in {args.timeout}s')

if __name__=='__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, TimeoutError) as exc:
        print(f'ERROR: {exc}',file=sys.stderr)
        sys.exit(1)
