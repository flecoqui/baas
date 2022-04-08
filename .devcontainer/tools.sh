#!/bin/bash

function installPandoc() {
    # Install Pandoc
    version="2.17.0.1"

    pushd /tmp > /dev/null

    if [[ `dpkg --print-architecture` == "amd64" ]]; then
        arch="amd64"
    else
        # The if is required, because sometimes Linux on arm64 is listed as aarch64
        arch="arm64"
    fi

    sudo wget -q "https://github.com/jgm/pandoc/releases/download/$version/pandoc-$version-1-$arch.deb"
    sudo dpkg -i "pandoc-$version-1-$arch.deb";

    popd > /dev/null
}

function installDockerCli() {

    # Install Docker CLI
    pushd /tmp > /dev/null
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update \
    && apt-get install -y docker-ce-cli
    popd > /dev/null

}
function installDotnetSDK() {

    pushd /tmp > /dev/null

    sudo wget -q https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh
    sudo chmod +x dotnet-install.sh
    ./dotnet-install.sh --install-dir /usr/local/bin/

    popd > /dev/null

}
function installAzureCli() {

    # Installing az-cli via "pip" install Python dependencies in conflicts with development around security & login
    # So instead, we will use the deb package to do so (not from Universe repo, as outdated). The script below adds a repo
    # and install the latest version of the cli
    # Note: the deb package does not support arm64 architecture, hence the test first

    pushd /tmp > /dev/null
    if [[ `dpkg --print-architecture` == "amd64" ]]; then
        sudo curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash;
    else
    # arm based, install pip (and gcc) then azure-cli
        sudo apt-get -y install gcc python3-dev
        python3 -m pip install --upgrade pip
        python3 -m pip install azure-cli
    fi

    # Append required extensions
    az extension add --name azure-iot &> /dev/null

    popd > /dev/null

}

installPandoc
installDockerCli
installDotnetSDK
installAzureCli