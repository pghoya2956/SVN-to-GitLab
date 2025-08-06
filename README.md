# SVN to GitLab Migration Tool

SVN 저장소를 GitLab으로 완벽하게 마이그레이션하는 웹 기반 도구입니다. git-svn을 사용하여 전체 커밋 이력을 보존합니다.

## 🎯 주요 기능

### 핵심 기능
- **완전한 이력 보존**: git-svn을 사용한 모든 커밋, 브랜치, 태그 마이그레이션
- **재개 가능한 마이그레이션**: 대용량 저장소를 위한 체크포인트 시스템
- **실시간 진행률 모니터링**: ActionCable WebSocket 기반 실시간 업데이트
- **SVN 구조 자동 감지**: 표준/비표준 레이아웃 자동 인식
- **Authors 매핑**: SVN 사용자를 Git 이메일로 자동 매핑
- **증분 동기화**: 초기 마이그레이션 후 변경사항 지속 동기화

### 마이그레이션 모드
- **Full History 모드**: 전체 커밋 이력 보존 (git svn clone --stdlayout)
- **Simple 모드**: 최신 리비전만 마이그레이션 (빠른 처리)

## 🚀 빠른 시작

### 사전 요구사항
- Docker Desktop 20.10+
- Docker Compose 2.0+
- 4GB+ RAM
- 20GB+ 여유 디스크 공간

### 설치 및 실행

```bash
# 1. 프로젝트 클론
git clone https://github.com/your-org/svn_to_gitlab.git
cd svn_to_gitlab

# 2. 환경 변수 설정
cat > .env << EOF
RAILS_ENV=development
RAILS_MASTER_KEY=your_master_key_here
EOF

# 3. 볼륨 초기화 (첫 실행 시)
./scripts/init_volumes.sh

# 4. 초기 설정 (Docker 이미지 빌드, DB 생성)
bin/setup

# 5. 서비스 시작
docker compose up

# 6. 웹 브라우저에서 접속
open http://localhost:3000
```

### 첫 마이그레이션

1. **GitLab 토큰 등록**
   - GitLab 개인 액세스 토큰 생성 (api, write_repository 권한 필요)
   - 시스템에 토큰 등록

2. **SVN 저장소 추가**
   - SVN URL 입력 (예: https://svn.apache.org/repos/asf/commons/proper/lang/trunk)
   - 인증 정보 입력 (필요한 경우)
   - SVN 구조 감지 실행

3. **Authors 매핑 설정**
   - 자동 감지된 Authors 확인
   - 이메일 주소 매핑 편집
   - 도메인 일괄 적용 가능

4. **마이그레이션 시작**
   - GitLab 대상 프로젝트 선택
   - 마이그레이션 모드 선택
   - 실시간 진행률 모니터링

## 💻 개발

### 주요 명령어

```bash
# 컨테이너 상태 확인
docker compose ps

# Rails 콘솔
docker compose run --rm web rails console

# 데이터베이스 마이그레이션
docker compose run --rm web rails db:migrate

# 로그 확인
docker compose logs -f web       # Rails 로그
docker compose logs -f sidekiq   # 백그라운드 작업 로그

# 테스트 실행
docker compose run --rm -e RAILS_ENV=test web rails test
./scripts/run_e2e_tests.sh      # E2E 테스트

# 데이터베이스 초기화
docker compose run --rm web rails db:reset
```

### 프로젝트 구조

```
svn_to_gitlab/
├── app/
│   ├── controllers/     # 웹 컨트롤러
│   ├── jobs/            # Sidekiq 백그라운드 작업
│   ├── services/        # 비즈니스 로직
│   └── channels/        # WebSocket 채널
├── config/              # Rails 설정
├── db/                  # 데이터베이스 스키마
├── docker-compose.yml   # Docker 설정
├── git_repos/          # 변환된 Git 저장소 (영구 저장)
└── docs/               # 프로젝트 문서
```

## 📚 문서

**[📖 문서 읽기 가이드](docs/00-README.md)** - 어디서부터 시작할지 모르겠다면 여기부터!

### 순서대로 읽기
1. [프로젝트 구조](docs/01-project-structure.md)
2. [시스템 아키텍처](docs/02-architecture.md)
3. [데이터베이스 스키마](docs/03-database-schema.md)
4. [주요 기능 및 플로우](docs/04-features-and-flows.md)
5. [Ruby/Rails 빌드 및 배포](docs/05-ruby-rails-build-deploy.md)
6. [Docker 볼륨 매핑](docs/06-docker-volume-mapping.md)
7. [DB, Redis, Sidekiq 상호작용](docs/07-db-redis-sidekiq-interaction.md)
8. [Redis, Sidekiq, Nginx 설명](docs/08-redis-sidekiq-nginx-explanation.md)
9. [회복 탄력성](docs/09-resilience-and-recovery.md)
10. [배포 및 운영 가이드](docs/10-deployment-operations-guide.md)

## 🔧 설정

### 환경 변수

```bash
# .env 파일
RAILS_ENV=development                    # 환경 (development/production)
RAILS_MASTER_KEY=your_key_here          # Rails 마스터 키
DATABASE_URL=postgresql://...           # 데이터베이스 연결
REDIS_URL=redis://redis:6379/0         # Redis 연결
GITLAB_API_ENDPOINT=https://gitlab.com/api/v4  # GitLab API 엔드포인트
```

### Docker 볼륨 (로컬 디렉토리 매핑)

모든 데이터는 `docker_volumes/` 폴더에서 직접 확인 가능:

- `./docker_volumes/postgres`: PostgreSQL 데이터
- `./docker_volumes/redis`: Redis 데이터 (dump.rdb, appendonly.aof)
- `./docker_volumes/bundle`: Ruby gem 캐시
- `./git_repos`: 변환된 Git 저장소 (영구 보관)

## 🐛 문제 해결

### 일반적인 문제

**Docker 관련 오류**
```bash
# Docker Desktop이 실행 중인지 확인
docker version

# 컨테이너 재시작
docker compose restart
```

**데이터베이스 오류**
```bash
# 데이터베이스 초기화
docker compose down -v
docker compose up -d db
docker compose run --rm web rails db:create db:migrate
```

**메모리 부족**
```bash
# Docker Desktop 메모리 할당 증가 (Settings > Resources)
# 권장: 4GB 이상
```

**Git-SVN 오류**
```bash
# git-svn 설치 확인
docker compose exec web git svn --version

# Authors 파일 형식 확인
docker compose exec web cat /tmp/authors_files/1_authors.txt
```

### 로그 확인

```bash
# 전체 로그
docker compose logs

# 특정 서비스 로그
docker compose logs web
docker compose logs sidekiq

# 실시간 로그
docker compose logs -f --tail=100
```

## 🧪 테스트

### 테스트 SVN 저장소 (공개)

1. **소규모** (~50MB)
   - https://svn.code.sf.net/p/svnbook/source/trunk

2. **중규모** (~200MB)
   - https://svn.apache.org/repos/asf/commons/proper/collections/trunk

3. **대규모** (2GB+)
   - https://svn.apache.org/repos/asf/subversion/trunk

### 테스트 실행

```bash
# 단위 테스트
docker compose run --rm -e RAILS_ENV=test web rails test

# 통합 테스트
./scripts/run_integration_tests.sh

# E2E 테스트 (Playwright)
./scripts/run_e2e_tests.sh
```

## 📊 모니터링

### Sidekiq 대시보드
```ruby
# Rails 콘솔에서
docker compose exec web rails c
> Sidekiq::Queue.all.map { |q| [q.name, q.size] }
> Sidekiq::Workers.new.size  # 실행 중인 작업
```

### 시스템 리소스
```bash
# Docker 리소스 사용량
docker stats

# 디스크 사용량
du -sh git_repos/
```

## 🤝 기여

버그 리포트와 기능 제안은 GitHub Issues를 통해 제출해 주세요.

## 📝 라이선스

MIT License

## 🔗 관련 링크

- [GitLab API 문서](https://docs.gitlab.com/ee/api/)
- [git-svn 문서](https://git-scm.com/docs/git-svn)
- [Rails 가이드](https://guides.rubyonrails.org/)
- [Sidekiq 문서](https://github.com/sidekiq/sidekiq/wiki)

## ⚙️ 기술 스택

- **Backend**: Ruby 3.2, Rails 7.1
- **Frontend**: Turbo, Stimulus.js, Bootstrap 5, Chart.js
- **Database**: PostgreSQL 15
- **Cache/Queue**: Redis 7
- **Background Jobs**: Sidekiq 7.2
- **Real-time**: ActionCable (WebSocket)
- **Container**: Docker, Docker Compose
- **VCS Tools**: git-svn, git-lfs