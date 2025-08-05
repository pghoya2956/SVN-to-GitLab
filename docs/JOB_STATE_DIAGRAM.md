# Job 상태 전이 다이어그램

## 1. 기존 상태 (status)

```mermaid
stateDiagram-v2
    [*] --> pending: Job 생성
    pending --> running: 작업 시작
    running --> completed: 성공
    running --> failed: 실패
    running --> cancelled: 사용자 취소
    failed --> [*]
    completed --> [*]
    cancelled --> [*]
```

## 2. 새로운 단계 (phase) - 재개 가능

```mermaid
stateDiagram-v2
    [*] --> pending: Job 생성
    
    pending --> cloning: 작업 시작
    
    cloning --> applying_strategy: Clone 완료
    cloning --> failed: Clone 실패
    
    applying_strategy --> pushing: 전략 적용 완료
    applying_strategy --> failed: 적용 실패
    
    pushing --> completed: Push 완료
    pushing --> failed: Push 실패
    
    failed --> cloning: 재개 (Clone 단계)
    failed --> applying_strategy: 재개 (Apply 단계)
    failed --> pushing: 재개 (Push 단계)
    
    completed --> [*]
    
    note right of failed
        재개 가능 조건:
        - resumable = true
        - retry_count < 3
        - local_git_path 존재
    end note
```

## 3. 재개 가능한 오류 vs 치명적 오류

### 재개 가능한 오류 (resumable = true)
- 네트워크 연결 오류
- 타임아웃
- 일시적인 GitLab API 오류
- 디스크 공간 부족

### 치명적 오류 (resumable = false)
- SVN 인증 실패
- 저장소 접근 권한 없음
- Git 저장소 손상
- 잘못된 SVN URL

## 4. 체크포인트 데이터 구조

```json
{
  "timestamp": "2025-08-05T10:30:00Z",
  "phase": "cloning",
  "phase_details": {
    "start_time": "2025-08-05T10:00:00Z",
    "last_activity": "2025-08-05T10:29:30Z",
    "progress_percentage": 45
  },
  "git_path": "/app/git_repos/12/git_repo",
  "last_revision": 3500,
  "additional_data": {
    "total_estimated_revisions": 7500,
    "processing_speed": 2.5,
    "error_count": 0
  }
}
```

## 5. 재개 플로우

```mermaid
flowchart TD
    A[Failed Job] --> B{can_resume?}
    B -->|Yes| C[사용자가 재개 버튼 클릭]
    B -->|No| D[재개 불가 표시]
    
    C --> E[start_resume!]
    E --> F{checkpoint_data 확인}
    
    F --> G[phase = cloning]
    F --> H[phase = applying_strategy]
    F --> I[phase = pushing]
    
    G --> J[git svn fetch로 이어서]
    H --> K[전략 적용 계속]
    I --> L[Push 재시도]
    
    J --> M[성공/실패]
    K --> M
    L --> M
```

## 6. 구현 시 고려사항

1. **체크포인트 저장 시점**
   - 각 단계 시작 시
   - 주기적으로 (5분마다)
   - 중요한 진행 시점 (예: 1000 커밋마다)

2. **재개 시 검증**
   - Git 저장소 무결성 확인
   - SVN 저장소 접근 가능 여부
   - 마지막 성공한 리비전 확인

3. **사용자 피드백**
   - 재개 가능 여부 명확히 표시
   - 재개 진행률 표시
   - 실패 시 이유 설명