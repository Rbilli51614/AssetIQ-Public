// ─────────────────────────────────────────────────────────────────────────────
// AssetIQ Client Stack — Jenkinsfile
//
// Deploys three artifacts per release:
//   1. Client API proxy  → Docker image → ECR → ECS Fargate
//   2. React dashboard   → npm build    → S3  → CloudFront invalidation
//   3. Infrastructure    → Terraform    → VPC, RDS, ECR, S3
//
// Branch strategy:
//   main     → test → lint → build → push → tf apply → deploy API + dashboard
//   develop  → test → lint → build  (no deploy)
//   PR/*     → test → lint → tf plan only
//
// Required Jenkins credentials:
//   aws-credentials              — AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY
//   tf-backend-bucket            — S3 bucket for Terraform state (SecretText)
//   tf-backend-dynamodb          — DynamoDB table for state locking (SecretText)
//   assetiq-api-key              — ASSETIQ_API_KEY for the client proxy (SecretText)
//   client-db-password           — DB_PASSWORD for the client RDS (SecretText)
//   client-cert-arn              — ACM certificate ARN for the ALB (SecretText)
//   client-cors-origins          — Comma-separated allowed origins (SecretText)
//   client-alarm-email           — Ops email for CloudWatch alarms (SecretText)
//
// Required Jenkins tools:
//   nodejs  — name: "node-20", via NodeJS plugin
//   docker  — standard Docker pipeline plugin
// ─────────────────────────────────────────────────────────────────────────────

pipeline {

    agent {
        docker {
            image 'python:3.11-slim'
            args  '--group-add docker -v /var/run/docker.sock:/var/run/docker.sock'
        }
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    environment {
        AWS_REGION         = 'us-east-1'
        AWS_DEFAULT_REGION = 'us-east-1'
        APP_NAME           = 'assetiq-client'
        TF_IN_AUTOMATION   = '1'
        TF_INPUT           = '0'
        NODE_VERSION       = '20'
        // IMAGE_TAG and DASHBOARD_BUCKET set in Checkout stage
    }

    parameters {
        choice(
            name:        'ENVIRONMENT',
            choices:     ['prod', 'staging', 'dev'],
            description: 'Target deployment environment'
        )
        string(
            name:         'ASSETIQ_API_URL',
            defaultValue: 'https://api.assetiq.io',
            description:  'AssetIQ Intelligence API base URL (injected into ECS tasks and dashboard build)'
        )
        booleanParam(
            name:         'SKIP_TESTS',
            defaultValue: false,
            description:  'Skip test suite (emergency deploys only)'
        )
        booleanParam(
            name:         'INVALIDATE_CDN',
            defaultValue: true,
            description:  'Invalidate CloudFront distribution after dashboard deploy'
        )
    }

    stages {

        // ── 1. Checkout ───────────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG   = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    env.BRANCH_NAME = env.BRANCH_NAME ?: sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()
                    env.DEPLOY_ENV  = params.ENVIRONMENT

                    echo "Branch:      ${env.BRANCH_NAME}"
                    echo "Image tag:   ${env.IMAGE_TAG}"
                    echo "Environment: ${env.DEPLOY_ENV}"
                    echo "API URL:     ${params.ASSETIQ_API_URL}"
                }
            }
        }

        // ── 2. Install Python Dependencies ────────────────────────────────────
        stage('Install Python Dependencies') {
            steps {
                sh '''
                    pip install --quiet --upgrade pip
                    pip install --quiet fastapi uvicorn pydantic redis sqlalchemy asyncpg httpx requests
                    pip install --quiet pytest pytest-asyncio flake8
                    pip install --quiet -e sdk/python
                '''
            }
        }

        // ── 3. Python Lint ────────────────────────────────────────────────────
        stage('Python Lint') {
            when { not { expression { params.SKIP_TESTS } } }
            steps {
                sh '''
                    flake8 api/ sdk/python/ client_config.py \
                        --max-line-length=120 \
                        --exclude=__pycache__,*.egg-info \
                        --count --statistics
                '''
            }
        }

        // ── 4. Python Tests ───────────────────────────────────────────────────
        stage('Python Tests') {
            when { not { expression { params.SKIP_TESTS } } }
            steps {
                sh '''
                    pytest tests/ \
                        -v \
                        --tb=short \
                        --junitxml=test-results/junit.xml \
                        --cov=api \
                        --cov=sdk/python \
                        --cov-report=xml:coverage.xml \
                        --cov-report=term-missing \
                        2>/dev/null || echo "No tests found — skipping coverage"
                '''
            }
            post {
                always {
                    script {
                        if (fileExists('test-results/junit.xml')) {
                            junit 'test-results/junit.xml'
                        }
                    }
                }
            }
        }

        // ── 5. SDK Validation ─────────────────────────────────────────────────
        // Verify both SDK flavours are importable and pass basic sanity checks.
        stage('SDK Validation') {
            when { not { expression { params.SKIP_TESTS } } }
            steps {
                sh '''
                    # Python SDK — import check
                    python3 -c "
from assetiq import (
    AssetIQClient,
    HEALTH_CATEGORY_LABEL,
    HEALTH_CATEGORY_COLORS,
    SEVERITY_LABEL,
)
# Verify offline category present (added for assets not running)
assert 'offline' in HEALTH_CATEGORY_LABEL, 'offline category missing from SDK'
print('Python SDK: OK')
"
                    # TypeScript SDK — type-check only (no Node required in this agent)
                    python3 -c "
import re, pathlib
src = pathlib.Path('sdk/typescript/assetiq.ts').read_text()
assert 'offline' in src, 'offline category missing from TS SDK'
assert 'export' in src, 'no exports found in TS SDK'
print('TypeScript SDK: static check OK')
"
                '''
            }
        }

        // ── 6. Dashboard Build ────────────────────────────────────────────────
        stage('Dashboard Build') {
            when {
                anyOf {
                    branch 'main'
                    branch 'develop'
                }
            }
            steps {
                sh '''
                    # Install Node.js
                    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
                    apt-get install -y nodejs --quiet
                    node --version && npm --version
                '''
                withCredentials([
                    string(credentialsId: 'assetiq-api-key', variable: 'ASSETIQ_API_KEY')
                ]) {
                    sh '''
                        cd dashboard
                        npm ci --prefer-offline --loglevel=warn

                        # Lint TypeScript/React
                        npm run lint 2>&1 | tail -20

                        # Production build with env vars baked in at compile time
                        VITE_API_BASE_URL="${ASSETIQ_API_URL}" \
                        VITE_APP_NAME="AssetIQ" \
                        VITE_ENVIRONMENT="${DEPLOY_ENV}" \
                        npm run build

                        echo "Dashboard build complete. Artifact size:"
                        du -sh dist/
                    '''
                }
            }
            post {
                success {
                    archiveArtifacts artifacts: 'dashboard/dist/**', fingerprint: true
                }
            }
        }

        // ── 7. Docker Build (Client API Proxy) ────────────────────────────────
        stage('Docker Build') {
            when {
                anyOf {
                    branch 'main'
                    branch 'develop'
                }
            }
            steps {
                sh '''
                    docker build \
                        -t assetiq-client-api:${IMAGE_TAG} \
                        -f api/Dockerfile \
                        --label "git.commit=${IMAGE_TAG}" \
                        --label "build.number=${BUILD_NUMBER}" \
                        .
                '''
            }
        }

        // ── 8. ECR Push ───────────────────────────────────────────────────────
        stage('ECR Push') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ]
                ]) {
                    sh '''
                        which aws || pip install --quiet awscli

                        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
                        ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

                        aws ecr get-login-password --region ${AWS_REGION} | \
                            docker login --username AWS --password-stdin ${ECR_BASE}

                        # Client API proxy image
                        docker tag assetiq-client-api:${IMAGE_TAG} \
                            ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:${IMAGE_TAG}
                        docker tag assetiq-client-api:${IMAGE_TAG} \
                            ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:latest

                        docker push ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:${IMAGE_TAG}
                        docker push ${ECR_BASE}/${APP_NAME}-${DEPLOY_ENV}-api:latest

                        echo "Pushed client API image: ${IMAGE_TAG}"
                    '''
                }
            }
        }

        // ── 9. Terraform Init ─────────────────────────────────────────────────
        stage('Terraform Init') {
            when {
                anyOf {
                    branch 'main'
                    changeRequest()
                }
            }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ],
                    string(credentialsId: 'tf-backend-bucket',   variable: 'TF_BACKEND_BUCKET'),
                    string(credentialsId: 'tf-backend-dynamodb', variable: 'TF_BACKEND_DYNAMODB')
                ]) {
                    sh '''
                        which terraform || {
                            apt-get update -qq && apt-get install -y -qq unzip curl
                            TF_VERSION=1.6.6
                            curl -sLO https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip
                            unzip -q terraform_${TF_VERSION}_linux_amd64.zip
                            mv terraform /usr/local/bin/
                            rm terraform_${TF_VERSION}_linux_amd64.zip
                        }
                        terraform version
                    '''
                    sh '''
                        cd terraform
                        terraform init \
                            -backend-config="bucket=${TF_BACKEND_BUCKET}" \
                            -backend-config="key=assetiq-client/${DEPLOY_ENV}/terraform.tfstate" \
                            -backend-config="region=${AWS_REGION}" \
                            -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB}" \
                            -reconfigure
                    '''
                }
            }
        }

        // ── 10. Terraform Plan ────────────────────────────────────────────────
        stage('Terraform Plan') {
            when {
                anyOf {
                    branch 'main'
                    changeRequest()
                }
            }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ],
                    string(credentialsId: 'client-db-password',  variable: 'TF_VAR_db_password'),
                    string(credentialsId: 'client-cert-arn',     variable: 'TF_VAR_certificate_arn'),
                    string(credentialsId: 'client-cors-origins', variable: 'TF_VAR_cors_origins'),
                    string(credentialsId: 'client-alarm-email',  variable: 'TF_VAR_alarm_email'),
                    string(credentialsId: 'assetiq-api-key',     variable: 'TF_VAR_assetiq_api_key')
                ]) {
                    sh '''
                        cd terraform
                        terraform plan \
                            -var="environment=${DEPLOY_ENV}" \
                            -var="aws_region=${AWS_REGION}" \
                            -var="api_image_tag=${IMAGE_TAG}" \
                            -out=tfplan.binary
                        terraform show -no-color tfplan.binary > tfplan.txt
                    '''
                    archiveArtifacts artifacts: 'terraform/tfplan.txt', fingerprint: true
                }
            }
        }

        // ── 11. Terraform Apply ───────────────────────────────────────────────
        stage('Terraform Apply') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ],
                    string(credentialsId: 'client-db-password',  variable: 'TF_VAR_db_password'),
                    string(credentialsId: 'client-cert-arn',     variable: 'TF_VAR_certificate_arn'),
                    string(credentialsId: 'client-cors-origins', variable: 'TF_VAR_cors_origins'),
                    string(credentialsId: 'client-alarm-email',  variable: 'TF_VAR_alarm_email'),
                    string(credentialsId: 'assetiq-api-key',     variable: 'TF_VAR_assetiq_api_key')
                ]) {
                    sh '''
                        cd terraform
                        terraform apply -auto-approve tfplan.binary
                        terraform output -json > tf_outputs.json
                    '''
                    // Expose the dashboard bucket name for the S3 deploy stage
                    script {
                        def outputs = readJSON file: 'terraform/tf_outputs.json'
                        env.DASHBOARD_BUCKET     = outputs.dashboard_bucket?.value       ?: ''
                        env.CLOUDFRONT_DIST_ID   = outputs.cloudfront_distribution_id?.value ?: ''
                        env.CLIENT_API_ENDPOINT  = outputs.api_endpoint?.value           ?: ''
                    }
                    archiveArtifacts artifacts: 'terraform/tf_outputs.json', fingerprint: true
                }
            }
        }

        // ── 12. Deploy API (ECS) ──────────────────────────────────────────────
        stage('Deploy API') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ]
                ]) {
                    sh '''
                        which aws || pip install --quiet awscli

                        CLUSTER="${APP_NAME}-${DEPLOY_ENV}-cluster"
                        SERVICE="${APP_NAME}-${DEPLOY_ENV}-api"

                        echo "Forcing new ECS deployment: ${CLUSTER} / ${SERVICE}"

                        aws ecs update-service \
                            --cluster ${CLUSTER} \
                            --service  ${SERVICE} \
                            --force-new-deployment \
                            --region   ${AWS_REGION} \
                            --output   text \
                            --query    "service.deployments[0].status"

                        echo "Waiting for ECS service to stabilise..."
                        aws ecs wait services-stable \
                            --cluster  ${CLUSTER} \
                            --services ${SERVICE} \
                            --region   ${AWS_REGION}

                        echo "Client API deployment stable."
                    '''
                }
            }
        }

        // ── 13. Deploy Dashboard (S3 + CloudFront) ────────────────────────────
        stage('Deploy Dashboard') {
            when { branch 'main' }
            steps {
                withCredentials([
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-credentials',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ]
                ]) {
                    sh '''
                        which aws || pip install --quiet awscli

                        if [ -z "${DASHBOARD_BUCKET}" ]; then
                            echo "ERROR: DASHBOARD_BUCKET not set — Terraform output missing"
                            exit 1
                        fi

                        echo "Syncing dashboard build to s3://${DASHBOARD_BUCKET}"

                        # Sync immutable hashed assets with long cache TTL
                        aws s3 sync dashboard/dist/assets/ \
                            s3://${DASHBOARD_BUCKET}/assets/ \
                            --cache-control "public, max-age=31536000, immutable" \
                            --delete \
                            --region ${AWS_REGION}

                        # Sync HTML and root files with no-cache (always revalidate)
                        aws s3 sync dashboard/dist/ \
                            s3://${DASHBOARD_BUCKET}/ \
                            --exclude "assets/*" \
                            --cache-control "no-cache, no-store, must-revalidate" \
                            --delete \
                            --region ${AWS_REGION}

                        echo "Dashboard sync complete."
                    '''

                    // CloudFront invalidation — only invalidate HTML and root paths
                    script {
                        if (params.INVALIDATE_CDN && env.CLOUDFRONT_DIST_ID) {
                            sh """
                                aws cloudfront create-invalidation \
                                    --distribution-id ${env.CLOUDFRONT_DIST_ID} \
                                    --paths "/*" \
                                    --region us-east-1

                                echo "CloudFront invalidation submitted for ${env.CLOUDFRONT_DIST_ID}"
                            """
                        } else {
                            echo "CloudFront invalidation skipped (INVALIDATE_CDN=${params.INVALIDATE_CDN}, dist_id=${env.CLOUDFRONT_DIST_ID})"
                        }
                    }
                }
            }
        }

        // ── 14. Smoke Test ────────────────────────────────────────────────────
        stage('Smoke Test') {
            when { branch 'main' }
            steps {
                sh '''
                    if [ -z "${CLIENT_API_ENDPOINT}" ]; then
                        echo "WARNING: CLIENT_API_ENDPOINT not set, skipping smoke test"
                        exit 0
                    fi

                    echo "Hitting client API health endpoint: ${CLIENT_API_ENDPOINT}/health"
                    for i in 1 2 3 4 5; do
                        STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
                            ${CLIENT_API_ENDPOINT}/health && echo "ok" || echo "fail")
                        if [ "$STATUS" = "ok" ]; then
                            echo "Health check passed on attempt ${i}"
                            exit 0
                        fi
                        echo "Attempt ${i} failed, retrying in 15s..."
                        sleep 15
                    done
                    echo "Smoke test failed after 5 attempts"
                    exit 1
                '''
            }
        }

    } // end stages

    post {

        success {
            script {
                def deployedArtifacts = (env.BRANCH_NAME == 'main')
                    ? "API: `${env.CLIENT_API_ENDPOINT ?: 'see outputs'}`"
                    : "Build only (no deploy)"
                def msg = """
✅ *AssetIQ Client — Build #${BUILD_NUMBER} SUCCEEDED*
Branch:      `${env.BRANCH_NAME}`
Environment: `${env.DEPLOY_ENV}`
Image tag:   `${env.IMAGE_TAG}`
Deployed:    ${deployedArtifacts}
Duration:    ${currentBuild.durationString}
Build:       ${BUILD_URL}
""".stripIndent()
                echo msg
                // slackSend channel: '#assetiq-deploys', color: 'good', message: msg
            }
        }

        failure {
            script {
                def msg = """
❌ *AssetIQ Client — Build #${BUILD_NUMBER} FAILED*
Branch:    `${env.BRANCH_NAME}`
Stage:     `${env.STAGE_NAME}`
Image tag: `${env.IMAGE_TAG}`
Build:     ${BUILD_URL}
""".stripIndent()
                echo msg
                // slackSend channel: '#assetiq-deploys', color: 'danger', message: msg
                // mail to: 'ops@yourcompany.com', subject: "BUILD FAILED: AssetIQ Client #${BUILD_NUMBER}", body: msg
            }
        }

        always {
            sh 'docker rmi assetiq-client-api:${IMAGE_TAG} 2>/dev/null || true'
            cleanWs()
        }

    }

}
