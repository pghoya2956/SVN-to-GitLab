# SVN to GitLab Migration Tool

웹 기반 SVN → GitLab 마이그레이션 도구

## 주요 기능

- SVN 리포지토리를 GitLab으로 마이그레이션
- 마이그레이션 전략 설정 (브랜치/태그, Git LFS, 작성자 매핑)
- 백그라운드 작업 처리 및 실시간 진행률 모니터링
- 증분 동기화 (개발 중)

## 빠른 시작

```bash
# 1. 클론 및 설정
git clone <repository-url>
cd svn_to_gitlab
cp .env.example .env

# 2. 실행
bin/setup          # 초기 설정
docker compose up  # 서비스 시작

# 3. 접속
http://localhost:3000
```

## 개발

```bash
# 테스트
bin/test

# 로그 확인
docker compose logs -f web

# 콘솔
docker compose run --rm web rails console
```

## 문제 해결

- **Docker 오류**: Docker Desktop 실행 확인
- **DB 오류**: `docker compose down -v && bin/setup`
- **증분 동기화 오류**: 알려진 이슈, 수정 중

## 기술 스택

Rails 7.1, PostgreSQL, Redis, Sidekiq, Docker