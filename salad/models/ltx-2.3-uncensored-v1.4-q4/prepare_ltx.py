"""Use the shared LTX downloader without exposing incomplete final model files."""
import sys
from pathlib import Path
sys.path.insert(0, '/opt/profile')
import download_models

def prepare(root, repo, revision, pairs):
    files = [(remote, Path(root) / local) for remote, local in pairs]
    sizes = download_models.model_sizes(repo, revision, files)
    pending = []
    pending_sizes = []
    for (remote, final), size in zip(files, sizes):
        if final.is_file() and final.stat().st_size == size:
            continue
        pending.append((remote, final.with_name(final.name + '.part')))
        pending_sizes.append(size)
    if pending:
        base = f'https://huggingface.co/{repo}/resolve/{download_models.urllib.parse.quote(revision, safe="")}'
        download_models.download(pending, pending_sizes, base, 0)
        for (_, partial), size in zip(pending, pending_sizes):
            if partial.stat().st_size != size:
                raise RuntimeError('LTX model size mismatch')
            partial.replace(partial.with_name(partial.name.removesuffix('.part')))

if __name__ == '__main__':
    try:
        prepare(*sys.argv[1:4], list(zip(sys.argv[4::2], sys.argv[5::2])))
    except Exception:
        print('ERROR: LTX model preparation failed.', file=sys.stderr)
        raise SystemExit(1)
