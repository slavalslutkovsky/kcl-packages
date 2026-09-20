## 0.1.0 (2026-09-19)

Initial azure backend for the LandingPage XR: a Storage Account static website holding the page in `$web`, fronted by a Front Door Standard profile, endpoint, origin group, origin, route and — when `spec.domain` is set — a custom domain with a Front Door managed certificate.
