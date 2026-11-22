# svp-labs — đường học của lab short-video-platform: hướng dẫn cho agent

File này theo định dạng [AGENTS.md](https://agents.md): luật làm việc cho mọi agent.

Đọc trước: [`README.md`](README.md) (danh sách bài). Thiết kế và quyết định chung của lab nằm ở `docs/` của repo code (bản clone
`<workspace>/backend`); kết luận của mỗi bài ghi vào ADR ở đó.

## Quy ước

Quy ước chung (ngôn ngữ, tài liệu timeless, ADR, comment, Git, repo public, phụ thuộc): [`CONTRIBUTING.md` của `anhnvcoder/.github`](https://github.com/anhnvcoder/.github/blob/main/CONTRIBUTING.md); dưới đây chỉ luật riêng của repo này.

- **Bài lab:** mỗi bài một thư mục có `README.md` riêng (câu hỏi bài trả lời, thiết kế, cách chạy). Mục kết luận chỉ thêm sau buổi
  chạy, cùng ADR ở repo code. Dựng một lần, so với bản chuẩn của ngành, không bảo trì tiếp; đường chính (cái chạy ở stg, prd, CI) không
  nằm ở repo này.
- **Bố cục bài có Terraform:** `README.md` là cửa vào, trang giải thích ở `docs/*.md`. Root Terraform là thư mục `*.tf` không nằm dưới
  `modules/`: có khối provider, `allowed_account_ids`, `default_tags`, không khối backend (state local, không commit), commit
  `.terraform.lock.hcl` bằng `make lock`. Module ở `modules/<phần>/`: chỉ provider `aws` mặc định, có `tests/*.tftest.hcl`, không gọi
  module khác (root ghép module), không module registry. Script ở `scripts/*.sh`, kèm `*-test.sh` chạy với lệnh giả trên `PATH`. Giá trị
  mẫu ở `<root>/<tên>.auto.tfvars.example`; file không commit theo `.gitignore`. Sơ đồ kiến trúc của bài ở
  `docs/diagrams/<bài>/<tên>.d2` cùng hai SVG sinh ra, nhúng vào README bằng `<picture>`
  ([`docs/diagrams/README.md`](docs/diagrams/README.md)).
  Bản văn bản của plan trong buổi chỉ ghi vào thư mục buổi `.session/<bài>-<giờ UTC>/` ở gốc repo (`SVP_LAB_SESSION_DIR`, git bỏ qua).
- **Ngôn ngữ viết:** file `.md` viết tiếng Việt.
- **Repo public:** chỉ script, test và README; không `.env`, không output thật.
- **Git:** mọi thay đổi vào `main` đi qua PR có check bắt buộc xanh.

## Lệnh kiểm

Mọi lệnh chạy từ gốc repo qua `Makefile`; `make help` liệt kê target.

- `make docs-check`: markdownlint-cli2 và lychee `--offline` trên mọi `.md` (trừ phần chép của repo khác ở `drills/svp-backend/`,
  `drills/svp-frontend/`), từ image ghim digest, không mạng, cần Docker. Thu hẹp: `make docs-check DOCS='<file hay glob>'`. CI chạy
  cùng lệnh ở job `docs` của `.github/workflows/docs.yml`.
- `make diagrams`: sinh mỗi `docs/diagrams/<bài>/*.d2` thành `<tên>.svg` (sáng) và `<tên>-dark.svg` (tối) cạnh nguồn, D2 từ image ghim
  digest, không mạng. Thu hẹp: `NAMES='<bài>'` hay `NAMES='<bài>/<tên>'`; `PNG=1` thêm PNG để xem (không commit). Cách viết sơ đồ:
  [`docs/diagrams/README.md`](docs/diagrams/README.md).
- `make diagrams-check`: sinh vào thư mục tạm, đỏ và nêu file khi SVG đã commit lệch `.d2`, thiếu, hay không còn `.d2` cùng tên;
  `inventory/`, `icons/` không thuộc nó. CI chạy cùng lệnh ở job `docs`.
- `make inventory`: sinh trang `<bài>/docs/inventory.md` của năm bài SAP và sơ đồ `docs/diagrams/inventory/` từ plan của `terraform test`
  trên provider giả (bộ sinh `scripts/inventory.sh`, mock ở `scripts/inventory/`), cần `jq`. Không sửa tay các file đó.
- `make inventory-check`: sinh vào thư mục tạm, đỏ và nêu file khi trang hay sơ đồ đã commit lệch, thiếu hay thừa. CI chạy cùng lệnh ở
  job `terraform` của `.github/workflows/labs.yml`.
- `make check`: `docs-check`, `diagrams-check`, `inventory-check`, `test-guard`, `tf-check`, `go-test`, `shellcheck`, `script-test` trên
  cả repo; `lock`, `lambda-build`, `diagrams`, `inventory` không nằm trong `check`.
- `make tf-check`: `fmt-check`, `validate`, `tflint`, `trivy`, `test` trên mọi thư mục `*.tf`; mỗi target cũng chạy riêng. Thu hẹp:
  `DIRS='<thư mục> …'`, mỗi mục là mọi thư mục `*.tf` bên dưới nó. `make fmt` ghi lại định dạng. trivy: HIGH, CRITICAL làm đỏ; ngoại lệ
  chỉ bằng `#trivy:ignore:<id>` ngay trên resource, lý do ở comment.
- `make lock DIRS=<thư mục>`: ghi `.terraform.lock.hcl` của mọi root bên dưới cho các nền tảng ở `LOCK_PLATFORMS` của `Makefile`.
- Provider Terraform và ruleset tflint nằm ở `.plugin-cache/` (gitignore), mỗi version tải một lần, dùng chung cho mọi thư mục
  (provider AWS giải nén ra hàng trăm MB). `init` dùng bản đã có, kể cả khi module chưa có lock file, chỉ thêm version còn thiếu, lần
  lượt (khoá `.plugin-cache/lock`), nên các lần chạy khác `DIRS` vẫn song song được. Cache giữ mọi version từng tải: xoá
  `.plugin-cache/` cùng lock file của module (`**/modules/**/.terraform.lock.hcl`, gitignore) khi không có `make` nào chạy, để lấy lại
  đĩa hay sửa một bản giải nén dở.
- `make test-guard`: tự thử luật của `make test` với `docker` giả, trên module tạm ở `.test-guard/` (xoá khi xong).
- `make go-test`: `gofmt -l`, `go vet`, `go test -race` trên mỗi `go.mod` (ngoài `drills/`), Go của máy. Thu hẹp: `DIRS=…`.
- `make lambda-build`: build mỗi `serverless-variant/functions/cmd/<tên>/` thành `serverless-variant/build/<tên>/bootstrap`
  (linux arm64).
- `make shellcheck`: shellcheck trên mọi `*/scripts/*.sh`. Thu hẹp: `DIRS=…` hay `SH='<file> …'`.
- `make script-test`: chạy mọi `*/scripts/*-test.sh` (ngoài `drills/`), dừng ở test đỏ đầu tiên và in tên nó. Thu hẹp: `DIRS=…`.

Các target Terraform và shellcheck chạy từ image ghim digest, cần Docker; `go-test`, `lambda-build` cần Go. CI chạy chúng ở workflow
`labs` (`.github/workflows/labs.yml`).

## An toàn cloud

- **AI không chạy lệnh nào chạm account AWS, kể cả chỉ đọc:** `aws` (trừ `--version`), `terraform init` có backend, `plan`, `apply`,
  `destroy`, `import`, `state`, `output`, `refresh`, script hay chương trình dùng SDK AWS, script buổi của bài.
- **`terraform test` chỉ qua `make test` hay `make inventory`, `make inventory-check`:** container ghim digest, không biến `AWS_*`, mọi
  `run` là `command = plan`. AI không chạy `terraform test` trần.
  - `make test`: `--network none`, chỉ mount thư mục module và cache provider (cả hai read-only; provider trong thư mục dữ liệu là symlink
    vào cache), mỗi file test có đúng một `mock_provider "aws"`.
  - Bộ sinh inventory: plan trên bản chép tạm các file git theo dõi của năm bài SAP, không file cá nhân (`*.auto.tfvars`, `.envrc`,
    state, plan, backend, `*_override.tf`, `.session/`); chỉ `init` có mạng, lượt test `--network none`, bản chép mount read-only. Mock
    `scripts/inventory/<slug>.tftest.hcl` có một `mock_provider` cho mỗi provider root khai báo, cả alias. Provider giả không trả được
    khối `ephemeral`, nên bản chép bỏ các khối đó và `scripts/inventory/<slug>.override.hcl` (chỉ đối số module và `locals`) đặt giá
    trị giả vào đúng những chỗ đọc chúng (bộ sinh đỏ khi thừa hay thiếu một chỗ); không tài nguyên nào được thêm, bớt hay đổi.
- **Lệnh buổi do người học chạy:** README của bài viết sẵn từng bước, mỗi lệnh ghi profile và `--region`, nói rõ output cần dán lại;
  lệnh `terraform` theo khuôn của [`docs/terraform-commands.md`](docs/terraform-commands.md) (`-input=false`, `plan -out`, `show` ra thư
  mục buổi, `apply` đúng file plan). Buổi gỡ bằng `plan -destroy` theo cùng khuôn rồi apply file đó (không `terraform destroy` trần), và
  kết thúc bằng lệnh quét tài nguyên sót.
