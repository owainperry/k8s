#!/bin/bash

# Script to generate a kubeconfig file using a Kubernetes service account
# Usage: ./generate-kubeconfig.sh [options]

set -e

# Default values
NAMESPACE="kube-system"
SERVICE_ACCOUNT="admin-user"
CLUSTER_ROLE="cluster-admin"
CONTEXT_NAME="admin-context"
KUBECONFIG_FILE="admin-kubeconfig.yaml"
TOKEN_DURATION="8760h"  # 1 year

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate a kubeconfig file using a Kubernetes service account

OPTIONS:
    -n, --namespace <namespace>       Namespace for the service account (default: kube-system)
    -s, --service-account <name>      Service account name (default: admin-user)
    -r, --cluster-role <role>         Cluster role to bind (default: cluster-admin)
    -c, --context-name <name>         Context name in kubeconfig (default: admin-context)
    -o, --output <file>               Output kubeconfig file (default: admin-kubeconfig.yaml)
    -d, --duration <duration>         Token duration (default: 8760h)
    --skip-create                     Skip creating service account and role binding
    -h, --help                        Show this help message

EXAMPLES:
    # Create admin kubeconfig with defaults
    $0

    # Create kubeconfig for existing service account
    $0 --skip-create -n my-namespace -s my-sa

    # Create limited access kubeconfig
    $0 -s viewer-sa -r view -o viewer-kubeconfig.yaml

EOF
}

# Parse command line arguments
SKIP_CREATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -s|--service-account)
            SERVICE_ACCOUNT="$2"
            shift 2
            ;;
        -r|--cluster-role)
            CLUSTER_ROLE="$2"
            shift 2
            ;;
        -c|--context-name)
            CONTEXT_NAME="$2"
            shift 2
            ;;
        -o|--output)
            KUBECONFIG_FILE="$2"
            shift 2
            ;;
        -d|--duration)
            TOKEN_DURATION="$2"
            shift 2
            ;;
        --skip-create)
            SKIP_CREATE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Function to check if a resource exists
resource_exists() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    
    if [ -z "$namespace" ]; then
        kubectl get "$resource_type" "$resource_name" &> /dev/null
    else
        kubectl get "$resource_type" "$resource_name" -n "$namespace" &> /dev/null
    fi
}

# Function to create cluster-admin role
create_cluster_admin_role() {
    echo -e "${GREEN}Creating cluster-admin role...${NC}"
    
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-admin
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
- nonResourceURLs: ["*"]
  verbs: ["*"]
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ cluster-admin role created successfully${NC}"
    else
        echo -e "${RED}Failed to create cluster-admin role${NC}"
        exit 1
    fi
}

# Function to create service account and role binding
create_service_account_and_binding() {
    echo -e "${GREEN}Creating service account and role binding...${NC}"
    
    # Check if namespace exists
    if ! resource_exists "namespace" "$NAMESPACE"; then
        echo -e "${YELLOW}Namespace '$NAMESPACE' does not exist. Creating it...${NC}"
        kubectl create namespace "$NAMESPACE"
    fi
    
    # Check if service account exists
    if resource_exists "serviceaccount" "$SERVICE_ACCOUNT" "$NAMESPACE"; then
        echo -e "${YELLOW}Service account '$SERVICE_ACCOUNT' already exists in namespace '$NAMESPACE'${NC}"
    else
        echo "Creating service account '$SERVICE_ACCOUNT' in namespace '$NAMESPACE'"
        kubectl create serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE"
    fi
    
    # Check if cluster role exists
    if ! resource_exists "clusterrole" "$CLUSTER_ROLE"; then
        echo -e "${RED}Cluster role '$CLUSTER_ROLE' does not exist!${NC}"
        echo "Available cluster roles:"
        kubectl get clusterroles | grep -E "(admin|edit|view)" | head -10
        
        # If cluster-admin doesn't exist, offer to create it
        if [ "$CLUSTER_ROLE" = "cluster-admin" ]; then
            echo ""
            echo -e "${YELLOW}The 'cluster-admin' role is missing. This might be an AKS cluster with RBAC.${NC}"
            echo "Would you like to:"
            echo "1) Create the cluster-admin role"
            echo "2) Use an existing role (like 'cluster-admin-binding' or 'aks-cluster-admin-binding')"
            echo "3) Exit"
            read -p "Choose option (1-3): " choice
            
            case $choice in
                1)
                    create_cluster_admin_role
                    ;;
                2)
                    echo "Available admin-like roles:"
                    kubectl get clusterroles | grep -E "(admin|aks-)" | head -20
                    read -p "Enter role name to use: " CLUSTER_ROLE
                    if ! resource_exists "clusterrole" "$CLUSTER_ROLE"; then
                        echo -e "${RED}Role '$CLUSTER_ROLE' not found${NC}"
                        exit 1
                    fi
                    ;;
                *)
                    exit 1
                    ;;
            esac
        else
            exit 1
        fi
    fi
    
    # Create cluster role binding
    BINDING_NAME="${SERVICE_ACCOUNT}-${CLUSTER_ROLE}-binding"
    if resource_exists "clusterrolebinding" "$BINDING_NAME"; then
        echo -e "${YELLOW}Cluster role binding '$BINDING_NAME' already exists${NC}"
    else
        echo "Creating cluster role binding '$BINDING_NAME'"
        kubectl create clusterrolebinding "$BINDING_NAME" \
            --clusterrole="$CLUSTER_ROLE" \
            --serviceaccount="${NAMESPACE}:${SERVICE_ACCOUNT}"
    fi
}

# Function to get cluster information
get_cluster_info() {
    echo -e "${GREEN}Getting cluster information...${NC}"
    
    # Get current cluster name
    CURRENT_CLUSTER=$(kubectl config current-context)
    CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CURRENT_CLUSTER')].context.cluster}")
    
    # Get server URL
    SERVER=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.server}")
    
    # Get certificate authority data
    CA_DATA=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.certificate-authority-data}")
    
    if [ -z "$SERVER" ] || [ -z "$CA_DATA" ]; then
        echo -e "${RED}Failed to get cluster information. Make sure you're connected to a cluster.${NC}"
        exit 1
    fi
    
    echo "Cluster: $CLUSTER_NAME"
    echo "Server: $SERVER"
}

# Function to get or create token
get_token() {
    echo -e "${GREEN}Getting authentication token...${NC}"
    
    # Check Kubernetes version to determine token strategy
    K8S_VERSION=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' | cut -d'.' -f2)
    
    # For K8s 1.24+, create a token
    if [ "$K8S_VERSION" -ge 24 ] 2>/dev/null || [ -z "$K8S_VERSION" ]; then
        echo "Creating token for service account (K8s 1.24+)..."
        TOKEN=$(kubectl create token "$SERVICE_ACCOUNT" -n "$NAMESPACE" --duration="$TOKEN_DURATION" 2>/dev/null || \
                kubectl create token "$SERVICE_ACCOUNT" -n "$NAMESPACE")
    else
        # For older versions, get token from secret
        echo "Getting token from service account secret (K8s < 1.24)..."
        SECRET_NAME=$(kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" -o jsonpath='{.secrets[0].name}')
        if [ -z "$SECRET_NAME" ]; then
            echo -e "${RED}No secret found for service account. Creating token manually...${NC}"
            TOKEN=$(kubectl create token "$SERVICE_ACCOUNT" -n "$NAMESPACE" 2>/dev/null || echo "")
        else
            TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 --decode)
        fi
    fi
    
    if [ -z "$TOKEN" ]; then
        echo -e "${RED}Failed to get token for service account${NC}"
        exit 1
    fi
}

# Function to generate kubeconfig
generate_kubeconfig() {
    echo -e "${GREEN}Generating kubeconfig file...${NC}"
    
    cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${NAMESPACE}
    user: ${SERVICE_ACCOUNT}
  name: ${CONTEXT_NAME}
current-context: ${CONTEXT_NAME}
users:
- name: ${SERVICE_ACCOUNT}
  user:
    token: ${TOKEN}
EOF

    chmod 600 "$KUBECONFIG_FILE"
    echo -e "${GREEN}Kubeconfig file generated: $KUBECONFIG_FILE${NC}"
}

# Function to test the kubeconfig
test_kubeconfig() {
    echo -e "${GREEN}Testing the generated kubeconfig...${NC}"
    
    # Test with the new kubeconfig
    if KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes &> /dev/null; then
        echo -e "${GREEN}✓ Successfully connected to cluster${NC}"
        echo "Accessible resources:"
        KUBECONFIG="$KUBECONFIG_FILE" kubectl auth can-i --list | head -10
        echo "..."
    else
        echo -e "${YELLOW}⚠ Connection test failed. The kubeconfig might have limited permissions.${NC}"
        echo "Testing basic permissions..."
        KUBECONFIG="$KUBECONFIG_FILE" kubectl auth can-i get pods -n "$NAMESPACE" && \
            echo "✓ Can get pods in $NAMESPACE" || echo "✗ Cannot get pods in $NAMESPACE"
    fi
}

# Main execution
main() {
    echo -e "${GREEN}=== Kubeconfig Generator ===${NC}"
    echo "Configuration:"
    echo "  Namespace: $NAMESPACE"
    echo "  Service Account: $SERVICE_ACCOUNT"
    echo "  Cluster Role: $CLUSTER_ROLE"
    echo "  Output File: $KUBECONFIG_FILE"
    echo ""
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}kubectl is not installed or not in PATH${NC}"
        exit 1
    fi
    
    # Check if connected to a cluster
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Not connected to a Kubernetes cluster${NC}"
        exit 1
    fi
    
    # Create service account and role binding if needed
    if [ "$SKIP_CREATE" = false ]; then
        create_service_account_and_binding
    else
        echo -e "${YELLOW}Skipping service account creation (--skip-create flag set)${NC}"
        # Verify service account exists
        if ! resource_exists "serviceaccount" "$SERVICE_ACCOUNT" "$NAMESPACE"; then
            echo -e "${RED}Service account '$SERVICE_ACCOUNT' does not exist in namespace '$NAMESPACE'${NC}"
            exit 1
        fi
    fi
    
    # Get cluster information
    get_cluster_info
    
    # Get token
    get_token
    
    # Generate kubeconfig
    generate_kubeconfig
    
    # Test the kubeconfig
    test_kubeconfig
    
    echo ""
    echo -e "${GREEN}=== Setup Complete ===${NC}"
    echo "To use this kubeconfig:"
    echo "  export KUBECONFIG=$KUBECONFIG_FILE"
    echo "Or:"
    echo "  kubectl --kubeconfig=$KUBECONFIG_FILE get nodes"
    echo ""
    echo "To merge with existing kubeconfig:"
    echo "  export KUBECONFIG=\$KUBECONFIG:$KUBECONFIG_FILE"
    echo "  kubectl config view --flatten > ~/.kube/config"
}

# Run main function
main
