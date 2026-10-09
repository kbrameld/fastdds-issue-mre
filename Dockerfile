# Fast DDS TypeLookup reproducer. Two kinds of image:
#   stock   - the Fast DDS that ships with ROS 2 Lyrical, unmodified            (targets "bug" and "workaround")
#   custom  - Fast DDS v3.6.2 built from source with a patch applied, plus      (targets "fix" and "diagnose")
#             rmw_fastrtps rebuilt against it
ARG ROS_IMAGE=ros:lyrical-ros-base

FROM ${ROS_IMAGE} AS stock
RUN apt-get update \
 && apt-get install -y --no-install-recommends ros-lyrical-common-interfaces \
 && rm -rf /var/lib/apt/lists/*
COPY mre/ /mre/
COPY profiles/ /mre/profiles/
ENTRYPOINT ["/mre/entrypoint.sh"]

FROM stock AS builder
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake git ca-certificates python3-colcon-common-extensions \
        libasio-dev libtinyxml2-dev libssl-dev ros-lyrical-fastcdr ros-lyrical-foonathan-memory-vendor \
 && rm -rf /var/lib/apt/lists/*
COPY scripts/ /build/scripts/
COPY patches/ /build/patches/
ARG PATCHES=""
RUN cd /build && scripts/build_fastdds.sh /opt/fastdds-custom ${PATCHES}

FROM stock AS custom
COPY --from=builder /opt/fastdds-custom /opt/fastdds-custom
ENV MRE_ENV_FILE=/opt/fastdds-custom/env.sh
