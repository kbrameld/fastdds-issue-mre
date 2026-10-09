#!/bin/bash
# Container entrypoint: load ROS (and the custom Fast DDS build if this image has one), then run the reproducer.
source /opt/ros/lyrical/setup.bash
[ -n "${MRE_ENV_FILE:-}" ] && source "$MRE_ENV_FILE"
exec "$(dirname "$(readlink -f "$0")")/run.sh" "$@"
