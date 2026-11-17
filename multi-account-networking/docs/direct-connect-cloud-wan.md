# Direct Connect và Cloud WAN so với Transit Gateway của bài

Trang này giải thích hai dịch vụ mạng mà bài `multi-account-networking` không dựng: AWS Direct Connect (đường riêng từ
trung tâm dữ liệu tới AWS) và AWS Cloud WAN (mạng toàn cầu quản bằng policy), so chúng với Transit Gateway và
Site-to-Site VPN của bài, rồi áp vào svp. Giá ở region `ap-southeast-1`, USD, on-demand; nguồn và ngày đọc ở mục
[Nguồn](#nguồn).

## Direct Connect

### Kết nối

- **Dedicated connection:** một cổng Ethernet 1, 10, 100 hay 400 Gbps ở một điểm Direct Connect, của riêng khách hàng
  [D1].
- **Hosted connection:** 50 Mbps tới 25 Gbps, đặt qua partner của AWS [D1]. Hợp khi cần ít băng thông hay không có thiết
  bị ở điểm Direct Connect.
- Phí cổng ở Equinix SG2 (Singapore): $0,30 mỗi giờ cho cổng 1G, $2,25 cho cổng 10G; dữ liệu ra qua Direct Connect
  $0,041 mỗi GB, dữ liệu vào $0 [P1]. Bảng giá AWS không gồm phí cross-connect, rack của nhà colocation.

### Virtual interface (VIF)

- **Private VIF:** tới một VPC bằng địa chỉ riêng [D2].
- **Public VIF:** tới mọi dịch vụ công khai của AWS bằng địa chỉ công khai [D2].
- **Transit VIF:** tới một hay nhiều Transit Gateway gắn với Direct Connect gateway; dùng được với dedicated hay hosted
  connection mọi tốc độ [D2].
- Mỗi dedicated connection có tối đa 4 transit VIF và 50 private hay public VIF [D3].

### Direct Connect gateway

- Tài nguyên toàn cầu: một Direct Connect gateway gắn được với Transit Gateway, virtual private gateway hay core network
  của Cloud WAN ở các region [D4].
- Không cho hai association trên cùng gateway gửi lưu lượng cho nhau (ví dụ VPC qua virtual private gateway tới VPC
  khác) [D4]: nó không phải hub giữa VPC; hub vẫn là Transit Gateway.
- Quota: 30 VIF (private hay transit) mỗi gateway, 20 virtual private gateway, 6 Transit Gateway mỗi gateway; 20 Direct
  Connect gateway mỗi Transit Gateway [D3], [D5].

### SiteLink

Tính năng của private VIF gắn Direct Connect gateway và của transit VIF: nối hai điểm Direct Connect bất kỳ trong cùng
partition, nên hai văn phòng hay trung tâm dữ liệu nói chuyện được với nhau qua Direct Connect; tính phí riêng [D2]. Ở
Equinix SG2: $0,50 mỗi SiteLink VIF-giờ [P1].

### Độ bền

Resiliency Toolkit của Direct Connect đưa ba mô hình [D6]:

- **Maximum resiliency:** các connection riêng, kết thúc trên các thiết bị riêng ở nhiều hơn một điểm; SLA 99,99%.
- **High resiliency:** hai connection đơn tới nhiều điểm; SLA 99,9%.
- **Development and test:** các connection riêng trên các thiết bị riêng ở cùng một điểm; cho workload không quan trọng.

### Mã hoá

- **MACsec** (IEEE 802.1AE) mã hoá điểm-điểm trên dedicated connection 10, 100, 400 Gbps ở một số điểm [D1].
- **Private IP VPN:** IPsec chạy trên Direct Connect, không cần địa chỉ công khai; dùng Direct Connect gateway và
  Transit Gateway [D7].

## Cloud WAN

- **Core network:** mạng toàn cầu do AWS quản; **core network policy** là một tài liệu JSON nói ý định, AWS dựng mạng
  theo nó [D8].
- **Core network edge (CNE):** điểm nối của core network ở mỗi region mà policy nêu [D8].
- **Segment:** miền định tuyến riêng; mặc định chỉ attachment cùng segment nói chuyện được với nhau [D8]. Segment thay
  vai trò của route table tách env trong bài.
- **Attachment:** VPC, Site-to-Site VPN, route table của Transit Gateway, Connect [D8]; **network function group** gom
  attachment của tường lửa hay IDS/IPS [D8].
- Nối được với Transit Gateway cùng region bằng peering [D8]; home region của core network chỉ là US West (Oregon) [D8].
- Giá ở `ap-southeast-1`: $0,50 mỗi CNE-giờ, $0,09 mỗi VPC attachment-giờ, $0,09 mỗi peering-giờ với Transit Gateway,
  $0,02 mỗi GB xử lý [P2].

## So với bài

| Tiêu chí | Transit Gateway (bài này) | Cloud WAN |
| --- | --- | --- |
| Phạm vi | Một region; nhiều region cần peering giữa các Transit Gateway | Nhiều region trong một policy |
| Tách env | Route table, route tĩnh, blackhole viết trong Terraform | Segment và luật chia sẻ route trong policy |
| Phí cố định mỗi giờ ở `ap-southeast-1` | $0,07 mỗi attachment [P3] | $0,50 mỗi CNE và $0,09 mỗi attachment [P2] |
| Phí dữ liệu | $0,02 mỗi GB [P3] | $0,02 mỗi GB [P2] |

Với bốn VPC của bài trong một region: Transit Gateway $0,28 mỗi giờ; Cloud WAN $0,50 + 4 × $0,09 = $0,86 mỗi giờ.

Đường tới "on-prem": Site-to-Site VPN $0,05 mỗi connection-giờ cộng $0,07 mỗi giờ của VPN attachment trên Transit
Gateway [P3], qua Internet, có thể dựng trong một buổi (phần hybrid của bài). Direct Connect cần cổng ở điểm Direct
Connect, phí cổng chạy theo giờ kể cả khi không dùng, và dữ liệu ra rẻ hơn Internet: $0,041 mỗi GB so với $0,12 mỗi GB
cho 10 TB đầu mỗi tháng ra Internet [P1], [P4].

## Áp vào svp

- **Hiện tại:** svp chạy một region, hai env, không có trung tâm dữ liệu: không cần Direct Connect hay Cloud WAN.
- **Khi có on-prem** (ví dụ studio đẩy video gốc lên S3 mỗi ngày): bắt đầu bằng Site-to-Site VPN gắn Transit Gateway.
  Dedicated 1 Gbps ở Equinix SG2 tốn $0,30 × 730 ≈ $219 mỗi tháng cho cổng; tiết kiệm $0,12 − $0,041 = $0,079 mỗi GB ra
  so với Internet, nên hoà vốn quanh 2,8 TB dữ liệu ra mỗi tháng, chưa tính phí colocation. Dưới mức đó, hosted
  connection nhỏ hay VPN rẻ hơn.
- **Production qua Direct Connect:** High resiliency trở lên (nhiều điểm) [D6]; Development and test chỉ cho stg. Cần mã
  hoá thì private IP VPN trên transit VIF [D7] hay MACsec nếu cổng 10 Gbps trở lên [D1].
- **Cloud WAN:** khi svp chạy nhiều region với nhiều segment cần một policy chung (bài `multi-region-dr` chỉ thêm một
  region DR). Với hai region, hai CNE là $1,00 mỗi giờ (~$730 mỗi tháng) chỉ cho phần nền [P2]; peering giữa hai Transit
  Gateway rẻ hơn ở quy mô đó.

## Nguồn

Đọc 2026-11-17.

- [D1] Direct Connect features (tốc độ dedicated, hosted, MACsec): <https://aws.amazon.com/directconnect/features/>
- [D2] Direct Connect virtual interfaces và SiteLink:
  <https://docs.aws.amazon.com/directconnect/latest/UserGuide/WorkingWithVirtualInterfaces.html>
- [D3] Quota của Direct Connect: <https://docs.aws.amazon.com/directconnect/latest/UserGuide/limits.html>
- [D4] Direct Connect gateway:
  <https://docs.aws.amazon.com/directconnect/latest/UserGuide/direct-connect-gateways-intro.html>
- [D5] Quota của Transit Gateway: <https://docs.aws.amazon.com/vpc/latest/tgw/transit-gateway-quotas.html>
- [D6] Direct Connect Resiliency Toolkit:
  <https://docs.aws.amazon.com/directconnect/latest/UserGuide/resiliency_toolkit.html>
- [D7] Private IP Site-to-Site VPN qua Direct Connect:
  <https://docs.aws.amazon.com/vpn/latest/s2svpn/private-ip-dx.html>
- [D8] AWS Cloud WAN: <https://docs.aws.amazon.com/network-manager/latest/cloudwan/what-is-cloudwan.html>
- [P1] AWS Price List `AWSDirectConnect`, `ap-southeast-1` (phát hành 2026-11-13; `APS1-EqSG2-PortUsage:1G`, `:10G`,
  `APS1-EqSG2-DataXfer-Out`, `APS1-EqSG2-DataXfer-In`, `APS1-EqSG2-SiteLinkVifHour`):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDirectConnect/current/ap-southeast-1/index.json>
- [P2] AWS Price List `AWSCloudWAN`, `ap-southeast-1` (phát hành 2026-09-11):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSCloudWAN/current/ap-southeast-1/index.json>
- [P3] AWS Price List `AmazonVPC`, `ap-southeast-1` (phát hành 2026-11-05; `APS1-TransitGateway-Hours`,
  `APS1-TransitGateway-Bytes`, `APS1-VPN-Usage-Hours:ipsec.1`):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/ap-southeast-1/index.json>
- [P4] AWS Price List `AWSDataTransfer`, `ap-southeast-1` (phát hành 2026-11-11; `APS1-DataTransfer-Out-Bytes`):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDataTransfer/current/ap-southeast-1/index.json>
