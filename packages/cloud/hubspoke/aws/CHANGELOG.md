## 0.1.0 (2026-09-19)

Initial AWS backend for the NetworkHub XR: a Transit Gateway with one VPC attachment per existing spoke VPC, an optional summary route toward the gateway in each spoke's own route tables, and — in the isolated topology — a shared and an isolated Transit Gateway route table whose associations and propagations keep workload spokes from reaching one another.
