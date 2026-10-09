# TypeLookup replies are silently dropped when the built-in reply writer history (1000 samples) fills, and requesters never retry: endpoints are never discovered

## Is there an already existing issue for this?

I searched for TypeLookup/"Error sending reply" issues and found none; the search was not exhaustive (I could only use a web
search, not the GitHub issue search).

## Description

When many participants start at the same time and each has to resolve many types from one remote participant, the
TypeLookup *reply* writer of that participant runs out of room. `TypeLookupManager::send_impl()` then fails and the reply
is dropped. The requester sent exactly one request per type and has no timeout or retry, so it waits forever and every
remote endpoint that uses that type stays undiscovered: it never appears in the graph and never matches.

The failure is completely silent with default settings. I captured stdout and stderr of the affected participant while
thousands of replies were dropped, and both were empty. The EDP stream looks perfectly healthy throughout (every
announcement is received and acknowledged), which makes this very hard to diagnose from the outside.

We hit this in a ROS 2 system where a launch file starts about a dozen nodes: `wait_for_service` on one node's services
hung in roughly 1 of 10 runs, because the client had discovered only part of the server's endpoints (for example 20 of 68
services), and it never recovered.

## Expected behavior

Every endpoint is eventually discovered. If a TypeLookup exchange cannot complete, the requester should retry, or give up
after a timeout and register the endpoint without type information, instead of leaving it parked forever.

## Current behavior

Some endpoints are never discovered. The participant that dropped the replies is healthy and answers any later,
unrelated participant correctly (a freshly started participant sees everything).

## Steps to reproduce

Minimal reproducer (Docker, needs nothing else): <https://github.com/kbrameld/fastdds-issue-mre>

```bash
git clone https://github.com/kbrameld/fastdds-issue-mre && cd fastdds-issue-mre
docker compose run --rm bug         # Fast DDS as shipped with ROS 2 Lyrical: clients get stuck
docker compose run --rm diagnose    # same Fast DDS v3.6.2 source with a logging-only patch: shows the dropped messages
docker compose run --rm fix         # v3.6.2 + one-line patch: no stuck clients
docker compose run --rm workaround  # unmodified libraries, type propagation disabled: no stuck clients
```

The workload is one participant with 300 publishers, each with a *different* message type, and 6 participants with no
endpoints of their own that wait until they see all 300 topics. Output of `bug` on the stock libraries:

```
iteration 2: 6/6 clients are missing topics after 20s   (topics seen per client: 13 13 191 47 13 13  of 300)
=== RESULT: BUG REPRODUCED - in 3 of 3 iterations clients were still missing topics after 20s ...
```

Clients that are still missing topics after 20 s were also missing them after 90 s.

Output of `diagnose` (Fast DDS v3.6.2, only logging added to `send_impl`):

```
TypeLookup messages Fast DDS failed to send (silently, without this patch): 2930
    e.g. [fastdds-mre] TypeLookup message NOT SENT: add_change() failed (writer history holds 1000 samples)
    e.g. [fastdds-mre] TypeLookup message NOT SENT: create_change() returned null (writer history holds 1000 samples)
```

## Analysis

Code references are for `v3.6.2` (the same constant is present on `3.6.x` and `master`).

1. `src/cpp/fastdds/builtin/type_lookup_service/TypeLookupManager.cpp:554-557`, in `create_endpoints()`:
   ```cpp
   HistoryAttributes hatt;
   hatt.initialReservedCaches = 20;
   hatt.maximumReservedCaches = 1000;
   ```
   The same `hatt` is used for the request writer, request reader, reply writer and reply reader histories (lines
   573, 594, 616, 637). It has not changed since the original X-Types implementation (#4640).
2. A participant answers every request through its single reply writer (volatile, reliable, asynchronous). A reply stays
   in that history until every matched reader has acknowledged it. Requests and, as far as I can tell from
   `TypeLookupManager::receive(TypeLookup_Reply&)`, replies are delivered to all participants, and each reader discards the
   ones that are not addressed to it, so the number of outstanding replies is roughly `participants x distinct types`.
3. `send_impl()` (line 734) returns `false` when `create_change()` (line 745) returns null or `add_change()` (line 759)
   fails. `send(TypeLookup_Reply&)` (line 722) only emits `EPROSIMA_LOG_WARNING("Error sending reply.")`, which is not
   visible with default logging, and returns `false`, and the request listener has nowhere to report it.
4. The requester side, `check_type_identifier_received()` (line 368): if the type is unknown it sends **one**
   `getTypeDependencies` request, stores the proxy data in `async_get_type_callbacks` keyed by type id, and returns
   `RETCODE_NO_DATA`. Further endpoints with the same type just join that list without sending anything
   (line 394). The stored callback only runs from `notify_callbacks()` (line 429), which is only called when a reply
   arrives. There is no timeout and no retry.
5. `EDPBasePUBListener::add_writer_from_change()` and the reader counterpart
   (`src/cpp/rtps/builtin/discovery/endpoint/EDPSimpleListeners.cpp:133` and `:279`) remove the received EDP change
   from the history *before* calling `async_get_type()`, so from the EDP protocol's point of view the announcement is
   already acknowledged, and nothing is left that could trigger a retry.

Evidence that the cap is the trigger:

* The stall only appears when `clients x types` exceeds about 1000 (3 iterations per row, stock libraries):

  | types | clients | clients x types | iterations with stuck clients |
  |---|---|---|---|
  | 50 | 10 | 500 | 0/3 |
  | 100 | 4 | 400 | 0/3 |
  | 150 | 4 | 600 | 0/3 |
  | 300 | 2 | 600 | 0/3 |
  | 100 | 10 | 1000 | 2/3 |
  | 150 | 10 | 1500 | 3/3 |
  | 300 | 4 | 1200 | 3/3 |
  | 300 | 6 | 1800 | 3/3 |

  (measured with an earlier version of the reproducer script, same workload)
* Fast DDS v3.6.2 built from source and unmodified: 30 of 30 clients stuck (10 clients x 300 types, 3 iterations). The
  same build with only `hatt.maximumReservedCaches = 100000` (`patches/typelookup-history-cap.patch`, the `fix` service):
  0 of 30.
* In the real application (a dozen ROS 2 nodes), instrumenting `send(TypeLookup_Reply&)`: 12,495 of 542,112 replies
  failed to send with the cap at 1000, and 0 of 676,973 with the cap at 100000. Runs that stalled had 138-530 type
  requests unanswered for more than 5 s, all addressed to the participant that was dropping replies (healthy runs: 0-5);
  that participant had received essentially all of them, and in the one live dump I took its request-processing thread
  was idle. The stall rate dropped from roughly 5-18% of runs to 1 in 150.
* The `3.6.x` branch at `67778b925` (which includes #6542) shows the same stall rate in the application, so it is not
  fixed there.

## Suggested direction

A larger constant only moves the threshold, so I do not think it is the right fix on its own (the patch in the
reproducer is a demonstration). In order of how much they would help:

1. Requester side: retry the TypeLookup request after a timeout, and after a few attempts invoke the stored callbacks
   with an error status so that the endpoint is registered without type information. `after_typelookup_callback`
   already handles a non-`RETCODE_OK` status by clearing `type_information`, so the code path exists.
2. Reply side: do not drop replies silently. Options: let the builtin TypeLookup histories grow, or remove a reply once
   the participant it is addressed to has acknowledged it (instead of waiting for all readers), or deliver replies only
   to the requesting participant.
3. Log the failed send at error level and include the history size.

## Workaround

Disable type propagation for the participants, for example through an XML profile selected with
`FASTDDS_DEFAULT_PROFILES_FILE` (`profiles/no_type_propagation.xml` in the reproducer repo):

```xml
<participant profile_name="no_type_propagation" is_default_profile="true">
  <rtps><propertiesPolicy><properties>
    <property><name>fastdds.type_propagation</name><value>disabled</value></property>
  </properties></propertiesPolicy></rtps>
</participant>
```

With this, endpoints are announced without type information and TypeLookup is never used. Over 150 runs of our system
tests this took the stall rate from 13 stalled runs (3 failed outright) to 1 (recovered).

## Fast DDS version

3.6.2 (`ros-lyrical-fastdds 3.6.2-1resolute`, and `v3.6.2` built from source). Also seen with the `3.6.x` branch at
`67778b925` in the application. Not tested on `master` (the constant is the same).

## Platform / architecture

Ubuntu 26.04, x86_64, ROS 2 Lyrical, `rmw_fastrtps_cpp 9.4.10`.

## Transport layer

Default (UDPv4 and SHM). Also seen with `FASTDDS_BUILTIN_TRANSPORTS=UDPv4`.

## Additional context

* The reproducer uses ROS 2 (`rclpy` / `rmw_fastrtps_cpp`) to create participants with many distinct types cheaply. I do
  not have a ROS-free reproducer yet. The failing code is entirely inside `libfastdds`, and changing one constant
  inside `libfastdds` removes the failure, so I believe it is independent of the rmw, but I have not shown that.
* The reproducer repository also contains the diagnostic patch (`patches/log-failed-sends.patch`) used for the
  `diagnose` output above.
