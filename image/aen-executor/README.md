# Immutable AEN executor image overlay

`build-aen-executor-image.sh` accepts only a base image reference pinned by a
full SHA-256 digest. The base must be an AEN-compatible Linux executor image
that supplies envd, cgroup v2, and overlayfs; MoonFort does not silently choose
or download a mutable base.

The tool lock is tab-separated with four fields:

```text
label<TAB>host source<TAB>/opt/moonfort/tools/image-path<TAB>sha256
```

Packaging verifies every digest without executing inputs, installs only the
two fixed helpers and locked tools, and emits the non-circular digests to copy
into the protected executor configuration. After publishing, configure AEN
with the registry-returned `image@sha256:...` manifest reference; a mutable tag
is never an accepted deployment identity.
