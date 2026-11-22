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
make diagrams-check           # SVG đã commit ở docs/diagrams/ khớp nguồn .d2
make inventory-check          # trang inventory của năm lab SAP và sơ đồ của nó khớp plan với provider giả
make help                     # liệt kê target
```

Lệnh `terraform` của buổi chạy thật chạm account AWS, do người học chạy, theo khuôn ở
[`docs/terraform-commands.md`](docs/terraform-commands.md).

## Các bài lab

### Lab SAP

Năm lab dựng trên account AWS của người học để có số đo cho đề SAP-C03, xếp theo thứ tự chạy gợi ý. Phí, thời gian chép từ bảng tóm
tắt đầu README của từng lab, nơi có cách tính và nguồn; thời gian là ước tính, chưa đo.

| # | Bài | Hỏi gì | Phí (USD mỗi giờ khi dựng; mỗi buổi) | Thời gian (một buổi) |
| --- | --- | --- | --- | --- |
| 1 | [`serverless-variant`][sv] | Hai luồng svp làm serverless: được, mất gì so với EKS | Theo lượng dùng, trần ~1,4; ~0,2 | ~70 phút |
| 2 | [`dms-migration`][dms] | DMS sang RDS: full load, CDC trễ, cutover dừng ghi bao lâu | ~0,091; ~0,33 (buổi 3 giờ) | ~1 giờ 45 |
| 3 | [`multi-region-dr`][dr] | Mất region chính: RTO, RPO của pilot light so với backup | ~0,080; ~0,9 (buổi 3 giờ) | ~3 giờ |
| 4 | [`data-scaling`][ds] | Mở rộng quá một RDS instance | ~0,415, ~0,143–0,181; ≤ 1,23, ≤ 0,37 | ≈ 2 giờ, ≈ 67 phút |
| 5 | [`multi-account-networking`][net] | prd tách non-prd thật không; NAT, DNS dùng chung | ~1,12, ~1,80; ~3,97, ~6,2 | ~3 giờ |

- `data-scaling` có hai root chạy ở hai buổi riêng; mỗi ô phí, thời gian ghi `postgres/` trước, `valkey/` sau. Phần local
  `scripts/partition.sh` không dùng AWS: phí 0, ~10 phút.
- `multi-account-networking`: ô phí ghi lõi (root `core`) trước, cả hybrid (`core` cùng `hybrid`) sau, buổi 3 giờ. Account
  `svp-network` để không tốn thêm ~2,2 USD mỗi tháng.

Vì sao thứ tự này:

- Không lab nào là điều kiện trước của lab khác: mục `Điều kiện trước` của cả năm ghi không cần lab chạy trước. Thứ tự vì vậy đi từ
  rẻ, ngắn tới đắt, dài: buổi đầu làm quen [khuôn lệnh](docs/terraform-commands.md) và thư mục buổi với phí nhỏ nhất.
- Bốn lab đầu chỉ cần account `svp-stg` và profile `anhnv-stg` của `svp-infra`. `multi-account-networking` cần thêm account
  `svp-network`, tạo một lần ở bước 0 (root `account`), sống qua các buổi và tốn phí cả khi để không. Chạy nó cuối để account sống
  ngắn nhất; đóng account khi bài không còn buổi nào.
- Trong `multi-account-networking`: `account` (một lần), rồi `core`, rồi `hybrid`, vì `hybrid` tra tài nguyên của `core`; gỡ
  `hybrid` trước `core`.
- Trong `data-scaling`: `postgres/` và `valkey/` không đọc tài nguyên của nhau, nên hai buổi chạy theo thứ tự nào cũng được.

### Bài đóng băng

Dựng một lần, kết luận đã ghi vào ADR của `svp-backend`, không bảo trì tiếp.

| Bài | Hỏi gì | Kết luận ở |
| --- | --- | --- |
| [`dora`][dora] | Năm chỉ số DORA tính được từ bản ghi Deployment `stg` không | [ADR-0028][adr-0028], bị [ADR-0037][adr-0037] thay |
| [`attest-spike`][attest] | Kyverno có xác minh được provenance `actions/attest` (Sigstore bundle) không | [ADR-0040][adr-0040] |
| [`bundle-spike`][bundle] | Bản keyless toàn Sigstore bundle có qua Kyverno không; rescan `vuln` làm gì | [ADR-0040][adr-0040] |
| [`reusable-spike`][reusable] | Reusable workflow hay composite action thay checkout ghim script của repo khác | [ADR-0040][adr-0040] |
| [`drills`][drills] | Diễn tập k8s, compose, kịch bản runner `verify.yml`, đo một lần | [ADR-0039][adr-0039], [ADR-0050][adr-0050] |

[sv]: serverless-variant/
[dms]: dms-migration/
[dr]: multi-region-dr/
[ds]: data-scaling/
[net]: multi-account-networking/
[dora]: dora/
[attest]: attest-spike/
[bundle]: bundle-spike/
[reusable]: reusable-spike/
[drills]: drills/
[adr-0028]: https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0028-dora-metrics.md
[adr-0037]: https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0037-mainpath-standard-tools.md
[adr-0039]: https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0039-mainpath-drills-scan-gate-sourcemaps.md
[adr-0040]: https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0040-sigstore-bundle-actions-attest.md
[adr-0050]: https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0050-bash-to-standard-tools.md

## Đóng góp

Quy ước chung (ngôn ngữ, tài liệu, ADR, Git, repo public) ở
[`CONTRIBUTING.md`](https://github.com/anhnvcoder/.github/blob/main/CONTRIBUTING.md) của `anhnvcoder/.github`; luật riêng của repo ở
[`AGENTS.md`](AGENTS.md). Mọi thay đổi vào `main` đi qua pull request có check `docs` xanh.

## Giấy phép

[Apache-2.0](LICENSE).
