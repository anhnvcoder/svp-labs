# reusable-spike: reusable workflow hay composite action thay cho checkout ghim script của repo khác

Spike một lần. CI của `svp-frontend` chạy `deploy/ci/*.sh` của `svp-backend` từ một checkout ghim (`.backend/`, commit ở `.backend-commit`). Hai
cách chuẩn của GitHub để bỏ checkout đó: **reusable workflow** (`on: workflow_call`, gọi bằng `uses: owner/repo/.github/workflows/x.yml@<sha>`)
và **composite action** (`uses: owner/repo/.github/actions/x@<sha>`). Bài này thử cả hai trong `svp-labs`, gọi bằng đường đầy đủ
`anhnvcoder/svp-labs/...@<sha>` như một repo khác sẽ gọi, rồi đọc identity ký và thử Kyverno.

**Trạng thái: đã thử (2026-11-01).** Lượt `reusable-spike-caller` [41311975558](https://github.com/anhnvcoder/svp-labs/actions/runs/41311975558)
(commit chạy `8dab22d`, merge commit của PR #3), workflow và action gọi ở `@fa3cf13d77877fa8fde4ca8fe1126e068a304253`; hai job `reusable / release`,
`composite` đều success. Mọi phép đọc dưới đây chạy ẩn danh trên máy (package `reusable-spike` public), không đăng nhập GHCR hay Sigstore.

## Kết luận

**Composite action**, theo quy tắc đặt trước: (2) qua (workflow được gọi biết commit của chính nó mà không lặp `sha`), nhưng (3) không qua với
Kyverno v1.19.1: v1.19.1 bỏ qua `additionalExtensions` của attestor keyless, nên phép chữ ký và `vuln` chỉ thấy SAN của reusable workflow, giống
nhau cho mọi repo gọi; chỉ phép provenance (phép 9, `workflow.repository`) tách được repo gọi.

- Với composite action, identity ký là workflow của repo gọi, y như hôm nay: `sources.json` (subject đúng một chuỗi), phép 8 (`builder.id` bằng
  subject), `cosign verify --certificate-identity` của script không đổi.
- Composite action chỉ thay bảy lần gọi script; CI còn đọc `.backend/` ở chỗ khác (`generate-check`, `lockfile-scan`, `make tools`, job `promote`,
  `rescan`), nên `.backend-commit` còn và phải gom hai bản ghim về một (mục "Cái bỏ được ở cách thắng").
- Reusable workflow sẽ đổi identity của mọi nguồn dùng nó: SAN là `<workflow được gọi>@<sha>` (đổi mỗi lần Renovate nâng `sha`), nên subject
  phải thành `subjectRegExp`, phép 8 thành so regexp, và mọi phép (Kyverno và script) phải thêm điều kiện repo gọi (extension `1.3.6.1.4.1.57264.1.5`,
  `cosign verify --certificate-github-workflow-repository`).
- Ghi chú cho lần xét lại: Kyverno **v1.19.2** đọc `additionalExtensions` (commit `00935ea7`, "support additionalExtensions for keyless signing
  in the ivpol"), và ở v1.19.2 cả ba phép tách được repo gọi (hàng 3b). Quy tắc chốt v1.19.1 (bản lab chạy), nên kết luận không đổi; nếu Kyverno
  lên v1.19.2 thì điều kiện (3) của reusable workflow thoả, còn chi phí đổi identity ở trên vẫn còn.

**Mối đe doạ của reusable workflow:** reusable workflow của repo public gọi được từ repo bất kỳ (`uses:` không cần quyền gì trên repo được gọi).
Chứng chỉ của mọi lượt gọi mang cùng SAN (workflow được gọi ở commit được ghim), nên SAN chỉ chứng minh **mã nào** build, không chứng minh **repo
nào** gọi. Repo gọi chỉ nằm ở extension của chứng chỉ (Fulcio ký, đáng tin) và ở provenance (do `actions/attest` dựng từ claim OIDC). Một policy chỉ
xét issuer + SAN nhận image do một repo lạ build bằng mã đó; thứ còn chặn là quyền push vào package dưới prefix của nguồn (GHCR), không phải mật mã.

## Version

| Thành phần | Version | Nguồn |
| --- | --- | --- |
| Kyverno CLI (bản lab chạy) | `ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a` | `../attest-spike/README.md` |
| Kyverno CLI so sánh | `ghcr.io/kyverno/kyverno-cli:v1.19.2@sha256:322ec5044d600930cb3af0e56dc33154a2d1d1fba58f4cadad3f47be7e78b11c` | `../attest-spike/README.md` |
| cosign (ký, trong CI) | v3.1.4, `sigstore/cosign-installer` v4.1.2 (`6f9f177…`) | workflow, action của bài này |
| cosign (đọc, trên máy) | `ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8` | `COSIGN_IMAGE` của `Makefile` `svp-backend` |
| ORAS | `ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb` | `ORAS_IMAGE` của `Makefile` `svp-backend` |
| `actions/attest` | v4.2.2 (`1e69f48…`) | workflow, action của bài này |
| OpenSSL | máy của người học (Homebrew) | `openssl x509 -text` |
| Runner | `ubuntu-24.04` 20261025.353.1, runner 2.338.2 | log lượt 41311975558 |

## Image thử

| Đường | Image | Referrer (Sigstore bundle v0.3) |
| --- | --- | --- |
| reusable workflow | `ghcr.io/anhnvcoder/svp-labs/reusable-spike@sha256:57e0467016d694efa819dd5d0feb88f09944172a124198248da37965d83ae6c3` | chữ ký `bedb27f2…` (`https://sigstore.dev/cosign/sign/v1`), `vuln` `a19d5ce2…`, provenance `b772cdba…` |
| composite action | `ghcr.io/anhnvcoder/svp-labs/reusable-spike@sha256:2e8fd569f9e68ca5475cf3964bdc98c59aae7a996a2b6706e926f0dde52472ca` | chữ ký `990ca416…`, `vuln` `c0072e63…`, provenance `a5e9a616…` |

Biến dùng trong lệnh (chạy từ thư mục này):

```sh
COSIGN=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8
ORAS=ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb
CLI=ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a
c() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm "$COSIGN" "$@"; }
o() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm "$ORAS" "$@"; }
kyv() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm -v "$PWD/kyverno":/w:ro -w /w "$CLI" apply "$1" --resource "$2"; }
ISS=https://token.actions.githubusercontent.com
R=ghcr.io/anhnvcoder/svp-labs/reusable-spike
RD=sha256:57e0467016d694efa819dd5d0feb88f09944172a124198248da37965d83ae6c3   # đường reusable
CD=sha256:2e8fd569f9e68ca5475cf3964bdc98c59aae7a996a2b6706e926f0dde52472ca   # đường composite
RID=https://github.com/anhnvcoder/svp-labs/.github/workflows/reusable-spike-called.yml@fa3cf13d77877fa8fde4ca8fe1126e068a304253
CID=https://github.com/anhnvcoder/svp-labs/.github/workflows/reusable-spike-caller.yml@refs/heads/main
# chứng chỉ của một bundle: o manifest fetch $R@sha256:<referrer> → layers[0].digest; o blob fetch --output - $R@<layer> > b.json
# jq -r .verificationMaterial.certificate.rawBytes b.json | base64 -d | openssl x509 -inform der -noout -text
```

## Kết quả

| # | Câu hỏi | Kết quả | Lệnh và output |
| --- | --- | --- | --- |
| 1a | SAN của chứng chỉ khi ký trong reusable workflow | **SAN = workflow được gọi ở `@<sha>` của `uses:`** | `openssl x509` trên chứng chỉ của cả ba bundle đường reusable (chữ ký `cosign sign`, `vuln`, provenance `actions/attest`) → `URI:https://github.com/anhnvcoder/svp-labs/.github/workflows/reusable-spike-called.yml@fa3cf13d77877fa8fde4ca8fe1126e068a304253`. Ba chứng chỉ giống nhau ở mọi extension dưới đây |
| 1b | Extension của chứng chỉ (Fulcio OID `1.3.6.1.4.1.57264.1.*`) | **PASS: phần "build signer" là workflow được gọi, phần "source"/"build config" là repo gọi** | `.9` Build Signer URI = SAN; `.10` Build Signer Digest = `fa3cf13…`; `.12` Source Repository URI = `https://github.com/anhnvcoder/svp-labs`; `.13` Source Repository Digest = `8dab22d…`; `.14` Source Repository Ref = `refs/heads/main`; `.18` Build Config URI = `https://github.com/anhnvcoder/svp-labs/.github/workflows/reusable-spike-caller.yml@refs/heads/main`; `.19` Build Config Digest = `8dab22d…`; `.21` Run Invocation URI = `…/actions/runs/41311975558/attempts/1`; extension cũ: `.3` GithubWorkflowSha = `8dab22d…`, `.4` GithubWorkflowName = `reusable-spike-caller`, `.5` GithubWorkflowRepository = `anhnvcoder/svp-labs`, `.6` GithubWorkflowRef = `refs/heads/main` |
| 1c | `cosign verify --output json` | **PASS (identity), không in extension** | `c verify --output json --certificate-identity $RID --certificate-oidc-issuer $ISS $R@$RD` → exit 0, ba envelope (vuln, `sign/v1`, provenance: mọi bundle đúng identity tính là chữ ký, như `../attest-spike`), `optional: {}`: định dạng bundle không đưa extension vào output, nên đọc bằng `openssl x509` |
| 1d | Phép của script tách repo gọi bằng extension | **PASS** | `c verify --certificate-identity $RID --certificate-oidc-issuer $ISS --certificate-github-workflow-repository anhnvcoder/svp-labs $R@$RD` → exit 0; với `anhnvcoder/svp-frontend` → exit 1 `expected GithubWorkflowRepository to be "anhnvcoder/svp-frontend", got "anhnvcoder/svp-labs"`; cùng kết quả với `verify-attestation --type vuln`. `--certificate-github-workflow-sha 8dab22d…` (commit của caller) → exit 0, `fa3cf13…` → exit 1 `expected GithubWorkflowSHA`: phép "commit của chứng chỉ" của `verify-release.sh` vẫn là commit của lượt. `--certificate-identity-regexp '^https://github\.com/anhnvcoder/svp-labs/\.github/workflows/reusable-spike-called\.yml@[0-9a-f]{40}$'` → exit 0 |
| 1e | Provenance của `actions/attest` trong reusable workflow | **`builder.id` là workflow được gọi, `workflow.*` là repo gọi** | Đọc bundle `b772cdba…` (oras, ẩn danh): `runDetails.builder.id` = `…/reusable-spike-called.yml@fa3cf13…`; `externalParameters.workflow` = `{repository: https://github.com/anhnvcoder/svp-labs, ref: refs/heads/main, path: .github/workflows/reusable-spike-caller.yml}`; `resolvedDependencies[0]` = `git+https://github.com/anhnvcoder/svp-labs@refs/heads/main`, `gitCommit 8dab22d…` |
| 2a | Ngữ cảnh `github.*` trong workflow được gọi | **của caller** | Bước "Contexts of a called workflow": `github.workflow_ref=…/reusable-spike-caller.yml@refs/heads/main`, `github.workflow_sha=8dab22d…`, `github.sha=8dab22d…`; `GITHUB_WORKFLOW_REF`, `GITHUB_WORKFLOW_SHA` cũng vậy |
| 2b | Ngữ cảnh `job` trong workflow được gọi | **PASS: commit của chính nó** | `toJSON(job)` → `workflow_ref: anhnvcoder/svp-labs/.github/workflows/reusable-spike-called.yml@fa3cf13…`, `workflow_sha: fa3cf13…`, `workflow_repository: anhnvcoder/svp-labs`, `workflow_file_path: .github/workflows/reusable-spike-called.yml` (không cần token) |
| 2c | Claim của token OIDC | **PASS: commit của chính nó** | Bước "Claims of the OIDC token" (chỉ payload): `job_workflow_ref: anhnvcoder/svp-labs/.github/workflows/reusable-spike-called.yml@fa3cf13…`, `job_workflow_sha: fa3cf13…`; `workflow_ref`, `workflow_sha`, `sha` là của caller (`8dab22d…`) |
| 2d | Checkout script ở commit đó, không lặp `sha` | **PASS** | Checkout `repository`/`ref` lấy từ claim → `release.sh` in `script_root=…/scripts commit=fa3cf13…`, `code_root=…/code commit=8dab22d…`. Input `scripts-ref` (lặp `sha`) chỉ để so: `job_workflow_sha equals inputs.scripts-ref`; không cần nó |
| 3a | Kyverno v1.19.1: attestor keyless có `additionalExtensions` tách được repo gọi ở phép chữ ký, `vuln`, provenance | **FAIL** (bị bỏ qua) | `kyv policy-show.yaml pods/reusable.yaml` → `sig[reusable,A,B,caller]=1,1,1,0 vuln=1,1,1,0 provenance=1,1,1,0`: attestor `reusableB` (đòi repo gọi `anhnvcoder/svp-frontend`) đếm 1 như `reusableA`. Mã v1.19.1 (`pkg/image/verifiers/ivpol/cosign/opts.go`) chỉ chép `Issuer`, `Subject`, `IssuerRegExp`, `SubjectRegExp` vào `cosign.CheckOpts`; CRD có trường nhưng không ai đọc |
| 3a' | Kyverno v1.19.1: phép 9 (`workflow.repository` của provenance) tách được repo gọi | **PASS** | `kyv policy-reusable.yaml pods/reusable.yaml` → `pass: 1, fail: 1`: `reusable-caller-a` qua (phép 2, 3, 7, 8 với `subjectRegExp`, 9); `reusable-caller-b`: `fail` ở `image whose provenance names another repository than its source: …reusable-spike@sha256:57e0…`, sau khi đã qua phép chữ ký và `vuln` |
| 3b | Kyverno v1.19.2: như 3a | **PASS** (so sánh, ngoài quy tắc) | `CLI=<v1.19.2> kyv policy-show.yaml pods/reusable.yaml` → `sig=1,1,0,0 vuln=1,1,0,0 provenance=1,1,0,0`; `kyv policy-reusable.yaml pods/reusable.yaml` → `reusable-caller-b` `fail` ngay ở `image without a keyless signature by the workflow of its source`, `reusable-caller-a` qua |
| 4a | Composite action gọi bằng `@<sha>`: runner tải gì | **PASS: cả repo ở commit đó, không `.git`** | Bước "What the runner downloaded": `github.action_path=/home/runner/work/_actions/anhnvcoder/svp-labs/fa3cf13…/.github/actions/reusable-spike`; `$GITHUB_ACTION_PATH/../../..` liệt kê `.github AGENTS.md CLAUDE.md README.md attest-spike bundle-spike dora drills reusable-spike`, `no .git`. `release.sh` chạy từ đó: `script_root=/home/runner/work/_actions/anhnvcoder/svp-labs/fa3cf13… commit=not a git checkout`. `github.action_ref=fa3cf13…`, `github.action_repository=anhnvcoder/svp-labs` có; biến môi trường `GITHUB_ACTION_REF`, `GITHUB_ACTION_REPOSITORY` rỗng trong bước `run:` của composite |
| 4b | SAN khi ký trong job dùng composite action | **PASS: workflow của caller** | Chứng chỉ của ba bundle đường composite: SAN `…/reusable-spike-caller.yml@refs/heads/main`, `.9` = `.18` (Build Signer = Build Config), `.10` = `.13` = `8dab22d…`; claim `job_workflow_ref` = `workflow_ref` của caller. Provenance `a5e9a616…`: `builder.id` = `…/reusable-spike-caller.yml@refs/heads/main`. `c verify --certificate-identity $CID --certificate-oidc-issuer $ISS --certificate-github-workflow-sha 8dab22d… $R@$CD` → exit 0; với `$RID` → exit 1 `expected SAN value …reusable-spike-called.yml@fa3cf13…` |
| 4c | Kyverno v1.19.1 với identity hôm nay trên image composite | **PASS** | `kyv policy-composite.yaml pods/composite.yaml` → `pass: 1, fail: 0`, qua cả phép 2, 3, 7, 8 (`builder.id` bằng đúng subject), 9; đối chứng `pods/reusable.yaml` → `fail` `image without a keyless signature by the workflow of its source`; `policy-show.yaml pods/composite.yaml` → `sig[reusable,A,B,caller]=0,0,0,1 vuln=0,0,0,1 provenance=0,0,0,1`. v1.19.2 cùng kết quả |
| 5 | `allowed_actions` của `svp-labs` chặn gọi bằng đường đầy đủ của chính repo không | **PASS: không chặn** | `gh api repos/anhnvcoder/svp-labs/actions/permissions` → `{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}`; lượt 41311975558 gọi cả hai bằng `anhnvcoder/svp-labs/…@fa3cf13…`, cả hai job success. Với `allowed_actions: selected` chưa kiểm |

## Cái bỏ được ở cách thắng (composite action)

Đọc theo `backend/deploy/ci/common.sh`, `frontend/Makefile`, `frontend/scripts/contract.sh`, `frontend/.github/workflows/ci.yml` và `images.yml`
(`svp-frontend` ở `c8fce17`, ghim backend `21e5902`); chưa thử trên `svp-frontend`.

- **Composite action thay được:** bảy lần gọi script `deploy/ci/*.sh` từ `.backend/`: `plan`, `build-image`, `push-image`, `merge-index`,
  `sign-image`, `rescan` của `images.yml` (dòng 94, 141, 174, 236, 287, 482) và `scan-gate.sh --check-ignorefile` của job `config` (`ci.yml:144`).
- **Không bỏ được chỉ bằng đổi bảy lần gọi đó:** `.backend/`, `.backend-commit` và `make backend-checkout` còn ở CI, vì các chỗ sau đọc bản backend
  ngoài các script đó:

  | Chỗ | Đọc gì của `.backend/` |
  | --- | --- |
  | `ci.yml:98`, job `check`: `make generate-check` | target phụ thuộc `backend-checkout`; `scripts/contract.sh` source `.backend/deploy/ci/common.sh` (`sign_identity backend`, `release_source`, `tool_image ORAS_IMAGE`) |
  | `ci.yml:106`, job `check`: `make lockfile-scan` | target phụ thuộc `backend-checkout`; `TRIVY_IMAGE` ở `.backend/Makefile` |
  | `ci.yml:139`, `ci.yml:177`, job `config`, `gitleaks` | `make backend-checkout` |
  | `ci.yml:148`, `ci.yml:180` | `go-version-file: .backend/go.mod` (Go để build hai công cụ) |
  | `ci.yml:156` (job `gitleaks` dùng lại qua `*tools-key`, `ci.yml:186`) | cache key `hashFiles('Makefile', '.backend/Makefile')` |
  | `ci.yml:159`, `ci.yml:189`: `make tools` | `GITLEAKS_VERSION`, `ACTIONLINT_VERSION` ở `.backend/Makefile` |
  | `images.yml:351`, job `promote` | source `.backend/deploy/ci/common.sh` (`yq_`, `promote_open_pr`, `promote_image_row`); không gọi script nào |
  | `images.yml:469`, `images.yml:474`, job `rescan` | `make -C .backend gitops-clone` (target ở `deploy/k8s/k8s.mk` của backend) clone `svp-gitops` vào `.backend/.gitops/svp-gitops`, `SVP_GITOPS_DIR` trỏ đó |

- **Hai chỗ ghim:** chuyển riêng bảy lần gọi sang composite action thì repo có `.backend-commit` cạnh mỗi
  `uses: anhnvcoder/svp-backend/.github/actions/<x>@<sha>`. Hai bản có thể lệch nhau (ký và scan ở commit này, `common.sh` của `promote`, version
  công cụ và bảng nguồn của `generate-check` ở commit khác), trái với "`.backend-commit` là chỗ duy nhất ghim commit backend" của
  `frontend/AGENTS.md`. Hai cách gom về một, **chưa kiểm** cách nào:
  - Bản ghim duy nhất là SHA của `uses:` (literal, `uses:` không nhận biểu thức): một bước của composite action đưa đường dẫn bản backend runner
    tải về (4a: cả repo ở commit đó) cho các bước sau, thay `.backend/` ở mọi chỗ trong bảng; `Makefile` local đọc SHA đó từ workflow thay cho
    `.backend-commit`. Vướng đã biết: bản tải về nằm ngoài `GITHUB_WORKSPACE` (`/home/runner/work/_actions/…`, 4a), mà `hashFiles` chỉ đọc file
    trong `GITHUB_WORKSPACE` (tài liệu "Expressions" của GitHub), nên cache key `ci.yml:156` phải đổi; bản tải về không có `.git`; `gitops-clone`
    ghi `.gitops/` vào trong cây của action.
  - Giữ `.backend-commit` làm bản ghim, thêm một phép ở job `config` buộc mọi `uses: anhnvcoder/svp-backend/…@<sha>` bằng `.backend-commit`, và
    để Renovate nâng cả hai trong cùng một PR (ví dụ customManager `git-refs` cùng `depName` trên các dòng `uses:`).
- **Renovate không thêm gì:** `.backend-commit` hôm nay đã do Renovate nâng (`frontend/renovate.json`: customManager `git-refs`, nhánh `main`,
  nhóm "backend commit", duyệt tay). `svp-backend` không có tag nào (`git -C backend tag` → 0 dòng), nên dạng `@<sha> # <tag>` không áp được.
  Renovate (manager `github-actions`) nâng một `uses:` ghim SHA không kèm tag ra sao: chưa kiểm.
- **Còn ở script:** `SVP_CODE_ROOT` (cây script là bản runner tải về, cây code là checkout của caller: hai thư mục khác nhau như hôm nay; action nhận đường
  dẫn qua input), `code_root`/`script_root`, `require_code_files`, `use_build_source` (chọn nguồn theo repo của lượt: `GITHUB_REPOSITORY` vẫn là
  repo gọi), `check_code_tree` (HEAD của `code_root` phải là commit của lượt), `sign_identity` và bảng `sources.json` (identity không đổi).
- **Mới phải để ý:** bản tải về không có `.git`, nên mọi lệnh `git -C "$repo_root"` của script backend (`provenance_required` đọc chart ở
  commit khác, `promote_not_behind`, `changed-services.sh`, `contract.sh`, `ghcr-digest.sh`) không chạy được từ action. Theo grep, bảy script mà
  workflow của `svp-frontend` gọi hôm nay (`build-image`, `merge-index`, `plan`, `push-image`, `rescan`, `scan-gate`, `sign-image`) không gọi ba
  hàm lịch sử của `common.sh`; chưa chạy thử. `.backend/` hôm nay cũng chỉ fetch đúng một commit.
- **`Makefile` local của `svp-frontend` vẫn cần một bản backend:** `tools`, `lockfile-scan`, `generate`/`generate-check` (cùng các target CI chạy,
  bảng trên) đọc `.backend/`; các target e2e, đo đạc chạy với stack của bản clone backend của workspace (`SVP_BACKEND_DIR`, không phải `.backend/`).
  Composite action không giúp gì ở máy local.

## File

| File | Là gì |
| --- | --- |
| `../.github/workflows/reusable-spike-caller.yml` | Caller, chỉ `workflow_dispatch`: job `reusable` gọi workflow được gọi, job `composite` dùng composite action, cả hai ở `@fa3cf13…` |
| `../.github/workflows/reusable-spike-called.yml` | Reusable workflow: in ngữ cảnh và claim OIDC (chỉ payload), checkout repo của chính nó ở `job_workflow_sha`, chạy `release.sh` từ đó, `actions/attest` |
| `../.github/actions/reusable-spike/action.yml` | Composite action: in cái runner tải về (`$GITHUB_ACTION_PATH/../../..`), claim OIDC, chạy `release.sh` từ bản tải về, `actions/attest` |
| `release.sh` | Thay cho `deploy/ci/*.sh`: in `script_root`, `code_root` và commit của mỗi cái; build cây của caller, push, `cosign sign`, `cosign attest --type vuln` định dạng bundle |
| `image/` | Image `FROM scratch` nhỏ; label `spike.path` (`reusable`, `composite`) cho hai digest dưới một package |
| `kyverno/policy-show.yaml` | Đối chứng: luôn từ chối, message in số đếm của bốn attestor (`reusable`, `reusableA`, `reusableB`, `caller`) ở ba phép và trường provenance |
| `kyverno/policy-reusable.yaml` | Hai policy cùng identity reusable workflow (`subjectRegExp`), đòi repo gọi `svp-labs` (A) và `svp-frontend` (B): phép 2, 3, 7, 8, 9 |
| `kyverno/policy-composite.yaml` | Phép 2, 3, 7, 8, 9 với identity của caller, dạng `sources.json` hôm nay |
| `kyverno/pods/*.yaml` | Pod của hai image |

Reusable workflow được caller gọi bằng đường đầy đủ ở một commit (`anhnvcoder/svp-labs/.github/workflows/reusable-spike-called.yml@<sha>`), như một repo
khác sẽ gọi. Nó build cây của caller, ký và attest image keyless (cosign, định dạng Sigstore bundle) cùng build provenance (`actions/attest`), để
chứng chỉ cho thấy reusable workflow ký bằng identity nào. Trước đó nó in cái nó biết về commit của chính mình (các context, claim của token OIDC, input
`scripts-ref`), checkout repo của chính nó ở commit mà token nêu, rồi chạy script phát hành từ checkout đó: câu hỏi là reusable workflow có ghim được
script nó chạy mà không lặp lại SHA không. Caller phát hành image của `image/` hai lần, một lần qua reusable workflow và một lần qua composite action,
mỗi bên gọi bằng đường đầy đủ ở cùng một commit `fa3cf13d77877fa8fde4ca8fe1126e068a304253` (một repo ở đây nên cùng `owner/repo`, không bao giờ `./`), như
`svp-frontend` sẽ gọi của backend. Commit đó có trước commit ghi nó vào caller (mục "Chạy"), nên log của lượt chạy phân biệt được commit
của script với commit của lượt.

Hai workflow public nên theo các luật: `permissions: {}` ở đầu file, mỗi job chỉ xin đúng thứ ký cần (đọc code, đẩy package, lấy token OIDC cho chứng chỉ
keyless, ghi attestation), và reusable workflow không được hơn quyền job gọi nó cấp; mọi action và reusable workflow ghim SHA đầy đủ của commit, không
truyền secret nào (repo public); `actions/checkout` không để token trong `.git/config`; token OIDC được xin một lần để in claim (chỉ payload, không bao giờ
chính token); input vào script qua `env:`, không qua `${{ }}` trong `run:`. Caller chỉ chạy khi dispatch: nó ký, nên không gì chạy nó khi push hay PR.

## Chạy

Caller ghim workflow và action ở một commit **trước** commit ghi nó (`uses:` không nhận biểu thức), nên cần hai commit: commit 1 có mọi file với
chuỗi `CALLED_SHA` trong caller; commit 2 thay `CALLED_SHA` bằng SHA của commit 1. PR merge bằng merge commit (squash hay rebase tạo commit mới,
commit 1 không còn trên `main`). Sau merge: dispatch `reusable-spike-caller`, để package `reusable-spike` public, rồi trên máy:

```sh
for p in reusable composite; do kyv policy-show.yaml pods/$p.yaml; kyv policy-reusable.yaml pods/$p.yaml; kyv policy-composite.yaml pods/$p.yaml; done
# v1.19.2: CLI=ghcr.io/kyverno/kyverno-cli:v1.19.2@sha256:322ec5044d600930cb3af0e56dc33154a2d1d1fba58f4cadad3f47be7e78b11c, cùng lệnh
```

Mỗi lần `kyv` xác minh lại từ đầu (không cache giữa các container): `policy-show.yaml` gọi 12 phép xác minh mỗi image, vài phút một lượt.

## Giới hạn

- **Chỉ một repo gọi thật** (`svp-labs` gọi chính nó). "Repo gọi B" thử bằng policy đòi `svp-frontend` trên image do `svp-labs` gọi; chưa có lượt
  gọi từ repo thứ hai, nên chưa xem chứng chỉ khi repo gọi và repo được gọi khác nhau (theo tài liệu Fulcio thì `.12`, `.5` là repo gọi).
- **Chưa kiểm admission thật** (webhook, cache, `timeoutSeconds`): Kyverno CLI, như `../attest-spike`.
- **Chưa kiểm template `svp-policy` thật**: ba policy chép phép 2, 3, 7, 8, 9; phép 4–6 (nền tảng, CRITICAL, tuổi) không chạy vì predicate `vuln`
  của bài này tối giản (`scanner.result: {}`).
- **`vuln` không có trường repo gọi theo chuẩn**: ở v1.19.1 phép `vuln` không tách được repo gọi; `invocation.uri` của predicate bài này có URL lượt
  chạy của repo gọi nhưng do script tự ghi, không phải trường policy nên dựa vào.
- **Chưa thử `allowed_actions: selected`** và repo private (reusable workflow của repo private chỉ gọi được khi repo cho phép truy cập).
- **Chưa thử trên `svp-frontend`**: danh sách "bỏ được" ở trên đọc từ mã và workflow, chưa chạy script backend từ bản tải về của composite action;
  hai cách gom bản ghim và cách Renovate nâng `uses:` ghim SHA không tag chưa kiểm.
