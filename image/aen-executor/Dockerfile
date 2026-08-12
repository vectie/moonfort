# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG EXECUTOR_ROOT_DIGEST
ARG GUEST_ATTESTER_DIGEST
ARG GUEST_SUPERVISOR_DIGEST
ARG TOOL_REGISTRY_DIGEST

USER 0
COPY --chown=0:0 _build/aen-guest/rootfs/ /
LABEL org.moonfort.executor-root.digest="${EXECUTOR_ROOT_DIGEST}" \
      org.moonfort.guest-attester.digest="${GUEST_ATTESTER_DIGEST}" \
      org.moonfort.guest-supervisor.digest="${GUEST_SUPERVISOR_DIGEST}" \
      org.moonfort.tool-registry.digest="${TOOL_REGISTRY_DIGEST}" \
      org.opencontainers.image.source="https://github.com/vectie/moonfort"
