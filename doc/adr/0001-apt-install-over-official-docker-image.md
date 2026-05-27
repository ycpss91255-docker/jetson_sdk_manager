# Install SDK Manager via apt instead of official Docker image

SDK Manager is installed from NVIDIA's public CUDA apt repository (`apt-get install sdkmanager`) rather than using NVIDIA's official pre-built Docker image (`.tar.gz` from developer.nvidia.com). The official image requires manual download from NVIDIA Developer website (no container registry available), making fully automated `docker build` impossible. The apt repository carries the same version (verified: both at 2.4.0-13236) and requires no authentication, enabling zero-manual-step builds. Trade-off: we lose NVIDIA's pre-configured entrypoint and dependency set, but gain full control over the base image (important for Ubuntu version matrix and base template integration).

## Considered Options

- **Official Docker image** (`docker load -i sdkmanager-*_docker.tar.gz`): guaranteed working dependency set, but requires manual download from developer.nvidia.com (302 redirect to login page for direct URLs). Cannot be pulled from any container registry.
- **`.deb` direct download**: same authentication wall as the Docker image.
- **apt repository** (chosen): public CUDA keyring, no auth required, same package version, fully automatable.
