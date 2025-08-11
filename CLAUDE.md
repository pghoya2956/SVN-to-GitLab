# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Setup
bin/setup                    # Initial setup (builds Docker, creates DB)

# Development
docker compose up            # Start all services
docker compose logs -f web   # View Rails logs
docker compose run --rm web rails console
docker compose run --rm web rails db:migrate

# Testing
bin/test                     # Run all tests
docker compose run --rm -e RAILS_ENV=test web rails test
docker compose run --rm web npx playwright test

# Database
docker compose run --rm web rails db:reset  # Reset database
```

## Architecture

Rails 7.1 app with Sidekiq background jobs for SVN-to-GitLab migration.

### Key Components

1. **Service Objects** (`app/services/repositories/`)
   - `GitlabConnector`: GitLab API wrapper
   - `ValidatorService`: SVN repository validation  
   - `MigrationStrategyService`: Migration configuration
   - `SvnStructureDetector`: SVN 구조 자동 감지 및 Authors 추출

2. **Background Jobs** (`app/jobs/`)
   - `MigrationJob`: Main migration process (git svn clone → GitLab push) - 전체 커밋 이력 보존
     - Uses thread-based I/O handling for stdout/stderr/monitoring
     - Instance variables for thread communication: `@last_output_time`, `@output_count`, `@process_died`
   - `IncrementalSyncJob`: Sync changes after initial migration (git svn fetch/rebase)

3. **Multi-tenancy**
   - `User.current` thread-local storage
   - `default_scope` on models for data isolation

4. **Authentication**
   - GitLab tokens: Base64 encoded (needs stronger encryption for production)
   - SVN credentials: Stored per repository

## 아키텍처 개요

- **프레임워크**: Ruby on Rails 7.1
- **백그라운드 처리**: Sidekiq 7.2 
- **데이터베이스**: PostgreSQL 15
- **캐시**: Redis 7
- **실시간 통신**: ActionCable (WebSocket)
- **컨테이너화**: Docker & Docker Compose
- **버전 관리 변환**: git-svn (전체 커밋 이력 보존)

## 주요 디렉토리 구조

- `app/controllers/` - 웹 컨트롤러 및 API 엔드포인트
- `app/jobs/` - Sidekiq 백그라운드 작업
- `app/services/repositories/` - 비즈니스 로직 서비스
- `app/channels/` - ActionCable 실시간 통신
- `git_repos/` - 변환된 Git 저장소 영구 저장 (Docker 볼륨)

## Critical Paths

1. **Migration Flow**:
   ```
   RepositoriesController#create → JobsController#create → MigrationJob#perform → 
   git svn clone (with authors mapping) → GitLab push
   ```

2. **GitLab Integration**:
   ```
   GitlabTokensController → GitlabConnector#fetch_projects → 
   Store project_id in Repository
   ```

3. **Job Tracking**:
   - Status: pending → running → completed/failed
   - Logs: `output_log` and `error_log` fields
   - Progress: Updated via `job.update(progress: n)`
   - Checkpoint system for resumable migrations

## Database Schema

Key relationships:
- User has_many :repositories, :jobs
- User has_one :gitlab_token
- Repository has_many :jobs
- Repository fields: `gitlab_project_id`, `local_git_path`, `enable_incremental_sync`
- Job fields: `status`, `job_type`, `progress`, `output_log`, `error_log`

## Testing

### Unit Tests
- Rails tests in `test/`
- Run: `docker compose run --rm -e RAILS_ENV=test web rails test`
- Thread safety test: `docker compose run --rm -e RAILS_ENV=test web rails test test/integration/thread_safety_test.rb`

### E2E Tests
- Playwright tests in `tests/e2e/svn_migration.test.ts`
- Run: `./scripts/run_e2e_tests.sh`
- Test credentials: ghdi7662@gmail.com / password123
- Environment variables:
  - `TEST_USER_EMAIL`: Test user email
  - `TEST_USER_PASSWORD`: Test user password
  - `TEST_GITLAB_TOKEN`: GitLab personal access token
  - `HEADLESS`: Run in headless mode (true/false)
  - `TEST_PATTERN`: Run specific tests matching pattern

### Test Documentation
- `docs/TEST_SVN_REPOSITORIES.md`: List of public SVN repos for testing
- `docs/E2E_TEST_SCENARIOS.md`: Detailed test scenarios
- `docs/TEST_RESULTS_TEMPLATE.md`: Template for recording test results

### Test SVN Repositories (Public)
1. **Small**: https://svn.code.sf.net/p/svnbook/source/trunk (~50MB)
2. **Medium**: https://svn.apache.org/repos/asf/commons/proper/collections/trunk (~200MB)
3. **Large**: https://svn.apache.org/repos/asf/subversion/trunk (>2GB)

## Git-SVN Implementation

git-svn을 사용하여 전체 커밋 이력을 보존하는 마이그레이션이 완전히 구현되었습니다

### 전환 전략
- 사용자가 없으므로 기존 코드를 직접 수정 (호환성 불필요)
- MigrationJob과 IncrementalSyncJob을 git-svn 방식으로 수정
- 새로운 Job 클래스 생성 없이 기존 클래스 수정

### 현재 기능 상태

모든 주요 기능이 구현 완료되었습니다:
- ✅ git-svn을 사용한 전체 커밋 이력 보존
- ✅ 재개 가능한 마이그레이션 (체크포인트 시스템)
- ✅ SVN 구조 자동 감지 (표준/비표준 레이아웃)
- ✅ Authors 매핑 UI 및 실시간 미리보기
- ✅ ActionCable 실시간 진행률 모니터링
- ✅ 증분 동기화 (git svn fetch/rebase)

## Critical Bug Fixes

### Thread Variable Scope Bug (Fixed)
MigrationJob에서 스레드 간 변수 공유 문제를 해결했습니다:

**문제**: 로컬 변수 사용으로 스레드 간 공유 안됨
```ruby
# Before (버그)
last_output_time = Time.now  # 로컬 변수
Thread.new { last_output_time = Time.now }  # 스레드 로컬!
```

**해결**: 인스턴스 변수로 변경
```ruby
# After (수정됨)
@last_output_time = Time.now  # 인스턴스 변수
Thread.new { @last_output_time = Time.now }  # 공유됨
```

**수정 내역** (`app/jobs/migration_job.rb`):
- Line 455-456: `@last_output_time`, `@output_count` 인스턴스 변수로 변경
- Line 476: stderr 스레드에도 타임스탬프 업데이트 추가
- Line 502: `@process_died` 인스턴스 변수로 변경
- Line 505-506: 환경변수로 타임아웃 설정 가능

### Environment Variables
```bash
GITSVN_OUTPUT_WARNING=300  # 경고 표시 시간 (초, 기본 5분)
GITSVN_OUTPUT_TIMEOUT=600  # 프로세스 종료 시간 (초, 기본 10분)
```

## Thread Safety Considerations

### Current Implementation
- 인스턴스 변수 사용 (`@last_output_time`, `@output_count`, `@process_died`)
- Ruby의 객체 참조 할당은 atomic이므로 단순 타임스탬프 추적에는 충분
- 초당 10회 미만의 낮은 빈도 업데이트
- ±1초 오차 허용 가능한 모니터링 용도

### Why Not Mutex or Concurrent-Ruby?
- **현재 사용 패턴**: 단순 타임스탬프 업데이트 (초당 1-10회)
- **Mutex**: 불필요한 복잡도 추가, 성능 오버헤드
- **Concurrent-Ruby**: 오버엔지니어링, 외부 의존성 추가
- **결론**: 인스턴스 변수만으로 충분히 안전하고 신뢰성 있음
- to