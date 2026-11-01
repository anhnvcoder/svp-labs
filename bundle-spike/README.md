# bundle-spike: bản phát hành keyless toàn Sigstore bundle, và rescan `vuln` hằng ngày với bundle

Spike một lần, trả lời trước khi đổi chữ ký, `vuln`, provenance của đường chính sang Sigstore bundle, hai câu mà
[`attest-spike/README.md`](../attest-spike/README.md) mục "Giới hạn gặp" để "chưa kiểm":

- **(A) Một image keyless toàn bundle:** chữ ký `cosign sign --new-bundle-format=true`, `vuln` `cosign attest --new-bundle-format=true --type vuln`
  (predicate dạng của `deploy/ci/vuln-predicate.sh` của `svp-backend`, hai nền tảng), provenance `actions/attest` (`push-to-registry: true`), cùng
  identity `bundle-spike.yml@refs/heads/main` của `svp-labs`. Kyverno CLI v1.19.1 với policy render từ template thật `svp-policy` của
  `svp-backend` (`requireProvenance: true`, bảng nguồn thêm nguồn `labs`): mười phép đều qua; image thiếu `vuln` bị từ chối đúng message.
- **(B) Rescan:** `vuln` attest lần hai, lần ba lên cùng digest với `scanFinishedOn` mới hơn, như job `rescan` hằng ngày: `--replace` có tác dụng
  với bundle không; Kyverno, `cosign verify-attestation` đọc bundle `vuln` nào; gỡ được bundle cũ không và bằng quyền gì; thời gian xác minh
  khi có N bundle.

**Trạng thái: đã thử (2026-11-01)** bằng bốn lượt workflow trên `main` của `svp-labs` và Kyverno CLI v1.19.1, cosign v3.1.3 trên máy (đọc
ẩn danh). Ca nhiều bundle `vuln` chạy trên bản sao trong registry tạm (`multi.sh`) vì lượt `prune` đã gỡ chúng khỏi GHCR.

## Kết luận

**Rescan phải gỡ bundle `vuln` cũ.** Attest thêm thôi thì sai ở cả hai phía:

- `cosign attest --replace` không thay gì ở định dạng bundle: mỗi lượt thêm một referrer (cosign v3.1.4 báo `Flag --replace has been
  deprecated, not needed when OCI referrers become the default behavior`). Sau hai lượt rescan image có ba bundle `vuln`.
- `cosign verify-attestation --type vuln` trả mọi bundle đúng identity (ba envelope), nên `verify-release.sh` (đòi đúng một) từ chối bản phát
  hành ngay sau lượt rescan đầu tiên.
- Kyverno v1.19.1 giữ **một** payload mỗi loại predicate: payload của bundle đúng loại **đứng cuối danh sách referrer**, không phải bundle mới
  nhất (`AddVerifiedIntotoPayloads` của `kyverno/sdk` ghi đè theo thứ tự `cosign.GetBundles` trả, tức thứ tự của registry). GHCR không có
  referrers API; cosign ghi chỉ mục tag dự phòng `sha256-<digest>` **xếp theo digest** (go-containerregistry v0.21.7, `commitSubjectReferrers`),
  nên Kyverno đọc bundle `vuln` có digest manifest lớn nhất, không liên quan tới tuổi. Một bundle cũ có digest lớn thì nằm cuối mãi; qua
  `maxAttestationAge` (72h), Kyverno từ chối mọi pod mới dù rescan hằng ngày vẫn chạy.

**Cách gỡ, quyền cần:** trong cùng job rescan, sau `cosign attest`, chạy `oras manifest delete` cho mọi bundle `vuln` khác của digest (giữ cái
vừa attest), với `GITHUB_TOKEN` `packages: write` (đã `docker login ghcr.io`). Trên GHCR lệnh này **trả exit 1** (`unsupported: The operation is
unsupported.`, GHCR không cho xoá manifest qua registry API) nhưng trước đó oras đã ghi lại tag dự phòng, bỏ referrer ra khỏi danh sách: sau đó
Kyverno và cosign chỉ thấy bundle còn lại và đọc đúng nó. Vì vậy script phải kiểm danh sách referrer sau khi gỡ, không tin exit code. Manifest
đã gỡ còn trong package (phiên bản không tag, kéo theo digest được); dọn chúng cần API xoá package version của GitHub, chưa thử. Chọn bundle để giữ
phải theo bundle vừa attest (hay `scanFinishedOn` của bundle **đã xác minh** đúng identity), không theo nội dung chưa xác minh.

Giữa lúc attest và lúc gỡ có vài giây image mang hai bundle `vuln`: Kyverno đọc một trong hai (cả hai còn trong tuổi), `verify-release.sh` từ
chối trong khoảng đó.

**Phần (A) đạt:** image keyless toàn bundle qua đủ mười phép của template thật, phép 4–6 đọc `vuln` dạng bundle; image thiếu `vuln` bị từ chối ở
phép 3 đúng message. **Nhưng xác minh chậm hơn rõ:** cùng policy, cùng máy, CLI mất 36–46 s cho image bundle (ba bundle) so với 14–16 s cho bản
phát hành `gateway` định dạng cũ; trên registry tạm cùng image chỉ 4–5 s và không tăng tới 32 bundle, nên phần lớn là các lượt gọi GHCR. Thời
gian admission thật (có cache, trong cluster) chưa đo; trước khi đổi đường chính cần đo nó so với `timeoutSeconds: 30` (Giới hạn gặp).

## Version

| Thành phần | Version | Nguồn |
| --- | --- | --- |
| Kyverno CLI | `ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a` | digest của [`attest-spike/README.md`](../attest-spike/README.md) (`base/kyverno.yaml` của `svp-gitops`) |
| cosign trong workflow | v3.1.4 (`sigstore/cosign-installer` v4.1.2) | như job ký của `images.yml` của `svp-backend` |
| cosign trên máy | `ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2e…` | `COSIGN_IMAGE` của `Makefile` `svp-backend` |
| `actions/attest` | v4.2.2 (`1e69f48acb82d1966a394da916b4c1698aa569d6`) | như `attest-spike.yml` |
| ORAS | v1.3.6 (`ORAS_IMAGE` của `Makefile` `svp-backend`) | |
| Registry tạm | `registry:3@sha256:d4032d4c…` | như `attest-spike/mixed.sh` |
| Chart `svp-policy` | `svp-backend` commit `f09d2ec` | `policy.sh` in commit |
| Mã đọc để giải thích | cosign v3.1.2 `pkg/cosign/verify.go` (thư viện trong Kyverno v1.19.1), Kyverno v1.19.1 `pkg/image/verifiers/ivpol/cosign/verifier.go`, `kyverno/sdk` `68d74afc` `extensions/imagedataloader/loader.go`, go-containerregistry v0.21.7 `pkg/v1/remote/write.go` | |

## Lượt chạy

Mọi lượt trên `main` của `svp-labs` ở commit `8dab22d`, identity `https://github.com/anhnvcoder/svp-labs/.github/workflows/bundle-spike.yml@refs/heads/main`.

| Lượt | Mode | Run id | Kết quả |
| --- | --- | --- | --- |
| 1 | `build` | [41311972410](https://github.com/anhnvcoder/svp-labs/actions/runs/41311972410) | `release` `sha256:1f6154f1d726771265309311d0114383cd086c4f27eb9dafb40fb0a8de15f866` (amd64 `21f186ea54df…`, arm64 `7f7cb677c8f3…`): chữ ký `0fc372d3…`, `vuln` `24758370…` (`scanFinishedOn` 13:36:10Z), provenance `076edcd7…`. `novuln` `sha256:ac10945e02b7302e076cd47a9f88290ac4b8e200b8eefe570ccb2ce1278c6ed2`: chữ ký `a929c12a…`, provenance `7be45646…` |
| 2 | `rescan` | [41312225051](https://github.com/anhnvcoder/svp-labs/actions/runs/41312225051) | thêm `vuln` `627ba767…` (13:38:27Z) |
| 3 | `rescan` | [41312503891](https://github.com/anhnvcoder/svp-labs/actions/runs/41312503891) | thêm `vuln` `dee76329…` (13:42:00Z) |
| 4 | `prune` | [41312657175](https://github.com/anhnvcoder/svp-labs/actions/runs/41312657175) | gỡ `24758370…`, `627ba767…` khỏi danh sách referrer (B4) |

Biến dùng trong lệnh dưới đây (chạy từ thư mục này; `W` là thư mục tạm chứa policy đã render và `pods/*.yaml`):

```sh
CLI=ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a
COSIGN=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8
kyv() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm -v "$W":/w:ro -w /w "$CLI" apply "$1" --resource "$2"; }
c() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm "$COSIGN" "$@"; }
ISS=https://token.actions.githubusercontent.com
ID=https://github.com/anhnvcoder/svp-labs/.github/workflows/bundle-spike.yml@refs/heads/main
REL=ghcr.io/anhnvcoder/svp-labs/bundle-spike@sha256:1f6154f1d726771265309311d0114383cd086c4f27eb9dafb40fb0a8de15f866
NOV=ghcr.io/anhnvcoder/svp-labs/bundle-spike@sha256:ac10945e02b7302e076cd47a9f88290ac4b8e200b8eefe570ccb2ce1278c6ed2
W=$(mktemp -d); cp pods/*.yaml "$W"
./policy.sh ../../backend "$W/policy.yaml"                 # ok svp-policy of f09d2ec with source labs, requireProvenance true, maxAttestationAge 72h
cat "$W/policy.yaml" show.yaml >"$W/policy-show.yaml"
```

## (A) Image keyless toàn bundle

| Ca | Câu hỏi | Kết quả | Lệnh đã chạy và output |
| --- | --- | --- | --- |
| A1 | Image `release` có đúng ba bundle referrer (chữ ký, `vuln`, provenance) | **PASS** | Sau `build` (log bước `prune`, dòng `before:` trừ hai `vuln` của rescan) và hiện tại: `./referrers.sh list $REL` → `dee76329… https://cosign.sigstore.dev/attestation/vuln/v1 2026-11-01T13:42:00Z`, `0fc372d3… https://sigstore.dev/cosign/sign/v1 -`, `076edcd7… https://slsa.dev/provenance/v1 -`. Chữ ký của cosign v3 cũng là bundle DSSE (predicate `https://sigstore.dev/cosign/sign/v1`). `./referrers.sh list $NOV` → chỉ chữ ký và provenance. Không còn tag `.sig`, `.att` |
| A2 | Mười phép của `svp-policy` (`requireProvenance: true`) đều qua trên image `release` | **PASS** | `kyv policy.yaml release.yaml` → `pass: 1, fail: 0` |
| A3 | Phép 4–6 (đủ hai nền tảng, không CRITICAL, tuổi) đọc `vuln` dạng bundle | **PASS** (phép 5 chỉ với báo cáo rỗng) | `kyv policy-show.yaml release.yaml` → `checks 1-10 passed; read: vuln scanFinishedOn=2026-11-01T13:42:00Z platforms=linux/amd64@21f186ea54df(results 0),linux/arm64@7f7cb677c8f3(results 0) provenance builder.id=…/bundle-spike.yml@refs/heads/main repository=https://github.com/anhnvcoder/svp-labs ref=refs/heads/main` (hai digest đúng index). Đối chứng phép 6: `./policy.sh ../../backend $W/policy-1m.yaml 1m`, `kyv policy-1m.yaml release.yaml` → `fail: 1`, `vuln attestation older than 1m (scanFinishedOn): …bundle-spike@sha256:1f61…`. Đối chứng phép 4: `sed "s#== 'linux/arm64'#== 'linux/s390x'#"` trên policy, `kyv` → `fail: 1`, `vuln attestation does not cover exactly linux/amd64 and linux/arm64: …`. Phép 5 qua vì `Results` rỗng (image `FROM scratch`); ca có CRITICAL trên bundle chưa kiểm |
| A4 | Đối chứng: image `novuln` (chữ ký, provenance, không `vuln`) bị từ chối ở phép 3 đúng message | **PASS** | `kyv policy.yaml novuln.yaml` → `fail: 1`, `image without a vuln attestation signed by the workflow of its source: ghcr.io/anhnvcoder/svp-labs/bundle-spike@sha256:ac10945e… (source labs, subject https://github.com/anhnvcoder/svp-labs/.github/workflows/bundle-spike.yml@refs/heads/main)` |
| A5 | `cosign verify`, `cosign verify-attestation --type vuln`, `--type slsaprovenance1` trên image `release`, không token | **PASS** | `c verify --certificate-identity $ID --certificate-oidc-issuer $ISS $REL` → exit 0, 1 envelope; `c verify-attestation --type vuln …` → exit 0, 1 envelope (`scanFinishedOn` 13:42:00Z); `--type slsaprovenance1` → exit 0, 1 envelope (`builder.id` …`bundle-spike.yml@refs/heads/main`). Trên `$NOV`: `verify` exit 0, `--type vuln` exit 1 `none of the attestations matched the predicate type: vuln, found: https://sigstore.dev/cosign/sign/v1,https://slsa.dev/provenance/v1` (vẫn khớp chuỗi `provenance_absent` của `svp-backend` dò) |

## (B) Rescan

Ca B2, B3 (nhiều `vuln`) và B6 (N lớn) chạy bằng `./multi.sh ../../backend`: bản sao index `release` và năm bundle thật của workflow (hai bundle
`vuln` đã gỡ vẫn kéo được theo digest) trong `registry:3` tạm; bản sao bundle chỉ khác manifest một annotation `spike.copy`, không ký lại.

| Ca | Câu hỏi | Kết quả | Lệnh đã chạy và output |
| --- | --- | --- | --- |
| B1 | `cosign attest --replace --type vuln` lần hai, ba: thay bundle cũ hay thêm bundle | **Thêm**, `--replace` không tác dụng | Log hai lượt `rescan`: `Flag --replace has been deprecated, not needed when OCI referrers become the default behavior`. Log `prune`, `before:` (thứ tự của tag dự phòng trên GHCR): `076edcd7… provenance`, `0fc372d3… sign`, `24758370… vuln 13:36:10Z`, `627ba767… vuln 13:38:27Z`, `dee76329… vuln 13:42:00Z`: ba bundle `vuln`, xếp theo digest (thứ tự đẩy là `0fc372d3`, `24758370`, `076edcd7`, `627ba767`, `dee76329`) |
| B2 | Kyverno đọc bundle `vuln` nào | **Bundle cuối danh sách referrer**, không phải mới nhất | `multi.sh`, ca `ordered` (ba `vuln` theo thứ tự đẩy, cũng là thứ tự digest): `policy-show` đọc `scanFinishedOn=13:42:00Z`; policy `maxAttestationAge` = tuổi của mốc 13:40:14Z (`1038s`, chỉ bundle mới nhất còn trong tuổi) → `pass: 1`. Ca `reversed` (thêm bản sao bundle 13:36:10Z, đẩy sau cùng, digest `e3e2b260…` lớn hơn mọi digest khác): `policy-show` đọc `scanFinishedOn=13:36:10Z`; policy `1054s` → `fail: 1`, `vuln attestation older than 1054s (scanFinishedOn): …bundle-spike@sha256:1f61…` dù bundle 13:42:00Z vẫn ở đó và hợp lệ. Ca `pad-10`, `pad-30` (bản sao 13:42:00Z đẩy sau) → đọc 13:42:00Z, `pass: 1`. `registry:3` trả referrer theo thứ tự đẩy; GHCR theo digest (B1) |
| B3 | `cosign verify-attestation --type vuln` trả mấy envelope | **Mọi bundle** (`verify-release.sh` từ chối) | `multi.sh`: `ordered` → `1 13:36:10Z, 1 13:38:27Z, 1 13:42:00Z` (ba envelope); `reversed` → bốn; `pad-30` → `2 13:36:10Z, 1 13:38:27Z, 27 13:42:00Z`. Trên GHCR sau `prune`: một envelope (A5) |
| B4 | Gỡ bundle `vuln` cũ: `oras manifest delete`, rồi API xoá package version bằng `GITHUB_TOKEN` | **Gỡ được khỏi danh sách** bằng `oras manifest delete`, exit 1; API GitHub chưa kiểm | Log `prune`: mỗi bundle `Error response from registry: unsupported: The operation is unsupported.`, `oras manifest delete: exit 1`; `after:` chỉ còn `dee76329… vuln 13:42:00Z`, chữ ký, provenance. Đọc ẩn danh: `GET /v2/anhnvcoder/svp-labs/bundle-spike/referrers/sha256:1f61…` → `404 MANIFEST_UNKNOWN` (GHCR không có referrers API); `GET …/manifests/sha256-1f61…` (tag dự phòng) → ba manifest `076edcd7`, `0fc372d3`, `dee76329`; `GET …/manifests/sha256:24758370…`, `…627ba767…` → `200` (manifest vẫn còn, chỉ ra khỏi chỉ mục). Nhánh API GitHub của `referrers.sh prune` chỉ chạy khi bundle còn trong danh sách, nên không chạy |
| B5 | Sau khi gỡ: Kyverno, cosign đọc đúng bundle còn lại | **PASS** | Trên GHCR sau `prune`: `kyv policy-show.yaml release.yaml` → đọc `scanFinishedOn=2026-11-01T13:42:00Z`, mười phép qua; `c verify-attestation --type vuln … $REL` → exit 0, đúng một envelope 13:42:00Z |
| B6 | Thời gian xác minh một image bằng CLI khi có N bundle (so `timeoutSeconds: 30`) | **Đo một phần** | Mỗi lần là một tiến trình CLI mới, không cache. GHCR, `release` (N = 3 sau `prune`): `kyv policy.yaml release.yaml` 37 s, 46 s, 37 s; `policy-show` 36 s, 37 s. Cùng policy trên `gateway` định dạng cũ (`ghcr.io/anhnvcoder/svp-backend/gateway@sha256:fd968eb2…`, bản stg): 16 s, 15 s, 16 s, 14 s. `novuln` (dừng ở phép 3): 22 s, 23 s. Pod không image nào khớp glob (không gọi registry): 1 s. Registry tạm: `ordered` (N = 5) 5 s, `reversed` 5 s, `pad-10` (N = 12) 4 s, `pad-30` (N = 32) 5 s. GET một manifest GHCR từ máy: 0,43–0,44 s. GHCR với N > 5 chưa kiểm |

Vì sao (mã đã đọc, khớp với B2, B3): `cosign.GetBundles` lấy danh sách referrer (referrers API, không có thì tag dự phòng), tải **lần lượt** từng
bundle (manifest rồi blob), không lọc theo loại; `verifyImageAttestationsSigstoreBundle` xác minh song song nhưng giữ đúng thứ tự đó. Kyverno
gọi nó cho mỗi phép xác minh (chữ ký, `vuln`, provenance), sau một lượt `GetBundles` nữa để dò định dạng (`buildCheckOptsWithBundleDetection`),
nên mỗi image tải mọi bundle khoảng sáu lần; định dạng cũ chỉ tải tag `.sig`, `.att`. Trong vòng lặp, mỗi bundle đúng loại gọi
`image.AddVerifiedIntotoPayloads(type, payload)`, hàm này gán `map[type] = payload`: cái sau đè cái trước. cosign ghi tag dự phòng qua
go-containerregistry, hàm `commitSubjectReferrers` thêm referrer rồi `sort.Slice` theo digest ("for reproducibility").

## Cách chạy

Workflow [`.github/workflows/bundle-spike.yml`](../.github/workflows/bundle-spike.yml) (`workflow_dispatch`, input `mode`, `digest`):

- `build`: dựng image `FROM scratch` hai nền tảng (index của hai manifest) ở `ghcr.io/anhnvcoder/svp-labs/bundle-spike`, hai biến thể:
  `release` (ký, `vuln`, provenance, cả ba là bundle) và `novuln` (ký, provenance; đối chứng thiếu `vuln`). Summary in hai digest và các
  referrer.
- `rescan` với `digest` của `release`: attest thêm một `vuln` (`scanFinishedOn` lúc chạy) bằng `--replace`, như `rescan.sh` của `svp-backend`.
- `prune` với `digest` của `release`: giữ bundle `vuln` mới nhất, gỡ mọi bundle `vuln` khác (`referrers.sh prune`).

Trên máy chỉ đọc ẩn danh (package `bundle-spike` public): khối biến ở mục "Lượt chạy", rồi lệnh ở từng dòng bảng, và

```sh
./referrers.sh list "$REL"
./multi.sh ../../backend        # B2, B3, B6 trên bản sao trong registry tạm (xoá khi xong)
```

## File

| File | Là gì |
| --- | --- |
| `image/` | Image `FROM scratch`; `VARIANT` chỉ đổi label, cho digest thứ hai cùng nội dung |
| `vuln-predicate.sh` | Predicate `vuln` dạng của `vuln-predicate.sh` của `svp-backend` từ index thật; báo cáo trivy rỗng (image không có gói nào) |
| `policy.sh` | Render `svp-policy` của một clone `svp-backend` (bản sao tạm, thêm nguồn `labs`), `requireProvenance: true`, tuổi tối đa tuỳ chọn |
| `show.yaml` | Nối vào cuối policy đã render: chỉ tới được khi mười phép qua, luôn từ chối, message in các giá trị phép 4–10 đọc |
| `pods/` | Pod của image `release`, `novuln` (namespace `svp`) |
| `referrers.sh` | `list`: bundle referrer của một image (loại predicate, `scanFinishedOn`), đọc từ chính bundle; `prune`: gỡ bundle `vuln` cũ (chỉ trong workflow) |
| `multi.sh` | Ca nhiều bundle `vuln` (`ordered`, `reversed`, `pad-10`, `pad-30`) trên bản sao trong `registry:3` tạm (không publish cổng, xoá khi xong) |

## Giới hạn gặp

- **Chưa kiểm admission thật** (webhook trong cluster, cache xác minh và TUF của Kyverno, `timeoutSeconds: 30`): CLI là tiến trình mới mỗi lần,
  nên 36–46 s ở B6 là cận trên khi không cache, không phải thời gian admission. Con số đáng lo vì định dạng cũ cùng điều kiện mất 14–16 s;
  cần đo trên cluster trước khi đổi đường chính.
- **Ca nhiều bundle `vuln` chạy trên bản sao**, không trên GHCR: lượt `prune` đã gỡ chúng trước khi thử Kyverno. Bundle là bản thật của
  workflow; chỗ khác là thứ tự danh sách (`registry:3` theo thứ tự đẩy, GHCR theo digest, đọc từ log `prune`) và độ trễ mạng. Thời gian trên
  GHCR với N > 5 chưa đo (mã tải bundle lần lượt, nên dự kiến tăng theo N).
- **Xoá package version bằng API GitHub chưa thử**: `oras manifest delete` đã đưa bundle ra khỏi danh sách nên nhánh đó không chạy. Manifest đã
  gỡ còn trong package; dọn chúng cần `DELETE /users/<owner>/packages/container/<package>/versions/<id>` hay quy tắc giữ phiên bản của GHCR.
- **Ghi đồng thời chưa kiểm**: tag dự phòng là đọc-sửa-ghi; hai lượt attest hay gỡ cùng digest chạy cùng lúc có thể làm mất một referrer.
  Workflow của spike khoá `concurrency` nên không gặp.
- Phép 5 (CRITICAL) chỉ chạy với báo cáo rỗng; một `vuln` bundle có CRITICAL chưa kiểm (đường đọc giống phép 4, 6 đã thử).
- Predicate `vuln` không từ trivy thật (image không có gói); spike thử cách đọc attestation, không thử scan.
- Chỉ thử Kyverno v1.19.1; v1.19.2 (`loadBundles`, `verifyBundles`, theo `attest-spike`) có thể đổi số lần tải bundle, chưa kiểm.
