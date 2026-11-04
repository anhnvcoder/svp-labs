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

Mỗi bài tự nêu công cụ nó cần ở README của bài. Lệnh kiểm tài liệu cần Docker và `make`.

## Sử dụng

README của mỗi bài nói cách chạy lại. Kiểm tài liệu của repo:

```sh
make docs-check   # markdownlint-cli2 và lychee --offline trên mọi .md
make help         # liệt kê target
```

## Các bài lab

| Bài | Hỏi gì | Kết luận ở |
| --- | --- | --- |
| [`dora/`](https://github.com/anhnvcoder/svp-labs/tree/main/dora) | Năm chỉ số DORA tính được từ bản ghi Deployment `stg` của `svp-gitops` không (bản đóng băng của `dora.sh`) | [ADR-0028](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0028-dora-metrics.md), bị [ADR-0037](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0037-mainpath-standard-tools.md) thay |
| [`attest-spike/`](https://github.com/anhnvcoder/svp-labs/tree/main/attest-spike) | Kyverno có xác minh được provenance của `actions/attest` (Sigstore bundle) không, và một policy nhận cả định dạng cũ lẫn mới được không | [ADR-0040](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0040-sigstore-bundle-actions-attest.md) |
| [`bundle-spike/`](https://github.com/anhnvcoder/svp-labs/tree/main/bundle-spike) | Một bản phát hành keyless toàn Sigstore bundle qua template thật `svp-policy` được không, và rescan `vuln` hằng ngày làm gì với bundle | [ADR-0040](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0040-sigstore-bundle-actions-attest.md) |
| [`reusable-spike/`](https://github.com/anhnvcoder/svp-labs/tree/main/reusable-spike) | Reusable workflow hay composite action thay được checkout ghim script của repo khác không | [ADR-0040](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0040-sigstore-bundle-actions-attest.md) |
| [`drills/`](https://github.com/anhnvcoder/svp-labs/tree/main/drills) | Diễn tập k8s đo một lần (KEDA, PDB, canary, DR Postgres, thời gian giao hàng, quan sát web) và kịch bản runner của `verify.yml` (bản đóng băng, cách chạy lại ở commit ghim) | [ADR-0039](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0039-mainpath-drills-scan-gate-sourcemaps.md) |

## Đóng góp

Quy ước chung (ngôn ngữ, tài liệu, ADR, Git, repo public) ở
[`CONTRIBUTING.md`](https://github.com/anhnvcoder/.github/blob/main/CONTRIBUTING.md) của `anhnvcoder/.github`; luật riêng của repo ở
[`AGENTS.md`](AGENTS.md). Mọi thay đổi vào `main` đi qua pull request có check `docs` xanh.

## Giấy phép

[Apache-2.0](LICENSE).
