Below is the exact CloudShell workflow to:

update your Dockerfile

rebuild the image

push to ECR

register a new ECS task definition revision using the new image

update your EventBridge schedule target to use the new revision

This assumes:

Region: ap-south-1

Account: 843581821008

ECR repo: gemdw

Cluster: gemdw-cluster

Task family: gemdw-task

Rule: gemdw-every-6-hours

A) Update Dockerfile (recommended version)

In CloudShell, open editor:

nano Dockerfile


Use this Dockerfile (safe, minimal, uses your script’s CLI defaults if you pass args via CMD):

FROM python:3.11-slim

WORKDIR /app

# Copy script
COPY gem_latest.py /app/gem_latest.py

# Install deps
RUN pip install --no-cache-dir requests boto3

# Create writable work dir
RUN mkdir -p /data/pdfs

# Default command (can be overridden in ECS task def if needed)
CMD ["python","/app/gem_latest.py",
     "--keyword","Toner",
     "--state","Uttar Pradesh",
     "--pages","2",
     "--out","/data/latest_bids.json",
     "--download-pdf",
     "--pdf-dir","/data/pdfs",
     "--pdf-timeout","90",
     "--upload-s3",
     "--s3-bucket","svt-gem-dw-1",
     "--s3-prefix","gemdw"]


Save and exit (nano): Ctrl+O, Enter, Ctrl+X.

If you prefer not to bake args into the image, tell me — we’ll move these into ECS command overrides instead.

B) Rebuild + push image to ECR

Set variables:

REGION=ap-south-1
ACCOUNT_ID=843581821008
REPO=gemdw
IMAGE_URI=${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}
TAG=$(date +%Y%m%d-%H%M%S)
echo "TAG=$TAG"


Login (if not already):

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com


Build:

docker build -t ${REPO}:${TAG} .


Tag for ECR:

docker tag ${REPO}:${TAG} ${IMAGE_URI}:${TAG}
docker tag ${REPO}:${TAG} ${IMAGE_URI}:latest


Push both tags:

docker push ${IMAGE_URI}:${TAG}
docker push ${IMAGE_URI}:latest

C) Register new ECS task definition revision (points to the new image tag)

We’ll create a new revision of gemdw-task using the timestamp tag (best practice).

EXEC_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole-gemdw --query 'Role.Arn' --output text)
TASK_ROLE_ARN=$(aws iam get-role --role-name ecsTaskRole-gemdw --query 'Role.Arn' --output text)

LOG_GROUP=/ecs/gemdw

cat > taskdef-gemdw.json <<JSON
{
  "family": "gemdw-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "gemdw",
      "image": "${IMAGE_URI}:${TAG}",
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

aws ecs register-task-definition --region $REGION --cli-input-json file://taskdef-gemdw.json


Get the new task definition ARN:

NEW_TASKDEF_ARN=$(aws ecs describe-task-definition --region $REGION --task-definition gemdw-task --query 'taskDefinition.taskDefinitionArn' --output text)
echo "NEW_TASKDEF_ARN=$NEW_TASKDEF_ARN"

D) Update EventBridge schedule target to use the new revision

EventBridge target stores a specific TaskDefinitionArn, so update it:

RULE_NAME=gemdw-every-6-hours

# Reuse existing target ID; if different, check it with list-targets-by-rule
aws events list-targets-by-rule --region $REGION --rule "$RULE_NAME" --output table


Now update the target JSON to point to the new task def ARN (also keeps your private subnets/SG exactly as configured).

If you already have variables set for subnets/SG, reuse them:

PRIVATE_SUBNET_1, PRIVATE_SUBNET_2, SG_ID
If not, run:

# Default VPC
VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text)

# SG (created earlier)
SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values=gemdw-ecs-sg --query "SecurityGroups[0].GroupId" --output text)

# Two private subnets (MapPublicIpOnLaunch=false)
SUBNETS=$(aws ec2 describe-subnets --region $REGION --filters Name=vpc-id,Values=$VPC_ID --query "Subnets[?MapPublicIpOnLaunch==\`false\`].SubnetId" --output text)
PRIVATE_SUBNET_1=$(echo $SUBNETS | awk '{print $1}')
PRIVATE_SUBNET_2=$(echo $SUBNETS | awk '{print $2}')

echo $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2 $SG_ID


Now update the rule target:

CLUSTER=gemdw-cluster
EVENT_ROLE_ARN=$(aws iam get-role --role-name eventbridge-run-ecs-gemdw --query 'Role.Arn' --output text)

cat > targets.json <<JSON
[
  {
    "Id": "gemdw-ecs-target",
    "Arn": "arn:aws:ecs:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER}",
    "RoleArn": "${EVENT_ROLE_ARN}",
    "EcsParameters": {
      "TaskDefinitionArn": "${NEW_TASKDEF_ARN}",
      "TaskCount": 1,
      "LaunchType": "FARGATE",
      "NetworkConfiguration": {
        "awsvpcConfiguration": {
          "Subnets": ["${PRIVATE_SUBNET_1}", "${PRIVATE_SUBNET_2}"],
          "SecurityGroups": ["${SG_ID}"],
          "AssignPublicIp": "DISABLED"
        }
      },
      "PlatformVersion": "LATEST"
    }
  }
]
JSON

aws events put-targets --region $REGION --rule "$RULE_NAME" --targets file://targets.json


Verify:

aws events list-targets-by-rule --region $REGION --rule "$RULE_NAME" --output table

E) Quick “run now” test (recommended)
aws ecs run-task \
  --region $REGION \
  --cluster $CLUSTER \
  --launch-type FARGATE \
  --task-definition "$NEW_TASKDEF_ARN" \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2],securityGroups=[$SG_ID],assignPublicIp=DISABLED}"


Watch logs:

aws logs tail /ecs/gemdw --region $REGION --since 30m --follow