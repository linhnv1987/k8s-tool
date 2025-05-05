#!/bin/bash

RANCHER_URL="${1:-https://rancher.koga.edu.vn}"
KUBECONFIG_FILE="${2:-$HOME/.kube/config}"
NS="cattle-system"

header() {
  echo -e "\n\033[1;34m🔹 $1\033[0m"
}

success() {
  echo -e "  ✅ $1"
}

warning() {
  echo -e "  ⚠️  $1"
}

error() {
  echo -e "  ❌ $1"
}

header "Kiểm tra kết nối đến Rancher: $RANCHER_URL"
curl -k --max-time 5 -s -o /dev/null "$RANCHER_URL" && success "Rancher truy cập được" || { error "Không truy cập được Rancher"; exit 1; }

header "Kiểm tra kubeconfig..."
kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes &>/dev/null && success "Kết nối được cụm Kubernetes" || { error "kubeconfig không hợp lệ"; exit 2; }

header "Kiểm tra quyền cluster-admin..."
CAN_I=$(kubectl --kubeconfig="$KUBECONFIG_FILE" auth can-i '*' '*' --all-namespaces)
[ "$CAN_I" = "yes" ] && success "Có quyền cluster-admin" || warning "Không có quyền đầy đủ (cluster-admin)"

header "Kiểm tra namespace cattle-system..."
if ! kubectl get ns $NS &>/dev/null; then
  warning "Namespace $NS chưa tồn tại → có thể cụm chưa được import"
  exit 0
fi

header "Liệt kê Pod trong $NS:"
kubectl -n $NS get pods -o wide

header "Kiểm tra cattle-cluster-agent..."
AGENT_POD=$(kubectl -n $NS get pods -l app=cattle-cluster-agent -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
if [ -n "$AGENT_POD" ]; then
  STATUS=$(kubectl -n $NS get pod "$AGENT_POD" -o jsonpath="{.status.phase}")
  echo "  📦 Pod: $AGENT_POD → Trạng thái: $STATUS"
  if [[ "$STATUS" != "Running" ]]; then
    warning "Log cattle-cluster-agent ($AGENT_POD):"
    kubectl -n $NS logs "$AGENT_POD" --tail=20
  fi
else
  error "Không tìm thấy Pod cattle-cluster-agent"
fi

header "Kiểm tra cattle-node-agent..."
NODE_AGENT_DS=$(kubectl get daemonset -A -l app=cattle-node-agent -o jsonpath="{range .items[*]}{.metadata.namespace}/{.metadata.name}{'\n'}{end}")
if [ -n "$NODE_AGENT_DS" ]; then
  while read -r line; do
    NS_NAME=(${line//// })
    DS_NS="${NS_NAME[0]}"
    DS_NAME="${NS_NAME[1]}"
    READY=$(kubectl -n "$DS_NS" get daemonset "$DS_NAME" -o jsonpath="{.status.numberReady}")
    DESIRED=$(kubectl -n "$DS_NS" get daemonset "$DS_NAME" -o jsonpath="{.status.desiredNumberScheduled}")
    echo "  📦 $DS_NAME trong namespace $DS_NS: $READY / $DESIRED Pod sẵn sàng"
    [ "$READY" != "$DESIRED" ] && warning "Một số node không chạy cattle-node-agent đầy đủ"
  done <<< "$NODE_AGENT_DS"
else
  warning "Không tìm thấy DaemonSet cattle-node-agent → có thể cụm là local hoặc thiếu import"
fi

header "Phát hiện loại cụm..."
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath="{.clusters[0].name}")
if echo "$CLUSTER_NAME" | grep -iq "local"; then
  warning "Cụm này có thể là local cluster"
else
  success "Tên cụm: $CLUSTER_NAME"
fi
