# entropy_control

Understanding and controlling policy entropy in RL training of language models

## Layout

```
src/entropy_control/     # the package (installed editable)
experiments/
  MM_DD_<name>/
    run.py          # the experiment definition — synced, versioned
    notes.md        # optional context — synced, versioned
    job.sbatch      # optional slurm submission — synced, versioned
    out/            # everything the run PRODUCES — remote-only, git-ignored
      sync_meta.txt     # copy of .sync_meta: git commit the run came from
      metrics.jsonl     # appended incrementally
      slurm/            # slurm job logs
tests/
sync.sh             # ./sync.sh (sc) | ./sync.sh marlowe (sc, then marlowe)
```

All execution happens on the cluster; see `CLAUDE.md` for the workflow.

## Experiment contract

- **Code in the experiment dir, products in `out/`.** `out/` is excluded from
  git and `sync.sh` (so it is protected from `rsync --delete`). Anything a run
  writes outside `out/` will be clobbered by the next sync.
- Start every `run.py` with `out = entropy_control.provenance.init_out_dir(__file__)`.
- To inspect results locally, rsync the experiment's `out/` down; it never syncs up.
