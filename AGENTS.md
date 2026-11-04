# svp-labs — đường học của lab short-video-platform: hướng dẫn cho agent

File này theo định dạng [AGENTS.md](https://agents.md): luật làm việc cho mọi agent.

Đọc trước: [`README.md`](README.md) (danh sách bài). Thiết kế và quyết định chung của lab nằm ở `docs/` của repo code (bản clone
`<workspace>/backend`); kết luận của mỗi bài ghi vào ADR ở đó.

## Quy ước

Quy ước chung (ngôn ngữ, tài liệu timeless, ADR, comment, Git, repo public, phụ thuộc): [`CONTRIBUTING.md` của `anhnvcoder/.github`](https://github.com/anhnvcoder/.github/blob/main/CONTRIBUTING.md); dưới đây chỉ luật riêng của repo này.

- **Bài lab:** mỗi bài một thư mục có `README.md` riêng (mục tiêu, cách chạy, kết luận). Dựng một lần, so với bản chuẩn của ngành, không
  bảo trì tiếp; đường chính (cái chạy ở stg, prd, CI) không nằm ở repo này.
- **Ngôn ngữ viết:** file `.md` viết tiếng Việt.
- **Repo public:** chỉ script, test và README; không `.env`, không output thật.
- **Git:** mọi thay đổi vào `main` đi qua PR có check bắt buộc xanh.

## Lệnh kiểm

Mọi lệnh chạy từ gốc repo qua `Makefile`; `make help` liệt kê target.

- `make docs-check`: markdownlint-cli2 và lychee `--offline` trên mọi `.md` (trừ phần chép của repo khác ở `drills/svp-backend/`,
  `drills/svp-frontend/`), từ image ghim digest, không mạng, cần Docker. Thu hẹp: `make docs-check DOCS='<file hay glob>'`. CI chạy
  cùng lệnh ở job `docs` của `.github/workflows/docs.yml`.
