# Chiến lược migration khi svp đang chạy on-prem

Trang giải thích cách AWS phân loại một cuộc migration, các công cụ của AWS cho từng loại cùng tình trạng hiện hành, rồi
áp vào svp với giả định svp đang chạy trong data center của mình. Bài lab của thư mục này ([`README.md`](../README.md))
đo một mảnh của bức tranh: chuyển một database PostgreSQL bằng DMS.

Giả định: mọi khối của svp ([kiến trúc](https://github.com/anhnvcoder/svp-backend/blob/main/docs/architecture.md)) chạy
on-prem: `web`, `gateway`, bốn service Go mỗi service một database PostgreSQL (`svp_user`, `svp_video`,
`svp_engagement`, `svp_feed`), `media-worker` transcode bằng ffmpeg, Kafka, Valkey, object storage tương thích S3. Đích
là đường chính của svp trên AWS: EKS, RDS for PostgreSQL, MSK, ElastiCache for Valkey, S3, MediaConvert.

## Bảy chiến lược

AWS Prescriptive Guidance nêu bảy chiến lược migration, gọi là 7 Rs [N1]:

| Chiến lược | Nghĩa theo [N1] | Ứng viên trong svp |
| --- | --- | --- |
| Retire | Ngừng hay lưu trữ ứng dụng, tắt các server của nó | Server PostgreSQL, Kafka, object storage on-prem sau cutover và hết hạn quay lại |
| Retain | Giữ ở môi trường nguồn, có thể chuyển sau | Không khối nào lâu dài; trong lúc chuyển, khối chưa tới đợt của nó |
| Rehost | Lift and shift: chuyển server không đổi ứng dụng | Chỉ khi một service chạy trên VM chưa đóng container |
| Relocate | Chuyển nhiều server sang bản cloud của cùng nền tảng, hay chuyển tài nguyên sang VPC, region, account khác | Không áp cho on-prem sang AWS của svp; áp khi chuyển một RDS giữa account |
| Repurchase | Thay bằng sản phẩm khác, thường là SaaS | Tracker lỗi GlitchTip tự host đổi sang một dịch vụ SaaS |
| Replatform | Lift, tinker and shift: chuyển kèm tối ưu, ví dụ sang dịch vụ managed hay container | Phần lớn svp: PostgreSQL sang RDS, Kafka sang MSK, Valkey sang ElastiCache, object storage sang S3, service sang EKS, ffmpeg sang MediaConvert |
| Refactor or re-architect | Đổi kiến trúc để dùng tính năng cloud-native; phức tạp và tốn nhất | Bộ đếm lượt xem dạng serverless ([bài `serverless-variant`](https://github.com/anhnvcoder/svp-labs/tree/main/serverless-variant)) |

Với migration lớn, AWS khuyên rehost, replatform, relocate, retire và không khuyên refactor trong lúc chuyển [N1]. svp
đã đóng container và tách database theo service
([ADR-0001](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0001-service-boundaries-and-data-ownership.md)),
nên replatform là đường chính, refactor để sau khi đã chạy trên AWS.

## Công cụ và tình trạng hiện hành

| Công cụ | Làm gì | Tình trạng | Dùng cho svp |
| --- | --- | --- | --- |
| AWS Transform MGN (MGN) | Sao chép liên tục từng block của server vật lý, ảo, cloud khác rồi dựng lại trên AWS, cutover thường vài phút; exam guide SAP-C02 và Migration Hub gọi là AWS Application Migration Service, tài liệu ở cùng chỗ [N2], [N8], [N9] | Hiện hành; tài liệu của dịch vụ dùng tên AWS Transform MGN [N2] | Không: service của svp đã có image và Helm chart, chạy thẳng trên EKS |
| AWS DMS | Chuyển dữ liệu database cùng hay khác engine, full load rồi CDC, validation [N3] | Hiện hành; replication instance và DMS Serverless ([README](../README.md#thiết-kế)) | Bốn database PostgreSQL, đo ở bài này |
| DMS Schema Conversion | Chuyển schema (không chuyển dữ liệu) sang engine khác, có báo cáo đánh giá; chạy trong console, API [N4] | Hiện hành | Không: PostgreSQL sang PostgreSQL, schema nằm ở migration của mỗi service |
| AWS SCT | Công cụ cài trên máy, chuyển schema OLTP và data warehouse sang engine khác [N5] | Hiện hành | Không, cùng lý do |
| AWS DataSync | Chuyển file và object qua mạng, từ NFS, SMB, HDFS, object storage on-prem tới S3, EFS, FSx [N6] | Hiện hành | Bucket upload và media |
| AWS Snowball Edge, thiết bị của AWS Snow Family mà exam guide nêu [N9] | Thiết bị có ổ và máy tính, chuyển dữ liệu bằng cách gửi thiết bị [N7] | Không còn cho khách hàng mới; AWS gợi ý DataSync, AWS Data Transfer Terminal [N7] | Không: dữ liệu nhỏ, có mạng |
| AWS Migration Hub | Một chỗ khám phá server, lập kế hoạch, theo dõi tiến độ migration từ nhiều công cụ [N8] | Không mở cho khách hàng mới từ 2025-11-07; AWS gợi ý AWS Transform [N8] | Không: svp ít khối, theo dõi bằng kế hoạch của repo |

## Áp vào svp

| Khối | Chiến lược | Đường | Ghi chú |
| --- | --- | --- | --- |
| Bốn database PostgreSQL | Replatform sang RDS for PostgreSQL 17 ([ADR-0057](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0057-postgres17-verify-full.md)) | DMS full load và CDC mỗi database, hay logical replication gốc (mục cuối) | Bài lab đo trên `svp_engagement` |
| Object storage | Replatform sang S3 | DataSync từ object storage tương thích S3 [N6]; lượt chạy cuối trong cửa sổ cutover chép object mới | Bucket lớn nhất về dung lượng, nên chạy sớm nhất |
| Kafka | Replatform sang MSK ([ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md)) | Không chép topic: dừng producer, để consumer đọc hết, rồi trỏ client sang MSK | Event của svp sống ngắn; outbox giữ event chưa gửi trong database, nên đi cùng database; DLQ phát lại hay xả trước |
| Valkey | Replatform sang ElastiCache for Valkey (ADR-0053) | Không chép: rate limit và cache feed khám phá dựng lại | Session của `web` mất: người dùng đăng nhập lại |
| `gateway`, service Go, `dlq-replay`, `web` | Replatform sang EKS ([ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md)) | Image và chart có sẵn | Rehost bằng MGN chỉ khi còn khối chạy trên VM |
| `media-worker` (ffmpeg) | Replatform sang MediaConvert ([ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md)) | Job đang chạy xong ở on-prem, job mới sang AWS | Đổi cách transcode, không chuyển dữ liệu |
| Server on-prem | Retire | Tắt sau khi hết hạn quay lại | — |

## Thứ tự và rủi ro

Thứ tự, mỗi bước xong mới sang bước sau:

1. Mạng và account: Site-to-Site VPN hay Direct Connect ([bài
   `multi-account-networking`](https://github.com/anhnvcoder/svp-labs/tree/main/multi-account-networking)),
   Organizations, IAM. Mọi đường chuyển dữ liệu đi qua đây.
2. Hạ tầng đích dựng bằng IaC của `svp-infra`, chạy rỗng, qua kiểm như một môi trường mới.
3. Object storage: DataSync chép trước, vì lớn nhất và chỉ thêm object mới.
4. Database: DMS full load rồi CDC chạy trước cutover nhiều ngày, validation bật, đo độ trễ CDC dưới tải thật.
5. Cutover cả nền tảng trong một cửa sổ, vì mọi service nói với nhau qua một Kafka: dừng ghi (gateway trả lỗi tạm thời),
   xả Kafka, chờ CDC rút hết, chờ validation, đối chiếu, dừng task, đổi chuỗi kết nối và DNS. Bài lab đo đúng đoạn
   database của cửa sổ này.
6. Sau cutover: bật backup và Multi-AZ của RDS (DMS khuyên tắt tới cutover [N10]), giữ đường quay lại tới hết hạn, rồi
   retire.

Rủi ro chính:

- **Downtime vượt ngân sách.** Cửa sổ là tổng các cổng; bài lab in thời gian của từng cổng để biết cổng nào cần rút
  ngắn.
- **Schema đổi lúc CDC chạy.** DMS không áp một số thay đổi DDL như đổi default hay nullability của cột [N3]: đóng băng
  migration schema
  ([ADR-0068](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0068-zero-downtime-migrations.md)) từ lúc
  task chạy tới cutover.
- **Sequence.** Logical replication không chép giá trị sequence [N11]; bảng của svp khoá `uuid` nên không có bước này,
  bảng dùng `serial` hay `identity` thì cutover thêm `setval` ở đích.
- **Đĩa nguồn.** Slot replication giữ WAL tới khi được đọc; DMS khuyên đặt cảnh báo dung lượng ở nguồn [N3]. Bài lab đặt
  `max_slot_wal_keep_size` và gỡ slot trước khi dọn.
- **Quay lại.** Sau cutover, dữ liệu ghi vào RDS không tự về nguồn. Muốn giữ đường quay lại thì chạy thêm một task CDC
  chiều ngược (RDS for PostgreSQL làm nguồn của DMS được [N3]) từ lúc cutover.
- **Quyền trong lúc chuyển.** User DMS ở nguồn tự quản là superuser theo tài liệu DMS [N3]; chỉ cho nó vào qua TLS từ
  subnet của DMS, và xoá nó khi retire.

## Logical replication gốc của PostgreSQL so với DMS

| Tiêu chí | Logical replication gốc | AWS DMS |
| --- | --- | --- |
| Engine | PostgreSQL sang PostgreSQL | Cùng hay khác engine [N3] |
| Nơi chạy | Publication ở nguồn, subscription ở đích; RDS for PostgreSQL hỗ trợ cú pháp publication, subscription [N12] | Replication instance riêng tính theo giờ, hay DMS Serverless tính theo DCU ([README](../README.md#chi-phí)) |
| Schema, DDL | Không chép; chép schema bằng tay, ví dụ `pg_dump --schema-only` [N11] | Tuỳ chọn bắt DDL, có giới hạn [N3]; bài lab tạo schema trước như với cách gốc |
| Sequence | Không chép [N11] | Bài lab không dựa vào: svp khoá `uuid` |
| Đối chiếu | Không có sẵn; tự viết như `pgload.sh compare` | Validation dựng sẵn [N13] |
| Theo dõi | Truy vấn PostgreSQL ở hai phía | Metric `CDCLatencySource`, `CDCLatencyTarget` trên CloudWatch [N14] |
| Mạng | Đích nối được nguồn | Replication instance nối được cả hai |

Với svp (PostgreSQL sang PostgreSQL, schema nằm ở migration của mỗi service), logical replication gốc đủ chép dữ liệu và
không tốn instance; DMS thêm validation, metric có sẵn và cùng một công cụ cho cả migration khác engine. Chọn cái nào
cho svp là việc của ADR sau buổi đo, dựa trên độ trễ và downtime đo được.

## Nguồn

Tài liệu đọc 2026-11-17.

- [N1] AWS Prescriptive Guidance, About the migration strategies:
  <https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html>
- [N2] AWS Transform MGN, What is AWS Transform MGN?: <https://docs.aws.amazon.com/mgn/latest/ug/what-is-mgn.html>
- [N3] AWS DMS, Using a PostgreSQL database as an AWS DMS source (đích khác engine, giới hạn DDL, slot, quyền, RDS làm
  nguồn): <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Source.PostgreSQL.html>
- [N4] AWS DMS, Converting database schemas using DMS Schema Conversion:
  <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_SchemaConversion.html>
- [N5] What is the AWS Schema Conversion Tool?:
  <https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html>
- [N6] What is AWS DataSync?: <https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html>
- [N7] AWS Snowball Edge Developer Guide, What is Snowball Edge?:
  <https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html>
- [N8] AWS Migration Hub User Guide, What Is AWS Migration Hub?:
  <https://docs.aws.amazon.com/migrationhub/latest/ug/whatishub.html>
- [N9] AWS Certified Solutions Architect - Professional (SAP-C02), In-Scope AWS Services:
  <https://docs.aws.amazon.com/aws-certification/latest/solutions-architect-professional-02/sap-02-in-scope-services.html>
- [N10] AWS DMS, Best practices: <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_BestPractices.html>
- [N11] PostgreSQL 17, Logical Replication Restrictions:
  <https://www.postgresql.org/docs/17/logical-replication-restrictions.html>
- [N12] Amazon RDS, Performing logical replication for Amazon RDS for PostgreSQL:
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.FeatureSupport.LogicalReplication.html>
- [N13] AWS DMS, Data validation: <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Validating.html>
- [N14] AWS DMS, Monitoring AWS DMS tasks: <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Monitoring.html>
