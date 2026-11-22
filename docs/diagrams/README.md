# Sơ đồ

Trang này tra cách dựng và cập nhật sơ đồ kiến trúc của các lab: viết bằng D2, sinh ra hai SVG (sáng, tối) có icon dịch vụ AWS, nhúng vào
README của lab. Công cụ và quy ước chép từ `svp-infra`; lý do chọn D2 nằm ở
[ADR-0079](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0079-d2-diagrams.md) của `svp-backend`.

## Bố cục thư mục

| Đường dẫn | Chứa gì |
| --- | --- |
| `<lab>/<tên>.d2` | Nguồn một sơ đồ của lab (`multi-region-dr/overview.d2`); viết tay |
| `<lab>/<tên>.svg`, `<lab>/<tên>-dark.svg` | Bản sáng (theme 0) và tối (theme 200), `make diagrams` sinh, commit, không sửa tay |
| `tokens.d2` | Class dùng chung (mục [Token](#token)); không phải sơ đồ |
| `icons/` | Icon dịch vụ AWS dùng tới (mục [Icon](#icon)) |
| `inventory/` | Sơ đồ inventory (mục [Sơ đồ inventory](#sơ-đồ-inventory)) |

## Lệnh

Chạy từ gốc repo; D2 chạy trong container ghim digest (`D2_IMAGE` của `Makefile`, cùng tham chiếu với `svp-infra`), không mạng.

| Lệnh | Việc |
| --- | --- |
| `make diagrams` | Sinh mọi `<lab>/*.d2` thành `<tên>.svg` và `<tên>-dark.svg` cạnh nguồn |
| `make diagrams NAMES='<lab>'` | Chỉ sơ đồ của một lab; `NAMES='<lab>/<tên>'`: một sơ đồ; tên không có `.d2` thì exit 1 nêu tên |
| `make diagrams-check` | Sinh vào thư mục tạm, so với hai SVG đã commit; lệch, thiếu, hay SVG không còn `.d2` thì exit 1 nêu file |
| `make diagrams PNG=1` | Sinh thêm `<tên>.png`, `<tên>-dark.png` cạnh nguồn để xem; không commit, xoá sau khi xem |
| `make diagrams LAYOUT=<engine> OUT=<thư mục> SUFFIX=<chữ>` | Bản thử: engine khác, ghi vào `<thư mục>/<lab>/`, hậu tố tên; không commit |

`diagrams-check` chạy ở job `docs` của `.github/workflows/docs.yml` (job chạy mọi PR, kể cả PR chỉ đổi `.d2`, `.svg`) và trong
`make check`. Không có sơ đồ nào thì nó in `diagrams-check: no .d2 file` và vẫn tìm SVG mồ côi. CI chỉ kiểm SVG khớp `.d2`; `.d2` khớp
Terraform do người viết và review kiểm. Cùng nguồn, cùng digest của image thì ra cùng byte, arm64 lẫn amd64. Đổi digest `D2_IMAGE` có
thể đổi byte của SVG: PR đổi nó chạy `make diagrams` và commit SVG mới cùng PR.

## Một file `.d2`

Mỗi sơ đồ mở bằng `vars` đặt engine và lề, rồi nạp token từ thư mục cha. Theme không nằm trong file: `make diagrams` truyền theme 0 cho bản
sáng và theme 200 cho bản tối, cùng `--scale 1` để SVG mang cỡ thật. Engine ở gốc là ELK; khối nào có `grid-rows`, `grid-columns` thì D2
xếp theo lưới. Engine khác chỉ khi có lý do, ghi ở comment đầu file.

```d2
vars: {d2-config: {layout-engine: elk; pad: 20}}
...@../tokens

title: "<câu hỏi của sơ đồ>" {
  shape: text
  near: top-center
  style: {font-size: 18; bold: true}
}
```

Đường dẫn trong file (token, icon) tính từ chính file `.d2`; `make` mount cả `docs/diagrams/` vào container nên `../tokens`, `../icons/`
đều tới được. Tên `top`, `layers` là từ khoá của D2: không dùng làm tên nút hay container.

## Bố cục

Đích: đọc trọn trong một màn hình laptop, chữ cỡ thường. Cỡ thật của hình (viewBox, đọc bằng
`grep -o 'viewBox="[^"]*"' docs/diagrams/<lab>/<tên>.svg`) rộng khoảng 1000–1500 px; tỉ lệ cao/rộng không quá 1,3, thường 0,5–1. Hình
dựng dọc một chuỗi dài (tỉ lệ trên 1,5) bị GitHub kéo cho rộng bằng cột chữ rồi dài hơn một màn hình.

- **Lưới thay cho chuỗi dọc.** Bọc các khối cấp gốc vào một container trong suốt `all` (`style: {stroke: transparent; fill:
  transparent}`) có cả `grid-rows` lẫn `grid-columns` (chỉ `grid-columns` thì D2 điền theo cột); chuỗi dài xếp thành hàng rắn (hàng trên
  trái sang phải, hàng dưới phải sang trái). Tiêu đề `title` đứng ngoài `all`.
- **Mũi tên trong lưới là đoạn thẳng giữa hai ô.** Đặt hai nút nối nhau ở hai ô kề nhau; mũi tên không đi xuyên nút khác. Chừa khoảng cách
  ô (`horizontal-gap` 75–110) cho nhãn, ngắt nhãn dài bằng `\n`.
- **Ô cùng hàng cùng cao, ô cùng cột cùng rộng.** Gom nhóm nhỏ vào container trong suốt (`grid-rows` riêng). Khối đứng một mình cạnh cột
  cao (máy người học) đặt trong cột trong suốt cùng một nút trống có `height` phía trên, để khối giữ cỡ thật.
- **`grid-gap` cũng là lề trong của container.** Container trong suốt đặt `grid-gap: 0` và chừa khoảng cách bằng nút trống có `width` hay
  `height`, nếu không hình có khoảng trống lớn quanh viền.
- **Nhãn mũi tên không nằm trên viền khung.** Khoảng cách trước khung account, region phải lớn hơn lề trong của khung cộng nửa nhãn; mũi
  tên đi qua góc có nhãn khung thì dời nhãn khung (`label.near: top-right` hay `bottom-left`).
- **Ngắt dòng `sub`, `root` quanh 28 ký tự** bằng `\n` để khối hẹp, hình không rộng quá.

Hình giữ tỉ lệ trên 1,2 (các bước đọc từ trên xuống) nói lý do ở comment đầu file `.d2`. Hình rộng hơn 1500 px bị GitHub thu xuống vừa cột
chữ nên chữ nhỏ hơn cỡ thật: tách thành hai sơ đồ khi chữ không còn đọc được.

## Nhúng vào trang

Mỗi sơ đồ có hai SVG, mỗi file một theme; README của lab nhúng cả hai bằng một thẻ `<picture>`, đường dẫn tương đối tính từ README:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/<lab>/<tên>-dark.svg">
  <img src="../docs/diagrams/<lab>/<tên>.svg" alt="<câu hỏi của sơ đồ>">
</picture>
```

Đặt một dòng trống trước và sau khối để khối HTML không nuốt đoạn văn bên cạnh. `make docs-check` kiểm cả `src`, `srcset` bằng lychee.

- **Vì sao không một SVG chứa cả hai theme.** SVG trong thẻ `<img>` chọn theme theo `prefers-color-scheme` của hệ điều hành, không theo
  theme người dùng chọn trong GitHub: máy sáng mà GitHub tối thì hình vẫn sáng, nền trắng trên trang tối.
- **Vì sao `<picture>`, không hậu tố riêng của GitHub trên URL ảnh** (kiểu `#gh-dark-mode-only`). Hậu tố đó chỉ GitHub hiểu; trình xem
  markdown khác hiện cả hai ảnh liền nhau. `<picture>` là HTML: trình nào cũng hiện một ảnh, trình không hiểu `<source>` hiện bản sáng.
  `.markdownlint.yaml` bật `no-inline-html` (MD033) và chỉ cho ba thẻ `picture`, `source`, `img`.
- **Cỡ.** SVG mang `width`, `height` của cỡ thật, nên không đặt `width` trên thẻ ảnh. GitHub chỉ thu hình rộng hơn cột chữ.

## Token

`tokens.d2` giữ các `class` dùng chung, chép từ `tokens.d2` của `svp-infra` cộng class `onprem`; nút gắn bằng `class: <tên>`, mũi tên gắn
bằng `{class: <tên>}`. Một khối là container bo góc nền nhạt, viền màu theo chức năng, nhãn đậm là tiêu đề; `grid-rows` xếp các dòng con
dưới tiêu đề: dòng `sub` liệt kê dịch vụ bằng ` · `, dòng `root` ghi root Terraform. Nền nhạt đi với chữ tối nên đọc được ở cả hai theme.

| Class | Dùng cho |
| --- | --- |
| `governance`, `prevention`, `detection`, `alerting`, `investigation`, `recovery` | lớp bảo mật: quản trị, phòng ngừa, phát hiện, … |
| `workload`, `data` | khối nền nhạt: dịch vụ chạy tải (cả máy người học), nơi giữ dữ liệu |
| `sub`, `root` | dòng phụ dưới tiêu đề: dịch vụ (chữ thường), root Terraform (chữ đơn cách) |
| `account` | container một account AWS: bo góc, nét liền, không nền |
| `region` | vị trí (region): nét đứt mảnh; không phải ranh giới tin cậy |
| `trust` | ranh giới tin cậy thật (tổ chức, mạng của bên khác): nét đứt dày |
| `onprem` | phía on-prem của lab hybrid, mô phỏng trong AWS: nâu, góc vuông, nét đứt; nhãn nói cái gì đóng vai data center |
| `group` | nhóm nhiều account theo vòng đời hay mục đích: nét chấm mảnh |
| `data-flow`, `control-flow` | mũi tên mảnh: dữ liệu (nét liền), điều khiển như API, trigger, chính sách (nét đứt) |

Dòng `sub`, `root` và nhãn icon có chữ tối: chỉ đặt chúng trong khối nền nhạt (`workload`, `data`…). Trong container không nền (`account`,
`region`, `onprem`) theme tối tô nền tối, chữ tối không đọc được.

## Icon

Khối là một dịch vụ AWS thì mang icon của dịch vụ đó. Icon là SVG cỡ 48 của
[AWS Architecture Icons](https://aws.amazon.com/architecture/icons/), bản `07312026` (gói `Icon-package_07312026`, thư mục
`Architecture-Service-Icons_07312026/<nhóm>/48/Arch_<dịch vụ>_48.svg`), chép vào [`icons/`](icons/) với tên ngắn kebab-case. Chỉ Service
icon, không Resource icon (`Res_*`). AWS cho dùng bộ này để vẽ sơ đồ kiến trúc; không sửa hình, không đổi màu. Icon trùng dịch vụ với
`svp-infra` mang cùng tên file và cùng byte.

```d2
fn: "Lambda · 2" {
  shape: image
  icon: ../icons/lambda.svg
  width: 48
  height: 48
  style: {font-color: "#1A1A1A"; font-size: 13; bold: false}
}
```

- **Trong repo, không URL.** D2 chạy với `--network none`; đường dẫn tương đối tính từ file `.d2` và D2 nhúng hình vào SVG (base64), nên
  máy và CI ra cùng byte.
- **Chỉ icon dùng tới.** Dịch vụ mới thì chép đúng một file từ gói cùng bản; nâng bản gói thì thay mọi file trong `icons/` cùng lúc, sửa
  bản ở đoạn trên, chạy lại `make diagrams`. Dịch vụ không có icon trong `icons/`, máy người học, người dùng là dòng chữ `sub`.
- **Tính năng con dùng icon của dịch vụ cha:** NAT gateway là `vpc`; RDS Proxy là `rds`; Route 53 Resolver, Route 53 Profiles là
  `route53`.
- **Cỡ.** Nút icon là `shape: image`, `width: 48; height: 48`, nhãn `<dịch vụ> · <số>` nằm dưới hình, tối đa ba icon một hàng trong khối.

| File | Service icon trong gói |
| --- | --- |
| `api-gateway.svg` | `Arch_Networking-Content-Delivery/48/Arch_Amazon-API-Gateway_48.svg` |
| `aurora.svg` | `Arch_Databases/48/Arch_Amazon-Aurora_48.svg` |
| `cloudwatch.svg` | `Arch_Management-Tools/48/Arch_Amazon-CloudWatch_48.svg` |
| `dms.svg` | `Arch_Databases/48/Arch_AWS-Database-Migration-Service_48.svg` |
| `dynamodb.svg` | `Arch_Databases/48/Arch_Amazon-DynamoDB_48.svg` |
| `ec2.svg` | `Arch_Compute/48/Arch_Amazon-EC2_48.svg` |
| `elasticache.svg` | `Arch_Databases/48/Arch_Amazon-ElastiCache_48.svg` |
| `elb.svg` | `Arch_Networking-Content-Delivery/48/Arch_Elastic-Load-Balancing_48.svg` |
| `eventbridge.svg` | `Arch_Application-Integration/48/Arch_Amazon-EventBridge_48.svg` |
| `iam.svg` | `Arch_Security-Identity/48/Arch_AWS-Identity-and-Access-Management_48.svg` |
| `kms.svg` | `Arch_Security-Identity/48/Arch_AWS-Key-Management-Service_48.svg` |
| `lambda.svg` | `Arch_Compute/48/Arch_AWS-Lambda_48.svg` |
| `organizations.svg` | `Arch_Management-Tools/48/Arch_AWS-Organizations_48.svg` |
| `privatelink.svg` | `Arch_Networking-Content-Delivery/48/Arch_AWS-PrivateLink_48.svg` |
| `ram.svg` | `Arch_Security-Identity/48/Arch_AWS-Resource-Access-Manager_48.svg` |
| `rds.svg` | `Arch_Databases/48/Arch_Amazon-RDS_48.svg` |
| `route53.svg` | `Arch_Networking-Content-Delivery/48/Arch_Amazon-Route-53_48.svg` |
| `s3.svg` | `Arch_Storage/48/Arch_Amazon-Simple-Storage-Service_48.svg` |
| `secrets-manager.svg` | `Arch_Security-Identity/48/Arch_AWS-Secrets-Manager_48.svg` |
| `site-to-site-vpn.svg` | `Arch_Networking-Content-Delivery/48/Arch_AWS-Site-to-Site-VPN_48.svg` |
| `sqs.svg` | `Arch_Application-Integration/48/Arch_Amazon-Simple-Queue-Service_48.svg` |
| `step-functions.svg` | `Arch_Application-Integration/48/Arch_AWS-Step-Functions_48.svg` |
| `systems-manager.svg` | `Arch_Management-Tools/48/Arch_AWS-Systems-Manager_48.svg` |
| `transit-gateway.svg` | `Arch_Networking-Content-Delivery/48/Arch_AWS-Transit-Gateway_48.svg` |
| `vpc.svg` | `Arch_Networking-Content-Delivery/48/Arch_Amazon-Virtual-Private-Cloud_48.svg` |

Đường dẫn trong bảng tính từ `Architecture-Service-Icons_07312026/`. Thêm icon thì thêm một dòng.

## Sơ đồ inventory

`inventory/<slug>.d2` cùng `<slug>.svg`, `<slug>-dark.svg` là sơ đồ "root này tạo gì trên account trống" của mỗi root Terraform của năm
bài SAP, nhúng ở trang `<bài>/docs/inventory.md`. Bộ sinh `scripts/inventory.sh` viết cả trang lẫn sơ đồ từ plan của `terraform test` trên
provider giả: mỗi phần của root một khối, mỗi dịch vụ AWS một icon của `icons/` kèm số tài nguyên.

- Sinh lại: `make inventory` (cần `jq`), sau mỗi thay đổi Terraform, mock ở `scripts/inventory/`, `tokens.d2` hay `icons/`.
- Kiểm: `make inventory-check` sinh vào thư mục tạm, đỏ và nêu file khi bản commit lệch, thiếu hay thừa; CI chạy nó ở job `terraform`
  của `.github/workflows/labs.yml`. `make diagrams`, `make diagrams-check` bỏ qua `inventory/`.
- Không sửa tay file nào trong `inventory/`: đổi cách vẽ ở hàm `diagram()` của bộ sinh, đổi dịch vụ, icon ở `SERVICES` của nó.

## Luật

- PR đổi kiến trúc mà một sơ đồ `.d2` tả (account, luồng, dịch vụ, tên, CIDR) thì sửa `.d2` đó và chạy `make diagrams` trong cùng PR;
  không sửa SVG bằng tay (`diagrams-check` đỏ, lần sinh sau ghi đè).
- Mỗi sơ đồ trả lời một câu hỏi (tiêu đề và `alt` là câu hỏi đó), tối đa khoảng 15 nút, mọi nút đối chiếu được với Terraform của lab; lab
  lớn có một sơ đồ tổng quan và sơ đồ chi tiết mỗi phần. Sơ đồ kiến trúc vẽ bằng D2; sơ đồ tuần tự và luồng nhỏ giữ Mermaid.
- Xoá một sơ đồ thì xoá `.d2`, hai SVG và khối `<picture>` nhúng nó cùng lúc.
- Trước khi giao, `make diagrams NAMES='<lab>/<tên>' PNG=1` rồi xem `<tên>.png` (sáng) và `<tên>-dark.png` (tối): chữ không tràn, mũi tên
  không xuyên nút hay cắt nhãn khung, chữ đọc được ở cả hai theme, tỉ lệ cao/rộng không quá 1,3. Xoá PNG sau khi xem.
