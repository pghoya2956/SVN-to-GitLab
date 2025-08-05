# Playwright 테스트 가이드

## 개요
이 프로젝트는 Playwright를 사용하여 E2E 테스트를 수행합니다. Chrome 프로필 충돌을 방지하기 위해 여러 격리 전략을 사용합니다.

## 주요 기능

### 1. 프로필 격리
- 각 테스트 프로젝트마다 별도의 사용자 데이터 디렉토리 사용
- `.playwright-profiles/` 디렉토리에 프로젝트별로 저장

### 2. 포트 충돌 방지
- `--remote-debugging-port=0` 플래그로 랜덤 포트 사용
- 여러 테스트가 동시에 실행되어도 충돌 없음

### 3. Docker 격리
- `docker-compose.test.yml`로 완전히 격리된 테스트 환경 제공
- CI/CD 파이프라인에서 안정적인 테스트 실행

## 테스트 실행 방법

### 로컬 환경
```bash
# 모든 테스트 실행
npx playwright test

# 특정 프로젝트만 실행
npx playwright test --project=chromium

# UI 모드로 실행
npx playwright test --ui

# 디버그 모드
npx playwright test --debug
```

### Docker 환경
```bash
# Docker Compose로 테스트 실행
docker compose -f docker-compose.test.yml up --abort-on-container-exit

# 테스트 결과 확인
docker compose -f docker-compose.test.yml logs playwright
```

## 테스트 작성 가이드

### 1. 브라우저 헬퍼 사용
```typescript
import { createBrowser } from './helpers/browser-helper';

const browser = await createBrowser('my-test-project');
const page = browser.getPage();
```

### 2. 인증 상태 저장/복원
```typescript
// 로그인 후 상태 저장
await browser.saveAuthState('playwright/.auth/user.json');

// 저장된 상태로 새 컨텍스트 생성
const context = await browser.createAuthenticatedContext('playwright/.auth/user.json');
```

### 3. 병렬 실행 제어
```typescript
// 순차 실행이 필요한 경우
test.describe.configure({ mode: 'serial' });
```

## 문제 해결

### Chrome 프로필 충돌
- 증상: "Browser is already in use" 오류
- 해결: 프로젝트별 고유 프로필 디렉토리 사용

### 포트 충돌
- 증상: "ECONNREFUSED 127.0.0.1:9222" 오류
- 해결: `--remote-debugging-port=0` 사용

### Docker 환경 문제
- 증상: 브라우저가 시작되지 않음
- 해결: `--no-sandbox`, `--disable-dev-shm-usage` 플래그 추가

## 베스트 프랙티스

1. **격리**: 각 테스트는 독립적으로 실행 가능해야 함
2. **재시도**: 네트워크 오류에 대비한 재시도 로직 구현
3. **대기**: 명시적 대기 사용 (`waitForSelector`, `waitForLoadState`)
4. **정리**: 테스트 후 브라우저 인스턴스 정리
5. **로깅**: 실패 시 스크린샷/비디오 저장