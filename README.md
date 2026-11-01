# svp-labs

Đường học của lab short-video-platform: bản **tự làm để hiểu bên trong**, mỗi bài một thư mục. Cái chạy thật ở stg, prd và CI (đường chính, theo chuẩn ngành)
nằm ở `svp-backend`, `svp-frontend`, `svp-gitops`, `svp-infra`, không ở đây.

Quy ước mỗi bài: dựng một lần, so với bản chuẩn của ngành, kết luận ghi vào ADR của `svp-backend`, không bảo trì tiếp. Repo public: chỉ script, test và README,
không `.env`, không output thật.

| Bài | Nội dung | Trạng thái |
| --- | --- | --- |
| [`dora/`](dora/README.md) | Năm chỉ số DORA tính từ bản ghi Deployment `stg` của `svp-gitops`, bản đóng băng của `dora.sh` (đã rời đường chính) | Đã dựng; so với Apache DevLake: chưa làm |
| [`attest-spike/`](attest-spike/README.md) | Kyverno (bản lab ghim) có xác minh được provenance của `actions/attest` (Sigstore bundle), và một policy nhận cả định dạng cũ lẫn mới không | Đã thử bằng Kyverno CLI; kết luận: chuyển phải gồm chữ ký, `vuln`, provenance trong một bản phát hành |
