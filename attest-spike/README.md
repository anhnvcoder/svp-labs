# attest-spike: Kyverno đang ghim có xác minh được provenance của `actions/attest` không

Spike một lần, trả lời trước khi đổi định dạng build provenance của đường chính từ `cosign attest --type slsaprovenance1` (predicate do script
của `svp-backend` dựng, ADR-0027 của `svp-backend`) sang `actions/attest` (Sigstore bundle, đẩy vào registry bằng `push-to-registry: true`).

**Trạng thái: khung (lượt 1).** Đã có workflow sinh image và attestation; chưa thử gì với Kyverno. Mọi dòng của bảng dưới đây là "chưa kiểm"
cho tới khi có lệnh đã chạy và output đi kèm.

## Version

| Thành phần | Version | Nguồn |
| --- | --- | --- |
| Kyverno | v1.19.2 (chart `kyverno` 3.9.2) | `argocd/apps/components.json` của `svp-gitops`; `appVersion` đọc bằng `helm show chart --repo https://kyverno.github.io/kyverno/ kyverno --version 3.9.2` |
| `actions/attest` | v4.2.2 (`1e69f48acb82d1966a394da916b4c1698aa569d6`) | `.github/workflows/attest-spike.yml` |

## Image thử

| Ca | Image | Định dạng provenance | Identity ký |
| --- | --- | --- | --- |
| mới | `ghcr.io/anhnvcoder/svp-labs/attest-spike@<digest của lượt workflow>` | Sigstore bundle của `actions/attest` | `https://github.com/anhnvcoder/svp-labs/.github/workflows/attest-spike.yml@refs/heads/main` |
| cũ | `ghcr.io/anhnvcoder/svp-backend/gateway@sha256:15c32ac48a6fd3b67ebe7f0e9549eb9c7accfafdbdd93ece96a273142e634e3c` (bản stg lúc viết, `envs/stg/images/gateway.yaml` của `svp-gitops`) | `cosign attest --type slsaprovenance1` định dạng cũ | `https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main` |
| không provenance | `ghcr.io/anhnvcoder/svp-backend/drill-no-provenance@<digest mới nhất>` | không có | (ký và attest `vuln`, không provenance) |

Workflow `.github/workflows/attest-spike.yml` chạy khi push đổi `attest-spike/**` hay bằng dispatch: build `image/` (`FROM scratch`, một file
text), đẩy lên GHCR bằng `GITHUB_TOKEN` (BuildKit tắt provenance và SBOM của nó, nên image là một manifest trơn), rồi `actions/attest` với
`subject-name`, `subject-digest`, `push-to-registry: true`. `create-storage-record: false` vì storage record chỉ có cho repo của organization.
Digest của image nằm ở summary của lượt chạy.

## Kết quả

| Ca | Câu hỏi | Kết quả | Lệnh đã chạy |
| --- | --- | --- | --- |
| a | `ImageValidatingPolicy` xác minh chữ ký keyless của attestation bundle theo issuer, subject | chưa kiểm (chưa có lượt workflow) | — |
| b | Đọc predicate, so `buildDefinition.externalParameters.workflow.repository`, `.ref`, `runDetails.builder.id` như bốn phép provenance của `svp-policy` | chưa kiểm | — |
| c | Một policy nhận định dạng cũ **hoặc** định dạng mới | chưa kiểm | — |
| d | Image không provenance bị từ chối đúng message | chưa kiểm | — |
| CI | Lệnh kiểm phía script không cần token: `cosign verify-attestation` với bundle mới, hay `gh attestation verify --bundle-from-oci` | chưa kiểm | — |

## Cách thử (lượt 2)

1. Kyverno CLI bằng image ghim đúng v1.19.2: `kyverno apply` policy `policy*.yaml` lên manifest Pod của từng image.
2. CLI không đánh giá được phép xác minh image thì dựng cluster tạm k3d `svp-spike` bằng `Makefile` của thư mục này (mọi lệnh
   `env -u DOCKER_DEFAULT_PLATFORM`, `kubectl --context k3d-svp-spike`), cài chart `kyverno` 3.9.2, gửi Pod bằng `kubectl apply --dry-run=server`,
   xoá cluster khi xong.
3. Kéo image và attestation ẩn danh; không đăng nhập GHCR hay Sigstore từ máy.

## Giới hạn gặp

Chưa có.
