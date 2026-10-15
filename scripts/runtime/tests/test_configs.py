import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]


class RuntimeConfigTests(unittest.TestCase):
    def test_every_setup_has_a_config_and_comfy_ports_are_unique(self):
        ports = set()
        for setup in (ROOT / 'models').glob('*/setup.sh'):
            config_path = setup.parent / 'runtime.json'
            self.assertTrue(config_path.is_file(), setup.parent.name)
            config = json.loads(config_path.read_text(encoding='utf-8'))
            self.assertEqual(config['model_id'], setup.parent.name)
            self.assertGreater(config['gpu_policy']['reserve_mb'], 0)
            if config['runtime_type'] == 'comfyui':
                self.assertRegex(config['comfy_commit'], r'^[0-9a-f]{40}$')
                self.assertNotIn(config['port'], ports)
                ports.add(config['port'])
                self.assertTrue(config['model_paths'])
                self.assertTrue(config['workflows'])
            else:
                self.assertEqual(config['runtime_type'], 'cli')


if __name__ == '__main__':
    unittest.main()
