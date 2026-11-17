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
  mẫu ở `<root>/<tên>.auto.tfvars.example`; file không commit theo `.gitignore`.
- **Ngôn ngữ viết:** file `.md` viết tiếng Việt.
- **Repo public:** chỉ script, test và README; không `.env`, không output thật.
- **Git:** mọi thay đổi vào `main` đi qua PR có check bắt buộc xanh.

## Lệnh kiểm

Mọi lệnh chạy từ gốc repo qua `Makefile`; `make help` liệt kê target.

- `make docs-check`: markdownlint-cli2 và lychee `--offline` trên mọi `.md` (trừ phần chép của repo khác ở `drills/svp-backend/`,
  `drills/svp-frontend/`), từ image ghim digest, không mạng, cần Docker. Thu hẹp: `make docs-check DOCS='<file hay glob>'`. CI chạy
  cùng lệnh ở job `docs` của `.github/workflows/docs.yml`.
- `make check`: `docs-check`, `test-guard`, `tf-check`, `go-test`, `shellcheck`, `script-test` trên cả repo; `lock` và `lambda-build`
  không nằm trong `check`.
- `make tf-check`: `fmt-check`, `validate`, `tflint`, `trivy`, `test` trên mọi thư mục `*.tf`; mỗi target cũng chạy riêng. Thu hẹp:
  `DIRS='<thư mục> …'`, mỗi mục là mọi thư mục `*.tf` bên dưới nó. `make fmt` ghi lại định dạng. trivy: HIGH, CRITICAL làm đỏ; ngoại lệ
  chỉ bằng `#trivy:ignore:<id>` ngay trên resource, lý do ở comment.
- `make lock DIRS=<thư mục>`: ghi `.terraform.lock.hcl` của mọi root bên dưới cho các nền tảng ở `LOCK_PLATFORMS` của `Makefile`.
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
- **`terraform test` chỉ qua `make test`:** container ghim digest, `--network none`, không biến `AWS_*`, chỉ mount thư mục module, mỗi
  file test có đúng một `mock_provider "aws"` và mọi `run` là `command = plan`. AI không chạy `terraform test` trần.
- **Lệnh buổi do người học chạy:** README của bài viết sẵn từng bước, mỗi lệnh ghi profile và `--region`, nói rõ output cần dán lại.
  Buổi kết thúc bằng `terraform destroy` và lệnh quét tài nguyên sót.
