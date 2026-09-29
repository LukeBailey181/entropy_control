# Cluster workflow

Code in this repo is developed locally, but **all execution happens on a compute
cluster** — never run project code, tests, or jobs on the local machine. The
local repo is the source of truth; each cluster holds a synced copy.

There are **two clusters**, and every remote command must be aimed at one of them:

| | **sc** (Stanford NLP) | **marlowe** |
|---|---|---|
| default? | yes | no — opt in |
| sync | `./sync.sh` | `./sync.sh marlowe` |
| project dir | `/nlp/scr/ljbailey/projects/<repo>` | `/scratch/m000123-pm06/ljbailey/projects/<repo>` |
| reach it | `ssh john10 '…'` | `ssh john10 "ssh marlowe-login '…'"` (double hop) |
| gotcha | `getjohn` allocations expire | needs Duo unless the ControlMaster is alive |

Sections below describe sc unless they say marlowe.

## Machines

- **Login node** — ssh alias `stanford-sc` (sc.stanford.edu). Light use only:
  slurm queries, quick file checks. Don't run real work here.
- **Data-transfer node** — ssh alias `stanford-scdt`. Same cluster, meant for
  data movement: all rsync/scp traffic (including `sync.sh`) goes through it.
- **Persistent CPU machine** — a `johnN` machine obtained by running `getjohn`
  on the login node. This is the workhorse for everything that isn't a slurm
  job: environment setup, data prep, launching/monitoring jobs. The current
  machine is named in "This Project" below; if it changes, ssh aliases
  `john1`–`john17` exist in the local ssh config.
- **Slurm compute nodes** — GPU/CPU nodes reached only via `sbatch`/`srun`.

## Running commands remotely

Run everything through non-interactive ssh from the local machine:

```sh
ssh john10 'bash -lc "cd /nlp/scr/ljbailey/projects/entropy_control && <command>"'
```

- `bash -lc` matters: without a login shell, conda/uv and PATH setup from the
  remote profile are not loaded.
- Before running anything remote, sync first: `./sync.sh` (rsync, one-way
  local → cluster, `--delete`). `./sync.sh marlowe` also pushes onward to the
  second cluster (stage 1 laptop → sc, stage 2 sc → marlowe run from the john
  machine so the Duo-free ControlMaster is used — see the Marlowe section).
  **Never edit files in the remote copy** — the next sync clobbers them. Job
  outputs must go to directories excluded in `sync.sh` (`experiments/*/out/`,
  `outputs/`, `results/`, `data/`, `checkpoints/`, `wandb/`, `slurm_logs/`)
  or outside the synced dir entirely.
- To get results back, `rsync`/`scp` them down or inspect them remotely.

## Storage

`sync.sh` mirrors this repo to `/nlp/scr/ljbailey/projects/<repo-name>` on
the cluster (same directory name as the local repo). That filesystem has
plenty of space, so datasets, checkpoints, and other large artifacts can be
stored there too — just keep them in directories excluded from the sync so
`--delete` never touches them.

Avoid the AFS home directory (`/afs/cs.stanford.edu/u/ljbailey`) — it is slow
and quota-limited. Tooling on the cluster: `uv` and conda (miniconda at
`/nlp/scr/ljbailey/miniconda3`) are both installed.

## Experiments

One subdirectory per experiment under `experiments/`, named with an `MM_DD_`
start-date prefix so they list in chronological order (e.g.
`experiments/07_15_baseline/`): the run script (and any notes/config) is
synced and versioned; everything the run produces goes in that experiment's
`out/` subdirectory, which is git-ignored, sync-excluded, and therefore
protected from `rsync --delete` — it exists only on the remote. Never write run
products anywhere else inside the synced tree.

- Run experiments on the john machine from the remote project root. For
  anything long-running, launch detached with `setsid nohup`:

  ```sh
  ssh john10 "setsid nohup bash -lc 'cd <remote project dir> && .venv/bin/python experiments/<name>/run.py' > <remote project dir>/experiments/<name>/out/run.log 2>&1 < /dev/null &"
  ```

  When an ssh connection closes, sshd SIGHUPs the session it created —
  a plain backgrounded process (even with `&` or `disown`) dies with it.
  `setsid` puts the process in its own session so it survives; `nohup`
  ignores any stray SIGHUP. The log must live somewhere sync-excluded
  (the experiment's `out/`), or a later `./sync.sh` will remove it mid-run.
- Point slurm job logs at the experiment (`out/slurm/`), not a global dir.
- `sync.sh` stamps `.sync_meta` (git commit, dirty flag, sync time) into the
  project root; run scripts should call `entropy_control.provenance.init_out_dir(__file__)`,
  which creates `out/` and copies `.sync_meta` into it — the remote copy has no `.git`.
- Dump rollouts/metrics incrementally (append JSONL as steps complete), so a
  crashed, preempted, or timed-out run keeps everything finished so far.
- Fetch results by rsyncing an experiment's `out/` down; it never syncs up.

## Slurm

Submit and monitor from the john machine (or login node):

```sh
ssh john10 'cd /nlp/scr/ljbailey/projects/entropy_control && sbatch experiments/<name>/job.sbatch'
ssh john10 'squeue -u ljbailey'
```

Write sbatch scripts into the repo, sync, then submit via ssh. Useful:
`squeue -u ljbailey`, `sacct -j <id>`, `scancel <id>`,
`sinfo -p <partition>`.

Partitions I have access to (GPU counts are per node):

| Partition | Time limit | Hardware |
|---|---|---|
| `sphinx`, `sphinx-lo`, `sphinx-hi` | 14 days | A100×8, H100×8, H200×8 |
| `jag-lo` … `jag-standard` … `jag-urgent` | 21 days | A6000×8, A6000Ada×8, 3090×8, A5000, TitanRTX |
| `tiger`, `tiger-lo`, `tiger-quick` | 21 days (quick: 4) | A100×8, A5000×10, TitanRTX×10 |
| `sc-loprio` | 21 days | Large mixed low-priority pool: H200×8, H100×8, A100×8, L40S×8, A6000×8, and older |
| `miso`, `miso-lo` | 14 days | H200×8 |
| `miso-interactive` | 30 min | H200×8 |
| `john`, `john-lo` | 21 days | CPU only (this is where getjohn machines come from) |

Request GPUs with `--gres=gpu:1` or a specific type, e.g.
`--gres=gpu:a100:1`, plus `-p <partition>`. `sc-loprio` is low-priority
(preemptible) but has the widest hardware selection; `miso`/`sphinx` are the
go-to for H200/H100/A100.

# Marlowe (second cluster)

Marlowe is a separate cluster, used when sc capacity is taken. **It requires Duo
2FA**, so it is reached only by hopping through the john machine, which holds a
long-lived authenticated ssh session.

## The Duo-free hop

```
laptop  ->  john10 (sc)  ->  marlowe-login
```

`~/.ssh/config` on the cluster (AFS home, so shared by every sc host) defines the
**`marlowe-login`** host — `login.marlowe.stanford.edu` — with `ControlMaster auto`
and `ControlPersist 12h`. If a marlowe ssh ever hangs with no output, a login node
may be down; test them directly:
`for h in login-01 login-02 login-03; do timeout 5 bash -c "</dev/tcp/$h.marlowe.stanford.edu/22" && echo "$h up"; done`

Once a master session exists, every later `ssh marlowe-login` **from that same
john machine** multiplexes over it and needs no push. From the laptop:

```sh
ssh john10 "ssh marlowe-login 'hostname'"
# heredoc form for anything non-trivial (quoting gets ugly across two hops):
ssh john10 bash -ls <<'EOF'
ssh marlowe-login bash -lc '"cd /scratch/m000123-pm06/ljbailey/projects/entropy_control && <cmd>"'
EOF
```

**Keeping the master alive.** A tmux session on the **sc login node** holds:
`ssh <johnN>` → inside it `ssh marlowe-login`. That inner session is the
ControlMaster. The socket is served by the process on that john machine, so the
hop only works from it (not from the login node, not from the laptop). Check it
with `ssh john10 "ssh -O check marlowe-login"` → `Master running (pid=…)`. It
dies when the john allocation ends AND after 12h idle, so expect to re-establish
it often: re-open the tmux chain and approve one Duo push. `./sync.sh marlowe`
preflights this and refuses early with instructions rather than hanging.

**Do NOT** try `rsync -e "ssh -J john10" marlowe-login:…` from the laptop. `-J`
only tunnels — the laptop still does its own handshake with marlowe and
triggers Duo.

## Storage and layout

**Everything lives on the pm06 scratch allocation:**
`/scratch/m000123-pm06/ljbailey/projects/<repo-name>` — the repo mirror (created
by `./sync.sh marlowe`), the `.venv`, and all `out/` directories. Same layout as
sc, just a different root.

Not `/projects/m000123` (full) and not `/users` (32GB cap; docs say no env
installs there). Not `/scratch/m000123` either — it is far over its inode quota,
so even `mkdir` fails with `Disk quota exceeded`.

Quotas are enforced by Lustre **project ID**, not user or group. Our tree is
project `851763151`: `lfs quota -p 851763151 /scratch` is the meter that binds.

**Scratch is NOT backed up.** Archive finished runs back to sc — rsync an
experiment's `out/` to `/nlp/scr/ljbailey/projects/entropy_control/experiments/<exp>/`.

## Slurm on marlowe

Slurm is **not on the default non-interactive PATH** — load it first:

```sh
module load slurm/slurm/25.05.2
```

| Partition | Time limit | Access |
|---|---|---|
| `batch` | 2 days | **yes — use this one** |
| `preempt` | 12 h | yes (preemptible) |
| `hero` | 30 days | **NO access** |

QOS available: `medium`, `normal` (account `marlowe-m000123`). The 2-day `batch`
limit means long runs need checkpoint-resume.

Hardware: 31 × DGX H100 — **8 × H100 80GB** per node, 112 cores, 2TB RAM. Same
Hopper/sm_90 as sc's miso H200s but less HBM, so memory knobs tuned on miso may
need lowering.

## Environment on marlowe

`uv` is at `~/.local/bin/uv` (not on PATH by default). No conda on PATH; the
module system provides `conda/24.3.0-0` and `cuda12.9/toolkit/12.9.1` (sets
`CUDA_HOME`). Point uv's cache at pm06 scratch:

```sh
export PATH=$HOME/.local/bin:$PATH
export UV_CACHE_DIR=/scratch/m000123-pm06/ljbailey/.cache/uv
```

# This Project

Understanding and controlling policy entropy in RL training of language models

- Remote copies: `/nlp/scr/ljbailey/projects/entropy_control` (sc) and
  `/scratch/m000123-pm06/ljbailey/projects/entropy_control` (marlowe). `sync.sh`
  derives both from the local directory name.
- Current CPU machine: `john10` (as of project creation — verify with `squeue -u ljbailey -p john` on the login node). Allocations expire —
  when ssh returns `Access denied by pam_slurm_adopt: you have no active jobs on
  this node`, the machine is gone; check `squeue -u ljbailey -p john` on the
  login node, get a fresh `getjohn` if needed, and update this line plus the
  `MARLOWE_HOP` default in `sync.sh`. The Marlowe ControlMaster dies with the
  john machine and must be re-established on the new one.
- **Never `scancel -u ljbailey`**: cancel explicit job IDs only (the getjohn
  machines are themselves slurm jobs on the `john` partition, and other projects
  share this account).
- **Process management only works ON the machine the process runs on.**
  `pgrep`/`pkill` from the login node cannot see processes on a john machine.
- Python environment: uv venv at `.venv/` inside each remote project dir
  (CPython 3.12), created with `uv venv --python 3.12` then
  `uv pip install -e ".[dev]"`. Run things with `.venv/bin/python` /
  `.venv/bin/pytest` from the project dir. The GPU stack is project-specific —
  when it is, record the pins and install steps here.
