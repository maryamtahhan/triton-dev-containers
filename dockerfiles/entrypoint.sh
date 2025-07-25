#! /bin/bash -e

trap "echo -e '\nScript interrupted. Exiting gracefully.'; exit 1" SIGINT

# Copyright (C) 2024-2025 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

USER=${USERNAME:-triton}
USER_ID=${USER_UID:-1000}
GROUP_ID=${USER_GID:-1000}
CUSTOM_LLVM=${CUSTOM_LLVM:-}
DEMO_TOOLS=${DEMO_TOOLS:-}
NOTEBOOK_PORT=${NOTEBOOK_PORT:-8888}
AMD=${AMD:-}
TRITON_CPU_BACKEND=${TRITON_CPU_BACKEND:-}
ROCM_VERSION=${ROCM_VERSION:-}
TORCH_VERSION=${TORCH_VERSION:-"2.5.1"}
HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-}
DISPLAY=${DISPLAY:-}
WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
CREATE_USER=${CREATE_USER:-false}
CLONED=0
CUDA_VERSION=12-8
CUDA_REPO=https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
INSTALL_NSIGHT=${INSTALL_NSIGHT:-false}
export_cmd=""

navigate() {
    if [ -n "$TRITON_CPU_BACKEND" ] && [ "$TRITON_CPU_BACKEND" -eq 1 ]; then
        if [ -d "/workspace/triton-cpu" ]; then
            export TRITON_DIR="/workspace/triton-cpu"
        fi
    else
        if [ -d "/workspace/triton" ]; then
            export TRITON_DIR="/workspace/triton"
        fi
    fi

    if [ -d "/workspace/user" ]; then
        export WORKSPACE="/workspace/user"
    else
        export WORKSPACE=$TRITON_DIR
    fi

    cd "$WORKSPACE" || exit 1
}

install_system_dependencies() {
    if [ "$INSTALL_NSIGHT" = "true" ]; then
        echo "################################################################"
        echo "################# INSTALLING NVIDIA NSIGHT... ##################"
        echo "################################################################"
        sudo dnf -y config-manager --add-repo ${CUDA_REPO}
        sudo dnf -y install cublasmp cuda-cupti-${CUDA_VERSION} \
            cuda-gdb-${CUDA_VERSION} cuda-nsight-${CUDA_VERSION} \
            cuda-nsight-compute-${CUDA_VERSION} cuda-nsight-systems-${CUDA_VERSION} \
            libxkbfile qt5-qtwayland xcb-util-cursor
        sudo dnf clean all

        # Create a symlink to the installed version of CUDA
        COMPUTE_VERSION=$(ls /opt/nvidia/nsight-compute)
        sudo alternatives --install /usr/local/bin/ncu ncu "/opt/nvidia/nsight-compute/${COMPUTE_VERSION}/ncu" 100
        sudo alternatives --install /usr/local/bin/ncu-ui ncu-ui "/opt/nvidia/nsight-compute/${COMPUTE_VERSION}/ncu-ui" 100
    fi
}

install_user_dependencies() {
    echo "#############################################################################"
    echo "################### Cloning the Triton repos (if needed)... #################"
    echo "#############################################################################"
    if [ -n "$TRITON_CPU_BACKEND" ] && [ "$TRITON_CPU_BACKEND" -eq 1 ]; then
        if [ ! -d "/workspace/triton-cpu" ]; then
            echo "/workspace/triton-cpu not found. Cloning repository..."
            git clone https://github.com/triton-lang/triton-cpu.git "/workspace/triton-cpu"

            if [ ! -d "/workspace/triton-cpu" ]; then
                echo "/workspace/triton-cpu not found. ERROR Cloning repository..."
                exit 1
            else
                CLONED=1
            fi
        fi
    else
        if [ ! -d "/workspace/triton" ]; then
            echo "/workspace/triton not found. Cloning repository..."
            git clone https://github.com/triton-lang/triton.git "/workspace/triton"
            if [ ! -d "/workspace/triton" ]; then
                echo "/workspace/triton not found. ERROR Cloning repository..."
                exit 1
            else
                CLONED=1
            fi
        fi
    fi

    echo "#############################################################################"
    echo "################################## Upgrade pip... ###########################"
    echo "#############################################################################"
    pip install --upgrade pip

    # Make sure to clone vllm before navigating
    if [ -n "$DEMO_TOOLS" ] && [ "$DEMO_TOOLS" = "true" ]; then
        echo "################################################################"
        echo "##################### ENABLE DEMO TOOLS ########################"
        echo "################################################################"
        pip install jupyter

        if [ "$INSTALL_NSIGHT" = "true" ]; then
            pip install jupyterlab-nvidia-nsight nvtx
        fi

        if [ ! -f "flash_attention.py" ]; then
            wget https://raw.githubusercontent.com/fulvius31/triton-cache-comparison/refs/heads/main/scripts/flash_attention.py
        fi

    JUPYTER_FUNCTION=$(cat << 'EOF'

start_jupyter() {
    original_dir=$(pwd)
    cd /workspace || return
    jupyter notebook --ip=0.0.0.0 --port=$NOTEBOOK_PORT --no-browser --allow-root
    cd "$original_dir" || return
}
EOF
    )

        if grep -q "start_jupyter()" ~/.bashrc; then
            echo "start_jupyter function already exists in ~/.bashrc"
        else
            echo "Adding start_jupyter function to ~/.bashrc"
            echo "$JUPYTER_FUNCTION" >> ~/.bashrc
            echo "start_jupyter added!"
        fi
    fi


    navigate

    if [ -n "$CLONED" ] && [ "$CLONED" -eq 1 ]; then
        git submodule init
        git submodule update
    fi

    if [ -n "$AMD" ] && [ "$AMD" = "true" ]; then
        echo "###########################################################################"
        echo "##################### Installing ROCm dependencies... #####################"
        echo "###########################################################################"
        TORCH_VERSION="2.5.1"
        pip install --no-cache-dir torch=="${TORCH_VERSION}" --index-url https://download.pytorch.org/whl/rocm"${ROCM_VERSION}"
    elif [ -n "$TRITON_CPU_BACKEND" ] && [ "$TRITON_CPU_BACKEND" -eq 1 ]; then
        echo "###########################################################################"
        echo "###################### Installing torch CPU ... ###########################"
        echo "###########################################################################"
        pip install --no-cache-dir torch=="${TORCH_VERSION}" --index-url https://download.pytorch.org/whl/cpu
    else
        echo "###########################################################################"
        echo "######################### Installing torch ... ############################"
        echo "###########################################################################"
        pip install torch=="${TORCH_VERSION}"
    fi

    echo "#############################################################################"
    echo "##################### Installing Triton dependencies... #####################"
    echo "#############################################################################"
    if [ -f "${TRITON_DIR}/python/requirements.txt" ]; then
        pip install --no-cache-dir -r "${TRITON_DIR}/python/requirements.txt"
    fi
    pip install tabulate scipy ninja cmake wheel pybind11 pytest
    pip install numpy pyyaml ctypeslib2 matplotlib pandas

    echo "####################################################################################"
    echo "##################### Installing Triton Proton dependencies... #####################"
    echo "####################################################################################"
    pip install llnl-hatchet

    if [ -n "$CLONED" ] && [ "$CLONED" -eq 1 ]; then
        echo "###############################################################################"
        echo "#####################Installing pre-commit dependencies...#####################"
        echo "###############################################################################"
        pip install pre-commit
        pre-commit install
    fi

    if [ -n "$CUSTOM_LLVM" ] && [ "$CUSTOM_LLVM" = "true" ]; then
        echo "################################################################"
        echo "##################### CUSTOM LLVM BUILD... #####################"
        echo "################################################################"
        if [ -d "/llvm-project/install/bin" ]; then
            echo "export LLVM_BUILD_DIR=/llvm-project/install " >> "${HOME}/.bashrc" && \
            echo "export LLVM_INCLUDE_DIRS=/llvm-project/install/include" >> "${HOME}/.bashrc" && \
            echo "export LLVM_LIBRARY_DIR=/llvm-project/install/lib" >> "${HOME}/.bashrc" && \
            echo "export LLVM_SYSPATH=/llvm-project/install" >> "${HOME}/.bashrc";
            declare -a llvm_vars=(
                "LLVM_BUILD_DIR=/llvm-project/install"
                "LLVM_INCLUDE_DIRS=/llvm-project/install/include"
                "LLVM_LIBRARY_DIR=/llvm-project/install/lib"
                "LLVM_SYSPATH=/llvm-project/install"
            )
            for var in "${llvm_vars[@]}"; do
                export var
            done
        else
            echo "ERROR /llvm-project/install is empty skipping this step"
        fi
    fi
}

# Function to update MAX_UID and MAX_GID in /etc/login.defs
update_max_uid_gid() {
    local current_max_uid
    local current_max_gid
    local current_min_uid
    local current_min_gid

    # Get current max UID and GID from /etc/login.defs
    current_max_uid=$(grep "^UID_MAX" /etc/login.defs | awk '{print $2}')
    current_max_gid=$(grep "^GID_MAX" /etc/login.defs | awk '{print $2}')
    current_min_uid=$(grep "^UID_MIN" /etc/login.defs | awk '{print $2}')
    current_min_gid=$(grep "^GID_MIN" /etc/login.defs | awk '{print $2}')

    # Check and update MAX_UID if necessary
    if [ "$USER_ID" -gt "$current_max_uid" ]; then
        echo "Updating UID_MAX from $current_max_uid to $USER_ID"
        sed -i "s/^UID_MAX.*/UID_MAX $USER_ID/" /etc/login.defs
    fi

    # Check and update MAX_GID if necessary
    if [ "$GROUP_ID" -gt "$current_max_gid" ]; then
        echo "Updating GID_MAX from $current_max_gid to $GROUP_ID"
        sed -i "s/^GID_MAX.*/GID_MAX $GROUP_ID/" /etc/login.defs
    fi

    # Check and update MIN_UID if necessary
    if [ "$USER_ID" -lt "$current_min_uid" ]; then
        echo "Updating UID_MIN from $current_min_uid to $USER_ID"
        sed -i "s/^UID_MIN.*/UID_MIN $USER_ID/" /etc/login.defs
    fi

    # Check and update MIN_GID if necessary
    if [ "$GROUP_ID" -lt "$current_min_gid" ]; then
        echo "Updating GID_MIN from $current_min_gid to $GROUP_ID"
        sed -i "s/^GID_MIN.*/GID_MIN $GROUP_ID/" /etc/login.defs
    fi
}

export_vars() {
    # Define environment variables to export
    declare -a export_vars=(
        "USERNAME=$USER"
        "USER_UID=$USER_ID"
        "USER_GID=$GROUP_ID"
    )

    if [ -n "$CUSTOM_LLVM" ]; then
        export_vars+=("CUSTOM_LLVM=$CUSTOM_LLVM")
    fi

    if [ -n "$DEMO_TOOLS" ]; then
        export_vars+=("DEMO_TOOLS=$DEMO_TOOLS")
    fi

    if [ -n "$TRITON_CPU_BACKEND" ]; then
        export_vars+=("TRITON_CPU_BACKEND=$TRITON_CPU_BACKEND")
    fi

    if [ -n "$AMD" ]; then
        export_vars+=("AMD=$AMD")
    fi

    if [ -n "$ROCM_VERSION" ]; then
        export_vars+=("ROCM_VERSION=$ROCM_VERSION")
    fi

    if [ -n "$HIP_VISIBLE_DEVICES" ]; then
        export_vars+=("HIP_VISIBLE_DEVICES=$HIP_VISIBLE_DEVICES")
    fi

    if [ -n "$TORCH_VERSION" ]; then
        export_vars+=("TORCH_VERSION=$TORCH_VERSION")
    fi

    if [ -n "$DISPLAY" ]; then
        export_vars+=("DISPLAY=$DISPLAY")
    fi

    if [ -n "$WAYLAND_DISPLAY" ]; then
        export_vars+=("WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
    fi

    if [ -n "$XDG_RUNTIME_DIR" ]; then
        export_vars+=("XDG_RUNTIME_DIR=/tmp")
    fi

    for var in "${export_vars[@]}"; do
        export_cmd+="export $var; "
    done
}

# Check if the USER environment variable is set and not empty
if [ -n "$CREATE_USER" ] && [ "$CREATE_USER" = "true" ]; then
    if [ -n "$USER" ] && [ "$USER" != "root" ] ; then
        update_max_uid_gid
        # Create user if it doesn't exist
        if ! id -u "$USER" >/dev/null 2>&1; then
            echo "Creating user $USER with UID $USER_ID and GID $GROUP_ID"
            ./user.sh -u "$USER" -i "$USER_ID" -g "$GROUP_ID"
        fi

        export_vars
        install_system_dependencies

        echo "Switching to user: $USER to install user dependencies."
        runuser -u "$USER" -- bash -c "$export_cmd $(declare -f install_user_dependencies navigate); install_user_dependencies"
        navigate
        exec gosu "$USER" "$@"
    fi
else
    install_system_dependencies
    install_user_dependencies
    navigate
    exec "$@"
fi
