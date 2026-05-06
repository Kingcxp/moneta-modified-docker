# Docker wrap for moneta-modified

## Introduction

This is a docker wrap for moneta-modified, which is a modified version of moneta, a tool for fuzzing GPU kernel drivers(especially NVIDIA driver) with syzkaller

**Tested only on Ubuntu 22.04!**

## Installation

1. Install docker

See install steps in [Docker official website](https://docs.docker.com/engine/install/ubuntu/)

2. Clone this repository

```bash
git clone --recurse-submodules https://github.com/Kingcxp/moneta-modified-docker.git
cd moneta-modified-docker/
```

3. Run the automation script

```bash
chmod +x scripts/*.sh
./scripts/docker_run_vm.sh
```

This will automatically detects available nvidia GPU on your machine and download the latest compatible NVIDIA driver to run the `moneta-modified` project.

If you need to manually manage the NVIDIA driver version and the selected GPU, you can refer to `.env.example` and create a `.env` file with your own settings.

## Run project and see the results

Just wait for the docker container to be ready and automatically runs itself without any manual intervention.
