import .kind
import .k3s
import .talos

# Render a single cluster config document at the root (no `items:` wrapper), so
# the runner's CLI can consume `kcl run` output directly. `-D runner=`:
#   kind  (default) → `kind create cluster --config <file>`
#   k3s   → `k3d cluster create --config <file.yaml>`
#   talos → the talosctl argv (see talos.k)
_runner = option("runner", default="kind")
assert _runner in ["kind", "k3s", "talos"], "runner must be kind, k3s or talos, got '${_runner}'"

if _runner == "kind":
    kind.Cluster {}
elif _runner == "talos":
    talos.TalosCluster {}
else:
    k3s.K3sCluster {}
schema AuthGenericOauth:
    verbose_logging: bool = False
    enabled: bool = False
    name: str
    allow_sign_up: bool = True
    client_id: str = "grafana" # keycloa, alerts, crossplane, app1, app2, admin-manager, kyverno
    client_secret: str
    scopes: str = "openid email profile"
    auth_url: str
    token_url: str
    api_url: str
    role_attribute_path: str
    login_attribute_path: str
    name_attribute_path: str
    email_attribute_path: str
