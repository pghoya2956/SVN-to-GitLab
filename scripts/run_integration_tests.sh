#!/bin/bash

# 통합 테스트 실행 스크립트

set -e

echo "=== SVN to GitLab 통합 테스트 ==="
echo

# 환경 설정
export RAILS_ENV=test
export DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL=true

# 테스트 데이터베이스 준비
echo "1. 테스트 데이터베이스 준비..."
docker compose run --rm -e RAILS_ENV=test web rails db:drop db:create db:migrate

# 테스트 SVN 저장소 설정
echo "2. 테스트 SVN 저장소 설정..."
export TEST_SVN_URL="https://svn.code.sf.net/p/svnbook/source"
export TEST_SVN_WITH_ENCODING_URL="https://svn.apache.org/repos/asf/commons/proper/collections"

# 단위 테스트 실행
echo "3. 단위 테스트 실행..."
docker compose run --rm -e RAILS_ENV=test web rails test

# 통합 테스트 실행
echo "4. 통합 테스트 실행..."
docker compose run --rm -e RAILS_ENV=test web rails test test/integration/git_svn_migration_test.rb

# 성능 테스트 실행 (선택적)
if [ "$RUN_PERFORMANCE_TESTS" = "true" ]; then
  echo "5. 성능 테스트 실행..."
  docker compose run --rm -e RAILS_ENV=test web rails test test/performance/git_svn_performance_test.rb
else
  echo "5. 성능 테스트 건너뜀 (RUN_PERFORMANCE_TESTS=true로 실행)"
fi

# API 테스트 실행
echo "6. API 테스트 실행..."
docker compose run --rm -e RAILS_ENV=test web rails test test/controllers/api/v1/migrations_controller_test.rb

# 결과 요약
echo
echo "=== 테스트 완료 ==="
echo "모든 테스트가 성공적으로 완료되었습니다."