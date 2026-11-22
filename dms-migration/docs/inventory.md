# Tài nguyên mỗi root của `dms-migration` tạo trên account trống

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

## `dms-migration/terraform`

- Account chưa có `dms-vpc-role`, `dms-cloudwatch-logs-role`, nên lab tạo cả hai: mock đặt
  `create_dms_vpc_role`, `create_dms_logs_role` là `true`, thay giá trị của `dms.auto.tfvars.example` (file cho account đã có role).
- Khi sinh bảng, khối `ephemeral` thay bằng giá trị giả của `scripts/inventory/dms-migration.override.hcl`
  (provider giả không trả được ephemeral); ephemeral không phải tài nguyên nên số không đổi.

`Plan: 56 to add, 0 to change, 0 to destroy.`

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/diagrams/inventory/dms-migration-dark.svg">
  <img src="../../docs/diagrams/inventory/dms-migration.svg" alt="Tài nguyên của dms-migration">
</picture>

| Phần | Tài nguyên |
| --- | ---: |
| `module.aws_network` | 6 |
| `module.dms` | 20 |
| `module.onprem_network` | 6 |
| `module.peering` | 3 |
| `module.source_db` | 12 |
| `module.source_secret` | 2 |
| `module.target_db` | 5 |
| `module.target_secret` | 2 |

| Loại | Dịch vụ | Số |
| --- | --- | ---: |
| `aws_cloudwatch_log_group` | CloudWatch | 1 |
| `aws_db_instance` | RDS | 1 |
| `aws_db_subnet_group` | RDS | 1 |
| `aws_dms_certificate` | DMS | 1 |
| `aws_dms_endpoint` | DMS | 2 |
| `aws_dms_replication_instance` | DMS | 1 |
| `aws_dms_replication_subnet_group` | DMS | 1 |
| `aws_dms_replication_task` | DMS | 1 |
| `aws_iam_instance_profile` | IAM | 1 |
| `aws_iam_role` | IAM | 4 |
| `aws_iam_role_policy` | IAM | 3 |
| `aws_iam_role_policy_attachment` | IAM | 3 |
| `aws_instance` | EC2 | 1 |
| `aws_internet_gateway` | VPC | 1 |
| `aws_route` | VPC | 3 |
| `aws_route_table` | VPC | 2 |
| `aws_route_table_association` | VPC | 3 |
| `aws_secretsmanager_secret` | Secrets Manager | 2 |
| `aws_secretsmanager_secret_version` | Secrets Manager | 2 |
| `aws_security_group` | VPC | 4 |
| `aws_ssm_parameter` | Systems Manager | 1 |
| `aws_subnet` | VPC | 3 |
| `aws_vpc` | VPC | 2 |
| `aws_vpc_endpoint` | PrivateLink | 1 |
| `aws_vpc_peering_connection` | VPC | 1 |
| `aws_vpc_security_group_egress_rule` | VPC | 5 |
| `aws_vpc_security_group_ingress_rule` | VPC | 5 |
