# You can pick any Debian/Ubuntu-based image.
FROM mcr.microsoft.com/vscode/devcontainers/base:ubuntu-21.04

ARG USERNAME=vscode

# Install additional OS packages
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends make cmake sudo git git-lfs curl \
        nodejs npm apt-transport-https dnsutils vim jq ffmpeg wget python3-pip

# Add markdownlint tools
RUN npm install -g markdownlint-cli

# apt stuff
RUN echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME 

# Install missing packages out of apt-get
COPY tools.sh /home/$USERNAME/
RUN ./home/$USERNAME/tools.sh

# Ensure container does not run under root anymore
USER $USERNAME

# configure az cli to automatically install extension
RUN az config set extension.use_dynamic_install=yes_without_prompt

# Add bashrc extensions
COPY --chown=$USERNAME:$USERNAME ./bashrc_extension /home/$USERNAME/.bashrc_extension
RUN echo "source ~/.bashrc_extension" >> ~/.bashrc