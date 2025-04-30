#!/bin/bash

# this script installs kubernetes on Ubuntu 24.04

set -eE

#
# errors and cleanup
#

# NOTE: A lot of grouped output calls are used here:
#
# {
#   some_command
#   some_other_command
# } > do something with outout
#
# This causes problems catting the logfile on an error, so there is some
# magic done there ala:
# https://unix.stackexchange.com/questions/448323/trap-and-collect-script-output-input-file-is-output-file-error

function err_report() {
  echo "Error on line $(caller)" >&2
  exec >&3 2>&3 3>&-
  cat $LOG_FILE
  cleanup_tmp
}
trap err_report ERR

function cleanup_tmp(){
  rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

### help
function show_help(){
    echo "USAGE:"
    echo "On a control plane node use the '-c' option"
    echo "$0 -c"
    echo "On a worker node, run with no options"
    echo "$0"
    echo "For a single node, control plane and worker together, run with the '-s' option"
    echo "$0 -s"
    echo "For verbose output, run with the '-v' option"
    echo "$0 -v"
}

### check if Ubuntu 24.04
function check_linux_distribution(){
  echo "Checking Linux distribution"
  source /etc/lsb-release
  if [ "$DISTRIB_RELEASE" != "${UBUNTU_VERSION}" ]; then
      echo "ERROR: This script only works on Ubuntu 22.04"
      exit 1
  fi
}

### disable linux swap and remove any existing swap partitions
function disable_swap(){
  echo "Disabling swap"
  {
    swapoff -a
    sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab
  } 3>&2 >> $LOG_FILE 2>&1
}

### remove packages
function remove_packages(){
  echo "Removing packages"
  {
    # remove packages
    apt-mark unhold kubelet kubeadm kubectl kubernetes-cni || true
    # moby-runc is on github runner? have to remove it
    apt-get remove -y moby-buildx moby-cli moby-compose moby-containerd moby-engine moby-runc || true
    apt-get autoremove -y
    apt-get remove -y docker.io containerd kubelet kubeadm kubectl || true
    apt-get autoremove -y
    systemctl daemon-reload
  } 3>&2 >> $LOG_FILE 2>&1 
}

function install_docker(){
  echo "Installing Docker"
  {
    sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    sudo apt update
    sudo apt install -y containerd.io
    } 3>&2 >> $LOG_FILE 2>&1
} 

### install kubernetes packages
function install_kubernetes_packages(){
  echo "Installing Kubernetes packages"
  {
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt update
    sudo apt install -y kubeadm=${KUBE_VERSION}-1.1 kubelet=${KUBE_VERSION}-1.1 kubectl=${KUBE_VERSION}-1.1
  } 3>&2 >> $LOG_FILE 2>&1
}

### start services
function start_services(){
  echo "Starting services"
  {
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    systemctl enable kubelet && systemctl start kubelet
  } 3>&2 >> $LOG_FILE 2>&1
}

### install calico as the CNI
function install_cni(){
  # need to deploy two manifests for calico to work
  echo "Installing Calico CNI"
  {
    #kubectl create -f ${CALICO_URL}/tigera-operator.yaml
    #kubectl create -f ${CALICO_URL}/custom-resources.yaml
    kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
    #kubectl taint nodes --all node-role.kubernetes.io/control-plane-
  } 3>&2 >> $LOG_FILE 2>&1
}

function install_metrics_server(){
  echo "Installing metrics server"
  {
    kubectl apply -f manifests/metrics-server.yaml
    # TODO: wait for metrics server to be ready
  } 3>&2 >> $LOG_FILE 2>&1
}

### initialize the control plane
function kubeadm_init(){
  echo "Initialising the Kubernetes cluster via Kubeadm"
  {
    # Get the IP address of the main interface
    MAIN_IP=$(ip route get 1 | awk '{print $7;exit}')
    
    # Validate that MAIN_IP is actually an IP address
    if ! [[ $MAIN_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Error: Could not determine main interface IP address" >&2
      exit 1
    fi
    
    cat > kubeadm-config.yaml <<-EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${KUBE_VERSION}
networking:
  podSubnet: 192.168.9.0/24
controlPlaneEndpoint: "${MAIN_IP}:6443"
EOF
    # use config file for kubeadm
    kubeadm init --config kubeadm-config.yaml
  } 3>&2 >> $LOG_FILE 2>&1
}


### wait for nodes to be ready
function wait_for_nodes(){
  echo "Waiting for nodes to be ready..."
  {
    kubectl wait \
      --for=condition=Ready \
      --all nodes \
      --timeout=180s
  } 3>&2 >> $LOG_FILE 2>&1
  echo "==> Nodes are ready"
}

### configure kubeconfig for root and ubuntu
function configure_kubeconfig(){
  echo "Configuring kubeconfig for root and ubuntu users"
  {
    # NOTE(curtis): sometimes ubuntu user won't exist, so we don't care if this fails
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
  } 3>&2 >> $LOG_FILE 2>&1
}

### check if worker services are running
function check_worker_services(){
  echo "Check worker services"
  # Really until it's added to the kubernetes cluster only containerd
  # will be running...
  {
    echo "==> Checking containerd"
    systemctl is-active containerd
  } 3>&2 >> $LOG_FILE 2>&1
}

### taint the node so that workloads can run on it, assuming there is only
### one node in the cluster
function configure_as_single_node(){
  echo "Configuring as a single node cluster"
  {
    # this is a single node cluster, so we need to taint the master node
    # so that pods can be scheduled on it
    kubectl taint nodes --all \
      node-role.kubernetes.io/control-plane:NoSchedule-
    echo "==> Sleeping for 10 seconds to allow taint to take effect..."
    sleep 10 # wait for the taint to take effect
  } 3>&2 >> $LOG_FILE 2>&1
}

### test if an nginx pod can be deployed to validate the cluster
function test_nginx_pod(){
  echo "Deploying test nginx pod"
  {
    # deploy a simple nginx pod
    kubectl run --image nginx --namespace default nginx
    # wait for all pods to be ready
    kubectl wait \
      --for=condition=Ready \
      --all pods \
      --namespace default \
      --timeout=180s
    # delete the nginx pod
    kubectl delete pod nginx --namespace default
  } 3>&2 >> $LOG_FILE 2>&1
}

function wait_for_pods_running() {
  echo "Waiting for all pods to be running..."
  {
    local timeout=300  # 5 minutes timeout
    local start_time=$(date +%s)

    while true; do
      local not_running=$(kubectl get pods --all-namespaces --no-headers | grep -v "Running" | wc -l)
      if [ $not_running -eq 0 ]; then
        echo "All pods are running!"
        return 0
      fi

      local current_time=$(date +%s)
      local elapsed_time=$((current_time - start_time))
      
      if [ $elapsed_time -ge $timeout ]; then
        echo "Timeout reached. Not all pods are running."
        kubectl get pods --all-namespaces
        return 1
      fi

      echo "Waiting for $not_running pods to be in Running state..."
      sleep 10
    done 
  } 3>&2 >> $LOG_FILE 2>&1
}

### doublecheck the kubernetes version that is installed
function test_kubernetes_version() {
  echo "Checking Kubernetes version..."
  kubectl_version=$(kubectl version -o json)

  # use gitVersion
  client_version=$(echo "$kubectl_version" | jq '.clientVersion.gitVersion' | tr -d '"')
  server_version=$(echo "$kubectl_version" | jq '.serverVersion.gitVersion' | tr -d '"')

  echo "Client version: $client_version"
  echo "Server Version: $server_version"

  # check if kubectl and server are the same version
  if [[ "$client_version" != "$server_version" ]]; then
    echo "Client and server versions differ, exiting..."
    exit 1
  fi

  # check if what we asked for was what we got
  local kube_version="v${KUBE_VERSION}"
  if [[ "$kube_version" == "$server_version" ]]; then
    echo "Requested KUBE_VERSION matches the server version."
  else
    echo "Requested KUBE_VERSION does not match the server version, exiting..."
    exit 1
  fi

}

#
# MAIN
#

### run the whole thing
function run_main(){
  echo "Starting install..."
  echo "Logging all output to $LOG_FILE"
  check_linux_distribution
  disable_swap
  remove_packages
  install_docker
  install_kubernetes_packages
  configure_system
  configure_kubelet
  configure_containerd
  install_containerd
  start_services

  # only run this on the control plane node
  if [[ "${CONTROL_NODE}" == "true" || "${SINGLE_NODE}" == "true" ]]; then
    echo "Configuring control plane node..."
    kubeadm_init
    configure_kubeconfig
    install_cni
    wait_for_nodes
    # now  test what was installed
    test_kubernetes_version
    install_metrics_server
    if [[ "${SINGLE_NODE}" == "true" ]]; then
      echo "Configuring as a single node cluster"
      configure_as_single_node
      test_nginx_pod
      wait_for_pods_running
    fi
    echo "Install complete!"

    echo
    echo "### Command to add a worker node ###"
    kubeadm token create --print-join-command --ttl 0
  else
    # is a worker node
    check_worker_services
    echo "Install complete!"
    echo
    echo "### To add this node as a worker node ###"
    echo "Run the below on the control plane node:"
    echo "kubeadm token create --print-join-command --ttl 0"
    echo "and execute the output on the worker nodes"
    echo
  fi
}

# assume it's a worker node by default
WORKER_NODE=true
CONTROL_NODE=false
SINGLE_NODE=false
VERBOSE=false
UBUNTU_VERSION=24.04

# software versions
KUBE_VERSION=1.33.0
CONTAINERD_VERSION=2.0.5
CALICO_VERSION=3.29.3
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/"

# create a temp dir to store logs
TMP_DIR=$(mktemp -d -t install-kubernetes-XXXXXXXXXX)
readonly TMP_DIR
LOG_FILE=${TMP_DIR}/install.log

while getopts "h?cvs" opt; do
  case "$opt" in
    h|\?)
      show_help
      exit 0
      ;;
    c) CONTROL_NODE=true
       WORKER_NODE=false
      ;;
    v) VERBOSE=true
      ;;
    s) SINGLE_NODE=true
  esac
done

# only run main if running from scripts not testing with bats
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  run_main
  # print the log file if verbose, though it will be after all the commands run
  if [ "${VERBOSE}" == "true" ]; then
    echo
    echo "### Log file ###"
    cat $LOG_FILE
  fi
fi
