FROM mcr.microsoft.com/devcontainers/base:resolute

USER vscode
# The reference is cloned beside the workspace, which is root's otherwise.
RUN sudo mkdir -p /workspaces && sudo chown vscode:vscode /workspaces
ENV PATH="/home/vscode/.local/bin:/home/vscode/.elan/bin:${PATH}"
RUN curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y
RUN elan toolchain install stable
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
