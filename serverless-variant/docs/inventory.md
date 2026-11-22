# Tài nguyên mỗi root của `serverless-variant` tạo trên account trống

Trang này đếm, cho mỗi root Terraform của lab, các tài nguyên mà lần `apply` đầu tiên tạo trên account chưa có gì của root đó, chia
theo phần và theo loại, kèm một sơ đồ. Đọc trước khi chạy một root để biết plan đúng ra bao nhiêu `to add` và chúng thuộc dịch vụ
nào; các bước của buổi ở [README của lab](../README.md). Trang và sơ đồ sinh bằng `make inventory` từ plan của `terraform test` trên
provider giả: offline, không credential, không phí. Không sửa tay: `make inventory-check` ở CI đỏ khi trang hay sơ đồ lệch code. Lý
do chọn cách này, và các phương án đã bỏ:
[ADR-0081](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0081-terraform-inventory.md).

## Cách đọc

- Dòng `Plan: …` là dòng tóm tắt `terraform plan` in ra trên account trống; `to import` là tài nguyên root nhận quản qua khối `import`
  thay vì tạo.
- **Phần**: lời gọi module cấp root (`module.<tên>`); tài nguyên khai báo thẳng trong root thì là file `.tf` khai báo nó.
- Bảng theo loại đếm mọi bản của `count`, `for_each`; cột dịch vụ là dịch vụ AWS của icon trên sơ đồ.
- Sơ đồ: mỗi khối một phần, tiêu đề ghi số tài nguyên của phần; mỗi icon một dịch vụ AWS kèm số tài nguyên của dịch vụ đó trong phần.
  Icon lấy từ bộ AWS Architecture Icons ([nguồn và bản](../../docs/diagrams/README.md#icon)).

## Giới hạn

- Số là của **account trống chạy lần đầu**. Chạy root trên account đã có một phần của nó: plan thật chỉ hiện phần còn thiếu cùng các
  thay đổi.
- Giá trị: biến theo mặc định của `variables.tf`, rồi theo `*.auto.tfvars.example` của root nếu có; account id giả dạng
  `000000000000`. Buổi đặt biến khác (file `*.auto.tfvars`) thì số đổi theo.
- Data source trả giá trị giả của `scripts/inventory/<slug>.tftest.hcl` (provider giả, không đọc account). Mỗi root dưới đây nêu giả
  định nào của giá trị giả quyết định số.

## `serverless-variant/terraform`

- Account trống. `archive_file` chạy trên provider giả: plan không cần `make lambda-build`, số không
  phụ thuộc binary.

`Plan: 48 to add, 0 to change, 0 to destroy.`

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/diagrams/inventory/serverless-variant-dark.svg">
  <img src="../../docs/diagrams/inventory/serverless-variant.svg" alt="Tài nguyên của serverless-variant">
</picture>

| Phần | Tài nguyên |
| --- | ---: |
| `module.counter` | 4 |
| `module.transcode` | 4 |
| `module.transcode_flow` | 19 |
| `module.view_counter` | 2 |
| `module.view_ingest` | 19 |

| Loại | Dịch vụ | Số |
| --- | --- | ---: |
| `aws_api_gateway_deployment` | API Gateway | 1 |
| `aws_api_gateway_integration` | API Gateway | 1 |
| `aws_api_gateway_integration_response` | API Gateway | 2 |
| `aws_api_gateway_method` | API Gateway | 1 |
| `aws_api_gateway_method_response` | API Gateway | 2 |
| `aws_api_gateway_method_settings` | API Gateway | 1 |
| `aws_api_gateway_resource` | API Gateway | 3 |
| `aws_api_gateway_rest_api` | API Gateway | 1 |
| `aws_api_gateway_stage` | API Gateway | 1 |
| `aws_cloudwatch_event_bus` | EventBridge | 1 |
| `aws_cloudwatch_event_rule` | EventBridge | 2 |
| `aws_cloudwatch_event_target` | EventBridge | 2 |
| `aws_cloudwatch_log_group` | CloudWatch | 4 |
| `aws_cloudwatch_log_resource_policy` | CloudWatch | 1 |
| `aws_dynamodb_table` | DynamoDB | 1 |
| `aws_iam_role` | IAM | 5 |
| `aws_iam_role_policy` | IAM | 5 |
| `aws_lambda_event_source_mapping` | Lambda | 1 |
| `aws_lambda_function` | Lambda | 2 |
| `aws_s3_bucket` | S3 | 1 |
| `aws_s3_bucket_notification` | S3 | 1 |
| `aws_s3_bucket_ownership_controls` | S3 | 1 |
| `aws_s3_bucket_policy` | S3 | 1 |
| `aws_s3_bucket_public_access_block` | S3 | 1 |
| `aws_s3_bucket_server_side_encryption_configuration` | S3 | 1 |
| `aws_sfn_state_machine` | Step Functions | 1 |
| `aws_sqs_queue` | SQS | 2 |
| `aws_sqs_queue_policy` | SQS | 2 |
