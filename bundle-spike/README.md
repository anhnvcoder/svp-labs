# bundle-spike: bản phát hành keyless toàn Sigstore bundle, và rescan `vuln` hằng ngày với bundle

Spike một lần, trả lời trước khi đổi chữ ký, `vuln`, provenance của đường chính sang Sigstore bundle, hai câu mà
[`attest-spike/README.md`](../attest-spike/README.md) mục "Giới hạn gặp" để "chưa kiểm":

- **(A) Một image keyless toàn bundle:** chữ ký `cosign sign --new-bundle-format=true`, `vuln` `cosign attest --new-bundle-format=true --type vuln`
  (predicate dạng của `deploy/ci/vuln-predicate.sh` của `svp-backend`, hai nền tảng), provenance `actions/attest` (`push-to-registry: true`), cùng
  identity `bundle-spike.yml@refs/heads/main` của `svp-labs`. Kyverno CLI v1.19.1 với policy render từ template thật `svp-policy` của
  `svp-backend` (`requireProvenance: true`, bảng nguồn thêm nguồn `labs`): mười phép đều qua; image thiếu `vuln` bị từ chối đúng message.
- **(B) Rescan:** `vuln` attest lần hai, lần ba lên cùng digest với `scanFinishedOn` mới hơn, như job `rescan` hằng ngày: `--replace` có tác dụng
  với bundle không; Kyverno, `cosign verify-attestation` đọc bundle `vuln` nào; gỡ được bundle cũ không và bằng quyền gì; thời gian xác minh
  khi có N bundle.

**Trạng thái: chưa chạy.** Đã có workflow, script; chờ các lượt `bundle-spike.yml` trên `main` của `svp-labs`.

## Kết luận

Chưa có: điền sau khi chạy đủ các phép dưới đây.

## Version

| Thành phần | Version | Nguồn |
| --- | --- | --- |
| Kyverno CLI | `ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a` | digest của [`attest-spike/README.md`](../attest-spike/README.md) (`base/kyverno.yaml` của `svp-gitops`) |
| cosign trong workflow | v3.1.4 (`sigstore/cosign-installer` v4.1.2) | như job ký của `images.yml` của `svp-backend` |
| `actions/attest` | v4.2.2 (`1e69f48acb82d1966a394da916b4c1698aa569d6`) | như `attest-spike.yml` |
| ORAS | v1.3.6 (`ORAS_IMAGE` của `Makefile` `svp-backend`) | |
| Chart `svp-policy` | commit `svp-backend` lúc render: ghi khi chạy | `policy.sh` in commit |

## Lượt chạy

| Lượt | Mode | Run id | Digest |
| --- | --- | --- | --- |
| 1 | `build` | | |
| 2 | `rescan` | | |
| 3 | `rescan` | | |
| 4 | `prune` | | |

## (A) Image keyless toàn bundle

| Ca | Câu hỏi | Kết quả | Lệnh đã chạy và output |
| --- | --- | --- | --- |
| A1 | Image `release` có đúng ba bundle referrer (chữ ký, `vuln`, provenance) | chưa chạy | |
| A2 | Mười phép của `svp-policy` (`requireProvenance: true`) đều qua trên image `release` | chưa chạy | |
| A3 | Phép 4–6 (đủ hai nền tảng, không CRITICAL, tuổi) đọc `vuln` dạng bundle | chưa chạy | |
| A4 | Đối chứng: image `novuln` (chữ ký, provenance, không `vuln`) bị từ chối ở phép 3 đúng message | chưa chạy | |
| A5 | `cosign verify`, `cosign verify-attestation --type vuln`, `--type slsaprovenance1` trên image `release`, không token | chưa chạy | |

## (B) Rescan

| Ca | Câu hỏi | Kết quả | Lệnh đã chạy và output |
| --- | --- | --- | --- |
| B1 | `cosign attest --replace --type vuln` lần hai, ba: thay bundle cũ hay thêm bundle | chưa chạy | |
| B2 | Kyverno đọc bundle `vuln` nào (policy tạm tuổi tối đa vài giây, chỉ bundle mới nhất còn trong tuổi) | chưa chạy | |
| B3 | `cosign verify-attestation --type vuln` trả mấy envelope (`verify-release.sh` đòi đúng một) | chưa chạy | |
| B4 | Gỡ bundle `vuln` cũ: `oras manifest delete`, rồi API xoá package version bằng `GITHUB_TOKEN` | chưa chạy | |
| B5 | Sau khi gỡ: Kyverno, cosign đọc đúng bundle còn lại | chưa chạy | |
| B6 | Thời gian xác minh một image bằng CLI khi có N bundle (so `timeoutSeconds: 30`) | chưa chạy | |

## Cách chạy

Workflow [`.github/workflows/bundle-spike.yml`](../.github/workflows/bundle-spike.yml) (`workflow_dispatch`, input `mode`, `digest`):

- `build`: dựng image `FROM scratch` hai nền tảng (index của hai manifest) ở `ghcr.io/anhnvcoder/svp-labs/bundle-spike`, hai biến thể:
  `release` (ký, `vuln`, provenance, cả ba là bundle) và `novuln` (ký, provenance; đối chứng thiếu `vuln`). Summary in hai digest và các
  referrer.
- `rescan` với `digest` của `release`: attest thêm một `vuln` (`scanFinishedOn` lúc chạy) bằng `--replace`, như `rescan.sh` của `svp-backend`.
- `prune` với `digest` của `release`: giữ bundle `vuln` mới nhất, gỡ mọi bundle `vuln` khác (`referrers.sh prune`).

Trên máy chỉ đọc ẩn danh (package `bundle-spike` để public):

```sh
CLI=ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a
kyv() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm -v "$PWD":/w:ro -w /w "$CLI" apply "$1" --resource "$2"; }
./policy.sh <clone svp-backend> policy.yaml          # mười phép, tuổi tối đa 72h
./policy.sh <clone svp-backend> policy-age.yaml 30s  # cùng chart, tuổi tối đa ngắn (B2)
./referrers.sh list ghcr.io/anhnvcoder/svp-labs/bundle-spike@<digest>
```

## File

| File | Là gì |
| --- | --- |
| `image/` | Image `FROM scratch`; `VARIANT` chỉ đổi label, cho digest thứ hai cùng nội dung |
| `vuln-predicate.sh` | Predicate `vuln` dạng của `vuln-predicate.sh` của `svp-backend` từ index thật; báo cáo trivy rỗng (image không có gói nào) |
| `policy.sh` | Render `svp-policy` của một clone `svp-backend` (bản sao tạm, thêm nguồn `labs`), `requireProvenance: true`, tuổi tối đa tuỳ chọn |
| `referrers.sh` | `list`: bundle referrer của một image (loại predicate, `scanFinishedOn`), đọc từ chính bundle; `prune`: gỡ bundle `vuln` cũ (chỉ trong workflow) |

## Giới hạn gặp

Điền sau khi chạy.
