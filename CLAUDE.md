# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Setup
bin/setup                    # Initial setup (builds Docker, creates DB)
./scripts/init_volumes.sh    # Initialize Docker volumes (first run only)

# Development  
docker compose up            # Start all services
docker compose logs -f web   # View Rails logs
docker compose logs -f sidekiq # View background job logs
docker compose run --rm web rails console
docker compose run --rm web rails db:migrate

# Testing
bin/test                     # Run all tests
docker compose run --rm -e RAILS_ENV=test web rails test
docker compose run --rm -e RAILS_ENV=test web rails test test/integration/thread_safety_test.rb
./scripts/run_e2e_tests.sh  # Run Playwright E2E tests
docker compose run --rm web npx playwright test

# Database
docker compose run --rm web rails db:reset  # Reset database
docker compose run --rm web rails db:seed   # Seed test data

# Sidekiq/Background Jobs
docker compose exec web rails c
> Sidekiq::Queue.all.map { |q| [q.name, q.size] }
> Sidekiq::Workers.new.size  # Check running jobs
```

## Architecture

Rails 7.1 application with Sidekiq background jobs for SVN-to-GitLab migration using git-svn.

### Core Components

1. **Service Objects** (`app/services/repositories/`)
   - `GitlabConnector`: GitLab API wrapper for project operations
   - `ValidatorService`: SVN repository validation and authentication
   - `MigrationStrategyService`: Migration configuration management
   - `SvnStructureDetector`: SVN layout detection with path-specific revision calculation

2. **Background Jobs** (`app/jobs/`)
   - `MigrationJob`: Main migration using git-svn (preserves full commit history)
     - Thread-based I/O handling with instance variables: `@last_output_time`, `@output_count`, `@process_died`
     - Checkpoint system for resumable migrations
     - Environment variables: `GITSVN_OUTPUT_WARNING=300`, `GITSVN_OUTPUT_TIMEOUT=600`
   - `IncrementalSyncJob`: Post-migration sync (git svn fetch/rebase)
   - `SvnStructureDetectionJob`: Background SVN structure detection with ActionCable notifications

3. **Real-time Communication**
   - ActionCable channels: `JobChannel`, `RepositoryChannel`
   - WebSocket-based progress updates
   - Live log streaming during migration

4. **Data Persistence**
   - `git_repos/`: Permanent storage for converted repositories (Docker volume)
   - Checkpoint data stored in Job model for resumability
   - Authors mapping stored per repository

## 📌 Critical Design Principles

### 1. git-svn을 신뢰하라
- git-svn은 모든 엣지 케이스를 이미 처리하는 성숙한 도구
- 브랜치 중복, 경로 겹침 등은 git-svn이 자동으로 해결
- 우리의 역할은 단순히 사용자 입력을 git-svn에 전달하는 것

```ruby
# GOOD: Simple pass-through
def git_svn_layout_options
  options = []
  options << ['--trunk', custom_trunk_path] if custom_trunk_path.present?
  options << ['--branches', custom_branches_path] if custom_branches_path.present?
  options << ['--tags', custom_tags_path] if custom_tags_path.present?
  options.flatten
end

# BAD: Trying to handle overlapping paths or validation
# git-svn automatically handles cases like:
# --trunk branches/ace_wrapper --branches branches
```

### 2. 복잡한 검증 로직을 추가하지 마라
- 중복 경로 체크 ❌
- 특수 케이스별 분기 처리 ❌
- git-svn의 동작을 예측하려는 시도 ❌
- **오버엔지니어링은 오히려 문제를 만든다**

### 3. UI와 실제 동작을 구분하라
- UI 표시 문제 ≠ git-svn 동작 문제
- 데이터 저장 문제 ≠ 마이그레이션 로직 문제
- 각 레이어의 책임을 명확히 구분

### 4. KISS 원칙 (Keep It Simple, Stupid)
- 사용자 입력 → 저장 → git-svn 전달
- 에러 발생 시 git-svn 메시지 그대로 표시
- 불필요한 중간 처리 최소화

### Path-Specific Revision Calculation
When calculating revisions for migration, use path-specific counts:
- `trunk="."`: Use total repository revisions
- Single trunk: Use trunk path revisions only
- Multiple paths: Use maximum revision across all paths

### Thread Safety
Instance variables for thread communication in MigrationJob:
- Simple timestamp tracking with `@last_output_time`
- No mutex needed for low-frequency updates (1-10/sec)
- Ruby's atomic reference assignment is sufficient

## Database Schema

Key models and relationships:
- Repository: `has_many :jobs`
  - Fields: `custom_trunk_path`, `custom_branches_path`, `custom_tags_path`, `layout_type`, `total_revisions`, `last_detected_at`
- Job: `belongs_to :repository`
  - Types: 'migration', 'incremental_sync', 'structure_detection'
  - Checkpoint support: `checkpoint_data`, `resumable`, `current_revision`

## Testing Approach

### Test SVN Repositories
1. **Small**: https://svn.code.sf.net/p/svnbook/source/trunk (~50MB)
2. **Medium**: https://svn.apache.org/repos/asf/commons/proper/collections/trunk (~200MB)
3. **Large**: https://svn.apache.org/repos/asf/subversion/trunk (>2GB)

### Special Test Cases
- Trunk as subdirectory of branches: `--trunk branches/ace_wrapper --branches branches`
- Entire repository as trunk: `--trunk .`
- Non-standard layouts with custom paths

## Current Feature Status

All major features implemented:
- ✅ Full history preservation with git-svn
- ✅ Resumable migrations with checkpoints
- ✅ Background structure detection (page navigation safe)
- ✅ SVN layout auto-detection (standard/non-standard)
- ✅ Authors mapping with UI
- ✅ Real-time progress monitoring
- ✅ Incremental sync post-migration

## Known Issues & Solutions

### Rails Empty String Handling
Rails converts empty strings to nil. Handle in controller:
```ruby
layout_params[:custom_branches_path] = nil if layout_params[:custom_branches_path] == ""
```

### Background Job Monitoring
Jobs continue running even when navigating away from the page:
- Structure detection runs in `SvnStructureDetectionJob`
- Migration runs in `MigrationJob`
- Check status via Job model or Sidekiq dashboard