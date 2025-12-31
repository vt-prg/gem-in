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

function Write-Step([string]$msg) {
  Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Run-AwsJson([string]$cmd) {
  # Runs an AWS CLI command string and returns parsed JSON (ConvertFrom-Json).
  # Throws on non-zero exit or empty output.
  $out = Invoke-Expression $cmd
  if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: $cmd" }
  if ([string]::IsNullOrWhiteSpace($out)) { throw "AWS CLI returned empty output: $cmd" }
  return ($out | ConvertFrom-Json)
}

$ecr = "$AccountId.dkr.ecr.$Region.amazonaws.com"
$imageUri = "$ecr/$Repo`:$ImageTag"

Write-Step "AWS identity"
aws sts get-caller-identity --profile $Profile --region $Region | Out-Host
if ($LASTEXITCODE -ne 0) { throw "STS get-caller-identity failed. Did you run: aws sso login --profile $Profile ?" }

Write-Step "ECR login"
aws ecr get-login-password --region $Region --profile $Profile |
  docker login --username AWS --password-stdin $ecr | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ECR login failed" }

Write-Step "Build image: $imageUri"
docker build -t $imageUri .
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }

Write-Step "Push image"
docker push $imageUri | Out-Host
if ($LASTEXITCODE -ne 0) { throw "docker push failed" }

Write-Step "Load current task definition: $TaskDef"
$tdJson = Run-AwsJson "aws ecs describe-task-definition --task-definition `"$TaskDef`" --region `"$Region`" --profile `"$Profile`""
$td = $tdJson.taskDefinition

# Update image for all containers in the task def
foreach ($c in $td.containerDefinitions) { $c.image = $imageUri }

# Build register payload (strip read-only fields)
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

  # Include these if present (AWS may accept/require them depending on your TD)
  ipcMode                 = $td.ipcMode
  pidMode                 = $td.pidMode
  proxyConfiguration       = $td.proxyConfiguration
  inferenceAccelerators    = $td.inferenceAccelerators
  ephemeralStorage         = $td.ephemeralStorage
}

# Remove null keys (AWS rejects some nulls)
$nullKeys = @()
foreach ($k in $payload.Keys) { if ($null -eq $payload[$k]) { $nullKeys += $k } }
foreach ($k in $nullKeys) { $payload.Remove($k) }

# Write JSON as UTF-8 WITHOUT BOM (AWS CLI can choke on BOM)
$tempFile = Join-Path $env:TEMP "ecs-register-gemdw.json"
$json = ($payload | ConvertTo-Json -Depth 80)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tempFile, $json, $utf8NoBom)

# Use file:/// path format for AWS CLI reliability on Windows
$fileUri = "file:///" + ($tempFile -replace '\\','/')

Write-Step "Register new task definition revision"
$regRaw = aws ecs register-task-definition --cli-input-json $fileUri --region $Region --profile $Profile
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($regRaw)) {
  throw "register-task-definition failed. Open JSON and fix: $tempFile"
}

$reg = $regRaw | ConvertFrom-Json
$newTdArn = $reg.taskDefinition.taskDefinitionArn
if ([string]::IsNullOrWhiteSpace($newTdArn)) {
  throw "register-task-definition returned no taskDefinitionArn. JSON file: $tempFile"
}

Write-Host "New task definition: $newTdArn" -ForegroundColor Green

Write-Step "Run ECS one-off task (PRIVATE subnets via NAT, assignPublicIp DISABLED)"
$netCfg = "awsvpcConfiguration={subnets=[{0}],securityGroups=[{1}],assignPublicIp=DISABLED}" -f ($Subnets -join ","), ($SecGroups -join ",")

$run = Run-AwsJson ("aws ecs run-task --cluster `"$Cluster`" --task-definition `"$newTdArn`" --launch-type FARGATE --network-configuration `"$netCfg`" --region `"$Region`" --profile `"$Profile`"")

if (-not $run.tasks -or $run.tasks.Count -eq 0) {
  Write-Host "Run-task failed. Failures:" -ForegroundColor Red
  $run.failures | ConvertTo-Json -Depth 10 | Out-Host
  throw "ecs run-task failed"
}

$taskArn = $run.tasks[0].taskArn
Write-Host "Task started: $taskArn" -ForegroundColor Green

Write-Step "Wait for STOPPED"
aws ecs wait tasks-stopped --cluster $Cluster --tasks $taskArn --region $Region --profile $Profile
if ($LASTEXITCODE -ne 0) { throw "ecs wait tasks-stopped failed" }

$desc = Run-AwsJson "aws ecs describe-tasks --cluster `"$Cluster`" --tasks `"$taskArn`" --region `"$Region`" --profile `"$Profile`""

Write-Step "RESULT"
foreach ($c in $desc.tasks[0].containers) {
  "container={0} | exitCode={1} | reason={2}" -f $c.name, $c.exitCode, $c.reason | Out-Host
}

Write-Host "`nTip: If awslogs is enabled in the task definition, check CloudWatch Logs for full output." -ForegroundColor Yellow
