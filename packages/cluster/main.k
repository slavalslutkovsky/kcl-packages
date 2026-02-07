import .kind

# Generate Kind cluster configuration
# Usage: kcl run scripts/kcl/cluster/main.k -D name=dev -D workers=2 -D ingress=true
items = [kind.Cluster {}]
