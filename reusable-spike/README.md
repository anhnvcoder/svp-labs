# reusable-spike: reusable workflow hay composite action thay cho checkout ghim script của repo khác

Spike một lần. CI của `svp-frontend` chạy `deploy/ci/*.sh` của `svp-backend` từ một checkout ghim (`.backend/`, commit ở `.backend-commit`). Hai
cách chuẩn của GitHub để bỏ checkout đó: **reusable workflow** (`on: workflow_call`, gọi bằng `uses: owner/repo/.github/workflows/x.yml@<sha>`)
và **composite action** (`uses: owner/repo/.github/actions/x@<sha>`). Bài này thử cả hai trong `svp-labs`, gọi bằng đường đầy đủ
`anhnvcoder/svp-labs/...@<sha>` như một repo khác sẽ gọi, rồi đọc identity ký và thử Kyverno.

**Trạng thái: workflow đã viết, chưa chạy. Mọi dòng dưới đây "chưa kiểm" cho tới khi có lượt `reusable-spike-caller`.**

## Câu hỏi

1. Reusable workflow ký keyless (`cosign sign`, `cosign attest --type vuln`, định dạng Sigstore bundle) và `actions/attest` provenance: SAN của
   chứng chỉ Fulcio, các extension (Build Signer URI, Build Config URI, Source Repository URI, workflow ref/sha); `builder.id`,
   `externalParameters.workflow.repository` của provenance.
2. Workflow được gọi biết commit của chính nó (để checkout script đúng bản ghim) bằng gì: ngữ cảnh `github.*`, `job`; claim `job_workflow_ref`,
   `job_workflow_sha` của token OIDC; hay input lặp lại `@<sha>`.
3. Kyverno CLI v1.19.1: `ImageValidatingPolicy` có buộc được image của repo gọi A (không phải repo gọi B) khi cả hai ký dưới cùng SAN của reusable
   workflow, ở cả ba phép chữ ký, `vuln`, provenance.
4. Composite action gọi bằng `@<sha>`: runner tải cả repo ở commit đó không; SAN khi ký trong job dùng composite action.
5. `allowed_actions` của `svp-labs` có chặn gọi bằng đường đầy đủ của chính repo không.

Quy tắc kết luận (đặt trước khi chạy): **reusable workflow** nếu (2) có cách ghim không lặp `sha` và (3) tách được nguồn ở cả ba phép với Kyverno
v1.19.1; không thì **composite action**.

## File

| File | Là gì |
| --- | --- |
| `../.github/workflows/reusable-spike-caller.yml` | Caller, chỉ `workflow_dispatch`: job `reusable` gọi workflow được gọi, job `composite` dùng composite action, cả hai ở cùng commit `@<sha>` |
| `../.github/workflows/reusable-spike-called.yml` | Reusable workflow: in ngữ cảnh và claim OIDC (chỉ payload), checkout repo của chính nó ở `job_workflow_sha`, chạy `release.sh` từ đó, `actions/attest` |
| `../.github/actions/reusable-spike/action.yml` | Composite action: in cái runner tải về (`$GITHUB_ACTION_PATH/../../..`), claim OIDC, chạy `release.sh` từ bản tải về, `actions/attest` |
| `release.sh` | Thay cho `deploy/ci/*.sh`: in `script_root`, `code_root` và commit của mỗi cái; build cây của caller, push, `cosign sign`, `cosign attest --type vuln` định dạng bundle |
| `image/` | Image `FROM scratch` nhỏ; label `spike.path` (`reusable`, `composite`) cho hai digest dưới package `ghcr.io/anhnvcoder/svp-labs/reusable-spike` |

## Chạy

Caller ghim workflow và action ở một commit **trước** commit ghi nó (`uses:` không nhận biểu thức), nên cần hai commit: commit 1 có mọi file với
chuỗi `CALLED_SHA` trong caller; commit 2 thay `CALLED_SHA` bằng SHA của commit 1. PR merge bằng merge commit (squash hay rebase tạo commit mới,
commit 1 không còn trên `main`). Sau merge: dispatch `reusable-spike-caller`, để package `reusable-spike` public, kết quả đọc ẩn danh trên máy.
