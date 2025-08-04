#!/bin/bash

# Script to diagnose RBAC configuration in AKS cluster

echo "=== AKS RBAC Diagnostic ==="
echo ""

# Check current context
echo "Current context:"
kubectl config current-context
echo ""

# Check if connected
if ! kubectl cluster-info &> /dev/null; then
    echo "ERROR: Not connected to a Kubernetes cluster"
    exit 1
fi

# Check for common admin roles
echo "Checking for admin-related cluster roles:"
echo "----------------------------------------"
kubectl get clusterroles | grep -E "(admin|aks-|azure-)" | sort

echo ""
echo "Checking for system roles:"
echo "-------------------------"
kubectl get clusterroles | grep -E "^(system:|cluster-admin|admin|edit|view)$" | sort

echo ""
echo "Current user permissions:"
echo "------------------------"
kubectl auth can-i '*' '*' --all-namespaces && echo "✓ You have cluster-admin access" || echo "✗ You do NOT have cluster-admin access"

echo ""
echo "Checking what you CAN do:"
echo "------------------------"
kubectl auth can-i --list | grep -E "^\*|create|delete|update" | head -20

echo ""
echo "Existing service accounts in kube-system:"
echo "---------------------------------------"
kubectl get serviceaccounts -n kube-system

echo ""
echo "For AKS-specific scenarios:"
echo "-------------------------"
echo "1. If using Azure AD integration, you might need to use:"
echo "   az aks get-credentials --resource-group <rg> --name <cluster> --admin"
echo ""
echo "2. Common AKS admin roles:"
echo "   - Azure Kubernetes Service Cluster Admin Role"
echo "   - Azure Kubernetes Service Cluster User Role"
echo "   - Azure Kubernetes Service RBAC Admin"
echo "   - Azure Kubernetes Service RBAC Cluster Admin"
