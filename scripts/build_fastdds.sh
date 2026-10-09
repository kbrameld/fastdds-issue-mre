#!/bin/bash
# Builds Fast DDS from source (optionally patched) plus rmw_fastrtps against it, into PREFIX.
#
#   build_fastdds.sh PREFIX [PATCH_FILE ...]
#
# Why rmw_fastrtps is rebuilt: the packaged librmw_fastrtps_* binaries are not ABI-compatible with a Fast DDS built
# from source (different compile flags change inline code and struct layouts), so they must be compiled against it.
#
# Result: PREFIX/env.sh, which puts the custom libfastdds and the rebuilt rmw on top of /opt/ros/lyrical.
# Versions match the ROS Lyrical packages (ros-lyrical-fastdds 3.6.2, ros-lyrical-rmw-fastrtps-cpp 9.4.10).
#
# Optional environment: WORK (scratch dir), FASTDDS_TAG, RMW_TAG, JOBS, EXTRA_CMAKE_ARGS.
set -euo pipefail
PREFIX=$(readlink -m "$1"); shift
PATCHES=("$@")
WORK=${WORK:-/tmp/fastdds-build}
FASTDDS_TAG=${FASTDDS_TAG:-v3.6.2}
RMW_TAG=${RMW_TAG:-9.4.10}
JOBS=${JOBS:-$(nproc)}
HERE=$(dirname "$(readlink -f "$0")")
set +u; source /opt/ros/lyrical/setup.bash; set -u

mkdir -p "$WORK" "$PREFIX"
rm -rf "$WORK/Fast-DDS" "$WORK/rmw_fastrtps"
git clone --quiet --depth 1 --branch "$FASTDDS_TAG" https://github.com/eProsima/Fast-DDS.git "$WORK/Fast-DDS"
for patch in "${PATCHES[@]}"; do
  echo "applying $patch"
  git -C "$WORK/Fast-DDS" apply "$(readlink -f "$patch")"
done

cmake -S "$WORK/Fast-DDS" -B "$WORK/fastdds-build" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$PREFIX/fastdds" -DCMAKE_PREFIX_PATH=/opt/ros/lyrical \
  -DBUILD_TESTING=OFF -DCOMPILE_EXAMPLES=OFF -DCOMPILE_TOOLS=OFF -DSECURITY=OFF -DTHIRDPARTY=OFF ${EXTRA_CMAKE_ARGS:-} > "$WORK/cmake.log"
cmake --build "$WORK/fastdds-build" -j"$JOBS" > "$WORK/fastdds-build.log"
cmake --install "$WORK/fastdds-build" > /dev/null

git clone --quiet --depth 1 --branch "$RMW_TAG" https://github.com/ros2/rmw_fastrtps.git "$WORK/rmw_fastrtps"
(
  cd "$WORK"
  CMAKE_PREFIX_PATH="$PREFIX/fastdds:${CMAKE_PREFIX_PATH:-}" colcon build \
    --base-paths rmw_fastrtps --packages-select rmw_fastrtps_shared_cpp rmw_fastrtps_cpp \
    --build-base "$WORK/rmw-build" --install-base "$PREFIX/rmw" \
    --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=OFF -Dfastdds_DIR="$PREFIX/fastdds/share/fastdds/cmake" \
    > "$WORK/rmw-build.log"
)

cat > "$PREFIX/env.sh" <<ENV
source /opt/ros/lyrical/setup.bash
source "$PREFIX/rmw/local_setup.bash"
export LD_LIBRARY_PATH="$PREFIX/fastdds/lib:\${LD_LIBRARY_PATH:-}"
ENV
echo "built Fast DDS $FASTDDS_TAG ${PATCHES[*]:-(unpatched)} + rmw_fastrtps $RMW_TAG -> $PREFIX/env.sh"
