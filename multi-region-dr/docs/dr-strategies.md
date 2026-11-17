# Bốn chiến lược DR áp vào svp

Trang này giải thích bốn chiến lược phục hồi khi mất một region (backup và restore, pilot light, warm standby,
active-active đa site): mỗi chiến lược giữ gì chạy sẵn ở region DR, RTO và RPO điển hình theo AWS, chi phí thêm mỗi
tháng nếu svp ở quy mô thiết kế dựng nó ở `us-east-1`, và từng thành phần của svp cần gì ở mỗi mức. Bài lab
([`README.md`](../README.md)) đo hai mức đầu trên tầng dữ liệu.

## Quy mô và giả định

- **Quy mô** theo đoạn "Quy mô" của
  [`architecture.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/architecture.md#2-ràng-buộc-và-yêu-cầu-phi-chức-năng)
  và bảng của [`capacity.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/explanation/capacity.md): media
  thêm khoảng 4 TB mỗi tháng, khoảng 50 TB sau một năm; PostgreSQL khoảng 38 GB sau một năm (follow 8 GB ở hai nơi,
  timeline 7 GB, like 15 GB).
- **Cấu hình prd** theo [`prd.tfvars`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/envs/prd/prd.tfvars) của
  `svp-infra`: ba AZ, NAT Gateway mỗi AZ, node hệ thống EKS `m7g.large` mỗi AZ (mặc định của module `eks`), RDS
  `db.m7g.large` Multi-AZ gp3 tới 100 GiB, MSK ba broker `kafka.m7g.large`, Valkey hai node `cache.m7g.large`,
  CloudFront phía trước.
- **Cách tính**: giá on-demand ở `us-east-1`, 730 giờ mỗi tháng, đơn giá ở mục Nguồn. Node Karpenter của ứng dụng không
  tính (số node theo tải); phí chuyển log giao dịch chéo region của PostgreSQL chưa ước (AWS không công bố khối lượng
  WAL theo tải).

## Bốn chiến lược

| Chiến lược | Chạy sẵn ở region DR | RTO, RPO điển hình | Thêm mỗi tháng ở svp (USD) |
| --- | --- | --- | --- |
| Backup và restore | Bản backup; hạ tầng, cấu hình, code dựng lại khi sự cố [N1] | RPO giờ, RTO tới 24 giờ [N2] | Dữ liệu chung ~1.031, cộng backup RDS ~4 |
| Pilot light | Database và object storage luôn bật, server ứng dụng tắt [N1] | RPO phút, RTO hàng chục phút [N2] | Dữ liệu chung ~1.031, cộng ~134 |
| Warm standby | Bản thu nhỏ nhưng đủ chức năng, nhận traffic ngay ở công suất thấp [N1] | RPO giây, RTO phút [N2] | Dữ liệu chung ~1.031, cộng ~481 |
| Active-active đa site | Toàn bộ workload, phục vụ traffic ở mọi region [N2] | RPO gần 0, RTO có thể bằng 0 [N2] | Dữ liệu chung ~1.031, cộng ~1.441 (trước khi tính node ứng dụng) |

Khác biệt giữa pilot light và warm standby: pilot light không xử lý được request khi chưa làm thêm bước nào, warm
standby nhận traffic ngay ở công suất giảm [N1]. svp hiện ở dưới cả bốn mức:
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §12 để mất region ngoài phạm
vi.

### Dữ liệu chung của mọi mức

| Khoản | Cách tính | USD mỗi tháng |
| --- | --- | --- |
| Bản sao media 50 TB ở S3 Standard-IA, `us-east-1` | 51.200 GB × 0,0125 | 640,00 |
| Chuyển media mới 4 TB `ap-southeast-1` → `us-east-1` (CRR) | 4.096 GB × 0,09 | 368,64 |
| Request PUT sao chép, tính ở đích [N9]: tới 150 object HLS mỗi video 3 phút (~50 mỗi clip 60 s theo phụ lục ADR-0067 §10), 1.000 video mỗi ngày | 4,5 triệu × 0,005 / 1.000 | ≤ 22,50 |
| **Cộng** | | **~1.031** |

Giữ bản sao ở S3 Standard thay vì Standard-IA thì khoản đầu là 51.200 × 0,023 = 1.177,60. Bật Replication Time Control
thêm 0,015 mỗi GB sao chép: 4.096 × 0,015 = 61,44 mỗi tháng.

### Phần thêm của từng mức

| Mức | Khoản | Cách tính | USD mỗi tháng |
| --- | --- | --- | --- |
| Backup và restore | Automated backup RDS sao sang `us-east-1`, ~38 GB | 38 × 0,095 | ~3,61 |
| Pilot light | Read replica `db.m7g.large` Single-AZ | 0,168 × 730 | 122,64 |
| | gp3 100 GB của replica | 100 × 0,115 | 11,50 |
| | **Cộng** | | **134,14** |
| Warm standby | Pilot light | | 134,14 |
| | Control plane EKS | 0,10 × 730 | 73,00 |
| | Hai node `m7g.large` | 2 × 0,0816 × 730 | 119,14 |
| | MSK hai broker `kafka.t3.small`, 100 GB mỗi broker | 2 × 0,0456 × 730 + 200 × 0,10 | 86,58 |
| | Valkey một node `cache.t4g.small` | 0,0256 × 730 | 18,69 |
| | Một NAT Gateway, một ALB (chưa tính LCU, byte qua NAT) | 0,045 × 730 + 0,0225 × 730 | 49,28 |
| | **Cộng** | | **~481** |
| Active-active | Control plane EKS, ba node hệ thống `m7g.large` | 73,00 + 3 × 0,0816 × 730 | 251,70 |
| | MSK ba broker `kafka.m7g.large`, 100 GB mỗi broker | 3 × 0,204 × 730 + 300 × 0,10 | 476,76 |
| | Valkey hai node `cache.m7g.large` | 2 × 0,1264 × 730 | 184,54 |
| | Ba NAT Gateway, một ALB | 3 × 0,045 × 730 + 0,0225 × 730 | 114,98 |
| | Cụm phụ Aurora PostgreSQL hai instance `db.r7g.large`, 100 GB | 2 × 0,276 × 730 + 100 × 0,10 | 412,96 |
| | **Cộng** (chưa tính I/O ghi được sao chép, 0,20 mỗi triệu) | | **~1.441** |

Khoản lớn nhất ở mọi mức là bản sao media, không phải compute: ở quy mô svp, chuyển và lưu media chéo region đắt hơn bảy
lần replica PostgreSQL của pilot light.

## Dịch vụ thay thế trong bảng

| Dịch vụ | Hợp với mức | RTO, RPO hay hành vi công bố | Giá | Áp vào svp |
| --- | --- | --- | --- | --- |
| Aurora Global Database | Pilot light tới warm standby | Trễ sao chép thường dưới một giây; managed failover RPO thường vài giây, cụm phụ lên chính trong vài phút; switchover RPO 0 [N3] | Instance `db.r7g.large` 0,276 mỗi giờ, I/O ghi được sao chép 0,20 mỗi triệu [P1] | Đổi RDS PostgreSQL sang Aurora PostgreSQL; một region ghi, region kia đọc |
| DynamoDB global tables | Active-active | RPO thấp hay bằng 0; nhất quán sau cùng (MREC, last writer wins) hay nhất quán mạnh đa region (MRSC) [N4] | Ghi được sao chép 0,625 mỗi triệu rWRU (on-demand), không phí chuyển chéo region [N4], [P2] | svp dùng PostgreSQL mỗi service một database ([ADR-0001](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0001-service-boundaries-and-data-ownership.md)); hợp với bộ đếm lượt xem kiểu bài [`serverless-variant`](https://github.com/anhnvcoder/svp-labs/tree/main/serverless-variant) |
| ARC routing control | Mọi mức có failover DNS | Công tắc bật tắt, mỗi cluster là data plane ở năm region [N5]; whitepaper xếp API của nó là data plane [N1] | Cluster 2,50 mỗi giờ: 1.825 mỗi tháng [P3] | So với công tắc alarm của bài: alarm 0,10, metric 0,30, health check 0,50 (hay miễn phí trong 50 health check đầu): dưới 1 USD mỗi tháng |
| ARC Region switch | Điều phối failover nhiều bước | Plan gồm các bước, mỗi bước chạy execution block song song hay tuần tự; kích hoạt tay hay theo CloudWatch alarm [N5] | 70 mỗi plan mỗi tháng [P3] | Thay `drill.sh failover` bằng plan được quản lý |
| ARC readiness check | — | Ngừng nhận khách mới từ 2026-04-30 [P3] | 0,045 mỗi giờ mỗi check [P3] | Không dùng |
| MSK Replicator | Warm standby, active-active | Sao chép dữ liệu giữa các cụm MSK khác region, kèm cấu hình topic, ACL, offset của consumer group [N6] | Chưa đọc | Event chéo region; mức thấp hơn dựng lại MSK, outbox phát lại ([ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §1) |
| ElastiCache Global Datastore | Warm standby, active-active | Sao chép Valkey giữa các region, chỉ cho cụm node-based [N7] | Chưa đọc | Session web, rate limit; mức thấp hơn dựng lại cache, người dùng đăng nhập lại |

## Áp vào từng thành phần của svp

| Thành phần | Backup và restore | Pilot light | Warm standby | Active-active |
| --- | --- | --- | --- | --- |
| RDS PostgreSQL | Automated backup sao chéo region, restore PITR (đường (b) của bài) | Read replica chéo region, promote (đường (a)) | Như pilot light | Aurora Global Database với một region ghi, hay chia dữ liệu theo region |
| S3 `uploads`, `media` | CRR hay AWS Backup copy sang region DR | CRR | CRR | Mỗi region một bucket nhận ghi, CRR sang region kia |
| CloudFront | Origin group: origin chính và origin phụ ở region DR, chuyển khi origin chính lỗi [N8] | Như backup và restore | Như backup và restore | Như backup và restore |
| EKS và các service | Dựng từ IaC và GitOps khi sự cố | Dựng khi sự cố | Cụm nhỏ chạy sẵn, scale khi sự cố | Cụm đủ ở mỗi region |
| MSK | Dựng lại, outbox phát lại | Dựng lại | Cụm nhỏ chạy sẵn | Cụm đủ, MSK Replicator khi cần event chéo region |
| ElastiCache Valkey | Dựng lại | Dựng lại | Một node nhỏ | Global Datastore hay mỗi region một cụm |

Hai lưu ý của whitepaper khi chọn mức: failover nên chỉ dùng thao tác data plane, vì scale bằng Auto Scaling là control
plane và làm giảm độ bền của chiến lược [N1]; failover tự kích hoạt theo health check hay alarm cần thận trọng, các bước
vẫn nên tự động để kích hoạt tay chỉ là một nút bấm [N1]. Warm standby của svp vì thế phụ thuộc việc scale EKS, MSK ở
region DR đúng lúc region chính lỗi.

## Nguồn

Tài liệu AWS đọc 2026-11-17.

- [N1] AWS Whitepaper, Disaster recovery options in the cloud:
  <https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html>
- [N2] AWS Well-Architected, REL13-BP02 Use defined recovery strategies to meet the recovery objectives:
  <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_planning_for_recovery_disaster_recovery.html>
- [N3] Amazon Aurora, Using Amazon Aurora Global Database và Using switchover or failover:
  <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html>,
  <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database-disaster-recovery.html>
- [N4] Amazon DynamoDB, Global tables và Billing for global tables:
  <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html>,
  <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/global-tables-billing.html>
- [N5] Amazon Application Recovery Controller, What is ARC, Routing control và Region switch:
  <https://docs.aws.amazon.com/r53recovery/latest/dg/what-is-route53-recovery.html>,
  <https://docs.aws.amazon.com/r53recovery/latest/dg/routing-control.html>,
  <https://docs.aws.amazon.com/r53recovery/latest/dg/region-switch.html>
- [N6] Amazon MSK, MSK Replicator: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-replicator.html>
- [N7] Amazon ElastiCache, Replication across AWS Regions using global datastores:
  <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Redis-Global-Datastore.html>
- [N8] Amazon CloudFront, Optimize high availability with CloudFront origin failover:
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/high_availability_origin_failover.html>
- [N9] Amazon S3 pricing, mục Replication (CRR tính PUT sao chép, lưu ở lớp đích, chuyển dữ liệu chéo region):
  <https://aws.amazon.com/s3/pricing/>

Giá on-demand `us-east-1`, đọc 2026-11-17 (file Price List bulk công khai, trang giá):

- [P1] AmazonRDS (RDS PostgreSQL `db.m7g.large` Single-AZ 0,168 mỗi giờ, gp3 0,115 mỗi GB-tháng, backup 0,095 mỗi
  GB-tháng; Aurora PostgreSQL `db.r7g.large` 0,276 mỗi giờ, lưu 0,10 mỗi GB-tháng, I/O ghi được sao chép 0,20 mỗi
  triệu): <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/us-east-1/index.json>
- [P2] AmazonDynamoDB (rWRU on-demand 0,625 mỗi triệu):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonDynamoDB/current/us-east-1/index.json>
- [P3] Amazon Application Recovery Controller pricing: <https://aws.amazon.com/application-recovery-controller/pricing/>
- [P4] AmazonEKS (cluster 0,10 mỗi giờ):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEKS/current/us-east-1/index.json>
- [P5] AmazonEC2 (`m7g.large` 0,0816 mỗi giờ, NAT Gateway 0,045 mỗi giờ):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-east-1/index.csv>
- [P6] AmazonMSK (`kafka.m7g.large` 0,204, `kafka.t3.small` 0,0456 mỗi broker-giờ, lưu 0,10 mỗi GB-tháng):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonMSK/current/us-east-1/index.json>
- [P7] AmazonElastiCache (Valkey `cache.m7g.large` 0,1264, `cache.t4g.small` 0,0256 mỗi node-giờ):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonElastiCache/current/us-east-1/index.json>
- [P8] AWSELB (Application Load Balancer 0,0225 mỗi giờ):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/us-east-1/index.json>
- [P9] AmazonS3 (Standard 0,023, Standard-IA 0,0125 mỗi GB-tháng, PUT 0,005 mỗi 1.000; RTC 0,015 mỗi GB từ
  `ap-southeast-1`): <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/us-east-1/index.json>,
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-southeast-1/index.json>
- [P10] AWSDataTransfer `ap-southeast-1` (sang `us-east-1` 0,09 mỗi GB):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDataTransfer/current/ap-southeast-1/index.json>
- [P11] Amazon CloudWatch `us-east-1` (alarm 0,10, metric tuỳ chỉnh 0,30 mỗi tháng) và Amazon Route 53 (health check
  0,50 mỗi tháng, 50 đầu cho endpoint AWS miễn phí):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/us-east-1/index.json>,
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRoute53/current/aws-other/index.json>
