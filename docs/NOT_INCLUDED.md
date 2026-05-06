# Not Included By Design

`cloudsec_remote_browser` is not a policy product. It is a remote browser runtime used
after SWG and policy-engine decide that traffic should isolate.

## Policy And SWG Responsibilities Kept Outside

- RBI package level calculation.
- `ComputeRbiAction` downgrade logic.
- AIC file parsing and tenant lookup.
- Destination/category/application policy management.
- SWG provider selection and canary flags.
- Menlo fallback and file/DLP/FTC route decisions.
- SWG NGINX/Envoy/MPS policy and scan pipelines.

## Browser Isolation Source Components Excluded

- Extension redirects and extension UI.
- Direct `/launch` page.
- Admin UI and admin APIs.
- SWG simulator policy files and simulator UI.
- Hybrid DOM public UI.
- AWS Terraform and one-off local lab deployment stacks.
- Generated screenshots, logs, caches, and node_modules.

## Parity Not Yet Provided

- Upload brokering.
- Download brokering.
- Safe-PDF/original-file semantics.
- DLP/FTC verdict propagation.
- Local AV passthrough.
- `X-SIG-RBI-File-*` equivalent metadata for MPS and Envoy.
- Full Cisco production identity model.
