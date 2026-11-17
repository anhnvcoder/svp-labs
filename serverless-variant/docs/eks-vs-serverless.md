# Đếm lượt xem trên EKS và trên serverless: được và mất

Trang này so đường lượt xem của svp trên EKS (Kafka, consumer gom lô, Postgres) với bản serverless của bài (API
Gateway, SQS, Lambda, DynamoDB), trên sáu trục: độ trễ, chi phí mỗi triệu event, công vận hành, giới hạn, REST API so
với HTTP API, Kinesis so với SQS. Số của bản serverless là **ước tính từ đơn giá** cho tới khi buổi đo của
[`README.md`](../README.md) xong; số của svp lấy từ ADR của `svp-backend`.

## Hai đường

- **EKS (svp).** `POST /videos/{id}/views` tới gateway rồi engagement-service; service produce `view.recorded` lên Kafka
  (`acks=all`, key `video_id`, hạn 2 s) rồi trả 202. Consumer gom tối đa 5.000 record hay 1 s, cộng dồn theo
  `video_id` trong bộ nhớ, ghi cả lô bằng một câu `INSERT ... ON CONFLICT` cùng offset của partition trong một
  transaction; lô giao lại chỉ cộng phần chưa cộng
  ([ADR-0009](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0009-engagement-feed-stage2b.md) §3, §4).
  Lỗi tạm thời thử lại trong ngân sách 5 phút rồi sang DLQ, phát lại bằng `dlq-replay`
  ([ADR-0045](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0045-bounded-batch-retry.md)). Ở stg, prd
  Kafka là Amazon MSK
  ([ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md)).
- **Serverless (bài này).** REST API gửi thẳng `SendMessage` vào SQS standard rồi trả 202; Lambda nhận lô tối đa 100
  record hay 1 s, mỗi lượt một `TransactWriteItems`: put mục chống trùng theo `event_id` cùng cộng bộ đếm của video.
  Chống trùng theo từng event, không theo offset, vì SQS standard không có offset và có thể giao trùng, lệch thứ tự
  [N1].

## Độ trễ

| | EKS (svp) | Serverless |
| --- | --- | --- |
| API, p50 / p95 / p99 | Chưa có số đo riêng của route lượt xem lúc bình thường. Điểm duy nhất: p99 458 ms khi engagement-service bị chèn trễ 200 ms (thí nghiệm (b), [phụ lục ADR-0021](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0021-deferred-verification-stage6b.md)) | Đo ở buổi (`measure.sh load`) |
| Đầu-cuối (gửi tới khi bộ đếm đổi) | Gom tối đa 1 s rồi một transaction; NFR chấp nhận trễ tới ~1 phút ([architecture §2](https://github.com/anhnvcoder/svp-backend/blob/main/docs/architecture.md#2-ràng-buộc-và-yêu-cầu-phi-chức-năng)) | Cửa sổ gom 1 s cộng thời gian ghi; đo từ `EndToEndLatencyMs` (`measure.sh e2e`) |
| Khởi động lạnh | Không: pod chạy sẵn | Môi trường thực thi mới phải tải code và chạy phần khởi tạo trước handler, tính tiền và cộng vào độ trễ [N2]; chỉ chạm lô đầu của mỗi môi trường, không chạm API vì đường vào không có Lambda |

Đường vào của bản serverless không có Lambda, nên độ trễ API chỉ gồm API Gateway và một lời gọi SQS; khởi động lạnh chỉ
làm chậm phía đếm, nằm trong độ trễ đầu-cuối.

## Chi phí mỗi triệu event

Hai mức tải: **mục tiêu tải của svp** ~10.000 event/s (36 triệu mỗi giờ) và **mức nhỏ** ~70 event/s (lượt xem trung bình
của 100k DAU, 252.000 mỗi giờ), cả hai từ
[capacity](https://github.com/anhnvcoder/svp-backend/blob/main/docs/explanation/capacity.md#kết-quả).

- **Serverless: chi phí theo lượng dùng, gần như không đổi mỗi triệu.** Ước tính từ đơn giá `ap-southeast-1` ở mục Chi
  phí của README: ~7,8 USD mỗi triệu với REST API (API Gateway 4,25, DynamoDB 2,84 vì 4 WRU mỗi lượt, SQS 0,48, phần
  còn lại nhỏ); ~4,8 USD với HTTP API.
- **EKS: chi phí theo giờ, chia cho số event.** Hạ tầng prd theo giờ ~0,90 USD
  ([ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) §10) cộng MSK và
  ElastiCache ~1,09 USD
  ([phụ lục ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0053-msk-elasticache-valkey.md)):
  ~1,99 USD mỗi giờ cho **cả env**, không riêng lượt xem. Riêng ba broker MSK `kafka.m7g.large`: 3 × 0,255 = 0,765 USD
  mỗi giờ
  ([phụ lục ADR-0049](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0049-kafka-prd.md)).

| Mức tải | Serverless, REST API | Serverless, HTTP API | EKS, cả env prd | EKS, chỉ MSK |
| --- | --- | --- | --- | --- |
| ~10.000 event/s, USD mỗi triệu | ~7,8 | ~4,8 | 1,99 / 36 ≈ 0,055 | 0,765 / 36 ≈ 0,021 |
| ~10.000 event/s, USD mỗi giờ | 36 × 7,8 ≈ 281 | 36 × 4,8 ≈ 173 | ~1,99 | 0,765 |
| ~70 event/s, USD mỗi triệu | ~7,8 | ~4,8 | 1,99 / 0,252 ≈ 7,9 | 0,765 / 0,252 ≈ 3,0 |
| ~70 event/s, USD mỗi giờ | 0,252 × 7,8 ≈ 2,0 | 0,252 × 4,8 ≈ 1,2 | ~1,99 | 0,765 |

Đọc bảng: ở mức nhỏ hai đường ngang nhau, kể cả khi tính cả env prd cho riêng lượt xem; ở mục tiêu tải bản serverless
đắt hơn khoảng 140 lần cả env, vì mỗi event trả tiền cho request API và cho write DynamoDB. Điểm hoà vốn với cả env prd
khoảng 1,99 / 7,8 ≈ 0,26 triệu event mỗi giờ, tức ~70 event/s. Phần EKS chưa tính egress, công vận hành và phần lượt xem
chia sẻ node, RDS với service khác; phần serverless chưa tính giới hạn ở mục dưới, mà ở mục tiêu tải thì phải nâng quota.

## Công vận hành

| Việc | EKS (svp) | Serverless |
| --- | --- | --- |
| Hạ tầng phải giữ | Cluster EKS nâng minor ít nhất mỗi ~14 tháng ([ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md)), MSK, RDS, node, autoscaling | Không máy chủ; cấu hình dịch vụ trong Terraform; quota của account |
| Code phải viết | Consumer theo lô, bảng offset, xử lý topic tạo lại, thử lại có ngân sách, công cụ phát lại DLQ (ADR-0009 §4, ADR-0045) | Handler mỗi record, partial batch response [N3]; SQS tự chuyển message lỗi sang DLQ theo `maxReceiveCount` [N4] |
| Quan sát | Prometheus, lag của consumer group, trace OpenTelemetry | Metric của dịch vụ, EMF [N5], lịch sử execution của Step Functions |
| Chạy local | Compose, k3d cùng phần mềm với cloud | Không có bản local cùng dịch vụ; test Go dùng bản giả |

## Giới hạn

- **Thứ tự.** Kafka giữ thứ tự mỗi partition, svp đặt key là `video_id` (ADR-0009 §3). SQS standard có thể giao lệch
  thứ tự và giao trùng [N1]: bộ đếm cộng không cần thứ tự, nhưng mọi luồng cần thứ tự theo thực thể thì không dùng được
  hàng đợi này.
- **Gom lô.** svp cộng dồn theo video trước khi ghi: một video viral nhận một câu ghi mỗi lô. Bản serverless ghi một
  transaction mỗi lượt xem lên cùng mục `video#<id>`; một mục chịu tối đa 1.000 WCU mỗi giây [N6], mỗi lượt tốn 2 WRU
  cho mục đó (write có transaction [N7]), nên một video chịu khoảng 500 lượt xem mỗi giây trước khi bị throttle.
  Transaction đồng thời trên cùng mục còn xung đột, bị huỷ rồi thử lại [N7]. Cộng dồn trong Lambda trước khi ghi đòi
  chống trùng theo lô, mà SQS không có offset để làm điều đó.
- **Khởi động lạnh.** Xem mục Độ trễ [N2].
- **Quota concurrency.** Lambda mặc định 1.000 môi trường đồng thời mỗi region [N8]; một event source mapping SQS tăng
  tối đa 300 mỗi phút, trần 1.250 [N9]. API Gateway mặc định 10.000 request/s cho mọi API của account trong region
  [N10]: mục tiêu tải của svp chạm đúng trần đó.

## REST API so với HTTP API

| | REST API (bài dùng) | HTTP API |
| --- | --- | --- |
| Giá `ap-southeast-1`, tầng đầu | 4,25 USD mỗi triệu request [P1] | 1,25 USD mỗi triệu request [P1] |
| Đưa request vào SQS | Mapping template dựng body và attribute, có hàm escape | Integration `SQS-SendMessage` nhận `MessageBody`, `MessageAttributes` từ tham số [N11] |
| Biến đổi body request | Có | Không [N12] |
| Throttling theo client, API key, WAF | Có | Không [N12] |

Bài chọn REST API vì mapping template dựng đúng body JSON có escape theo hợp đồng và WAF là đường chặn lạm dụng khi lên
thật. HTTP API rẻ hơn ~3,4 lần ở cửa vào, đáng chọn khi body gửi đi không cần biến đổi.

## Kinesis so với SQS cho đếm theo lô

| | SQS standard (bài dùng) | Kinesis Data Streams |
| --- | --- | --- |
| Thứ tự | Không đảm bảo [N1] | Lambda xử lý mỗi shard theo thứ tự, dừng shard khi lô lỗi [N13] |
| Chống trùng | Theo từng `event_id` (một mục DynamoDB mỗi event) | Theo sequence number mỗi shard, như offset của svp |
| Gom theo video | Không an toàn (không có offset) | Được: cộng dồn mỗi lô, một write mỗi video |
| Sức chứa | Gần như không giới hạn [N1] | Mỗi shard ghi tới 1.000 record/s [N14]: 10.000 event/s cần ≥ 10 shard |
| Giá ở 10.000 event/s (36 triệu mỗi giờ) | 1,2 request mỗi event (mục Chi phí của README) × 0,40 USD mỗi triệu request [P3] = 0,48 USD mỗi triệu event: 36 × 0,48 ≈ 17,3 USD mỗi giờ | 10 shard × 0,0184 = 0,184 cộng PUT 36 × 0,0195 ≈ 0,702: ≈ 0,89 USD mỗi giờ, ≈ 0,025 USD mỗi triệu event [P2] |

Ở mục tiêu tải, riêng phần hàng đợi Kinesis rẻ hơn SQS khoảng 20 lần (17,3 / 0,89 USD mỗi giờ). Kinesis đưa lại mô
hình của svp (thứ tự, offset, gom lô) lên dịch vụ managed: bỏ được phần write DynamoDB mỗi event, khoản lớn thứ hai
của bản SQS. Cái giá: phải chọn số shard và một lô lỗi chặn cả shard.

## Kết luận

- **EKS được:** chi phí theo giờ nên rẻ hơn hàng trăm lần mỗi event ở mục tiêu tải; gom lô theo video nên không có trần
  ghi của một mục nóng; giữ thứ tự theo `video_id`; một bộ công cụ cho local và cloud.
- **EKS mất:** công vận hành cluster, Kafka, consumer theo lô có bảng offset; trả tiền theo giờ kể cả khi không có tải,
  nên ở dưới ~70 event/s mỗi event đắt ngang hay hơn bản serverless.
- **Serverless hợp khi** tải nhỏ hay dồn cục, cần dựng nhanh, không có đội vận hành cluster; **không hợp** với đường ghi
  nóng ~10.000 event/s của svp nếu giữ thiết kế một write mỗi event. Phương án serverless đáng đo tiếp là Kinesis gom lô
  theo video, hay HTTP API ở cửa vào.

Kết luận cuối cùng chờ số đo của buổi và ADR của `svp-backend`.

## Nguồn

Tài liệu AWS đọc 2026-11-17.

- [N1] Amazon SQS, Standard queues:
  <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues.html>
- [N2] AWS Lambda, Understanding the Lambda execution environment lifecycle (cold start):
  <https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html>
- [N3] AWS Lambda, Handling errors for an SQS event source:
  <https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-errorhandling.html>
- [N4] Amazon SQS, Using dead-letter queues:
  <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html>
- [N5] Amazon CloudWatch, Embedded metric format specification:
  <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html>
- [N6] Amazon DynamoDB, Burst and adaptive capacity:
  <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/burst-adaptive-capacity.html>
- [N7] Amazon DynamoDB, Transactions (capacity, conflict):
  <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis.html>
- [N8] AWS Lambda, Lambda quotas: <https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html>
- [N9] AWS Lambda, Configuring scaling behavior for SQS event source mappings:
  <https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-scaling.html>
- [N10] API Gateway, Quotas: <https://docs.aws.amazon.com/apigateway/latest/developerguide/limits.html>
- [N11] API Gateway, Integration subtype reference:
  <https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-aws-services-reference.html>
- [N12] API Gateway, Choose between REST APIs and HTTP APIs:
  <https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html>
- [N13] AWS Lambda, Using Lambda with Kinesis Data Streams: <https://docs.aws.amazon.com/lambda/latest/dg/with-kinesis.html>
- [N14] Amazon Kinesis Data Streams, Quotas and limits:
  <https://docs.aws.amazon.com/streams/latest/dev/service-sizes-and-limits.html>

Giá đọc 2026-11-17 (file Price List bulk công khai của `ap-southeast-1`):

- [P1] AmazonApiGateway: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonApiGateway/current/ap-southeast-1/index.json>
- [P2] AmazonKinesis: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonKinesis/current/ap-southeast-1/index.json>
- [P3] AWSQueueService: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSQueueService/current/ap-southeast-1/index.json>
