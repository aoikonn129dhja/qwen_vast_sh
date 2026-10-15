import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class SharedImageTests(unittest.TestCase):
    def test_single_dockerfile_and_vast_layout(self):
        dockerfiles = list((ROOT / 'salad').rglob('Dockerfile'))
        self.assertEqual(dockerfiles, [ROOT / 'salad/Dockerfile'])
        source = dockerfiles[0].read_text(encoding='utf-8')
        self.assertIn('FROM pytorch/pytorch:2.11.0-cuda13.0-cudnn9-runtime@sha256:', source)
        self.assertIn('COPY models/ models/', source)
        self.assertIn('COPY scripts/ scripts/', source)
        self.assertIn('/venv/main/bin/python', source)

    def test_every_comfy_setup_has_runtime_config(self):
        models = {setup.parent.name for setup in (ROOT / 'models').glob('*/setup.sh')}
        for model in models - {'lightwan2.2-a14b'}:
            self.assertTrue((ROOT / 'models' / model / 'runtime.json').is_file(), model)


if __name__ == '__main__':
    unittest.main()
