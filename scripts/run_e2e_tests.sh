#!/bin/bash

# E2E 테스트 실행 스크립트

echo "=== SVN to GitLab E2E 테스트 시작 ==="

# 환경 변수 설정
export TEST_USER_EMAIL=${TEST_USER_EMAIL:-"ghdi7662@gmail.com"}
export TEST_USER_PASSWORD=${TEST_USER_PASSWORD:-"password123"}
export TEST_GITLAB_TOKEN=${TEST_GITLAB_TOKEN:-"glpat-SvhybvwSBFGkKgGxVsr-"}

# Docker 컨테이너가 실행 중인지 확인
if ! docker compose ps | grep -q "Up"; then
    echo "Docker 컨테이너를 시작합니다..."
    docker compose up -d
    echo "서비스가 준비될 때까지 대기 중..."
    sleep 10
fi

# 데이터베이스 마이그레이션 확인
echo "데이터베이스 상태 확인..."
docker compose run --rm web rails db:migrate:status

# 테스트 실행 옵션
HEADLESS=${HEADLESS:-false}
WORKERS=${WORKERS:-1}

# Playwright 설정
if [ "$HEADLESS" = "true" ]; then
    echo "Headless 모드로 실행합니다."
    export PLAYWRIGHT_HEADLESS=1
else
    echo "브라우저 UI 모드로 실행합니다."
    export PLAYWRIGHT_HEADLESS=0
fi

# 특정 테스트만 실행하려면 TEST_PATTERN 환경 변수 사용
if [ -n "$TEST_PATTERN" ]; then
    echo "테스트 패턴: $TEST_PATTERN"
    TEST_ARGS="--grep \"$TEST_PATTERN\""
else
    TEST_ARGS=""
fi

# Playwright 테스트 실행
echo "E2E 테스트 실행 중..."
npx playwright test tests/e2e/svn_migration.test.ts \
    --workers=$WORKERS \
    --reporter=list \
    $TEST_ARGS

# 테스트 결과 저장
TEST_RESULT=$?

# HTML 리포트 생성 옵션
if [ "$GENERATE_REPORT" = "true" ]; then
    echo "HTML 리포트 생성 중..."
    npx playwright show-report
fi

# 테스트 결과에 따른 종료 코드
if [ $TEST_RESULT -eq 0 ]; then
    echo "=== ✅ 모든 테스트가 성공했습니다 ==="
else
    echo "=== ❌ 일부 테스트가 실패했습니다 ==="
fi

exit $TEST_RESULT