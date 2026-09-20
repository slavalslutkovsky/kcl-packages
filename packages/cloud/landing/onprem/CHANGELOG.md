## 0.1.0 (2026-09-19)

Initial onprem backend for the LandingPage XR: one provider-helm Release of the pinned nginx chart that serves the XR's content from a ConfigMap, exposed in-cluster by a ClusterIP Service and — when a domain is set — by a cert-manager-annotated Ingress.
