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

### 구현 완료 태스크
- ✅ 완료: T-001 Docker 환경에 git-svn 설치
- ✅ 완료: T-002 데이터베이스 스키마 확장 (migration_method, svn_structure 추가)
- ✅ 완료: T-003 MigrationJob을 git-svn 방식으로 수정
  - `git svn clone` 사용하여 전체 커밋 이력 보존
  - SVN 표준 레이아웃 지원 (trunk/branches/tags)
  - 진행률 추적 기능 개선
  - `convert_to_git` 메서드 제거 (git-svn이 직접 Git 저장소 생성)
- ✅ 완료: T-004 IncrementalSyncJob을 git-svn 방식으로 수정
  - `git svn fetch`로 새 커밋만 가져오기
  - `git svn rebase`로 로컬 브랜치 업데이트
  - SVN checkout 및 파일 복사 로직 완전 제거
  - git-svn 저장소 검증 로직 추가
- ✅ 완료: T-005 SVN 구조 자동 감지 서비스
  - `SvnStructureDetector` 서비스 구현
  - 표준/비표준 레이아웃 감지 기능
  - Authors 목록 자동 추출 및 이메일 매핑
  - Repository 통계 정보 수집
  - Controller 액션 및 뷰 업데이트
- ✅ 완료: T-006 Authors 매핑 기능
  - Authors 편집 UI 구현 (`edit_authors` 액션)
  - 실시간 미리보기 기능
  - 도메인 일괄 적용 기능
  - Authors 파일 자동 생성
  - MigrationJob에서 authors 파일 사용
- ✅ 완료: T-007 진행률 모니터링 개선
  - ActionCable을 사용한 실시간 진행률 업데이트
  - ProgressTrackable concern 구현
  - Job 모델에 진행률 관련 필드 추가
  - 진행률 모니터 뷰 컴포넌트 구현
  - Chart.js를 사용한 처리 속도 그래프
  - 예상 완료 시간 (ETA) 계산 및 표시
  - 단계별 진행 상황 시각화
- ✅ 완료: T-008 통합 테스트 및 문서화
  - 통합 테스트 작성 (`test/integration/git_svn_migration_test.rb`)
  - 성능 테스트 구현 (`test/performance/git_svn_performance_test.rb`)
  - 사용자 가이드 작성 (`docs/USER_GUIDE.md`)
  - API 문서화 (`docs/API_DOCUMENTATION.md`)
  - 트러블슈팅 가이드 (`docs/TROUBLESHOOTING_GUIDE.md`)
  - API 컨트롤러 구현 (`app/controllers/api/v1/`)
  - 테스트 실행 스크립트 (`scripts/run_integration_tests.sh`)

### 관련 문서
- `docs/tasks/GIT_SVN_TASKS.md`: Git-SVN 구현 태스크 진행 현황 (7개 태스크)
- `docs/tasks/MIGRATION_REPLACEMENT_PLAN.md`: 코드 직접 수정 계획
- `docs/tasks/T-001_*.md` ~ `T-008_*.md`: 개별 태스크 상세 문서
- `docs/tasks/T-004_RESUMABLE_MIGRATION.md`: 긴 작업 재개 기능 구현 계획
- `docs/CURRENT_MIGRATION_FLOW.md`: 현재 마이그레이션 동작 방식 상세 설명