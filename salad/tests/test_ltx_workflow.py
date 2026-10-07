import copy
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


if __name__ == '__main__':
    unittest.main()
