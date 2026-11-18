# svp-labs

Đường học của lab short-video-platform: bản **tự làm để hiểu bên trong**, mỗi bài một thư mục.

## Bối cảnh

Cái chạy thật ở stg, prd và CI (đường chính, theo chuẩn ngành) nằm ở [svp-backend](https://github.com/anhnvcoder/svp-backend),
[svp-frontend](https://github.com/anhnvcoder/svp-frontend), [svp-gitops](https://github.com/anhnvcoder/svp-gitops) và
[svp-infra](https://github.com/anhnvcoder/svp-infra), không ở đây. Mỗi bài dựng một lần, so với bản chuẩn của ngành, kết luận ghi vào ADR của
`svp-backend`, và không bảo trì tiếp.

Repo public: chỉ script, test và README, không `.env`, không output thật.

## Cài đặt

```sh
git clone https://github.com/anhnvcoder/svp-labs.git
cd svp-labs
```

Lệnh kiểm cần Docker và `make`; bài có Go cần thêm Go đúng dòng `go` trong `go.mod` của bài. Công cụ khác (AWS CLI cho buổi chạy) nêu ở
README của bài.

## Sử dụng

README của mỗi bài nói cách chạy lại. Kiểm tĩnh repo, không chạm cloud:

```sh
make check                    # mọi lệnh kiểm dưới đây
make docs-check               # markdownlint-cli2 và lychee --offline trên mọi .md
make tf-check DIRS=<bài>      # fmt, validate, tflint, trivy, terraform test với provider giả
make go-test                  # gofmt, go vet, go test -race
make shellcheck DIRS=<bài>    # shellcheck trên scripts/*.sh
make help                     # liệt kê target
```

## Các bài lab

| Bài | Hỏi gì | Kết luận ở |
| --- | --- | --- |
| [`dora/`](https://github.com/anhnvcoder/svp-labs/tree/main/dora) | Năm chỉ số DORA tính được từ bản ghi Deployment `stg` của `svp-gitops` không (bản đóng băng của `dora.sh`) | [ADR-0028](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0028-dora-metrics.md), bị [ADR-0037](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0037-mainpath-standard-tools.md) thay |
| [`attest-spike/`](https://github.com/anhnvcoder/svp-labs/tree/main/attest-spike) | Kyverno có xác minh được provenance của `actions/attest` (Sigstore bundle) không, và một policy nhận cả định dạng cũ lẫn mới được không | [ADR-0040](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0040-sigstore-bundle-actions-attest.md) |
| [`bundle-spike/`](https://github.com/anhnvcoder/svp-labs/tree/main/bundle-spike) | Một bản phát hành keyless toàn Sigstore bundle qua template thật `svp-policy` được không, và rescan `vuln` hằng ngày làm gì với bundle | [ADR-0040](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0040-sigstore-bundle-actions-attest.md) |
| [`reusable-spike/`](https://github.com/anhnvcoder/svp-labs/tree/main/reusable-spike) | Reusable workflow hay composite action thay được checkout ghim script của repo khác không | [ADR-0040](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0040-sigstore-bundle-actions-attest.md) |
| [`drills/`](https://github.com/anhnvcoder/svp-labs/tree/main/drills) | Diễn tập k8s đo một lần (KEDA, PDB, canary, DR Postgres, thời gian giao hàng, quan sát web), diễn tập compose (kill worker, event trùng, breaker, rate limit, upload bỏ dở, cảnh báo tới GlitchTip, game day, đo `READY` và độ tươi feed) và kịch bản runner của `verify.yml` (bản đóng băng, cách chạy lại ở commit ghim) | [ADR-0039](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0039-mainpath-drills-scan-gate-sourcemaps.md), [ADR-0050](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0050-bash-to-standard-tools.md) (diễn tập compose) |
| [`multi-account-networking/`](https://github.com/anhnvcoder/svp-labs/tree/main/multi-account-networking) | Gói tin giữa VPC của nhiều account qua Transit Gateway đi đường nào, prd và non-prd có tách thật không, NAT và DNS riêng dùng chung thế nào, tốn bao nhiêu; hybrid: on-prem qua Site-to-Site VPN tới env nào, PrivateLink có nối được hai account bị tách không | — |
| [`serverless-variant/`](https://github.com/anhnvcoder/svp-labs/tree/main/serverless-variant) | Lượt xem và điều phối transcode làm bằng dịch vụ serverless (API Gateway, SQS, Lambda, DynamoDB, S3, EventBridge, Step Functions) thì được và mất gì so với EKS: độ trễ, đúng một lần, đường lỗi, chi phí mỗi triệu event | — |
| [`multi-region-dr/`](https://github.com/anhnvcoder/svp-labs/tree/main/multi-region-dr) | Mất cả region chính, tầng dữ liệu phục vụ lại ở region thứ hai sau bao lâu (RTO) và mất bao nhiêu dữ liệu (RPO), khi dùng read replica chéo region so với restore từ backup đã sao sang region kia | — |
| [`dms-migration/`](https://github.com/anhnvcoder/svp-labs/tree/main/dms-migration) | Chuyển database từ PostgreSQL tự quản sang RDS bằng DMS thì full load mất bao lâu, CDC trễ bao nhiêu, cutover dừng ghi bao lâu, và bước nào chiếm phần lớn downtime | — |
| [`data-scaling/`](https://github.com/anhnvcoder/svp-labs/tree/main/data-scaling) | Aurora và RDS PostgreSQL có read replica dưới tải ghi đều thì replica trễ bao nhiêu và failover làm client lỗi bao lâu; RDS Proxy làm database thấy bao nhiêu kết nối và tốn bao nhiêu; Valkey cluster mode bật so với tắt thì client thấy gì, reshard và failover lỗi bao lâu; chia đọc ghi ở client có giảm p95 không; partition `timeline` so với `DELETE` theo lô và `DETACH` khi dọn dữ liệu | — |

## Đóng góp

Quy ước chung (ngôn ngữ, tài liệu, ADR, Git, repo public) ở
[`CONTRIBUTING.md`](https://github.com/anhnvcoder/.github/blob/main/CONTRIBUTING.md) của `anhnvcoder/.github`; luật riêng của repo ở
[`AGENTS.md`](AGENTS.md). Mọi thay đổi vào `main` đi qua pull request có check `docs` xanh.

## Giấy phép

[Apache-2.0](LICENSE).
