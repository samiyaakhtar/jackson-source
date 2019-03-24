#!/bin/bash

function verify_access_token() {
    echo "VERIFYING PERSONAL ACCESS TOKEN"
    if [[ -z "$ACCESS_TOKEN_SECRET" ]]; then
        echo "Please set env var ACCESS_TOKEN_SECRET for git host: $GIT_HOST"
        exit 1
    fi
}
function verify_repo() {
    echo "CHECKING MANIFEST REPO URL"
    if [[ -z "$MANIFEST_REPO" ]]; then
        echo 'MANIFEST REPO URL not specified in variable $MANIFEST_REPO'
        exit 1
    fi
}

function init() {
    cp -r * $HOME/
    cd $HOME
    verify_repo
}

# Initialize Helm
function helm_init() {
    echo "RUN HELM INIT"
    helm init
}

# Obtain version for Fabrikate
# If the version number is not provided, then download the latest
function get_fab_version() {
    if [ -z "$VERSION" ]
    then
        VERSIONS=$(curl -s https://api.github.com/repos/Microsoft/fabrikate/tags)
        LATEST_RELEASE=$(echo $VERSIONS | grep "name" | head -1)
        VERSION_TO_DOWNLOAD=`echo "$LATEST_RELEASE" | cut -d'"' -f 4`
    else
        echo "Fabrikate Version: $VERSION"
        VERSION_TO_DOWNLOAD=$VERSION
    fi
}

# Obtain OS to download the appropriate version of Fabrikate
function get_os() {
    if [[ "$OSTYPE" == "linux-gnu" ]]; then
        eval "$1='linux'"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        eval "$1='darwin'"
    elif [[ "$OSTYPE" == "msys" ]]; then
        eval "$1='windows'"
    else
        eval "$1='linux'"
    fi
}

# Download Fabrikate
function download_fab() {
    echo "DOWNLOADING FABRIKATE"
    echo "Latest Fabrikate Version: $VERSION_TO_DOWNLOAD"
    os=''
    get_os os
    fab_wget=$(wget -SO- "https://github.com/Microsoft/fabrikate/releases/download/$VERSION_TO_DOWNLOAD/fab-v$VERSION_TO_DOWNLOAD-$os-amd64.zip" 2>&1 | egrep -i "302")
    if [[ $fab_wget == *"302 Found"* ]]; then
       echo "Fabrikate $VERSION_TO_DOWNLOAD downloaded successfully."
    else
        echo "There was an error when downloading Fabrikate. Please check version number and try again."
    fi
    wget "https://github.com/Microsoft/fabrikate/releases/download/$VERSION_TO_DOWNLOAD/fab-v$VERSION_TO_DOWNLOAD-$os-amd64.zip"
    unzip fab-v$VERSION_TO_DOWNLOAD-$os-amd64.zip -d fab
}

# Install Fabrikate
function install_fab() {
    echo "git status"
    git status
    # Run this command to make script exit on any failure
    set -e
    export PATH=$PATH:$HOME/fab
    fab install
    echo "FAB INSTALL COMPLETED"
}

# Run fab generate
function fab_generate() {
    # For backwards compatibility, support pipelines that have not set this variable
    echo "CHECKING FABRIKATE ENVIRONMENTS"
    if [ -z "$FAB_ENVS" ]; then 
        echo "FAB_ENVS is not set" 
        echo "FAB GENERATE prod"
        fab generate prod
    else 
        echo "FAB_ENVS is set to $FAB_ENVS" 
        IFS=',' read -ra ENV <<< "$FAB_ENVS"
        for i in "${ENV[@]}"; do
            echo "FAB GENERATE $i"
            fab generate $i
        done
    fi

    echo "FAB GENERATE COMPLETED"
    
    set +e

    # If generated folder is empty, quit
    # In the case that all components are removed from the source hld, 
    # generated folder should still not be empty
    if find "$HOME/generated" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        echo "Manifest files have been generated."
    else
        echo "Manifest files could not be generated, quitting..."
        exit 1
    fi  
}

# Authenticate with Git
function git_connect() {
    cd $HOME
    # Remove http(s):// protocol from URL so we can insert PA token
    repo_url=$MANIFEST_REPO
    repo_url="${repo_url#http://}"
    repo_url="${repo_url#https://}"
    echo "GIT CLONE: https://automated:$ACCESS_TOKEN_SECRET@$repo_url"

    git clone https://automated:$ACCESS_TOKEN_SECRET@$repo_url
    repo_url=$MANIFEST_REPO
    repo=${repo_url##*/}

    # Extract repo name from url
    repo_name=${repo%.*}
    cd $repo_name
}

# Git commit
function git_commit() {
    echo "GIT CHECKOUT $BRANCH_NAME"
    if ! git checkout $BRANCH_NAME ; then
        git checkout -b $BRANCH_NAME
    fi
    
    echo "GIT STATUS"
    git status
    echo "GIT REMOVE"
    rm -rf ./*/
    git rm -rf */
    echo "COPY YAML FILES TO REPO DIRECTORY..."
    cp -r $HOME/generated/* .
    echo "GIT ADD"
    git add -A

    #Set git identity 
    git config user.email "admin@azuredevops.com"
    git config user.name "Automated Account"

    if [[ `git status --porcelain` ]]; then
        echo "GIT COMMIT"
        git commit -m "Updated k8s manifest files post commit: $COMMIT_MESSAGE"
        retVal=$? && [ $retVal -ne 0 ] && exit $retVal
    else
        echo "NOTHING TO COMMIT"
    fi

    echo "GIT PULL origin $BRANCH_NAME" 
    git pull origin $BRANCH_NAME
}

# Perform a Git push
function git_push() {  
    # Remove http(s):// protocol from URL so we can insert PA token
    repo_url=$MANIFEST_REPO
    repo_url="${repo_url#http://}"
    repo_url="${repo_url#https://}"

    echo "GIT PUSH: https://$ACCESS_TOKEN_SECRET@$repo_url origin $BRANCH_NAME"
    git push https://$ACCESS_TOKEN_SECRET@$repo_url origin $BRANCH_NAME
    retVal=$? && [ $retVal -ne 0 ] && exit $retVal
    echo "GIT STATUS"
    git status
}

function unit_test() {
    echo "Sourcing for unit test..."
}

function verify_pull_request() {
    echo "Starting verification"
    init
    helm_init
    get_fab_version
    download_fab
    install_fab
    fab_generate
}

# Run functions
function verify_pull_request_and_merge() {
    verify_access_token
    verify_pull_request
    echo "Verification complete, push to yaml repo"
    git_connect
    git_commit
    git_push
}

echo "argument is ${1}"
if [[ "$VERIFY_ONLY" == "1" ]]; then
    verify_pull_request
elif [ "${1}" == "--source-only" ]; then
    unit_test
else
    verify_pull_request_and_merge
fi
