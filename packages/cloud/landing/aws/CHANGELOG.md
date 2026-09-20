## 0.1.0 (2026-09-19)

Initial AWS backend for the LandingPage XR: an S3 bucket holding the page content, fronted by a CloudFront distribution with an Origin Access Control and a DNS-validated ACM certificate, or served straight off the S3 website endpoint when the CDN is disabled.
