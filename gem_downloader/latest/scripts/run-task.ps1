param(
  [string]$Profile = "svt-sso-ecs",
  [string]$Region  = "ap-south-1",

  [string]$AccountId = "843581821008",
  [string]$Repo      = "gemdw",
  [string]$ImageTag  = "$(Get-Date -Format 'yyyyMMdd-HHmmss')",

  [string]$Cluster   = "gemdw-cluster",
  [string]$TaskDef   = "arn:aws:ecs:ap-south-1:843581821008:task-definition/gemdw-task:1",

  [string[]]$Subnets   = @("subnet-09f578f938facc7f3","subnet-032ec5983f626f32a"),
  [string[]]$SecGroups = @("sg-0206813926c8e25ee")
)

$ErrorActionPreference = "Stop"

$ecr = "$AccountId.dkr.ecr.$Region.amazonaws.com"
$imageUri = "$ecr/$Repo`:$ImageTag"

Write-Host "==> AWS identity"
aws sts get-caller-identity --profile $Profile --region $Region | Out-Host

Write-Host "==> ECR login"
aws ecr get-login-password --region $Region --profile $Profile |
  docker login --username AWS --password-stdin $ecr | Out-Null

Write-Host "==> Build image: $imageUri"
docker build -t $imageUri .

Write-Host "==> Push image"
docker push $imageUri | Out-Host

Write-Host "==> Load current task definition"
$tdJson = aws ecs describe-task-definition `
  --task-definition $TaskDef `
  --region $Region --profile $Profile | ConvertFrom-Json

$td = $tdJson.taskDefinition

foreach ($c in $td.containerDefinitions) {
  $c.image = $imageUri
}

$payload = [ordered]@{
  family                  = $td.family
  taskRoleArn             = $td.taskRoleArn
  executionRoleArn        = $td.executionRoleArn
  networkMode             = $td.networkMode
  containerDefinitions    = $td.containerDefinitions
  volumes                 = $td.volumes
  placementConstraints    = $td.placementConstraints
  requiresCompatibilities = $td.requiresCompatibilities
  cpu                     = $td.cpu
  memory                  = $td.memory
  runtimePlatform         = $td.runtimePlatform
}

$nullKeys = @()
foreach ($k in $payload.Keys) {
  if ($null -eq $payload[$k]) { $nullKeys += $k }
}
foreach ($k in $nullKeys) { $payload.Remove($k) }

$tempFile = Join-Path $env:TEMP "ecs-register-gemdw.json"
$payload | ConvertTo-Json -Depth 60 | Set-Content -Encoding UTF8 $tempFile

Write-Host "==> Register new task definition revision"
$reg = aws ecs register-task-definition `
  --cli-input-json "file://$tempFile" `
  --region $Region --profile $Profile | ConvertFrom-Json

$newTdArn = $reg.taskDefinition.taskDefinitionArn
Write-Host "New task definition: $newTdArn"

Write-Host "==> Run ECS one-off task (PRIVATE subnets via NAT)"
$netCfg = "awsvpcConfiguration={subnets=[subnet-09f578f938facc7f3,subnet-032ec5983f626f32a],securityGroups=[sg-0206813926c8e25ee],assignPublicIp=DISABLED}"

$run = aws ecs run-task `
  --cluster $Cluster `
  --task-definition $newTdArn `
  --launch-type FARGATE `
  --network-configuration $netCfg `
  --region $Region --profile $Profile | ConvertFrom-Json

$taskArn = $run.tasks[0].taskArn
Write-Host "Task started: $taskArn"

Write-Host "==> Waiting for task to STOP"
aws ecs wait tasks-stopped `
  --cluster $Cluster `
  --tasks $taskArn `
  --region $Region --profile $Profile

$desc = aws ecs describe-tasks `
  --cluster $Cluster `
  --tasks $taskArn `
  --region $Region --profile $Profile | ConvertFrom-Json

$container = $desc.tasks[0].containers[0]

Write-Host "==> RESULT"
"container=$($container.name) | exitCode=$($container.exitCode) | reason=$($container.reason)" | Out-Host

Write-Host "`nCheck CloudWatch Logs for detailed output."
