docker build -t gemdw:latest .

aws ecr create-repository --repository-name gemdw

aws ecr get-login-password --region <REGION> | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker tag gemdw:latest <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/gemdw:latest
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/gemdw:latest


REGION=ap-south-1
ACCOUNT_ID=843581821008
IMAGE_URI=${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/gemdw:latest
LOG_GROUP=/ecs/gemdw
TASK_FAMILY=gemdw-task
TASK_EXEC_ROLE=ecsTaskExecutionRole-gemdw
TASK_ROLE=ecsTaskRole-gemdw

aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null || true

cat > trust-ecs-tasks.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

aws iam create-role \
  --role-name "$TASK_EXEC_ROLE" \
  --assume-role-policy-document file://trust-ecs-tasks.json 2>/dev/null || true


aws iam create-role \
  --role-name "$TASK_ROLE" \
  --assume-role-policy-document file://trust-ecs-tasks.json 2>/dev/null || true

cat > gemdw-s3-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PutObjectsUnderPrefix",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::svt-gem-dw-1/gemdw/*"
    },
    {
      "Sid": "ListBucketForPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::svt-gem-dw-1",
      "Condition": { "StringLike": { "s3:prefix": ["gemdw/*"] } }
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$TASK_ROLE" \
  --policy-name gemdw-s3-write \
  --policy-document file://gemdw-s3-policy.json

EXEC_ROLE_ARN=$(aws iam get-role --role-name "$TASK_EXEC_ROLE" --query 'Role.Arn' --output text)
TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE" --query 'Role.Arn' --output text)

cat > taskdef-gemdw.json <<JSON
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "gemdw",
      "image": "${IMAGE_URI}",
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "gemdw"
        }
      }
    }
  ]
}
JSON

aws ecs register-task-definition \
  --region "$REGION" \
  --cli-input-json file://taskdef-gemdw.json


  aws ecs create-cluster --cluster-name gemdw-cluster --region "$REGION" 2>/dev/null || true
CLUSTER=gemdw-cluster


SUBNETS="subnet-aaa,subnet-bbb"
SG="sg-xxxx"

aws ecs run-task \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$TASK_FAMILY" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}"

Got it. Default VPC does NOT come with “private subnets + NAT” by default (its subnets are usually public). So we’ll create:

2 private subnets (in 2 AZs)

1 NAT Gateway (in an existing default/public subnet)

1 private route table (0.0.0.0/0 → NAT)

1 security group for ECS tasks (egress open)

All via CloudShell in ap-south-1.

0) Set variables (CloudShell)
REGION=ap-south-1
CLUSTER=gemdw-cluster
TASK_FAMILY=gemdw-task

1) Find Default VPC + its public subnet (for NAT)
VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

echo "Default VPC: $VPC_ID"


Pick any existing default subnet to host NAT (typically public). List subnets:

aws ec2 describe-subnets --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,MapPublicIP:MapPublicIpOnLaunch}" \
  --output table


Now choose one subnet that looks public (often MapPublicIP = True). Set it:

PUBLIC_SUBNET_ID=<PASTE_ONE_SUBNET_ID_FROM_TABLE>

2) Create TWO private subnets (2 AZs)

Get two AZs:

AZ1=$(aws ec2 describe-availability-zones --region $REGION --query "AvailabilityZones[0].ZoneName" --output text)
AZ2=$(aws ec2 describe-availability-zones --region $REGION --query "AvailabilityZones[1].ZoneName" --output text)
echo $AZ1 $AZ2


Choose non-conflicting CIDRs inside default VPC’s CIDR (default is usually 172.31.0.0/16). We’ll use these (safe for default VPC):

172.31.200.0/24

172.31.201.0/24

Create private subnets:

PRIVATE_SUBNET_1=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID \
  --availability-zone $AZ1 --cidr-block 172.31.200.0/24 \
  --query "Subnet.SubnetId" --output text)

PRIVATE_SUBNET_2=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID \
  --availability-zone $AZ2 --cidr-block 172.31.201.0/24 \
  --query "Subnet.SubnetId" --output text)

echo "Private subnets: $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2"


Make sure they do not auto-assign public IPs:

aws ec2 modify-subnet-attribute --region $REGION --subnet-id $PRIVATE_SUBNET_1 --no-map-public-ip-on-launch
aws ec2 modify-subnet-attribute --region $REGION --subnet-id $PRIVATE_SUBNET_2 --no-map-public-ip-on-launch

3) Create NAT Gateway in the public subnet

Allocate an Elastic IP:

EIP_ALLOC_ID=$(aws ec2 allocate-address --region $REGION --domain vpc \
  --query "AllocationId" --output text)
echo "EIP AllocationId: $EIP_ALLOC_ID"


Create NAT Gateway:

NAT_GW_ID=$(aws ec2 create-nat-gateway --region $REGION \
  --subnet-id $PUBLIC_SUBNET_ID \
  --allocation-id $EIP_ALLOC_ID \
  --query "NatGateway.NatGatewayId" --output text)

echo "NAT Gateway: $NAT_GW_ID"


Wait until NAT is available (important):

aws ec2 wait nat-gateway-available --region $REGION --nat-gateway-ids $NAT_GW_ID
echo "NAT is available"

4) Create private route table and route private subnets to NAT

Create route table:

PRIVATE_RT_ID=$(aws ec2 create-route-table --region $REGION --vpc-id $VPC_ID \
  --query "RouteTable.RouteTableId" --output text)

echo "Private Route Table: $PRIVATE_RT_ID"


Add default route to NAT:

aws ec2 create-route --region $REGION \
  --route-table-id $PRIVATE_RT_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_GW_ID


Associate route table with both private subnets:

aws ec2 associate-route-table --region $REGION --subnet-id $PRIVATE_SUBNET_1 --route-table-id $PRIVATE_RT_ID
aws ec2 associate-route-table --region $REGION --subnet-id $PRIVATE_SUBNET_2 --route-table-id $PRIVATE_RT_ID

5) Create a security group for ECS tasks (egress only)
SG_ID=$(aws ec2 create-security-group --region $REGION \
  --group-name gemdw-ecs-sg \
  --description "ECS task SG for gemdw" \
  --vpc-id $VPC_ID \
  --query "GroupId" --output text)

echo "Security Group: $SG_ID"


Allow outbound to internet (default SG already allows egress, but we’ll be explicit):

aws ec2 authorize-security-group-egress --region $REGION \
  --group-id $SG_ID \
  --ip-permissions '[
    {"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}
  ]' 2>/dev/null || true


(No inbound rules needed.)

6) Create ECS cluster (if not created yet)
aws ecs create-cluster --cluster-name $CLUSTER --region $REGION 2>/dev/null || true

7) Run your task ONCE (test) in private subnets (no public IP)
aws ecs run-task \
  --region $REGION \
  --cluster $CLUSTER \
  --launch-type FARGATE \
  --task-definition $TASK_FAMILY \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2],securityGroups=[$SG_ID],assignPublicIp=DISABLED}"


Then tail logs:

aws logs tail /ecs/gemdw --region $REGION --since 15m --follow


You should see your script logs + “Uploaded to s3://svt-gem-dw-1/gemdw/…”.

Fix (CloudShell): attach the correct AWS-managed policy to the execution role

Run exactly:

REGION=ap-south-1
EXEC_ROLE=ecsTaskExecutionRole-gemdw

aws iam attach-role-policy \
  --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# (Optional) confirm it attached
aws iam list-attached-role-policies --role-name "$EXEC_ROLE" --output table


That managed policy includes the needed ECR auth actions (including ecr:GetAuthorizationToken) and CloudWatch Logs permissions.

Get your default VPC ID

Run this in CloudShell:

aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query "Vpcs[0].VpcId" \
  --output text


Example output:

vpc-0abc1234def56789


Set it:

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text)
echo $VPC_ID

2️⃣ List all subnets in that VPC (THIS IS THE KEY STEP)
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query "Subnets[].{
    SubnetId:SubnetId,
    AZ:AvailabilityZone,
    CIDR:CidrBlock,
    PublicIP:MapPublicIpOnLaunch
  }" \
  --output table


You’ll see something like:

-----------------------------------------------
|            DescribeSubnets                  |
+--------------+-----------+-----------------+
|  SubnetId    | AZ        | CIDR            |
+--------------+-----------+-----------------+
| subnet-aaa   | ap-south-1a | 172.31.0.0/20 | True
| subnet-bbb   | ap-south-1b | 172.31.16.0/20| True
| subnet-ccc   | ap-south-1c | 172.31.32.0/20| True
-----------------------------------------------

🔴 IMPORTANT

MapPublicIpOnLaunch = True → PUBLIC subnet

MapPublicIpOnLaunch = False → PRIVATE subnet

3️⃣ If you ALREADY created private subnets (earlier steps)

Look for:

MapPublicIpOnLaunch = False

CIDRs like 172.31.200.0/24, 172.31.201.0/24

Those are your private subnets.

Set them:

PRIVATE_SUBNET_1=subnet-xxxxxxxx
PRIVATE_SUBNET_2=subnet-yyyyyyyy