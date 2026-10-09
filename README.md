# Fast DDS TypeLookup reproducer

When a participant has to resolve many types from another participant at the same time, Fast DDS 3.6.x can silently
drop some of the TypeLookup replies and never retries. The endpoints that use those types are then **never
discovered**. This repository reproduces that, shows the fix, and shows what Fast DDS drops.

The write-up of the bug (written for the Fast DDS maintainers) is in [ISSUE.md](ISSUE.md).

## Run it

You need Docker with the `docker compose` plugin. No ROS installation is needed.

```bash
git clone https://github.com/kbrameld/fastdds-issue-mre
cd fastdds-issue-mre

docker compose run --rm bug           # the problem
docker compose run --rm fix           # the fix
```

| command | what it runs | what you should see |
|---|---|---|
| `docker compose run --rm bug` | Fast DDS exactly as shipped with ROS 2 Lyrical (3.6.2) | `RESULT: BUG REPRODUCED`: clients are stuck seeing only some of the 300 topics |
| `docker compose run --rm fix` | Fast DDS v3.6.2 built from source with a one-line patch | `RESULT: OK`: every client sees all 300 topics |
| `docker compose run --rm diagnose` | Fast DDS v3.6.2 built from source with logging added | the bug again, plus a count of the TypeLookup messages Fast DDS dropped silently |
| `docker compose run --rm workaround` | the unmodified libraries with one setting changed | `RESULT: OK` |

`bug` and `workaround` start immediately after a quick image build. `fix` and `diagnose` compile Fast DDS the first time
(about 10 minutes, cached afterwards). Each command exits with status 1 if clients got stuck and 0 otherwise.

### What the demo does

One participant (the "server") publishes 300 topics, **each with a different message type**. Six participants (the
"clients") with no endpoints of their own then try to discover all of them. To know about an endpoint a client has to
resolve its type, so each client asks the server for 300 types: 6 x 300 = 1800 replies in one burst. The server answers
through one reply history that holds at most 1000 samples (`TypeLookupManager.cpp:556`). Whatever does not fit is
dropped, the client never asks again, and the topics of those types stay invisible.

Example output of `bug`:

```
=== Fast DDS TypeLookup reproducer ===
library under test : /opt/ros/lyrical/lib/libfastdds.so.3.6.2.0
workload           : 1 server with 300 topics (each a different message type) + 6 clients, 3 iterations, up to 20s per iteration

iteration 1: 6/6 clients are missing topics after 20s   (topics seen per client: 13 13 57 13 13 13  of 300)
iteration 2: 6/6 clients are missing topics after 20s   (topics seen per client: 13 13 191 47 13 13  of 300)
iteration 3: 6/6 clients are missing topics after 20s   (topics seen per client: 295 186 73 146 117 122  of 300)

=== RESULT: BUG REPRODUCED - in 3 of 3 iterations clients were still missing topics after 20s (they do not recover ...) ===
```

Example output of `diagnose` (the bug plus the messages that are dropped without any log output in stock Fast DDS):

```
TypeLookup messages Fast DDS failed to send (silently, without this patch): 2930
    e.g. [fastdds-mre] TypeLookup message NOT SENT: add_change() failed (writer history holds 1000 samples)
    e.g. [fastdds-mre] TypeLookup message NOT SENT: create_change() returned null (writer history holds 1000 samples)
```

Which clients get stuck, and on how many topics, varies from run to run. The number of stuck clients is almost never
zero with these settings.

### Change the workload

Everything is an environment variable, for example:

```bash
docker compose run --rm -e CLIENTS=10 -e TYPES=150 bug     # 1500 replies: still stuck
docker compose run --rm -e CLIENTS=2  bug                  # 600 replies: fine, nothing is dropped
docker compose run --rm -e WAIT=90 bug                     # wait 90 s instead of 20 s: still stuck
```

| variable | default | meaning |
|---|---|---|
| `TYPES` | 300 | topics (and different message types) published by the server, at most what the image has installed |
| `CLIENTS` | 6 | participants that have to discover them |
| `ITERATIONS` | 3 | repetitions |
| `WAIT` | 20 | seconds a client may take |

The bug appears once `CLIENTS x TYPES` is above roughly 1000, which is the size of the reply history.

## What the fix and the workaround are

* **`fix`** applies [`patches/typelookup-history-cap.patch`](patches/typelookup-history-cap.patch) to Fast DDS v3.6.2: it
  raises `hatt.maximumReservedCaches` from 1000 to 100000. This is a demonstration of the cause, not a proper fix; a
  real fix would make the requester retry or time out and stop the reply writer from dropping silently (see
  [ISSUE.md](ISSUE.md)).
* **`workaround`** keeps the stock libraries and points `FASTDDS_DEFAULT_PROFILES_FILE` at
  [`profiles/no_type_propagation.xml`](profiles/no_type_propagation.xml), which sets the participant property
  `fastdds.type_propagation=disabled`. Endpoints are then announced without type information, so TypeLookup is never
  used. ROS 2 does not need it, so this is what we use in our own tests.
* **`diagnose`** applies [`patches/log-failed-sends.patch`](patches/log-failed-sends.patch), which only adds a message to
  stderr when a TypeLookup message cannot be sent.

The custom images build Fast DDS v3.6.2 **and** `rmw_fastrtps` 9.4.10 (the version that goes with ROS Lyrical's Fast DDS),
because the packaged `rmw_fastrtps` binaries do not work with a Fast DDS built from source (the inline code and struct
layouts differ with the compile flags).

## Without Docker

On any machine with ROS 2 Lyrical (`ros-lyrical-ros-base` and `ros-lyrical-common-interfaces`):

```bash
mre/entrypoint.sh                                                                   # the problem
FASTDDS_DEFAULT_PROFILES_FILE=$PWD/profiles/no_type_propagation.xml mre/entrypoint.sh   # the workaround
```

To build the patched variants yourself (needs `git`, `cmake`, a compiler, `colcon`, `libasio-dev`, `libtinyxml2-dev`,
`libssl-dev`, `ros-lyrical-fastcdr`, `ros-lyrical-foonathan-memory-vendor`):

```bash
scripts/build_fastdds.sh /opt/fastdds-fix patches/typelookup-history-cap.patch
MRE_ENV_FILE=/opt/fastdds-fix/env.sh mre/entrypoint.sh
```

## Files

| path | purpose |
|---|---|
| `ISSUE.md` | the bug report |
| `Dockerfile`, `docker-compose.yml` | the four demos |
| `mre/tl_mre.py`, `mre/run.sh`, `mre/entrypoint.sh` | the reproducer: server and client participants, and the driver that prints the verdict |
| `scripts/build_fastdds.sh` | builds Fast DDS (optionally patched) and `rmw_fastrtps` against it |
| `patches/` | the one-line fix and the logging patch, both against Fast DDS v3.6.2 |
| `profiles/no_type_propagation.xml` | the workaround |

## Notes

* Tested with Fast DDS 3.6.2 / `rmw_fastrtps_cpp` 9.4.10 on Ubuntu 26.04 and ROS 2 Lyrical. The `bug` and `workaround`
  demos use whatever Fast DDS version the `ros:lyrical-ros-base` image currently ships; if that is no longer 3.6.2 the
  behaviour may differ.
* `ROS_DOMAIN_ID` must be 232 or lower (default here: 100).
* The reproducer uses ROS 2 only to create participants with many different types cheaply. The failing code is inside
  Fast DDS.
