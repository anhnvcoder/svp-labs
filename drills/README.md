# Lab `drills/`: diễn tập đo một lần và kịch bản runner của `verify.yml`

Bản **đóng băng** của các diễn tập k8s, kịch bản runner và manifest cluster cloud đã rời đường chính theo ADR-0039 của `svp-backend`. Mọi file
chép nguyên văn (không sửa), giữ cây thư mục gốc:

- `svp-backend/…` từ `anhnvcoder/svp-backend` ở commit `c213110f017f35e562228b5f16f86a009ad4941d` (`origin/main` trước khi các file này bị xoá);
- `svp-frontend/e2e/canary/clients.ts` (client trình duyệt của canary web) từ `anhnvcoder/svp-frontend` ở commit
  `265f4905ef44daf6c78a323104dea38b8f174d6f` (`origin/main` cùng lúc).

Dựng một lần, không bảo trì: sửa ở đây là sửa bản học. Số đo và id lượt chạy là bằng chứng nằm ở ADR của `svp-backend` (bảng dưới), không chép
output thật vào repo này (public).

## Có gì ở đây

| Nhóm | File (dưới `svp-backend/`) |
| --- | --- |
| Diễn tập k8s | `deploy/k8s/drills/`: `keda.sh`, `pdb.sh`, `canary.sh`, `web-canary.sh`, `backup.sh`, `gitops.sh`, `web-obs.sh` |
| Kịch bản runner | `deploy/ci/verify/`: `dev-k3d.sh`, `web-canary.sh`, `k6-cloud-mini.sh`, `chaos.sh`, `velero.sh`, và `compose-obs.sh`, `gitops.sh` bản đầy đủ (đường chính giữ bản thu gọn); `deploy/ci/verify-run.sh`, `verify-sample.sh`, `verify-tempo.sh`; `.github/workflows/verify.yml` bản ba job (`compose`, `k3d`, `gitops`), bảy kịch bản |
| Source map của image CI | `deploy/ci/sourcemaps-image.sh`, `gitops-sourcemaps.sh` và test của hai script |
| Cluster cloud | `deploy/k8s/cloud/`: `chaos/` (thí nghiệm Chaos Mesh), `velero/`, `runner/` (overlay runner: CSI hostpath, Velero, Chaos Mesh), `values/`, `charts.json`, `check.sh` |

## Vì sao rời đường chính

Nguyên tắc của ADR-0037: đường chính chỉ giữ cái bảo vệ bản phát hành hay cái buổi AWS dùng. Đường chính vẫn giữ `smoke`,
`drill-k8s-supplychain`, `drill-k8s-threats`, `drill-obs-threats`, `traffic.sh`, `deploy/k6/`; `verify.yml` còn kịch bản `gitops` và
`compose-obs` thu gọn, cả hai chạy lịch tuần. Phần còn lại đã trả lời xong câu hỏi của nó:

- **KEDA và RAM** (`drill-k8s-keda`, RAM nghỉ, đỉnh): số đo dung lượng của laptop và runner (ADR-0017); EKS đo lại bằng k6 của buổi AWS.
- **PDB** (`drill-k8s-pdb`): chứng minh một lần (ADR-0031 §1); PodDisruptionBudget vẫn trong chart.
- **Canary** (`drill-k8s-canary`, `measure-canary`, `drill-k8s-web-canary`): chứng minh phân tích canary abort bản lỗi; Rollout, AnalysisTemplate
  vẫn trong chart.
- **DR Postgres** (`drill-k8s-backup`): DR CloudNativePG trên k3d (ADR-0020 §5); EKS dùng RDS; runbook `postgres-restore.md` giữ quy trình tay.
- **Thời gian giao hàng** (`measure-gitops`, bước chờ phát hành): cùng lý do DORA rời đường chính ở ADR-0037 §1.
- **Quan sát web trên cluster** (`drill-k8s-web-obs`, bước `gitops-sourcemaps`, `k8s-web-e2e` của kịch bản): e2e web chạy ở job `stack` của CI
  `svp-frontend`; `make k8s-web-e2e`, `k8s-web-sourcemaps` giữ là công cụ đường dev. Image `web-sourcemaps` và hai script của nó chỉ bước
  `gitops-sourcemaps` dùng, nên đi cùng (ADR-0039 §3).
- **Kịch bản runner** `dev-k3d`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero` và `verify-sample.sh`, `verify-tempo.sh`, chế độ runner của
  `deploy/k6/cloud/run.sh`: đo một lần, số ở ADR-0021, 0020, 0031.
- **Phần còn lại của `compose-obs`** (load-local và cảnh báo, Lighthouse ×3, `drill-duplicates`, `drill-kill-worker`, `drill-upload-cleanup`,
  `measure-upload` và RAM `s3`, `drill-alert-to-sentry`, `object-store-roundtrip`): script diễn tập compose vẫn ở `svp-backend`, chạy tay.
- **Manifest Chaos Mesh, Velero, overlay runner** dưới `deploy/k8s/cloud/`: Velero cho EKS (bảng chi phí ADR-0034) quyết lại ở việc 7b, lấy từ bài
  lab này.

## Mỗi diễn tập trả lời gì

Target là của `Makefile` `svp-backend` ở commit ghim. Id lượt là lượt `verify.yml` trên `anhnvcoder/svp-backend`
(`https://github.com/anhnvcoder/svp-backend/actions/runs/<id>`); "máy" là buổi k3d trên laptop, số ghi ở ADR.

| Target | Câu hỏi | ADR | Bằng chứng |
| --- | --- | --- | --- |
| `make drill-k8s-keda N=9` | media-worker scale ra 2 replica theo lag Kafka và về 1, mỗi video transcode đúng một lần kể cả khi scale down giữa job, k3s server không chết | 0017, 0021 | `dev-k3d` 40335732223; `gitops` 40801610039 |
| `make drill-k8s-pdb` | Drain hai node: PDB cho evict pod đầu (201), từ chối pod thứ hai (429) của gateway và feed-service | 0014, 0031 §1 | `dev-k3d` 40810781486 |
| `make drill-k8s-canary`, `make measure-canary` | Canary gateway dưới traffic: bản tốt qua 25/50/100 % và promote, bản lỗi bị phân tích abort, pod stable không đụng | 0014, 0021 (D18) | `dev-k3d` 40145677985 |
| `make drill-k8s-web-canary` | Canary web: promote, abort, 404 asset, số lần tải lại của client trình duyệt (cả tab cũ), tỷ lệ 409 của Server Action | 0019, 0021 (D6, D14, D18), 0033 | `web-canary` 40641057955 |
| `make drill-k8s-backup MODE=latest\|pitr` | Xoá Postgres `svp-pg` và volume, phục hồi cùng tên từ backup Barman Cloud; RTO, RPO đo thật | 0020 §5 | máy 2026-10-24 (ADR-0020 Kết quả); `dev-k3d` 40145677985, 40151447243 |
| `make measure-gitops REV=<commit>` | Thời gian từ push commit `svp-gitops` qua sync Argo CD tới pod đầu, pod cuối Ready với digest mới | 0014, 0021 | máy (ADR-0014 Kết quả); `gitops` 40801610039 |
| `make drill-k8s-web-obs` | Tempo có trace web + gateway, Prometheus có RUM (LCP, CLS, INP) nhãn route đóng, event GlitchTip có frame map về mã nguồn | 0019, 0021 (D5), 0031 | `dev-k3d` 40810781486; `gitops` 40801610039 |

| Kịch bản `verify.yml` | Câu hỏi | ADR | Lượt cuối |
| --- | --- | --- | --- |
| `dev-k3d` | Cluster dev đủ bước (smoke, threats, PDB, canary, source map, e2e, web-obs, KEDA, backup) trên runner 4 vCPU, trong ngân sách RAM | 0021, 0031 | 40810781486 |
| `web-canary` | Canary web dưới traffic diễn tập và client trình duyệt | 0021 | 40641057955 |
| `k6-cloud-mini` | Bản thu nhỏ của profile k6 `cloud`: mức pod cao nhất đạt trên runner (2 pod) | 0020, 0021, 0031 | 40810768238, 40820505634 |
| `chaos` | Ba thí nghiệm Chaos Mesh (pod-kill, network delay, lỗi Redpanda) và Tempo dưới tải không mất span | 0020, 0021, 0031 | 40810755085 |
| `velero` | Backup, restore namespace bằng Velero (CSI snapshot, đích object store trong cluster), Redpanda giữ offset | 0020, 0021 | 40620319661, 40626700272 |
| `gitops` (bản đầy đủ) | Cluster GitOps như stg: thêm source map của image CI, e2e GlitchTip, web-obs, KEDA ×2, chờ phát hành, `measure-gitops` | 0021 | 40801610039 |
| `compose-obs` (bản đầy đủ) | Stack compose `OBS=lgtm`: tải local và cảnh báo, Lighthouse, diễn tập upload, worker, cảnh báo tới GlitchTip | 0020, 0021, 0022 | 40207235062 |

## Chạy lại

Script không đứng một mình: chúng nạp `deploy/k8s/lib.sh`, `deploy/k8s/drills/lib.sh`, `deploy/ci/common.sh`, `deploy/ci/platform.sh`, dùng
`Makefile`, chart và values của `svp-backend` ở đúng commit ghim. Nên chạy từ một bản clone `svp-backend` đã checkout commit đó, không từ thư mục
này:

```sh
D=$(mktemp -d)
git clone https://github.com/anhnvcoder/svp-backend.git "$D/svp-backend"
git -C "$D/svp-backend" checkout c213110f017f35e562228b5f16f86a009ad4941d
git clone https://github.com/anhnvcoder/svp-gitops.git "$D/gitops"   # cấu hình triển khai, make k8s-up đọc ../gitops hay SVP_GITOPS_DIR
git -C "$D/gitops" checkout 5c6b826d8cdf8eeff0b6aa1edcfb95b989540376   # G: svp-gitops main cùng lúc với svp-backend B
cd "$D/svp-backend"
make env
make k8s-up
make k8s-smoke
make drill-k8s-pdb          # hay target khác ở bảng trên
```

Commit `svp-gitops` G (`5c6b826d8cdf8eeff0b6aa1edcfb95b989540376`) là `main` lúc `svp-backend` B được ghim. Ở B, `verify-run.sh` chạy
`make gitops-clone` (main) cho mọi kịch bản, và `make k8s-up` đọc `components.json` và `base/` của `../gitops`; clone không checkout G (ở HEAD) có thể cho số khác
với lượt ghi ở ADR. Lệnh `git -C "$D/gitops" checkout` ở trên ghim G để khớp B.

Canary web cần thêm bản clone `svp-frontend` ở commit ghim của nó (web build từ bản clone, client trình duyệt ở `e2e/canary/clients.ts`):

```sh
git clone https://github.com/anhnvcoder/svp-frontend.git "$D/frontend"
git -C "$D/frontend" checkout 265f4905ef44daf6c78a323104dea38b8f174d6f
cd "$D/svp-backend"
SVP_WEB_DIR="$D/frontend" make k8s-up WEB_FROM=clone
SVP_WEB_DIR="$D/frontend" make drill-k8s-web-canary
```

Luật của dự án vẫn áp dụng: máy 16 GB không chạy KEDA, tải hay chaos trên k3d (ADR-0017); compose và k3d không chạy cùng lúc; mọi target ghi
"LOCAL LAB ONLY" chỉ trỏ vào cluster local.

### Dispatch lại một kịch bản runner

Kịch bản runner chạy trên runner GitHub của `svp-backend`. Sau ADR-0039, `verify.yml` trên `main` chỉ còn `gitops`, `compose-obs`; workflow chạy
theo file ở ref được dispatch, và bước kiểm ref của bản ghim chỉ nhận `main` hay nhánh `feat/stage6b-*`. Nên dựng một nhánh `feat/stage6b-*` từ
commit ghim, **đẩy lên chính `anhnvcoder/svp-backend`** (cần quyền ghi repo đó), rồi dispatch trên nhánh đó:

```sh
cd "$D/svp-backend"
git switch -c feat/stage6b-drills-rerun c213110f017f35e562228b5f16f86a009ad4941d
git push origin feat/stage6b-drills-rerun
gh workflow run verify.yml --repo anhnvcoder/svp-backend --ref feat/stage6b-drills-rerun -f scenario=chaos
# canary web với mã web ở commit ghim của svp-frontend
gh workflow run verify.yml --repo anhnvcoder/svp-backend --ref feat/stage6b-drills-rerun -f scenario=web-canary \
  -f web_ref=265f4905ef44daf6c78a323104dea38b8f174d6f
# chỉ vài bước: -f targets='<target> ...' (bước dựng luôn chạy)
```

`scenario` là một trong `compose-obs`, `dev-k3d`, `gitops`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero`. Kịch bản `gitops` dựng cluster từ
`svp-gitops` ở `main` lúc chạy (không ở G) và image phát hành trên GHCR **ở thời điểm chạy**, không ở commit ghim, nên kết quả của nó có thể khác lượt ghi ở ADR.
Mọi kịch bản dispatch đều dùng `svp-gitops` main lúc chạy (`make gitops-clone`), nên số có thể khác G. Xoá nhánh sau
khi đọc xong artifact.
