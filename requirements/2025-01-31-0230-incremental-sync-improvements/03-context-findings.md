# Context Findings

## 발견된 주요 문제점들

### 1. chdir 충돌 문제
- **원인**: IncrementalSyncJob의 `perform_incremental_sync` 메서드에서 `@repository.git_directory`가 nil을 반환
- **상세**: 
  - MigrationJob에서 `local_git_path`를 설정하지 않음
  - Repository ID 1의 `local_git_path`가 NULL
  - `git_directory` 메서드가 nil 반환 → `Dir.chdir(nil)` 호출로 에러 발생
- **위치**: `/app/jobs/incremental_sync_job.rb:82`

### 2. 잡 구분 문제
- **현재 상태**: 
  - Job 모델에 `job_type` 필드로 'migration'과 'incremental_sync' 구분
  - 하지만 어떤 리비전을 처리했는지, 몇 개의 커밋을 동기화했는지 등의 정보 없음
- **필요한 정보**:
  - 시작 리비전 번호
  - 종료 리비전 번호
  - 동기화된 커밋 수
  - 처리된 파일 수

### 3. Repository 페이지의 잡 가시성 문제
- **현재 상태**:
  - Repository show 페이지에서 관련 잡 목록을 볼 수 없음
  - Jobs 페이지로 이동해야만 확인 가능
- **필요한 기능**:
  - Repository별 잡 이력 표시
  - 현재 실행 중인 잡 상태
  - 최근 동기화 결과

### 4. 동시 실행 제어 부재
- **현재 상태**:
  - 동일 repository에 대해 여러 incremental_sync 잡이 동시 실행 가능
  - DB 조회 결과: repository_id 1에 대해 여러 개의 실패한 잡 존재
- **필요한 제어**:
  - Repository별 실행 중인 잡 체크
  - 이미 실행 중이면 새 잡 생성 방지

### 5. 재시도 메커니즘 부재
- **현재 상태**:
  - 실패한 잡에 대한 자동 재시도 없음
  - Sidekiq의 재시도 기능 미활용
- **필요한 기능**:
  - Sidekiq retry 설정
  - 실패 원인별 재시도 전략

## 관련 파일들

### 수정이 필요한 파일
1. `/app/jobs/migration_job.rb` - local_git_path 설정 추가
2. `/app/jobs/incremental_sync_job.rb` - nil 체크 및 에러 처리
3. `/app/models/job.rb` - 증분 동기화 관련 필드 추가
4. `/app/controllers/repositories_controller.rb` - sync 액션 중복 실행 방지
5. `/app/views/repositories/show.html.erb` - 잡 이력 표시
6. `/db/migrate/` - Job 테이블에 sync 관련 필드 추가

### 분석한 패턴
1. **Job 생성 패턴**: 
   - Controller에서 `perform_async` 호출
   - Job 내부에서 Job 레코드 생성
   - `mark_as_running!`, `mark_as_completed!`, `mark_as_failed!` 패턴 사용

2. **에러 처리 패턴**:
   - `begin-rescue-ensure` 블록 사용
   - `append_output`과 `append_error` 메서드로 로그 기록

3. **상태 관리 패턴**:
   - Job status: pending → running → completed/failed
   - Repository 상태: last_synced_at, last_synced_revision 업데이트

## 기술적 제약사항
1. Sidekiq Job ID를 통한 중복 실행 방지 필요
2. PostgreSQL 트랜잭션으로 동시성 제어
3. git-svn 명령어의 원자성 보장 필요

## 통합 포인트
1. Sidekiq - 백그라운드 작업 처리
2. PostgreSQL - 상태 관리 및 동시성 제어
3. git-svn - SVN 리포지토리 동기화
4. GitLab API - 코드 푸시