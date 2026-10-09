#!/usr/bin/env python3
"""Fast DDS TypeLookup reproducer (ROS 2 / rmw_fastrtps_cpp).

  tl_mre.py info                      print which libfastdds is loaded
  tl_mre.py server N READY_FILE       one participant with N publishers, each with a *different* message type
  tl_mre.py client N SECONDS          a participant with no endpoints of its own; waits until all N server topics are
                                      in its graph (or SECONDS elapse) and prints "RESULT seen=<k>/<N> ..."
"""
import importlib
import os
import re
import sys
import time

import rclpy
from rosidl_runtime_py import get_message_interfaces


def message_types(n):
    """The first n importable ROS message types, in a fixed (alphabetical) order."""
    types = []
    for package, names in sorted(get_message_interfaces().items()):
        for name in sorted(names):
            if not name.startswith("msg/"):
                continue
            try:
                types.append(getattr(importlib.import_module(f"{package}.msg"), name.split("/")[1]))
            except Exception:
                continue
            if len(types) == n:
                return types
    sys.exit(f"only {len(types)} message types are installed, {n} requested (install ros-lyrical-common-interfaces)")


def loaded_fastdds():
    with open("/proc/self/maps") as maps:
        paths = {line.split()[-1] for line in maps if "libfastdds.so" in line}
    return ", ".join(sorted(paths)) or "unknown"


def main():
    mode = sys.argv[1]
    rclpy.init()
    if mode == "info":
        rclpy.create_node("info")
        print(loaded_fastdds())
    elif mode == "server":
        count, ready_file = int(sys.argv[2]), sys.argv[3]
        node = rclpy.create_node("tl_server")
        publishers = [node.create_publisher(t, f"/tl_topic_{i}", 1) for i, t in enumerate(message_types(count))]
        open(ready_file, "w").write(f"{len(publishers)}\n")
        try:
            rclpy.spin(node)
        except KeyboardInterrupt:
            pass
    elif mode == "client":
        count, seconds = int(sys.argv[2]), float(sys.argv[3])
        node = rclpy.create_node(f"tl_client_{os.getpid()}")
        start, seen = time.time(), 0
        while time.time() - start < seconds and seen < count:
            seen = len({n for n, _ in node.get_topic_names_and_types() if re.fullmatch(r"/tl_topic_\d+", n)})
            time.sleep(0.2)
        print(f"RESULT seen={seen}/{count} seconds={time.time() - start:.1f}", flush=True)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
