import copy
import hashlib
import os
import subprocess
import tempfile
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODEL = 'ltx-2.3-uncensored-v1.4-q4'
VAST = ROOT / 'vast/models' / MODEL
SALAD = ROOT / 'salad/models' / MODEL
WORKFLOW = 'LTX-2.3_T2V_I2V_Two_Stage_Distilled.json'


class LtxWorkflowTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.graph = json.loads((SALAD / 'workflows' / WORKFLOW).read_text(encoding='utf-8'))

    def check_links(self, graph):
        nodes = {n['id']: n for n in graph['nodes']}
        self.assertEqual(len(nodes), len(graph['nodes']))
        links = {l[0]: l for l in graph['links']}
        self.assertEqual(len(links), len(graph['links']))
        for lid, source, slot, target, input_slot, kind in links.values():
            output = nodes[source]['outputs'][slot]
            incoming = nodes[target]['inputs'][input_slot]
            self.assertIn(lid, output['links'])
            self.assertEqual(incoming['link'], lid)
            self.assertEqual(output['type'], kind)
            self.assertEqual(incoming['type'], kind)
        for n in nodes.values():
            for output in n['outputs']:
                for lid in output['links']:
                    self.assertEqual(links[lid][1], n['id'])
            for incoming in n['inputs']:
                if incoming.get('link') is not None:
                    self.assertEqual(links[incoming['link']][3], n['id'])

    def test_i2v_and_t2v_graphs(self):
        self.check_links(self.graph)
        t2v = copy.deepcopy(self.graph)
        condition = next(n for n in t2v['nodes'] if n['type'] == 'LTXV23ImgToVideo')
        image_input = next(i for i in condition['inputs'] if i['name'] == 'image')
        lid = image_input['link']
        t2v['links'] = [l for l in t2v['links'] if l[0] != lid]
        next(n for n in t2v['nodes'] if n['type'] == 'LoadImage')['outputs'][0]['links'].remove(lid)
        image_input['link'] = None
        self.check_links(t2v)
        self.assertFalse(self.graph.get('floatingLinks'))

    def test_assets_and_two_stage_recipe(self):
        conf = (VAST / 'model.conf').read_text(encoding='utf-8')
        files = set(re.findall(r'^\w+_FILE="([^"]+)"', conf, re.M))
        for node in self.graph['nodes']:
            if node['type'] == 'LTXV23ModelsLoader':
                self.assertTrue(set(node['widgets_values']) <= files)
            if node['type'] == 'LatentUpscaleModelLoader':
                self.assertIn(node['widgets_values'][0], files)
            if node['type'] == 'LTXV23RefineSampler':
                self.assertEqual(node['widgets_values'][2:4], ['dmd (8 steps)', 8])
                self.assertEqual(node['widgets_values'][6:10], ['refine (3 steps)', 3, 1.0, 'euler'])
                self.assertEqual({i['name'] for i in node['inputs']}, {'model','positive','negative','latent_image','upscale_model','vae'})
            if node['type'] == 'LTXV23ImgToVideo':
                w = node['widgets_values']
                self.assertEqual((w[2]*2, w[3]*2), (768,512))
                self.assertEqual((w[4]-1)%8, 0)
        self.assertEqual(json.loads((VAST / WORKFLOW).read_text(encoding='utf-8')), self.graph)
        for path in [VAST / 'setup.sh', SALAD / 'prepare_models.sh']:
            text = path.read_text(encoding='utf-8')
            self.assertIn('models/latent_upscale_models/', text)
            self.assertIn('$UPSCALER_SHA256', text)
        self.assertEqual((SALAD / 'prepare_models.sh').read_text(encoding='utf-8').count('download_resume_verified'), 1)


    def test_vast_upscaler_skip_and_hash_failure(self):
        source = (VAST / 'setup.sh').read_text(encoding='utf-8')
        helper = source.split('sha256_matches() {', 1)[1].split('\ninstall_uv()', 1)[0]
        block = source.split('UPSCALER_PATH=', 1)[1].split('log "[5/5]', 1)[0]
        script = 'set -Eeuo pipefail\nsha256_matches() {' + helper
        script += '\ndie() { exit 1; }\nUPSCALER_PATH=' + block
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as folder:
            work = Path(folder)
            wget = work / 'wget'
            wget.write_text('#!/bin/bash\necho call >> "$CALLS"\nwhile (($#)); do if [ "$1" = -O ]; then out="$2"; shift 2; else shift; fi; done\nprintf "%s" "$CONTENT" > "$out"\n')
            wget.chmod(0o755)
            calls = work / 'calls'
            env = dict(os.environ, PATH=str(work)+':'+os.environ['PATH'], COMFY_DIR=str(work / 'comfy'), UPSCALER_FILE='upscale.bin', UPSCALER_URL='https://offline.invalid', UPSCALER_SHA256=hashlib.sha256(b'valid').hexdigest(), CALLS=str(calls), CONTENT='valid')
            def run():
                return subprocess.run(['bash','-c',script],env=env,capture_output=True)
            destination = work / 'comfy/models/latent_upscale_models/upscale.bin'
            self.assertEqual(run().returncode, 0)
            self.assertEqual(destination.read_bytes(), b'valid')
            self.assertEqual(run().returncode, 0)
            self.assertEqual(calls.read_text().splitlines(), ['call'])
            destination.write_bytes(b'existing invalid')
            env['CONTENT'] = 'corrupt'
            self.assertNotEqual(run().returncode, 0)
            self.assertEqual(destination.read_bytes(), b'existing invalid')
            self.assertFalse(Path(str(destination)+'.part').exists())

if __name__ == '__main__':
    unittest.main()
