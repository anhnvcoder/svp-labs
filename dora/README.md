# Lab `dora/` — năm chỉ số DORA tính từ bản ghi triển khai

Bản **đóng băng** của `dora.sh` và `dora-test.sh`, chép nguyên văn (không sửa) từ `anhnvcoder/svp-backend` ở commit
`344da5f7a602e74c5c02efdafb3e25064fea2e1c` (`origin/main`, đường `deploy/ci/dora.sh`, `deploy/ci/dora-test.sh`). Dựng một lần, không bảo trì:
sửa ở đây là sửa bản học, không phải bản chạy ở stg hay prd.

## Bài lab tính gì

Năm chỉ số giao phần mềm của DORA cho môi trường `stg` của lab: deployment frequency, change lead time, change fail rate, failed deployment
recovery time, deployment rework rate. Không xếp hạng (elite, high...), chỉ số thiếu mẫu ghi "chưa đủ dữ liệu", prd ghi "chưa có dữ liệu".

Dữ liệu vào, chỉ đọc:

- **Bản ghi Deployment `stg` của `svp-gitops`** (`success`, do bot promote tạo, payload là bộ bảy `repository@digest` kèm `deployed_at`, lượt
  `verify.yml` đã chạy): bằng chứng một bản đã chạy ở stg, không phải merge. Nhiều bản ghi cùng (revision, bộ digest) là một deployment.
- **Lịch sử git** của `svp-backend`, `svp-gitops` và (khi bản ghi có web của `svp-frontend`) `svp-frontend`: mỗi commit đổi thứ stg chạy là một
  thay đổi, một mẫu lead time lấy ở deployment sớm nhất chứa nó (`deployed_at` trừ ngày commit).
- **Front matter của `docs/postmortems/` của `svp-backend`**: `env`, `deployment`, `started_at`, `restored_at`, `fix_commits`, cho failure và recovery.

Định nghĩa đầy đủ ở comment đầu `dora.sh`; lý do chọn và cách đọc số ở ADR-0028 của `svp-backend` (đã bị ADR-0037 thay: DORA rời đường chính).

## Vì sao rời đường chính

stg của lab dựng rồi xoá trong mỗi lượt `verify.yml`, không có môi trường sống lâu. Số DORA tính trên đó đo nhịp của các lượt dựng/xoá nhiều
hơn đo giao hàng; chính `dora.sh` gắn nhãn "stg lab" ở mọi số. Cái chạy thật là đường chính nên không giữ một bộ script 1 000 dòng và một
workflow để ra số không có ý nghĩa giao hàng. Khi có môi trường prd chạy lâu dài thì dùng công cụ chuẩn của ngành (Apache DevLake); bài lab này
là bản tự làm để hiểu định nghĩa từng chỉ số và chỗ dữ liệu làm số sai lệch.

## Chạy lại

Script không đứng một mình: nó nạp `deploy/ci/common.sh`, `deploy/ci/platform.sh`, `deploy/k8s/lib.sh` của `svp-backend` ở đúng commit trên. Nên chạy
từ một bản clone `svp-backend` đã checkout commit ghim, không từ thư mục này:

```sh
D=$(mktemp -d)
git clone https://github.com/anhnvcoder/svp-backend.git "$D/svp-backend"
git -C "$D/svp-backend" checkout 344da5f7a602e74c5c02efdafb3e25064fea2e1c
cd "$D/svp-backend"

# 1. Test của script, không mạng
deploy/ci/dora-test.sh                      # cuối cùng in "all checks passed"

# 2. Tính số thật: chế độ local, chỉ đọc
git clone https://github.com/anhnvcoder/svp-gitops.git "$D/gitops"
SVP_GITOPS_DIR="$D/gitops" deploy/ci/dora.sh --days 30 "$D/dora.json"
```

Bước 2 cần `gh` đã đăng nhập (đọc bản ghi Deployment và lượt chạy qua API), `jq`, `git`, bản clone `svp-gitops` (đủ lịch sử, có `origin/main`) và,
khi bản ghi có web, bản clone `svp-frontend` ở `SVP_WEB_DIR`. Chỉ in bảng Markdown ra terminal và ghi JSON vào `<file>`; script không fetch gì,
đọc `origin/main` như lần fetch cuối. Output thật (bảng, JSON, bản ghi) **không** chép vào repo này (public).

Lưu ý: ở commit ghim `dora.sh` còn thuộc `svp-backend`; ADR-0037 đưa nó ra khỏi đường chính của repo đó, nên checkout đúng SHA, không dùng `main`.

## Bước sau (không làm ở đây)

So với Apache DevLake trên cùng dữ liệu, kết luận ghi vào ADR của `svp-backend`.
