# 증분 동기화 개선 요구사항 명세서

## 문제 정의

현재 SVN to GitLab 마이그레이션 도구의 증분 동기화 기능에 다음과 같은 치명적인 문제들이 발생하고 있습니다:

1. **실행 실패**: 모든 증분 동기화 작업이 "chdir 충돌" 에러로 실패
2. **정보 부족**: 동기화 작업이 처리한 리비전 정보 없음
3. **가시성 부족**: Repository 페이지에서 관련 작업 상태를 볼 수 없음
4. **제어 부재**: 동일 저장소에 대한 중복 실행 방지 메커니즘 없음

## 솔루션 개요

다음과 같은 개선사항을 통해 안정적이고 추적 가능한 증분 동기화 시스템을 구축합니다:

1. MigrationJob 완료 시 local_git_path 자동 설정
2. Job 모델에 동기화 상세 정보 필드 추가
3. Repository 상세 페이지에 작업 이력 표시
4. 중복 실행 방지 및 자동 재시도 메커니즘 구현

## 기능 요구사항

### FR1: MigrationJob 개선
- 마이그레이션 완료 시 `local_git_path` 자동 설정
- 경로 형식: `repositories/{user_id}/{repository_id}`
- 기존 마이그레이션된 저장소도 retroactive하게 업데이트

### FR2: Job 추적 정보 확장
- Job 모델에 다음 필드 추가:
  - `start_revision` (integer): 동기화 시작 SVN 리비전
  - `end_revision` (integer): 동기화 종료 SVN 리비전
  - `synced_commits_count` (integer): 동기화된 커밋 수
  - `synced_files_count` (integer): 처리된 파일 수
- 증분 동기화 작업 완료 시 자동 업데이트

### FR3: Repository 페이지 개선
- 최근 5개의 관련 작업 표시
- 각 작업별 상태, 시작 시간, 소요 시간, 처리 정보 표시
- 현재 실행 중인 작업 하이라이트
- "View All Jobs" 링크로 전체 이력 접근

### FR4: 중복 실행 방지
- sync 액션 호출 시 실행 중인 작업 확인
- 이미 실행 중이면 에러 메시지와 함께 거부
- 메시지: "이미 동기화 작업이 진행 중입니다. 완료 후 다시 시도해주세요."

### FR5: 자동 재시도
- Sidekiq retry 설정: 최대 3회
- 재시도 간격: 10초, 30초, 60초 (exponential backoff)
- 최종 실패 시 상세 에러 로그 보관

## 기술 요구사항

### TR1: 데이터베이스 변경
```ruby
# Migration: AddSyncDetailsToJobs
add_column :jobs, :start_revision, :integer
add_column :jobs, :end_revision, :integer
add_column :jobs, :synced_commits_count, :integer, default: 0
add_column :jobs, :synced_files_count, :integer, default: 0

add_index :jobs, [:repository_id, :job_type, :status]
```

### TR2: MigrationJob 수정
- `perform_migration` 메서드 끝에 다음 추가:
```ruby
@repository.update!(
  local_git_path: "repositories/#{@user.id}/#{@repository.id}"
)
```

### TR3: IncrementalSyncJob 수정
- `perform` 메서드 시작 부분에 nil 체크 추가:
```ruby
if @repository.git_directory.nil?
  @job.mark_as_failed!("Local git path not set. Please run initial migration first.")
  return
end
```
- Sidekiq options 추가:
```ruby
sidekiq_options retry: 3, backtrace: true
```

### TR4: RepositoriesController#sync 수정
```ruby
def sync
  running_job = @repository.jobs
    .where(job_type: 'incremental_sync', status: ['pending', 'running'])
    .exists?
    
  if running_job
    redirect_to @repository, alert: "이미 동기화 작업이 진행 중입니다. 완료 후 다시 시도해주세요."
  else
    job_id = IncrementalSyncJob.perform_async(@repository.id)
    redirect_to jobs_path, notice: "증분 동기화 작업이 시작되었습니다. (ID: #{job_id})"
  end
end
```

### TR5: Repository show 뷰 수정
```erb
<div class="card mt-3">
  <div class="card-header">
    <h6>Recent Jobs</h6>
  </div>
  <div class="card-body">
    <% @repository.jobs.recent.limit(5).each do |job| %>
      <%= render 'jobs/job_summary', job: job %>
    <% end %>
    <%= link_to "View All Jobs", jobs_path(repository_id: @repository.id), 
        class: "btn btn-sm btn-outline-primary" %>
  </div>
</div>
```

## 구현 순서

1. **긴급 수정** (즉시):
   - MigrationJob에 local_git_path 설정 추가
   - IncrementalSyncJob에 nil 체크 추가
   - 기존 repository의 local_git_path 수동 업데이트

2. **핵심 기능** (1일차):
   - Job 테이블 마이그레이션 추가
   - 중복 실행 방지 로직 구현
   - Sidekiq retry 설정

3. **UI 개선** (2일차):
   - Repository show 페이지에 작업 이력 추가
   - Job summary partial 생성
   - 동기화 상세 정보 표시

## 검증 기준

1. 모든 증분 동기화 작업이 성공적으로 완료됨
2. Repository 페이지에서 작업 이력을 확인할 수 있음
3. 중복 실행 시도 시 적절한 에러 메시지가 표시됨
4. 실패한 작업이 자동으로 재시도됨
5. 동기화된 리비전 정보가 정확하게 기록됨

## 가정 사항

- 시스템 기본 동기화 주기는 1시간으로 고정
- 최대 5개의 최근 작업만 Repository 페이지에 표시
- Sidekiq 표준 재시도 정책(3회) 사용
- git-svn 명령어가 정상적으로 작동함