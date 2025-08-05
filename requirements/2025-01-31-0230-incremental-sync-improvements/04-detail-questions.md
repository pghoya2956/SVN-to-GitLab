# Expert Requirements Questions

## Q6: 기존 migration job이 완료된 후 자동으로 local_git_path를 설정하도록 MigrationJob을 수정해야 하나요?
**기본값**: Yes (incremental sync가 작동하려면 local_git_path가 필수)

## Q7: Repository show 페이지에 최근 5개의 관련 잡만 표시하면 충분한가요?
**기본값**: Yes (전체 이력은 별도 페이지에서 보는 것이 UI 성능상 유리)

## Q8: 증분 동기화 실패 시 최대 3회까지 자동 재시도하도록 설정해야 하나요?
**기본값**: Yes (Sidekiq 표준 재시도 정책과 일치)

## Q9: 동일 repository에 대해 실행 중인 sync job이 있을 때 새 요청은 에러 메시지를 표시해야 하나요?
**기본값**: Yes (사용자에게 명확한 피드백 제공)

## Q10: Job 테이블에 start_revision, end_revision, synced_commits_count 필드를 추가해야 하나요?
**기본값**: Yes (증분 동기화의 상세 추적을 위해 필요)