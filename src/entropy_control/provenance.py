"""Run provenance: every experiment's out/ records the code that produced it."""

import shutil
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def init_out_dir(run_script: str) -> Path:
    """Create `<experiment>/out/` next to `run_script` and copy `.sync_meta` into it.

    Call as `out = init_out_dir(__file__)` at the top of an experiment's run.py.
    The remote copy has no .git, so `.sync_meta` (written by sync.sh) is the
    only record of which commit a run came from.
    """
    out = Path(run_script).resolve().parent / "out"
    out.mkdir(parents=True, exist_ok=True)
    meta = PROJECT_ROOT / ".sync_meta"
    if meta.exists():
        shutil.copy(meta, out / "sync_meta.txt")
    return out
