# attest-spike: Kyverno đang ghim có xác minh được provenance của `actions/attest` không

Spike một lần, trả lời trước khi đổi định dạng build provenance của đường chính từ `cosign attest --type slsaprovenance1` (predicate do script
của `svp-backend` dựng, ADR-0027 của `svp-backend`) sang `actions/attest` (Sigstore bundle, đẩy vào registry bằng `push-to-registry: true`).

**Trạng thái: đã thử (2026-11-01), bằng Kyverno CLI đúng bản lab chạy (v1.19.1), chạy lại cả bộ bằng v1.19.2, kết quả giống hệt.** CLI đánh giá
được các hàm xác minh image của `ImageValidatingPolicy` (gọi registry và Sigstore thật), nên không dựng cluster `svp-spike`.

## Kết luận ngắn

- Kyverno v1.19.1 đọc được attestation của `actions/attest`: chữ ký keyless theo issuer, subject; predicate với đúng các đường
  `runDetails.builder.id`, `buildDefinition.externalParameters.workflow.repository`, `.ref` như bốn phép provenance của `svp-policy`. Không cần
  khai gì mới: vẫn `intoto.type: https://slsa.dev/provenance/v1`, Kyverno tự chọn định dạng **theo từng image**.
- Một policy nhận được image định dạng cũ và image định dạng mới cùng lúc (kể cả trong một pod).
- **Nhưng một image không được lẫn hai định dạng.** Image nào có ít nhất một Sigstore bundle referrer thì Kyverno (và cả `cosign verify`,
  `cosign verify-attestation`) chỉ đọc bundle, bỏ qua tag `.sig`, `.att` của định dạng cũ, không quay lại đường cũ khi bundle không qua.
  Một bản phát hành chỉ chuyển provenance sang bundle (giữ chữ ký và `vuln` định dạng cũ) **qua phép chữ ký** (bundle provenance tính là chữ
  ký) **và bị từ chối ở phép `vuln`** (suy từ hai nửa đã thử, `moved` và `policy-signed`; ca trực tiếp chưa kiểm, xem Giới hạn): `image without a vuln attestation signed by the workflow of its source`. Message đó dễ đọc nhầm thành
  `vuln` thiếu hay quá hạn, trong khi `.att` `vuln` vẫn nằm đó. Đổi phải đổi cả ba (chữ ký, `vuln`, provenance) sang bundle trong cùng một bản
  phát hành; "cửa sổ chuyển" là giữa các bản phát hành, không phải trong một image.
- Ở định dạng bundle, phép chữ ký (`verifyImageSignatures` của Kyverno, `cosign verify`) qua khi có bất kỳ bundle attestation nào ký đúng
  identity, kể cả chỉ một bundle provenance: phép chữ ký không còn kiểm điều gì riêng ngoài các phép attestation.
- Lệnh phía script không cần token: `cosign verify`, `cosign verify-attestation` (cosign 3.1.3), cùng lệnh cho cả hai định dạng; thông báo
  "không có attestation loại này" giống nhau ở hai định dạng. `gh attestation verify --bundle-from-oci` đòi đăng nhập `gh`.

## Version

| Thành phần | Version | Nguồn |
| --- | --- | --- |
| Kyverno (lab chạy) | **v1.19.1** | `base/kyverno.yaml` của `svp-gitops` (`ba257ba`) ghim mọi image Kyverno ở v1.19.1: admission `ghcr.io/kyverno/kyverno:v1.19.1@sha256:b31d8511…`, CLI `kyverno-cli:v1.19.1@sha256:ced7b2be…`; template `svp-policy` của `svp-backend` cũng viết cho v1.19.1 |
| Chart `kyverno` | 3.9.2 (`appVersion` v1.19.2) | `argocd/apps/components.json` của `svp-gitops`; `appVersion` trong `Chart.yaml` của chart 3.9.2. Values ghim image v1.19.1 nên chart 3.9.2 không đổi bản chạy; dòng đầu của `base/kyverno.yaml` còn ghi chart 3.9.1 |
| Kyverno CLI dùng thử | `ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a` (`version`: `v1.19.1+dirty`, commit `40ec788d`) | digest của `base/kyverno.yaml` |
| Kyverno CLI so sánh | `ghcr.io/kyverno/kyverno-cli:v1.19.2@sha256:322ec5044d600930cb3af0e56dc33154a2d1d1fba58f4cadad3f47be7e78b11c` | digest đọc ẩn danh bằng `oras resolve` |
| cosign | v3.1.3 (`COSIGN_IMAGE` của `Makefile` `svp-backend`); thư viện cosign trong Kyverno v1.19.1 và v1.19.2: v3.1.2 (`go.mod`) | |
| ORAS | v1.3.6 (`ORAS_IMAGE` của `Makefile` `svp-backend`) | |
| `actions/attest` | v4.2.2 (`1e69f48acb82d1966a394da916b4c1698aa569d6`) | `.github/workflows/attest-spike.yml` |
| `gh` | 2.102.0 | máy của người học |

## Image thử

| Ca | Image | Định dạng provenance | Identity ký |
| --- | --- | --- | --- |
| mới | `ghcr.io/anhnvcoder/svp-labs/attest-spike@sha256:6ef501da57a3f43709b43d4cf0619a3753edcfdb10d9c2e1119567401654f8a7` (lượt `attest-spike` [41239694493](https://github.com/anhnvcoder/svp-labs/actions/runs/41239694493), commit `f6e379b`) | Sigstore bundle v0.3 (DSSE), OCI 1.1 referrer `sha256:a0055e31…`, `artifactType` `application/vnd.dev.sigstore.bundle.v0.3+json`; chứng chỉ Fulcio public, có `tlogEntries` (Rekor public). Không có chữ ký `cosign sign` hay `vuln` | `https://github.com/anhnvcoder/svp-labs/.github/workflows/attest-spike.yml@refs/heads/main` |
| cũ | `ghcr.io/anhnvcoder/svp-backend/gateway@sha256:15c32ac48a6fd3b67ebe7f0e9549eb9c7accfafdbdd93ece96a273142e634e3c` (bản stg, `envs/stg/images/gateway.yaml` của `svp-gitops` ở `ba257ba`) | `cosign attest --type slsaprovenance1` định dạng cũ (tag `sha256-<digest>.att`, cùng `vuln`; chữ ký ở tag `.sig`) | `https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main` |
| không provenance | `ghcr.io/anhnvcoder/svp-backend/drill-no-provenance@sha256:8c9d49f382f08a526a30fbec0c54d078a0bf61605de13552039462bdaef56c98` (mới nhất, `deploy/ci/gitops-sourcemaps.sh newest drill-no-provenance` của `svp-backend`) | không có | (ký và attest `vuln` định dạng cũ, không provenance) |

Predicate của `actions/attest` (đọc từ bundle bằng `oras manifest fetch` + `oras blob fetch`, ẩn danh): `buildType`
`https://actions.github.io/buildtypes/workflow/v1`, `externalParameters.workflow` `{ref, repository, path}`, `runDetails.builder.id` là
`<repo>/.github/workflows/<file>@<ref>`, `resolvedDependencies[0]` `git+<repo>@<ref>` với `digest.gitCommit`, `runDetails.metadata.invocationId`
trỏ lượt chạy; thêm `internalParameters.github` (`event_name`, `repository_id`, `repository_owner_id`, `runner_environment`) mà predicate tự
dựng không có. Các trường bốn phép provenance so nằm đúng chỗ như predicate tự dựng.

## Kết quả

Mọi dòng dưới đây chạy bằng CLI v1.19.1 (bản lab chạy), rồi chạy lại bằng CLI v1.19.2 (`CLI=` và `KYVERNO=` đổi sang digest v1.19.2): mọi
output giống hệt. Biến dùng trong lệnh (chạy từ thư mục này):

```sh
CLI=ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a
COSIGN=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8
kyv() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm -v "$PWD":/w:ro -w /w "$CLI" apply "$1" --resource "$2"; }
ISS=https://token.actions.githubusercontent.com
NEW=ghcr.io/anhnvcoder/svp-labs/attest-spike@sha256:6ef501da57a3f43709b43d4cf0619a3753edcfdb10d9c2e1119567401654f8a7
NEW_ID=https://github.com/anhnvcoder/svp-labs/.github/workflows/attest-spike.yml@refs/heads/main
```

| Ca | Câu hỏi | Kết quả | Lệnh đã chạy và output |
| --- | --- | --- | --- |
| a | `ImageValidatingPolicy` xác minh chữ ký keyless của attestation bundle theo issuer, subject | **PASS** | `kyv policy.yaml pods/new.yaml` → `pass: 1, fail: 0`. Đối chứng `kyv policy-wrong-identity.yaml pods/new.yaml` (subject `@refs/heads/other`) → `fail: 1`, `image without a provenance attestation signed by the workflow of its source: ghcr.io/anhnvcoder/svp-labs/attest-spike@sha256:6ef5…` |
| b | Đọc predicate, so `workflow.repository`, `.ref`, `runDetails.builder.id` như bốn phép provenance của `svp-policy` | **PASS** | `kyv policy.yaml pods/new.yaml` → `pass: 1` (bốn phép, cùng đường `extractPayload(...).?predicate...` như template của `svp-policy`). Đối chứng `kyv policy-show.yaml pods/new.yaml` in giá trị đã đọc: `builder.id=https://github.com/anhnvcoder/svp-labs/.github/workflows/attest-spike.yml@refs/heads/main repository=https://github.com/anhnvcoder/svp-labs ref=refs/heads/main` |
| c | Một policy nhận định dạng cũ **hoặc** định dạng mới | **PASS** giữa các image | `kyv policy.yaml pods/old.yaml` → `pass: 1`; `kyv policy.yaml pods/both.yaml` (một pod, image cũ và image mới) → `pass: 1`; `kyv policy-show.yaml pods/both.yaml` in đúng giá trị của cả hai; `kyv policy-wrong-identity.yaml pods/old.yaml` → `fail: 1` đúng message |
| c, trong một image | Image có cả `.sig`/`.att` cũ và một bundle referrer | **FAIL** | Ba phép 2, 3, 7 của `svp-policy` (`policy-mixed.yaml`, mỗi phép nhận identity của `svp-backend` hay khoá tạm của lượt) trên bản sao bản phát hành `gateway` trong registry tạm: `./mixed.sh legacy` (chỉ `.sig`, `.att` cũ) → `pass: 1`. `./mixed.sh moved` (cùng bản sao, thêm một bundle provenance **của đúng digest đó**, ký bằng khoá tạm) → `fail: 1`, `image without a vuln attestation signed by the workflow of its source`: phép chữ ký qua nhờ bundle, `.att` `vuln` cũ (vẫn hợp lệ, `legacy` vừa đọc được) không được đọc. `./mixed.sh mixed` (cùng bản sao, thêm bundle của image spike: digest khác, identity khác) → `fail: 1`, `image without a keyless signature by the workflow of its source`: bundle không qua thì Kyverno không quay lại `.sig` cũ |
| c, keyless | Phép 2, 3, 7 của `svp-policy` trên image chỉ có bundle provenance keyless | phép 2 **PASS**, phép 3 **FAIL** | `kyv policy-signed.yaml pods/new.yaml` → `fail: 1`, `image without a vuln attestation signed by the workflow of its source: ghcr.io/anhnvcoder/svp-labs/attest-spike@sha256:6ef5…` (chữ ký keyless đếm từ bundle provenance). Đối chứng: `pods/old.yaml` → `pass: 1`; `pods/none.yaml` → `fail: 1` ở phép 7 (`image without a provenance attestation …drill-no-provenance@sha256:8c9d…`); `pods/both.yaml` → `fail: 1` ở phép 3, chỉ image mới |
| d | Image không provenance bị từ chối đúng message | **PASS** | `kyv policy.yaml pods/none.yaml` → `fail: 1`, `image without a provenance attestation signed by the workflow of its source: ghcr.io/anhnvcoder/svp-backend/drill-no-provenance@sha256:8c9d…` |
| bundle | Mọi thứ ở định dạng bundle: chữ ký, `vuln`, provenance | **PASS** (ký bằng khoá, không keyless) | `./mixed.sh keybundle` (image không có `.sig`, hai bundle referrer `vuln` và provenance ký bằng khoá tạm, không Rekor): ba phép `verifyImageSignatures`, `vuln`, provenance đều qua, `extractPayload` đọc đúng cả hai predicate: `all three checks passed, signature counted from the bundles alone; vuln scanFinishedOn=2026-11-01T00:00:00Z provenance builder.id=…attest-spike.yml@refs/heads/main` |
| CI | `cosign verify` (bước đầu của `verify-release.sh`) trên bundle mới, không token | **PASS** (mọi bundle đúng identity tính là chữ ký) | `docker run --rm $COSIGN verify --certificate-identity $NEW_ID --certificate-oidc-issuer $ISS $NEW` → exit 0, in một envelope (bundle provenance), dù image không có chữ ký `cosign sign`. Đối chứng: identity `@refs/heads/other` → exit 1 `expected SAN value …/other`; cùng lệnh với identity `images.yml` của `svp-backend` trên image cũ → exit 0 |
| CI | `cosign verify-attestation` với bundle mới, không token | **PASS** | `docker run --rm $COSIGN verify-attestation --type slsaprovenance1 --certificate-identity $NEW_ID --certificate-oidc-issuer $ISS $NEW` → exit 0, một envelope (`jq -s length` = 1). Cùng lệnh với identity `images.yml` của `svp-backend` trên image cũ → exit 0. Đối chứng: identity `@refs/heads/other` → exit 1 `expected SAN value …/other`; `--type vuln` → exit 1 `none of the attestations matched the predicate type: vuln, found: https://slsa.dev/provenance/v1` (cùng chuỗi mà `provenance_absent` của `svp-backend` dò; định dạng cũ: `--type slsaprovenance1` trên `drill-no-provenance` → exit 1 `none of the attestations matched the predicate type: slsaprovenance1, found: https://cosign.sigstore.dev/attestation/vuln/v1`); `--certificate-github-workflow-sha f6e379b12e9afdc91949866b87b6945326d3dbbf` → exit 0, SHA khác → exit 1 `expected GithubWorkflowSHA` (phép "commit của provenance bằng commit trong chứng chỉ" của `verify-release.sh` dùng được trên bundle) |
| CI | `cosign verify`, `cosign verify-attestation --type vuln` trên image lẫn hai định dạng | **FAIL** | `./mixed.sh legacy` → cả hai exit 0; `./mixed.sh mixed` → cả hai exit 1 `no matching attestations: failed to verify signature: provided artifact digest does not match any digest in statement`; `./mixed.sh moved` → cả hai exit 1 `no matching attestations: failed to verify log inclusion: not enough verified log entries from transparency log: 0 < 1`. Có bundle referrer thì cosign cũng chỉ đọc bundle, không đọc `.sig`, `.att` cũ (ở `moved`, cosign từ chối vì bundle ký bằng khoá không Rekor; một bundle keyless đúng identity thì như hàng `cosign verify` trên image mới: `verify` qua, `verify-attestation --type vuln` exit 1) |
| CI | `gh attestation verify --bundle-from-oci`, không token | **FAIL** | `env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR=<thư mục rỗng> gh attestation verify oci://$NEW --bundle-from-oci --repo anhnvcoder/svp-labs --signer-workflow anhnvcoder/svp-labs/.github/workflows/attest-spike.yml` → exit 4, `To get started with GitHub CLI, please run: gh auth login` (dừng trước khi đọc registry) |

Vì sao image lẫn bị từ chối (mã Kyverno v1.19.1, `pkg/image/verifiers/ivpol/cosign/verifier.go`, thư viện cosign v3.1.2): mỗi lần xác minh
(mỗi image, mỗi attestor), `buildCheckOptsWithBundleDetection` gọi `cosign.GetBundles`; có ít nhất một bundle referrer thì đặt
`NewBundleFormat = true`. Khi đó `VerifyImageSignature` gọi `cosign.VerifyImageAttestations` với `IntotoSubjectClaimVerifier` thay cho
`cosign.VerifyImageSignatures` (đường tag `.sig`), còn `VerifyAttestationSignature` gọi `cosign.VerifyImageAttestations`, hàm này với
`NewBundleFormat` chỉ đi `verifyImageAttestationsSigstoreBundle` (bundle referrer), không đọc tag `.att`. Lỗi ở đường bundle trả thẳng lỗi, không
quay lại đường cũ. Vì phép chữ ký ở đường bundle là xác minh attestation bất kỳ với claim "subject là digest này", một bundle provenance đúng
identity cũng tính là chữ ký. Hàm CEL `verifyImageSignatures`, `verifyAttestationSignatures` (`pkg/cel/libs/imageverify/impl.go`) đếm attestor
qua, attestor lỗi tính 0, nên policy thấy 0 chứ không thấy lỗi. v1.19.2 viết lại chỗ này (`loadBundles`, `verifyBundles` đọc bundle một lần
cho cả lượt) mà chọn định dạng cùng cách; mọi ca trên cho cùng output ở hai version.

## File

| File | Là gì |
| --- | --- |
| `policy.yaml` | Bốn phép provenance của `svp-policy` (phép 7–10), hai nguồn (`svp-backend` định dạng cũ, `svp-labs` định dạng mới), một khai báo attestation cho cả hai |
| `policy-signed.yaml` | Phép 2, 3, 7 của `svp-policy` (chữ ký, `vuln`, provenance) theo thứ tự và message của nó, cùng hai nguồn |
| `policy-wrong-identity.yaml` | Đối chứng: như `policy.yaml`, signer của mỗi nguồn ở nhánh `other` |
| `policy-show.yaml` | Đối chứng: luôn từ chối, message in các trường mà `extractPayload` đọc từ provenance đã xác minh |
| `policy-mixed.yaml`, `policy-keybundle.yaml` | Mẫu cho `mixed.sh` (điền glob của bản sao, khoá công khai tạm) |
| `pods/*.yaml` | Pod của từng ca: `new`, `old`, `none`, `both` |
| `mixed.sh` | `legacy`, `mixed`, `moved` (bản sao bản phát hành `gateway`), `keybundle` (bản sao image spike) trên registry tạm (`registry:3` ghim digest, chỉ container công cụ vào được qua network namespace của nó, không publish cổng); khoá tạm sinh mỗi lượt, không Rekor; xoá registry và thư mục tạm khi xong. `KYVERNO=<image>` đổi CLI |
| `image/` | Image `FROM scratch` mà workflow build |
| `../.github/workflows/attest-spike.yml` | Workflow chạy khi push vào `attest-spike/` và chạy tay: build image nhỏ đó, đẩy lên GHCR và attest build provenance bằng `actions/attest`, ghi một Sigstore bundle vào registry cạnh image; kết quả là đầu vào của câu hỏi ở đầu README: Kyverno đang ghim có xác minh được bundle đó không |

Workflow public nên theo các luật: `permissions: {}` ở đầu file, job duy nhất chỉ xin đúng thứ nó cần (đọc code, đẩy package, lấy token OIDC cho chứng chỉ
keyless, ghi attestation); mọi action ghim SHA đầy đủ của commit (tag ở comment cho người đọc) dù repo cho phép action bất kỳ; `actions/checkout` không để
token trong `.git/config` vì không gì đẩy vào repo này; image đẩy bằng `GITHUB_TOKEN` của job, không có secret nào khác (repo public).

## Giới hạn gặp

- **Chưa kiểm admission thật** (webhook, `timeoutSeconds`, cache xác minh của Kyverno, `failurePolicy`): CLI chạy cùng engine đánh giá policy
  nhưng không qua API server. Không dựng cluster `svp-spike`: kế hoạch chỉ dựng khi CLI không đánh giá được.
- **Chưa kiểm template `svp-policy` thật** với `requireProvenance: true` trên image mới: `policy.yaml`, `policy-signed.yaml` chép phép 2, 3,
  7–10; phép 4–6 (nền tảng, CRITICAL, tuổi của `vuln`) chưa chạy trên một `vuln` dạng bundle (`./mixed.sh keybundle` chỉ cho thấy
  `extractPayload` đọc được `scanFinishedOn` của nó).
- **Chưa kiểm trực tiếp bản phát hành keyless chỉ chuyển provenance**: cần một image có `.sig`, `.att` cũ và một bundle provenance keyless
  cùng identity, tức phải ký bằng identity của workflow GitHub. Hai nửa đã thử riêng: `./mixed.sh moved` (`.sig`, `.att` thật, bundle cùng
  digest ký bằng khoá) và `kyv policy-signed.yaml pods/new.yaml` (bundle keyless thật, không `.sig`, `.att`); cả hai từ chối ở phép `vuln`.
- **Chưa kiểm keyless khi cả ba ở định dạng bundle**: `./mixed.sh keybundle` ký bằng khoá tạm, không Rekor (không ký gì bằng identity GitHub
  hay Sigstore từ máy). Mã chọn định dạng chỉ theo việc image có bundle referrer hay không, như nhau cho attestor keyless và attestor khoá, nhưng một bản phát hành keyless
  toàn bundle (cosign `--new-bundle-format=true` cho chữ ký, `vuln` cộng `actions/attest`) chưa có để thử.
- Khoá local không mô phỏng được định dạng cũ: attestation `.att` ký bằng khoá mà không có Rekor bị Kyverno từ chối (`cosign bundle
  verification failed`; thử ở lượt trước bằng v1.19.2; mã v1.19.1 như vậy: `VerifyAttestationSignature` trả lỗi đó khi không `verified`,
  không xét `insecureIgnoreTlog` như `VerifyImageSignature`). Vì vậy ca `legacy`, `mixed`,
  `moved` dùng bản sao bản phát hành thật `gateway` (có Rekor) thay vì tự ký định dạng cũ.
- **Chưa kiểm rescan ở định dạng bundle**: job `rescan` thay attestation `vuln` bằng `cosign attest --replace` (tag `.att`); với bundle
  referrer mỗi lần attest thêm một referrer, Kyverno đọc mọi bundle cùng type, còn `verify-release.sh` đòi đúng một envelope `vuln`. Chọn
  bundle nào khi có nhiều `vuln` cũ/mới và `--replace` có tác dụng với referrer hay không: chưa thử.
- `trustedRoot` của attestor (cho Sigstore riêng của GitHub ở repo private) không cần: repo public nên `actions/attest` ký bằng Fulcio, Rekor
  public, Kyverno lấy trust root qua TUF mặc định.
- Thời gian xác minh mỗi image chưa đo (`webhookConfiguration.timeoutSeconds: 30` của `svp-policy` tính cho ba lần xác minh).

## Tái lập

```sh
for p in new old none both; do kyv policy.yaml pods/$p.yaml; kyv policy-signed.yaml pods/$p.yaml; done
for p in new old; do kyv policy-wrong-identity.yaml pods/$p.yaml; done
for p in new old both; do kyv policy-show.yaml pods/$p.yaml; done
for m in legacy mixed moved keybundle; do ./mixed.sh $m; done
# v1.19.2: CLI=ghcr.io/kyverno/kyverno-cli:v1.19.2@sha256:322ec5044d600930cb3af0e56dc33154a2d1d1fba58f4cadad3f47be7e78b11c, KYVERNO="$CLI" ./mixed.sh …
```

Mọi lệnh kéo image ẩn danh (package `attest-spike` kéo được theo digest không cần đăng nhập), không đăng nhập GHCR hay Sigstore.
