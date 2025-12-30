Below is the clean, CloudShell copy-paste way to schedule your ECS Fargate task every 6 hours using EventBridge, running in private subnets + NAT.

I’ll auto-discover:

default VPC

your private subnets (the ones you created)

your security group (gemdw-ecs-sg)

your task definition ARN

your cluster (gemdw-cluster)

1) Set variables + auto-discover subnets/SG/taskdef
REGION=ap-south-1
CLUSTER=gemdw-cluster
TASK_FAMILY=gemdw-task
RULE_NAME=gemdw-every-6-hours
SG_NAME=gemdw-ecs-sg

# Default VPC
VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text)
echo "VPC_ID=$VPC_ID"

# Security group by name
SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values=$SG_NAME --query "SecurityGroups[0].GroupId" --output text)
echo "SG_ID=$SG_ID"

# Pick 2 private subnets in default VPC (MapPublicIpOnLaunch = false)
SUBNETS=$(aws ec2 describe-subnets --region $REGION \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query "Subnets[?MapPublicIpOnLaunch==\`false\`].SubnetId" --output text)

echo "PRIVATE SUBNETS FOUND: $SUBNETS"

# Convert first two into variables
PRIVATE_SUBNET_1=$(echo $SUBNETS | awk '{print $1}')
PRIVATE_SUBNET_2=$(echo $SUBNETS | awk '{print $2}')
echo "PRIVATE_SUBNET_1=$PRIVATE_SUBNET_1"
echo "PRIVATE_SUBNET_2=$PRIVATE_SUBNET_2"

# Task definition ARN
TASKDEF_ARN=$(aws ecs describe-task-definition --region $REGION --task-definition $TASK_FAMILY --query "taskDefinition.taskDefinitionArn" --output text)
echo "TASKDEF_ARN=$TASKDEF_ARN"


✅ If PRIVATE_SUBNET_1 or PRIVATE_SUBNET_2 is empty, you don’t have two private subnets yet (or they weren’t created in the default VPC). Tell me and I’ll fix that.

2) Create IAM role for EventBridge to run ECS tasks

EventBridge needs a role so it can call ecs:RunTask and pass roles to ECS.

EVENT_ROLE=eventbridge-run-ecs-gemdw

cat > trust-events.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "events.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

aws iam create-role --role-name "$EVENT_ROLE" --assume-role-policy-document file://trust-events.json 2>/dev/null || true


Now attach permissions (replace role names if yours differ):

TASK_ROLE_ARN=$(aws iam get-role --role-name ecsTaskRole-gemdw --query 'Role.Arn' --output text)
EXEC_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole-gemdw --query 'Role.Arn' --output text)

cat > eventbridge-ecs-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RunTask",
      "Effect": "Allow",
      "Action": ["ecs:RunTask"],
      "Resource": "$TASKDEF_ARN"
    },
    {
      "Sid": "PassRolesToECS",
      "Effect": "Allow",
      "Action": ["iam:PassRole"],
      "Resource": ["$TASK_ROLE_ARN", "$EXEC_ROLE_ARN"]
    },
    {
      "Sid": "DescribeTaskDef",
      "Effect": "Allow",
      "Action": ["ecs:DescribeTaskDefinition"],
      "Resource": "*"
    }
  ]
}
JSON

aws iam put-role-policy --role-name "$EVENT_ROLE" --policy-name eventbridge-run-ecs --policy-document file://eventbridge-ecs-policy.json


Get the role ARN:

EVENT_ROLE_ARN=$(aws iam get-role --role-name "$EVENT_ROLE" --query 'Role.Arn' --output text)
echo "EVENT_ROLE_ARN=$EVENT_ROLE_ARN"

3) Create the EventBridge schedule rule (every 6 hours)

This runs at 00:00, 06:00, 12:00, 18:00 UTC:

aws events put-rule \
  --region $REGION \
  --name "$RULE_NAME" \
  --schedule-expression "cron(0 0/6 * * ? *)" \
  --state ENABLED


If you want it aligned to specific IST times, tell me your preferred IST run times and I’ll convert to the right UTC cron.

4) Attach ECS Fargate target (private subnets + SG)
cat > targets.json <<JSON
[
  {
    "Id": "gemdw-ecs-target",
    "Arn": "arn:aws:ecs:$REGION:$(aws sts get-caller-identity --query Account --output text):cluster/$CLUSTER",
    "RoleArn": "$EVENT_ROLE_ARN",
    "EcsParameters": {
      "TaskDefinitionArn": "$TASKDEF_ARN",
      "TaskCount": 1,
      "LaunchType": "FARGATE",
      "NetworkConfiguration": {
        "awsvpcConfiguration": {
          "Subnets": ["$PRIVATE_SUBNET_1", "$PRIVATE_SUBNET_2"],
          "SecurityGroups": ["$SG_ID"],
          "AssignPublicIp": "DISABLED"
        }
      },
      "PlatformVersion": "LATEST"
    }
  }
]
JSON

aws events put-targets --region $REGION --rule "$RULE_NAME" --targets file://targets.json

5) Verify the rule + targets
aws events describe-rule --region $REGION --name "$RULE_NAME"
aws events list-targets-by-rule --region $REGION --rule "$RULE_NAME" --output table

6) Confirm it actually runs

After the next scheduled time, check ECS stopped tasks and logs:

aws ecs list-tasks --region $REGION --cluster $CLUSTER --desired-status STOPPED --max-results 5
aws logs tail /ecs/gemdw --region $REGION --since 2h --follow

Common “it didn’t run” causes (quick)

Missing two private subnets → target fails

Wrong SG ID → ENI attach fails

EventBridge role missing iam:PassRole for both roles → run-task denied

NAT/routing broken → pulls fail (you already saw that earlier)

~ $ aws events describe-rule --region $REGION --name "$RULE_NAME"
{
    "Name": "gemdw-every-6-hours",
    "Arn": "arn:aws:events:ap-south-1:843581821008:rule/gemdw-every-6-hours",
    "ScheduleExpression": "cron(0 0/6 * * ? *)",
    "State": "ENABLED",
    "EventBusName": "default",
    "CreatedBy": "843581821008"
}
~ $ aws events list-targets-by-rule --region $REGION --rule "$RULE_NAME" --output table
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
|                                                                           ListTargetsByRule                                                                          |
+----------------------------------------------------------------------------------------------------------------------------------------------------------------------+
||                                                                               Targets                                                                              ||
|+---------------------------------------------------------------------+-----------------------+----------------------------------------------------------------------+|
||                                 Arn                                 |          Id           |                               RoleArn                                ||
|+---------------------------------------------------------------------+-----------------------+----------------------------------------------------------------------+|
||  arn:aws:ecs:ap-south-1:843581821008:cluster/gemdw-cluster          |  gemdw-ecs-target     |  arn:aws:iam::843581821008:role/eventbridge-run-ecs-gemdw            ||
|+---------------------------------------------------------------------+-----------------------+----------------------------------------------------------------------+|
|||                                                                           EcsParameters                                                                          |||
||+----------------------+-----------------------+-------------+------------------+------------+---------------------------------------------------------------------+||
||| EnableECSManagedTags | EnableExecuteCommand  | LaunchType  | PlatformVersion  | TaskCount  |                          TaskDefinitionArn                          |||
||+----------------------+-----------------------+-------------+------------------+------------+---------------------------------------------------------------------+||
|||  False               |  False                |  FARGATE    |  LATEST          |  1         |  arn:aws:ecs:ap-south-1:843581821008:task-definition/gemdw-task:1   |||
||+----------------------+-----------------------+-------------+------------------+------------+---------------------------------------------------------------------+||
||||                                                                      NetworkConfiguration                                                                      ||||
|||+----------------------------------------------------------------------------------------------------------------------------------------------------------------+|||
|||||                                                                      awsvpcConfiguration                                                                     |||||
||||+----------------------------------------------------------------------------------------------+---------------------------------------------------------------+||||
|||||  AssignPublicIp                                                                              |  DISABLED                                                     |||||
||||+----------------------------------------------------------------------------------------------+---------------------------------------------------------------+||||
||||||                                                                       SecurityGroups                                                                       ||||||
|||||+------------------------------------------------------------------------------------------------------------------------------------------------------------+|||||
||||||  sg-0206813926c8e25ee                                                                                                                                      ||||||
|||||+------------------------------------------------------------------------------------------------------------------------------------------------------------+|||||
||||||                                                                           Subnets                                                                          ||||||
|||||+------------------------------------------------------------------------------------------------------------------------------------------------------------+|||||
||||||  subnet-09f578f938facc7f3                                                                                                                                  ||||||
||||||  subnet-032ec5983f626f32a                                                                                                                                  ||||||
|||||+------------------------------------------------------------------------------------------------------------------------------------------------------------+|||||
